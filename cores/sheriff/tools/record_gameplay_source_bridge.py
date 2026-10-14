#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bind saved real gameplay to the unchanged current main-board projection."""
import csv
import hashlib
import json
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    check = Path('_checks/gameplay-source-bridge-20261010')
    check.mkdir(exist_ok=False)
    reference_path = Path('docs/evidence/sheriff_clock_restart6780.json')
    reference = json.loads(reference_path.read_text())
    assert reference['terminal']['exit_code'] == 0
    model = reference['model_provenance']
    revision = model['revision']
    old = subprocess.check_output(['git', 'show', revision+':rtl/n8080_board.sv'])
    old = old.replace(b'\r\n', b'\n')
    current = Path('rtl/n8080_board.sv').read_bytes().replace(b'\r\n', b'\n')
    assert current.count(b'input wire clk, reset, pause, flip_screen,') == 1
    assert current.count(b'{8{flip ^ flip_screen}}') == 2
    specialized = current.replace(b'input wire clk, reset, pause, flip_screen,',
                                  b'input wire clk, reset, pause,')
    specialized = specialized.replace(b'{8{flip ^ flip_screen}}', b'{8{flip}}')
    assert specialized == old, 'Another board change prevents source projection reuse'
    for path in ['rtl/n8080_cpu.sv', 'rtl/n8080_vm80a_ce.v']:
        assert sha(path) == model['source_sha256'][path].lower(), path
    for key, hashkey in [('inputs', 'inputs_sha256'), ('executable', 'executable_sha256')]:
        assert sha(reference['terminal'][key]) == reference['terminal'][hashkey].lower()
    (check/'frozen_board.sv').write_bytes(old)
    (check/'current_board_user_flip_off.sv').write_bytes(specialized)
    native = Path(reference['terminal']['output'])
    frames = [600, 780, 1200, 1800, 2400, 2700, 2760, 3300, 3900, 4800, 6000, 6780]
    sheet = Image.new('RGB', (3*256, 4*248), '#303030')
    draw = ImageDraw.Draw(sheet)
    observations, artifacts = [], []
    for index, frame in enumerate(frames):
        stem = native/f'frame_{frame:05d}'
        image_path, ram_path, state_path = [stem.with_suffix(s) for s in ['.ppm', '.ram', '.state']]
        im = Image.open(image_path).convert('RGB')
        assert im.size == (256, 224)
        x, y = (index % 3)*256, (index//3)*248
        sheet.paste(im, (x, y+24))
        draw.text((x+4, y+5), f'native field {frame}', fill='white')
        ram = ram_path.read_bytes()
        assert len(ram) == 16384
        observations.append({'field': frame, 'state': state_path.read_text().strip(),
                             'ram_6000_603f_hex': ram[0x2000:0x2040].hex(),
                             'image': image_path.as_posix()})
        artifacts.extend([image_path, ram_path, state_path])
    sheet_path = check/'native-lifecycle-checkpoints.png'
    sheet.save(sheet_path)
    rows = list(csv.DictReader(Path(reference['terminal']['inputs']).open()))
    edges = [row for index, row in enumerate(rows) if (int(row['p2'])&0x8c) !=
             ((int(rows[index-1]['p2'])&0x8c) if index else 0)]
    out = {
        'scope': 'Source bridge for the unchanged main-board projection with user flip disabled; saved gameplay checkpoint overview, not final current full-wrapper/whole-audio/graphics qualification.',
        'saved_native_terminal': reference['terminal'],
        'frozen_revision': revision,
        'current_main_board_user_flip_off_equals_frozen_board': True,
        'unchanged_main_CPU_kernels': ['rtl/n8080_cpu.sv', 'rtl/n8080_vm80a_ce.v'],
        'source_bridge_assumption': 'flip_screen=0; the only board changes are the input and its two scanout coordinate XORs. Sound implementation/gain and framework are outside this main-board projection claim.',
        'input_event_count': len(rows), 'coin_start_edges': edges,
        'checkpoint_observations': observations,
        'contact_sheet': sheet_path.as_posix(),
        'source_sha256': {p.as_posix(): sha(p) for p in [Path(__file__), reference_path,
                         Path('rtl/n8080_board.sv'), Path('rtl/n8080_cpu.sv'), Path('rtl/n8080_vm80a_ce.v')]},
        'evidence_sha256': {p.as_posix(): sha(p) for p in [*artifacts, sheet_path,
                             check/'frozen_board.sv', check/'current_board_user_flip_off.sv']},
        'native_simulation_rerun': False,
        'complete_gameplay_gate_pass': False, 'strict_graphics_gate_pass': False,
        'limits': ['Main source projection reuse does not qualify changed sound or current complete wrapper.',
                   'HUD lifecycle observations require inspection and independent reference context; CPU activity alone does not prove all game events.',
                   'The saved field2760 pixel mismatch and physical raster/DRAM/READY/serializer remain open.',
                   'No new synthesis/fit/STA/resource report or RBF follows.'],
    }
    output = Path('docs/evidence/sheriff_gameplay_source_bridge.json')
    output.write_text(json.dumps(out, indent=2)+'\n')
    print(json.dumps({'report': output.as_posix(), 'source_projection_equal': True,
                      'fields': frames, 'contact_sheet': sheet_path.as_posix(),
                      'coin_start_edges': edges}))


if __name__ == '__main__':
    main()
