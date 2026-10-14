#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bind the current board's finite P1 gameplay regression to actual receipts."""
import csv
import hashlib
import json
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prefix_equal(prefix, full):
    with prefix.open('rb') as a, full.open('rb') as b:
        while chunk := a.read(1024 * 1024):
            if chunk != b.read(len(chunk)):
                return False
    return True


def input_reads(path):
    result = {}
    with path.open(newline='') as stream:
        for row in csv.DictReader(stream):
            if row['kind'] != 'in':
                continue
            port = str(int(row['address']) & 7)
            value = str(int(row['data']))
            result.setdefault(port, {}).setdefault(value, 0)
            result[port][value] += 1
    return result


def main():
    check = Path('_checks/current-gameplay-1201-20261010')
    receipt_path = check / 'terminal.json'
    receipt = json.loads(receipt_path.read_text(encoding='utf-8-sig'))
    assert receipt['exit_code'] == 0 and receipt['frames_requested'] == 1201
    assert not receipt['source_changed_during_run']
    assert sha(Path(receipt['model'])) == receipt['model_sha256']
    assert sha(Path(receipt['inputs'])) == receipt['inputs_sha256']
    boot = Path('_checks/current-board-boot-20261010')
    baseline = json.loads((boot / 'terminal.json').read_text(encoding='utf-8-sig'))
    assert baseline['source_sha256'] == receipt['source_sha256']
    for name, digest in receipt['source_sha256'].items():
        assert sha(Path(name)) == digest == sha(boot / 'sources' / name)
    native = Path(receipt['runtime_output'])
    mame = Path('sim/results/current-gameplay-1201-mame-20261010')
    mame_exit = json.loads((mame / 'exit.json').read_text(encoding='utf-8-sig'))
    assert mame_exit['exit_code'] == 0 and mame_exit['frames_requested'] == 1201
    assert mame_exit['lua_sha256'].lower() == sha(Path('sim/mame_capture.lua'))
    assert mame_exit['launcher_sha256'].lower() == sha(Path('tools/mame_capture.ps1'))
    mame_exe = Path('D:/Arcade/AI/mameexe/mame.exe')
    mame_exe_sha = sha(mame_exe)
    assert mame_exe_sha == 'af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3'
    features = json.loads((mame / 'input_sha256.json').read_text(encoding='utf-8-sig'))
    assert features['Hash'].lower() == receipt['inputs_sha256']
    comparison_path = check / 'video-comparison.json'
    comparison = json.loads(comparison_path.read_text())
    expected_fields = [1, 2, 3, 4] + list(range(60, 1201, 60)) + [1201]
    assert [c['frame'] for c in comparison['checks']] == expected_fields
    assert comparison['reference_uses_fpga_ram_or_pixels'] is False
    previous = Path('sim/results/physical-cpu-restart-corners-rtl-20261009')
    prefixes = {name: {'bytes': (native / name).stat().st_size,
                       'sha256': sha(native / name),
                       'identical_prefix_of_saved_cb67879': prefix_equal(native / name, previous / name)}
                for name in ('io.csv', 'memory_writes.bin', 'sound.csv')}
    result = {
        'scope': 'Current bare board cold boot, coin/P1 start and frozen movement/aim/fire stimulus through field1201; 25 exported RGB fields.',
        'native_receipt': receipt, 'mame_receipt': mame_exit,
        'mame_producer': {'version': '0.289', 'exe_sha256': mame_exe_sha,
            'observer_sha256': sha(Path('sim/mame_capture.lua')),
            'stream_sha256': {name: sha(mame / name) for name in ('io.csv', 'video_writes.csv', 'audio.wav')}},
        'source_closure_verified': True,
        'timed_MAME_scanout': comparison,
        'same_side_against_saved_cb67879': prefixes,
        'observed_input_reads': {'native': input_reads(native / 'io.csv'), 'mame': input_reads(mame / 'io.csv')},
        'scoped_regression_qualified': comparison['total_mismatch_pixels'] == 0
            and all(p['identical_prefix_of_saved_cb67879'] for p in prefixes.values()),
        'evidence_sha256': {p.as_posix(): sha(p) for p in [Path(__file__), receipt_path,
            mame / 'exit.json', comparison_path, check / 'run.log']},
        'limitations': ['Stored timed-reference regression, not admitted all-domain live MAME lockstep.',
            'Only exported native fields compared; intermediate images and audio waveforms unqualified.',
            'Full-wrapper hostile power-up failure, HPS gameplay and persistence remain open.',
            'P2/cocktail, all scoring/death/round/bonus/game-over/restart corners are not covered by this finite P1 scenario.',
            'Physical RAM/READY/serializer and absolute CPU/raster phase remain open.',
            'Saved-source field2760 pixel remains unresolved; current source has not reached that corner.',
            'Current fit/STA/resource qualification requires the registered Sheriff preassembly recipe.'],
        'full_gameplay_gate_qualified': False, 'release_qualified': False, 'rbf_built': False}
    output = Path('docs/evidence/sheriff_current_gameplay.json')
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'native_exit': receipt['exit_code'], 'mame_exit': mame_exit['exit_code'],
        'captured_fields': expected_fields, 'pixel_differences': comparison['total_mismatch_pixels'],
        'same_side_prefixes': {n: p['identical_prefix_of_saved_cb67879'] for n, p in prefixes.items()},
        'scoped_regression_qualified': result['scoped_regression_qualified'], 'report': output.as_posix()}))


if __name__ == '__main__':
    main()
