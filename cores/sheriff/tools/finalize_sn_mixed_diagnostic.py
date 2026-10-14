#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Retain a completed native functional diagnostic with missing OS receipt."""
import hashlib
import json
from pathlib import Path


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    check = Path('_checks/sn-mixed-gameplay-20261010')
    launch_path = check/'launch.json'
    launch = json.loads(launch_path.read_text())
    assert not (check/'terminal.json').exists()
    original = Path('tools/qualify_sn_mixed_gameplay.py')
    saved = check/'qualifier-source-original.py'
    original_key = str(original.resolve()).replace('\\', '/')
    if not saved.exists():
        saved.write_bytes(original.read_bytes())
    for path, digest in launch['source_sha256'].items():
        assert sha(saved if path == original_key else path) == digest, path
    result_path = check/'run/native-result.json'
    result = json.loads(result_path.read_text())
    assert result['samples'] == launch['samples'] == 1439875
    assert result['old_identity_differences'] == 0 and result['capacitor_state_identical']
    assert sha(check/'run/old-sn.raw') == sha(check/'old-expected-sn.raw')
    assert (check/'run/current-sn.raw').stat().st_size == result['samples']*2
    coverage_path = Path('docs/evidence/sheriff_sound_control_coverage.json')
    coverage = json.loads(coverage_path.read_text())['captures'][1]
    # Preserve the original source binding before the runner gains durable receipt support.
    sources = dict(launch['source_sha256'])
    del sources[original_key]
    sources[saved.as_posix()] = sha(saved)
    artifacts = [Path(__file__), launch_path, check/'old-expected-sn.raw',
                 result_path, check/'stdout.log', check/'stderr.log',
                 check/'run/old-sn.raw', check/'run/current-sn.raw',
                 check/'run/capacitor_window.csv']
    report = {
        'scope': 'Completed native functional diagnostic of actual cocktail output writes through first mono0 cancellation and mono1 overlap expiry; missing OS exit receipt prevents job qualification.',
        'native_result': result,
        'actual_os_exit_code': None,
        'native_job_qualification_pass': False,
        'observation': {'tool_error': 'Capsule OPERATION_FAILED after launch',
                        'native_pid': 20756, 'host_parent_pid': 39040,
                        'final_process_observation': 'Get-CimInstance Win32_Process filter ProcessId=20756 OR ProcessId=39040 returned no rows.',
                        'terminal_receipt_present': False,
                        'cause_of_missing_receipt': 'Unestablished; neither timeout nor inferred C++ return value is an observed OS exit.'},
        'source_sha256': sources,
        'evidence_sha256': {p.as_posix(): sha(p) for p in artifacts},
        'first_mono0': coverage['first_occurrences']['mono0_triggers'],
        'first_overlap': coverage['first_occurrences']['mono1_overlaps_mono0'],
        'native_old_pcm_byte_identical': True,
        'existing_native_model_reused': True,
        'full_gameplay_rerun': False,
        'whole_audio_gate_pass': False,
        'mame_mixed_class_waveform_pass': False,
        'limits': ['Native end-result and byte identity support functional diagnosis, not an OS-exit or MAME waveform pass.',
                   'Both classes and overlap came from the actual saved cocktail CPU writes; no synthetic gameplay input was substituted.',
                   'Preserve this completed prefix. Do not repeat it unchanged merely to repair observation; future required native cases use run_native_with_receipt.sh.',
                   'Mono1 retrigger and independent MAME mixed-class waveform comparison remain open.'],
    }
    output = Path('docs/evidence/sheriff_sn_mixed_gameplay.json')
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'report': output.as_posix(), 'samples': result['samples'],
                      'old_pcm_byte_identical': True, 'actual_os_exit_code': None,
                      'native_job_qualification_pass': False}))


if __name__ == '__main__':
    main()
