#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record file fidelity of the leading MAME reference; retain unknown runtime exit."""
import csv
import hashlib
import json
import subprocess
from decimal import Decimal
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    root = Path('_checks/physical-cpu-prior-vblank-20261009')
    new = Path('sim/results/prior-vblank-2758-mame-20261009')
    old = Path('sim/results/pixel-2760-irq-before-mame')
    runtime = json.loads((root / 'mame-result.json').read_text(encoding='utf-8-sig'))
    assert runtime['exit_code'] is None  # Preserve the actual observer limitation.
    checks = []
    for name in ('io.csv', 'video_writes.csv'):
        size = 0
        with (new / name).open('rb') as f, (old / name).open('rb') as g:
            while block := f.read(1 << 20):
                assert block == g.read(len(block)), f'Changed reference prefix: {name} at {size}'
                size += len(block)
        checks.append({'file': name, 'byte_prefix_equal': True, 'checked_bytes': size})
    with (new / 'irq_program_reads.csv').open() as f:
        all_new = list(csv.DictReader(f))
    with (old / 'irq_program_reads.csv').open() as f:
        overlap_old = [r for r in csv.DictReader(f) if r['frame'] == '2758']
    overlap_new = [r for r in all_new if r['frame'] == '2758']
    assert overlap_new == overlap_old and len(overlap_new) == 6730
    edge = 2_259_353_600
    nearby = [r for r in all_new if edge - 1000 < Decimal(r['time']) * 50_400_000 <= edge]
    assert nearby
    metadata = json.loads((new / 'capture_features.json').read_text(encoding='utf-8-sig'))
    input_sha = json.loads((new / 'input_sha256.json').read_text(encoding='utf-8-sig'))['Hash'].lower()
    assert input_sha == '15e27f7747d95c53762259b136b7b8aeff7e8a7c24dcf75ac81edad85456db3d'
    smoke = Path('_checks/mame-exit-observer-20261009')
    smoke_exit = json.loads((smoke / 'capture/exit.json').read_text(encoding='utf-8-sig'))
    assert smoke_exit['exit_code'] == 0 and smoke_exit['frames_requested'] == 3
    assert smoke_exit['launcher_sha256'].lower() == sha('tools/mame_capture.ps1')
    version = subprocess.run([runtime['mame_exe'], '-help'], capture_output=True, text=True,
                             creationflags=subprocess.CREATE_NO_WINDOW)
    assert version.returncode == 0 and '0.289' in version.stdout.splitlines()[0]
    (root / 'mame-version.txt').write_text(version.stdout.splitlines()[0] + '\n', encoding='utf-8')
    files = [new / 'io.csv', new / 'video_writes.csv', new / 'irq_program_reads.csv',
             new / 'input_sha256.json', new / 'capture_features.json', root / 'mame-result.json',
             smoke / 'capture/exit.json', smoke / 'receipt.json', Path('tools/mame_capture.ps1'), Path(__file__)]
    report = {
        'scope': 'Leading MAME 0.289 opcode reference file fidelity and separate exit-observer smoke',
        'MAME_version': version.stdout.splitlines()[0],
        'capture_runtime': runtime,
        'capture_runtime_qualified': False,
        'file_prefix_checks': checks,
        'overlapping_frame': 2758, 'overlapping_ROM_reads': 6730,
        'overlapping_ROM_reads_exact': True,
        'leading_frame': 2757, 'IRQ_edge_master_tick': edge,
        'MAME_program_accesses_before_IRQ': [
            {'address': int(r['address']), 'PC_after_access': int(r['pc']), 'cpu_time': r['time']}
            for r in nearby],
        'capture_features': metadata, 'frozen_input_sha256': input_sha,
        'exit_observer_fix_smoke': {'frames': 3, 'actual_exit_code': 0,
                                    'receipt': str(smoke / 'capture/exit.json')},
        'file_sha256': {p.as_posix(): sha(p) for p in files},
        'strict_graphics_gate_pass': False,
        'limits': ['The 2759-field capture watcher returned null ExitCode; it is not a verified runtime pass.',
                   'Exact file prefixes and overlapping reads establish preserved reference transactions, not hardware timing.',
                   'The corrected original-handle WaitForExit option is separately verified on three frames only; it does not retroactively supply the old exit code.',
                   'Native leading-window replay, upstream IRQ phase and remaining pixel comparison are pending. Quartus remains on hold.'],
    }
    out = Path('docs/evidence/sheriff_prior_vblank_reference.json')
    out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'prefix_equal': True, 'overlap_reads': 6730,
                      'pre_IRQ_accesses': len(nearby), 'capture_runtime_exit': None,
                      'separate_exit_smoke': 0, 'MAME_version': report['MAME_version']}))


if __name__ == '__main__':
    main()
