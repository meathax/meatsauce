#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Qualify saved P1 lifecycle observations; keep graphics/round gaps explicit."""
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageDraw


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    bridge_path = Path('docs/evidence/sheriff_gameplay_source_bridge.json')
    bridge = json.loads(bridge_path.read_text())
    for group in ['source_sha256', 'evidence_sha256']:
        for path, digest in bridge[group].items():
            assert sha(path) == digest, path
    assert bridge['current_main_board_user_flip_off_equals_frozen_board']
    assert bridge['saved_native_terminal']['exit_code'] == 0
    native = Path(bridge['saved_native_terminal']['output'])
    reference = Path('sim/results/restart-mame')
    artifacts, shared, negatives = [], [], []
    difference_addresses = {}
    for nram in sorted(native.glob('frame_*.ram')):
        mram = reference/nram.name
        if not mram.exists():
            continue
        nbytes, mbytes = nram.read_bytes(), mram.read_bytes()
        assert len(nbytes) == len(mbytes) == 16384
        frame = int(nram.stem.split('_')[1])
        state_equal = nbytes[0x2000:0x2040] == mbytes[0x2000:0x2040]
        differences = [0x4000+i for i, (n, m) in enumerate(zip(nbytes, mbytes)) if n != m]
        for address in differences:
            difference_addresses[address] = difference_addresses.get(address, 0)+1
        row = {'field': frame, 'control_RAM_6000_603f_equal': state_equal,
               'full_RAM_difference_bytes': len(differences),
               'full_RAM_difference_addresses_first16': differences[:16]}
        shared.append(row)
        if differences:
            negatives.append(row)
        artifacts.extend([nram, mram])
    assert shared
    visual_fields = [600, 780, 1200, 1800, 2400, 2760, 3900, 4800, 6060, 6780]
    selected = {row['field']: row for row in shared}
    assert all(selected[frame]['control_RAM_6000_603f_equal'] for frame in visual_fields)
    # Rotation is for readable inspection only; comparisons use untouched RAM/images.
    sheet = Image.new('RGB', (5*224, 2*280), '#303030')
    draw = ImageDraw.Draw(sheet)
    for index, frame in enumerate(visual_fields):
        path = native/f'frame_{frame:05d}.ppm'
        im = Image.open(path).convert('RGB').transpose(Image.Transpose.ROTATE_90)
        assert im.size == (224, 256)
        x, y = (index % 5)*224, (index//5)*280
        sheet.paste(im, (x, y+24))
        draw.text((x+4, y+5), f'native field {frame}', fill='white')
        artifacts.append(path)
    sheet_path = Path('_checks/gameplay-source-bridge-20261010/native-lifecycle-upright.png')
    sheet.save(sheet_path)
    report = {
        'scope': 'Saved genuine P1 main-CPU lifecycle and exact selected control-RAM reference matches, bridged to current main-board source with user flip off; not current complete-wrapper/audio/graphics qualification.',
        'source_bridge': bridge_path.as_posix(),
        'native_terminal': bridge['saved_native_terminal'],
        'reference_capture': reference.as_posix(),
        'shared_snapshots': len(shared),
        'control_RAM_6000_603f_equal_snapshots': sum(row['control_RAM_6000_603f_equal'] for row in shared),
        'full_RAM_equal_snapshots': sum(row['full_RAM_difference_bytes'] == 0 for row in shared),
        'snapshot_comparisons': shared,
        'full_RAM_negatives_retained': negatives,
        'selected_visual_fields': visual_fields,
        'upright_inspection_sheet': sheet_path.as_posix(),
        'inspection_transform': 'Lossless 90-degree counterclockwise rotation for readable ROM-rendered HUD only.',
        'visual_review': {
            'method': 'Read ROM-rendered native HUD in the lossless upright sheet; no OCR/golden-image substitution.',
            'attract': {'field': 600, 'text': 'INSERT COIN', 'credit': '00'},
            'start': {'field': 780, 'text': 'GET READY'},
            'scores': {'1200': '0000', '1800': '0030', '2400': '0060',
                       '2760': '0090', '3900': '0210', '4800': '0210'},
            'remaining_players_lives': {'1200': 3, '1800': 3, '2400': 2,
                                       '2760': 2, '3900': 2, '4800': 1},
            'game_over': {'field': 6060, 'text': 'GAME OVER', 'score': '0330',
                          'remaining': 0, 'high_score': '0330'},
            'restart': {'field': 6780, 'score': '0030', 'remaining': 3,
                        'high_score': '0330', 'coin_field': 6200, 'start_field': 6290},
            'transient_game_over_prefix': 'Field6000 shows only GAME O while CPU is drawing the message; full GAME OVER is present at6060 and6120.',
        },
        'all_RAM_difference_addresses': {f'{address:04x}': count for address, count in sorted(difference_addresses.items())},
        'covered_P1_main_program_events': ['attract', 'ordinary coin/start', 'score increases',
                                          'life losses', 'game over', 'ordinary coin/start restart'],
        'ordinary_coin_start_events': bridge['coin_start_edges'],
        'source_sha256': {p.as_posix(): sha(p) for p in [Path(__file__), bridge_path]},
        'evidence_sha256': {p.as_posix(): sha(p) for p in [*artifacts, sheet_path]},
        'native_simulation_rerun': False, 'RAM_or_CPU_state_forced': False,
        'complete_gameplay_gate_pass': False, 'strict_graphics_gate_pass': False,
        'limits': ['Control RAM matches do not turn other RAM/graphics differences into passes; all observed negatives are retained.',
                   'This restart input scenario does not demonstrate cleared rounds or the third-round red effect.',
                   'Current complete wrapper and changed sound path remain separately unqualified.',
                   'Do not rerun this completed lifecycle unchanged; fix the first graphics/physical timing divergence before the longer round campaign.'],
    }
    output = Path('docs/evidence/sheriff_gameplay_lifecycle.json')
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'report': output.as_posix(), 'shared_snapshots': len(shared),
                      'control_RAM_equal': report['control_RAM_6000_603f_equal_snapshots'],
                      'full_RAM_equal': report['full_RAM_equal_snapshots'],
                      'upright_sheet': sheet_path.as_posix()}))


if __name__ == '__main__':
    main()
