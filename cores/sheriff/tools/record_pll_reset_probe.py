#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record a bounded diagnostic of the retained Preflight model's reset driver."""
import csv
import hashlib
import json
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    root = Path('_checks/pll-reset-probe-20261010')
    build = json.loads((root / 'build-v5-receipt.json').read_text(encoding='utf-8-sig'))
    terminal = json.loads((root / 'cases-terminal.json').read_text())
    assert build['exit_code'] == 0 and terminal['exit_code'] == 0
    assert len(terminal['cases']) == 6
    for name, digest in build['inputs'].items():
        assert sha(Path(name)) == digest
    pairs = []
    for mode, seed in [(0, 1), (2, 1), (2, 2)]:
        paths = [root / f'paired-mode{mode}-seed{seed}-pll{forced}' for forced in (0, 1)]
        receipts = [json.loads((p / 'receipt.json').read_text()) for p in paths]
        assert all(r['exit_code'] == 0 for r in receipts)
        timeline = list(csv.DictReader((paths[0] / 'reset_timeline.csv').open()))
        assert len(timeline) == 4
        assert [int(r['time_ps']) for r in timeline] == [0, 100000000, 12034920635, 12061924603]
        assert timeline[-1]['reset_active'] == '0' and timeline[-1]['rom_loaded'] == '1'
        frame_sets = [{p.name: sha(p) for p in (directory / 'frames').glob('*.raw')}
                      for directory in paths]
        timeline_hashes = [sha(p / 'reset_timeline.csv') for p in paths]
        stdout = [(p / 'stdout.log').read_text().strip() for p in paths]
        assert all('time_ps=70000000000' in s and 'hps_ops=24' in s and 'stop=0' in s for s in stdout)
        assert timeline_hashes[0] == timeline_hashes[1] and frame_sets[0] == frame_sets[1]
        pairs.append({'rand_reset': mode, 'seed': seed, 'receipts': receipts,
            'timeline': timeline, 'timeline_sha256': timeline_hashes,
            'timelines_identical_with_initial_pll_0_or_1': True,
            'early_image_count_each': len(frame_sets[0]),
            'paired_image_hashes': frame_sets, 'paired_early_images_identical': True,
            'stdout': stdout})
    report = {'scope': '70ms diagnostic of retained Preflight compiled kernel and its real HPS download sequence; initial PLL-output perturbation only.',
        'build_receipt': build, 'cases_terminal': terminal, 'probe_exe_sha256': sha(root / 'probe.exe'),
        'pairs': pairs,
        'conclusion': 'No early lock/reset/image sensitivity to the forced initial PLL output in these six scoped cases; do not add a second driver/initial value to the production PLL output.',
        'observed_lock_time_ps': 100000000, 'observed_rom_loaded_time_ps': 12034920635,
        'observed_reset_release_time_ps': 12061924603,
        'original_hostile_failure_resolved': False,
        'limitations': ['Only70ms/24 of34 HPS operations; original120-field hostile black failure remains open.',
            'Diagnostic uses retained legacy Preflight objects and matching bundled runtime flags, not a current-source release qualification.',
            'Raw images are compared only within matched profile/seed pairs; board/hostile capture counts differ2 versus4 and are not aligned/resynchronized.',
            'Reset timeline does not qualify physical PLL behavior, absolute CPU/raster phase or all power-up states.',
            'No production RTL, sys, constraints, Quartus job, RBF or hardware deployment changed.'],
        'evidence_sha256': {p.as_posix(): sha(p) for p in [Path(__file__), root / 'probe.cpp',
            root / 'build.ps1', root / 'run_cases.py', root / 'build-v5-receipt.json', root / 'cases-terminal.json']},
        'release_qualified': False, 'rbf_built': False}
    output = Path('docs/evidence/sheriff_pll_reset_probe.json')
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'cases_exit0': 6, 'paired_timelines_identical': True,
        'lock_us': 100, 'reset_release_ms': 12.061924603, 'hps_ops_done': 24,
        'original_hostile_failure_resolved': False, 'report': output.as_posix()}))


if __name__ == '__main__':
    main()
