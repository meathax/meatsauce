#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bind terminal receipts, primary wiring and retained mixed-audio negatives."""
import json
from pathlib import Path
from diagnose_dac_waveform_origin import sha


def main():
    names = ['sheriff_sn_mixed_waveform', 'sheriff_dac_timestamp_bounds',
             'sheriff_sn_mixed_timestamp_lower', 'sheriff_sound_enable_network']
    reports = {}
    for name in names:
        path = Path('docs/evidence')/(name+'.json')
        report = json.loads(path.read_text())
        for group in ['source_sha256', 'evidence_sha256']:
            for source, digest in report.get(group, {}).items():
                assert sha(source) == digest, source
        reports[name] = report
    ordered = reports[names[0]]
    lower = reports[names[2]]
    assert ordered['native_Q32_shadow']['nonzero_samples'] == 0
    assert lower['comparison']['samples'] == 12482881
    assert lower['comparison']['nonzero_samples'] == 0
    assert ordered['source_ordered_reference_mix']['nonzero_samples'] == 4553
    assert ordered['atomic_reference_mix']['nonzero_samples'] == 648385
    assert reports[names[1]]['all_ambiguous_edges_lower_index']['nonzero_samples'] == 0
    terminals, artifacts = [], [Path(__file__)]
    for name, tool in [('sn-mixed-waveform-host', 'diagnose_sn_mixed_waveform'),
                       ('sn-mixed-lower-host', 'diagnose_sn_mixed_timestamp_lower')]:
        check = Path('_checks')/(name+'-20261010')
        terminal_path = check/'terminal.json'
        terminal = json.loads(terminal_path.read_text())
        assert terminal['exit_code'] == 0 and terminal['source_unchanged']
        assert terminal['source_sha256_before'] == sha(Path('tools')/(tool+'.py'))
        terminals.append({'path': terminal_path.as_posix(), **terminal})
        artifacts.extend([terminal_path, check/'launch.json', check/'stdout.log', check/'stderr.log'])
    artifacts.extend(Path('docs/evidence')/(name+'.json') for name in names)
    report = {
        'scope': 'Mixed Sheriff sound source-model checkpoint, with actual analysis exits; not complete native board/gameplay/physical sound qualification.',
        'actual_analysis_terminals': terminals,
        'native_mixed_prefix_Q32_shadow_samples': 1439875,
        'native_Q32_shadow_nonzero_samples': 0,
        'reference_samples': 12482881,
        'uniform_timestamp_bound_source_mix_nonzero_samples': 0,
        'retained_nominal_timestamp_source_mix_nonzero_samples': 4553,
        'retained_atomic_controls_nonzero_samples': 648385,
        'ordered_minus_atomic_mix': ordered['ordered_minus_atomic_mix'],
        'source_ordered_envelope_restarts': 132,
        'atomic_envelope_restarts': 106,
        'uniform_lower_bound_DAC_events': 1113,
        'per_event_fit_or_waveform_shift': False,
        'covered_reference_classes': ordered['covered_MAME_gameplay_classes'],
        'primary_wiring_report': 'docs/evidence/sheriff_sound_enable_network.json',
        'evidence_sha256': {p.as_posix(): sha(p) for p in artifacts},
        'production_RTL_changed': False,
        'physical_enable_pulse_qualified': False,
        'exact_reference_attoseconds_captured': False,
        'whole_audio_gate_pass': False,
        'limits': ['Uniform lower timestamp bound explains the saved WAV but does not recover measured sub-picosecond event times.',
                   'Source setter order generates 26 additional envelope restarts; exact Sheriff trigger/clear/enable propagation remains unqualified.',
                   'Original native mixed-prefix OS receipt is still missing; successful later analytical jobs do not repair it.',
                   'Retain completed cases. Obtain exact timestamp columns during the next otherwise-required MAME capture; do not rerun them unchanged.',
                   'No Quartus, RBF, hardware, full gameplay or graphics gate follows.'],
    }
    output = Path('docs/evidence/sheriff_mixed_sound_checkpoint.json')
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'report': output.as_posix(), 'actual_analysis_exits': [t['exit_code'] for t in terminals],
                      'reference_samples': 12482881, 'conditional_reference_differences': 0,
                      'ordered_minus_atomic': report['ordered_minus_atomic_mix']}))


if __name__ == '__main__':
    main()
