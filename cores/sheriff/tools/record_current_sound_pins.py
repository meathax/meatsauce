#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bind current sound-pin/DAC observations to successful frozen producers."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def main():
    native_receipt_path = Path('_checks/current-gameplay-1201-20261010/terminal.json')
    native_receipt = load(native_receipt_path)
    assert native_receipt['exit_code'] == 0 and native_receipt['frames_requested'] == 1201
    for name, digest in native_receipt['source_sha256'].items():
        assert sha(name) == digest
    assert sha(native_receipt['model']) == native_receipt['model_sha256']
    assert sha(native_receipt['inputs']) == native_receipt['inputs_sha256']
    native = Path(native_receipt['runtime_output'])
    reference = Path('sim/results/current-sound-pins-1201-mame-20261010')
    frozen_reference = Path('sim/results/current-gameplay-1201-mame-20261010')
    reference_receipt = load(reference / 'exit.json')
    assert reference_receipt['exit_code'] == 0 and reference_receipt['frames_requested'] == 1201
    features = load(reference / 'capture_features.json')
    assert features['sound_probe'] is True
    assert sha('sim/mame_capture.lua') == features['lua_sha256'].lower()
    assert sha('tools/mame_capture.ps1') == features['launcher_sha256'].lower()
    assert load(reference / 'input_sha256.json')['Hash'].lower() == native_receipt['inputs_sha256']
    unchanged = {name: sha(reference / name) == sha(frozen_reference / name)
                 for name in ('io.csv', 'audio.wav', 'states.csv')}
    assert all(unchanged.values()), 'Observer changed the frozen reference'
    check = Path('_checks/current-sound-pins-20261010')
    check.mkdir(exist_ok=False)
    report_path = check / 'pin-report.json'
    argv = [sys.executable, '-X', 'utf8', 'tools/compare_integrated_sound.py',
            '--mame', reference.as_posix(), '--rtl', native.as_posix(), '--frames', '1200',
            '--output', report_path.as_posix(), '--source-label', native_receipt['model_sha256']]
    started = datetime.now(timezone.utc).isoformat()
    with (check / 'stdout.log').open('wb') as stdout, (check / 'stderr.log').open('wb') as stderr:
        comparison = subprocess.run(argv, stdout=stdout, stderr=stderr)
    comparison_receipt = dict(exit_code=comparison.returncode, argv=argv,
                              started_utc=started, finished_utc=datetime.now(timezone.utc).isoformat())
    (check / 'receipt.json').write_text(json.dumps(comparison_receipt, indent=2) + '\n')
    pin_report = load(report_path) if report_path.exists() else None
    files = [Path(__file__), Path('tools/compare_integrated_sound.py'), native_receipt_path,
             reference / 'exit.json', reference / 'capture_features.json', reference / 'input_sha256.json',
             reference / 'sound_pins.csv', reference / 'audio.wav', native / 'sound.csv', native / 'audio.raw',
             check / 'receipt.json', check / 'stdout.log', check / 'stderr.log']
    if pin_report is not None:
        files.append(report_path)
    result = dict(scope='Current bare-board P1 output-latch sequence and pure-DAC levels through preset1200-field time scope.',
                  native_receipt=native_receipt, reference_receipt=reference_receipt,
                  reference_features=features, reference_observer_unchanged=unchanged,
                  comparison_receipt=comparison_receipt, pin_report=pin_report,
                  evidence_sha256={p.as_posix(): sha(p) for p in files},
                  limitations=['The1200-field time scope was selected before comparison; full1201 PCM length mismatch is retained.',
                               'Original sample indices retained; no offset, resynchronization, padding or pin-value masking beyond physical P2 ROM mux.',
                               'Exact output-latch values and pure-DAC levels do not prove physical event timing or mixed-waveform equivalence.',
                               'Current full-wrapper centered-input replay remains a separate running scenario.'],
                  whole_sound_gate_pass=False, release_qualified=False, rbf_built=False)
    output = Path('docs/evidence/sheriff_current_sound_pins.json')
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(report=output.as_posix(), actual_comparison_exit_code=comparison.returncode,
                          pin_sequence_pass=pin_report['pin_sequence_pass'] if pin_report else None,
                          pure_dac_levels_pass=pin_report['integrated_dac_levels_pass'] if pin_report else None,
                          first_pin_difference=pin_report['first_pin_difference'] if pin_report else None,
                          whole_sound_gate_pass=False)))
    return comparison.returncode


if __name__ == '__main__':
    raise SystemExit(main())
