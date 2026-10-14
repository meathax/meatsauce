#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Retain actual wrapper input observations without qualifying unseen gameplay."""
import csv
import hashlib
import io
import json
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[1]
probe = root / '_checks/preflight-inputs-20261009/probe-routed'
run = probe / 'sim/board-s1-routed'
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
# Snapshot only complete lines; a live writer's trailing partial row is not evidence.
raw = (run / 'input_probe.csv').read_bytes().rsplit(b'\n', 1)[0] + b'\n'
snapshot = probe / 'input_probe.snapshot.csv'
snapshot.write_bytes(raw)
rows = list(csv.DictReader(io.StringIO(raw.decode())))
rom = (root / 'roms/sheriff.bin').read_bytes()
decoded = []
for row in rows:
    if row['kind'] != 'cpu_io_read':
        continue
    pc = int(row['pc'])
    if 2 <= pc <= 0x4000 and rom[pc - 2] == 0xdb:
        decoded.append({'ns': int(row['ns']), 'joy0': int(row['joy0']),
                        'port': rom[pc - 1], 'data': int(row['din']),
                        'pc': pc, 'paused': int(row['paused'])})
reference = root / 'sim/results/wrapper-inputs-mame-20261009'
reference_reads = [r for r in csv.DictReader((reference / 'io.csv').open()) if r['kind'] == 'in']
windows = [('early_coin', 40, 46, 128, 2, 128),
           ('early_start', 100, 106, 32, 2, 4),
           ('late_coin', 600, 605, 128, 2, 128),
           ('late_start', 690, 730, 32, 2, 4),
           ('movement_aim', 740, 760, 0x911, 0, 145),
           ('fire', 740, 760, 0x911, 2, 1)]
checks = []
joystick_edges = [r for r in rows if r['kind'] == 'joystick']
for name, first, last, joy, port, data in windows:
    native = [r for r in decoded if r['joy0'] == joy and r['port'] == port and r['data'] == data]
    # Use observed joystick edges, not an assumed CPU/frame phase.
    matching_edges = [i for i, r in enumerate(joystick_edges) if int(r['joy0']) == joy]
    occurrence = 1 if name.startswith('late_') else 0
    if len(matching_edges) > occurrence:
        index = matching_edges[occurrence]
        begin = int(joystick_edges[index]['ns'])
        end = (int(joystick_edges[index + 1]['ns'])
               if index + 1 < len(joystick_edges) else int(rows[-1]['ns']) + 1)
        native = [r for r in native if begin <= r['ns'] < end]
    else:
        native = []
    mame = [r for r in reference_reads if first <= int(r['frame']) < last
            and int(r['address']) == port and int(r['data']) == data]
    checks.append({'action': name, 'port': port, 'expected_data': data,
                   'native_read_count': len(native), 'native_first': native[:1],
                   'native_last': native[-1:], 'mame_read_count': len(mame)})
terminal = probe / 'replay-result.json'
receipt = json.loads((probe / 'receipt.json').read_text())
for name, digest in receipt['generated_sources_sha256'].items():
    assert sha(probe / 'cache/obj' / name) == digest, name
report = {
    'scope': 'Ordinary HPS CPU input reads and named static video fields in one saved full-wrapper model',
    'saved_source_hash': receipt['saved_source_hash'],
    'binary_sha256': sha(probe / 'cache/obj/pfsim.exe'),
    'snapshot': str(snapshot.relative_to(root)), 'snapshot_sha256': sha(snapshot),
    'snapshot_end_ns': int(rows[-1]['ns']), 'decoded_reads': len(decoded),
    'decode': 'Observed real CPU DBIN rising edges with IN status; local parent ROM confirms IN opcode at observed PC minus two and identifies its port. No ROM bytes exported.',
    'checks': checks, 'terminal': terminal.exists(),
    'terminal_result': json.loads(terminal.read_text()) if terminal.exists() else None,
    'reference_io_sha256': sha(reference / 'io.csv'),
    'input_fixture_sha256': sha(root / 'sim/inputs_wrapper_probe.csv'),
    'recovery': str(probe.relative_to(root)),
    'all_scheduled_inputs_observed': all(r['native_read_count'] and r['mame_read_count'] for r in checks),
    'coin_start_path_observed': all(r['native_read_count'] and r['mame_read_count']
                                    for r in checks if 'coin' in r['action'] or 'start' in r['action']),
    'complete_sheriff': False, 'rtl_changed': False, 'state_forced': False,
    'quartus_used': False,
    'limits': 'A partial snapshot cannot prove later actions. Named static-field comparisons qualify only those scenes. Subsequent gameplay, complete graphics, analog audio and release gates remain open. MAME process exit code was not retained.',
}
# One static credited waiting-for-start field exercises the full wrapper's
# download/reset/control/video path. It does not replace moving-field scanout tests.
for frame, key, scope in (
    (360, 'static_credited_field', 'One static PUSH ONLY 1 PLAYER BUTTON field after the early coin.'),
    (720, 'static_started_field', 'One static GET READY field after the later Start 1 event.'),
):
    native_file = run / f'frames/r{frame:06d}.raw'
    mame_file = reference / f'frame_{frame:05d}.idx32'
    if not native_file.exists() or not mame_file.exists():
        continue
    frame_rows = [json.loads(s) for s in (run / 'frames.jsonl').read_text().splitlines()
                  if s.endswith('}')]
    metadata = next(r for r in frame_rows if r['frame'] == frame)
    header, pixels = native_file.read_bytes().split(b'\n', 1)
    magic, width, height = header.decode().split()
    width, height = int(width), int(height)
    assert magic == 'PF4' and len(pixels) == width * height * 4
    x, y = metadata['de_x_min'], metadata['de_first_line']
    w, h = metadata['de_w_min'], metadata['de_rows']
    assert (w, h) == (256, 224) and x + w <= width and y + h <= height
    native_rgb = bytes(c for row in range(y, y + h) for col in range(x, x + w)
                       for c in pixels[(row * width + col) * 4:(row * width + col) * 4 + 3])
    argb = mame_file.read_bytes()
    assert len(argb) == w * h * 4
    mame_rgb = bytes(c for (v,) in struct.iter_unpack('<I', argb)
                     for c in ((v >> 16) & 255, (v >> 8) & 255, v & 255))
    differences = sum(native_rgb[i:i + 3] != mame_rgb[i:i + 3]
                      for i in range(0, len(native_rgb), 3))
    report[key] = {
        'field': frame, 'pixels': w * h, 'different_pixels': differences,
        'exact': differences == 0, 'native_de_crop': [x, y, w, h],
        'native_file': str(native_file.relative_to(root)), 'native_sha256': sha(native_file),
        'reference_file': str(mame_file.relative_to(root)), 'reference_sha256': sha(mame_file),
        'rgb_sha256': hashlib.sha256(native_rgb).hexdigest(),
        'scope': scope + ' No color tolerance, pixel mask or fitted translation. This does not qualify subsequent gameplay or all graphics.',
    }
target = root / 'docs/evidence/sheriff_wrapper_inputs.json'
target.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'snapshot_end_ms': report['snapshot_end_ns'] / 1e6,
                  'terminal': report['terminal'],
                  'static_credited_field': report.get('static_credited_field'),
                  'static_started_field': report.get('static_started_field'),
                  'checks': [{k: r[k] for k in ('action', 'native_read_count', 'mame_read_count')} for r in checks]}))
