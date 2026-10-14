#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Retain the original/fixed real-CPU pause test and score-service regression."""
import csv
import json
from pathlib import Path
from record_current_gameplay import sha


def main():
    root = Path('_checks/hiscore-powerup-qualification-20261010')
    receipt = json.loads((root / 'receipt.json').read_text(encoding='utf-8-sig'))
    restore = json.loads((root / 'restore-receipt.json').read_text())
    assert receipt['exit_code'] == restore['exit_code'] == 0
    vendor = Path('rtl/vendor/hiscore/hiscore.v')
    assert vendor.read_bytes() == (root / 'hiscore_fixed.v').read_bytes()
    original = (root / 'hiscore_original.v').read_bytes()
    assert original.replace(b'pause_cpu,', b"pause_cpu = 1'b0,", 1) == vendor.read_bytes()
    logs = {}
    for variant, expected in [('original', 1), ('fixed', 0)]:
        assert int((root / f'exit-{variant}.txt').read_text()) == expected
        logs[variant] = (root / f'run-{variant}.log').read_text().strip()
    assert 'paused=1 configured=0 phase_updates=0' in logs['original']
    assert 'paused=0 configured=0 phase_updates=800' in logs['fixed']
    assert 'PASS production Sheriff config' in (root / 'restore.stdout.log').read_text()
    probe = Path('_checks/hiscore-pause-probe-20261010')
    probe_receipt = json.loads((probe / 'cases-terminal.json').read_text())
    assert probe_receipt['exit_code'] == 0
    snapshots = {}
    for case in probe_receipt['cases']:
        assert case['exit_code'] == 0
        with (probe / case['label'] / 'reset_timeline.csv').open(newline='') as stream:
            snapshots[case['label']] = list(csv.DictReader(stream))[-1]
    assert int(snapshots['initial-hs1']['phase_updates_after_rom_loaded']) == 0
    assert int(snapshots['initial-hs0']['phase_updates_after_rom_loaded']) > 0
    paths = [vendor, Path(__file__), root / 'receipt.json', root / 'restore-receipt.json',
             root / 'harness.cpp', root / 'hiscore_powerup_tb.sv', root / 'run.sh',
             root / 'hiscore_original.v', root / 'hiscore_fixed.v',
             root / 'run-original.log', root / 'run-fixed.log', root / 'restore.stdout.log',
             Path('sim/hiscore_qualification.cpp'), Path('sim/results/mra/sheriff_hiscore.cfg'),
             probe / 'cases-terminal.json', probe / 'build-receipt.json']
    paths += [probe / label / 'reset_timeline.csv' for label in snapshots]
    report = dict(scope='Idle hiscore CPU-pause power-up initialization and production score-service regression.',
                  change="Initialize pause_cpu to 1'b0; active restore/extract pause logic unchanged.",
                  qualification_receipt=receipt, real_cpu_test_logs=logs,
                  restore_receipt=restore, retained_kernel_snapshots=snapshots,
                  evidence_sha256={p.as_posix(): sha(p) for p in paths},
                  scoped_fix_qualified=True,
                  limitations=['Original post_reset_reads=600 counts a stuck level, not CPU transactions.',
                               'Retained-kernel baseline does not reproduce the original hostile black boot.',
                               'Original Preflight F-001/F-002 and full current wrapper qualification remain open.',
                               'Modified wrapper source still requires current fit/STA/resource reports.'],
                  original_preflight_failure_resolved=False, release_qualified=False, rbf_built=False)
    output = Path('docs/evidence/sheriff_hiscore_powerup.json')
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(scoped_fix_qualified=True, restore_exit=0, report=output.as_posix())))


if __name__ == '__main__':
    main()
