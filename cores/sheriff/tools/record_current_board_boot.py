#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record scoped current-board boot regression using retained native evidence."""
import hashlib
import json
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    check = Path('_checks/current-board-boot-20261010')
    receipt_path = check / 'terminal.json'
    receipt = json.loads(receipt_path.read_text(encoding='utf-8-sig'))
    assert receipt['exit_code'] == 0 and not receipt['source_changed_during_run']
    assert receipt['frames_requested'] == 106
    for name, digest in receipt['source_sha256'].items():
        assert sha(Path(name)) == digest
        assert sha(check / 'sources' / name) == digest
    assert sha(Path(receipt['inputs'])) == receipt['inputs_sha256']
    pixels_path = check / 'video-comparison.json'
    pixels = json.loads(pixels_path.read_text(encoding='utf-8'))
    assert [r['frame'] for r in pixels['checks']] == [1, 2, 3, 4, 60, 106]
    assert pixels['reference_uses_fpga_ram_or_pixels'] is False
    native = Path(receipt['runtime_output'])
    previous = Path('sim/results/physical-cpu-phase-rtl-20261009')
    same_side = {name: {'current_sha256': sha(native / name),
                        'saved_sha256': sha(previous / name),
                        'identical': sha(native / name) == sha(previous / name)}
                 for name in ('cpu_startup.csv', 'io.csv', 'memory_writes.bin', 'sound.csv')}
    model_digest = (check / 'model.sha256').read_text().split()[0]
    model = check / 'Vn8080_board'
    assert sha(model) == model_digest
    result = {
        'scope': 'Current board, factory inputs/user flip off, 106-field native boot/attract run; six captured RGB fields only.',
        'native_receipt': receipt,
        'model': {'path': model.as_posix(), 'sha256': model_digest},
        'toolchain': (check / 'toolchain.txt').read_text().splitlines()[:2],
        'source_closure_verified': True,
        'same_side_against_saved_cb67879': same_side,
        'timed_MAME_scanout': pixels,
        'scoped_regression_qualified': pixels['total_mismatch_pixels'] == 0
            and all(r['identical'] for r in same_side.values()),
        'sources': {p.as_posix(): sha(p) for p in [Path(__file__), receipt_path,
            pixels_path, check / 'model.sha256', check / 'build.log', check / 'run.log']},
        'limitations': ['Stored-reference regression, not admitted all-domain live MAME lockstep.',
            'Only six exported native RGB fields compared; no intermediate-field equivalence claim.',
            'No wrapper/HPS, user/game flip combinations, gameplay or audio waveform qualification.',
            'Physical RAM/READY/serializer and absolute CPU/raster phase remain open.',
            'Saved-source field2760 pixel remains unresolved; later current-source corners not captured.',
            'Current-source fit/STA/resources require the independently reviewed preassembly recipe.'],
        'full_graphics_gate_qualified': False, 'release_qualified': False,
        'rbf_built': False}
    output = Path('docs/evidence/sheriff_current_board_boot.json')
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'native_exit': receipt['exit_code'],
                      'source_closure_files': len(receipt['source_sha256']),
                      'same_side_identical': {n: r['identical'] for n, r in same_side.items()},
                      'captured_frames': [r['frame'] for r in pixels['checks']],
                      'pixel_differences': pixels['total_mismatch_pixels'],
                      'scoped_regression_qualified': result['scoped_regression_qualified'],
                      'evidence': output.as_posix()}))


if __name__ == '__main__':
    main()
