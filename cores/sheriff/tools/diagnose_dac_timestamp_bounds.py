#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bound printed DAC timestamps before any SN trigger; never shift PCM."""
import array
import csv
from decimal import Decimal
import json
from pathlib import Path
import wave
from diagnose_dac_waveform_origin import coefficients, f32, project_dac, sha, stats


def main():
    check = Path('_checks/dac-timestamp-bounds-20261010')
    check.mkdir(exist_ok=False)
    prior_path = Path('docs/evidence/sheriff_sn_mixed_waveform.json')
    prior = json.loads(prior_path.read_text())
    host = Path('_checks/sn-mixed-waveform-host-20261010')
    terminal = json.loads((host/'terminal.json').read_text())
    assert terminal['exit_code'] == 0 and terminal['source_unchanged']
    assert terminal['source_sha256_before'] == sha('tools/diagnose_sn_mixed_waveform.py')
    for path, digest in prior['source_sha256'].items():
        assert sha(path) == digest, path
    coverage_path = Path('docs/evidence/sheriff_sound_control_coverage.json')
    first = json.loads(coverage_path.read_text())['captures'][2]['first_occurrences']['mono1_triggers']
    count = int(Decimal(first['time'])*48000)+1
    reference = Path('sim/results/rounds-three-mame')
    pins, wav_path = reference/'sound_pins.csv', reference/'audio.wav'
    upper, lower, ambiguous, previous = [], [], [], None
    with pins.open(newline='') as stream:
        for row in csv.DictReader(stream):
            bit, time = int(row['dac']), Decimal(row['time'])
            if bit == previous:
                continue
            pos = time*1536000
            hi = 0 if time == 0 else int(pos)+1
            lo = hi-1 if time > 0 and pos == int(pos) else hi
            upper.append((hi, bit)); lower.append((lo, bit))
            if hi != lo:
                ambiguous.append({'time': str(time), 'bit': bit,
                                  'source_lower_index': lo, 'source_upper_index': hi})
            previous = bit
    assert upper[0] == lower[0] == (0, 1)
    assert all(a[0] < b[0] for a, b in zip(lower, lower[1:]))
    with wave.open(str(wav_path)) as wav:
        expected = array.array('h'); expected.frombytes(wav.readframes(count))
    projection = Path('_checks/sn-mixed-waveform-20261010/reference-source-mix.raw')
    assert sha(projection) == prior['evidence_sha256'][projection.as_posix()]
    with projection.open('rb') as stream:
        nominal = array.array('h'); nominal.frombytes(stream.read(count*2))
    low_pcm = array.array('h', (int(f32(x)*32768) for x in project_dac(lower, count, coefficients())))
    low_path = check/'lower-bound-dac.raw'; low_path.write_bytes(low_pcm.tobytes())
    report = {
        'scope': 'DAC-only prefix before the first SN trigger, with bounds for integer-source-grid events hidden by twelve-decimal timestamp printing.',
        'samples': count, 'first_SN_trigger': first,
        'printed_timestamp_nominal_upper_index': stats(nominal, expected, count),
        'all_ambiguous_edges_lower_index': stats(low_pcm, expected, count),
        'ambiguous_event_count_whole_capture': len(ambiguous),
        'first_ambiguous_events': ambiguous[:12],
        'timestamp_assumption': 'At positive printed time t exactly on the 1.536MHz source grid, an actual time just below t maps to index t*rate; exact or just above maps to index t*rate+1. Both are compatible with a twelve-decimal printed timestamp.',
        'selection_fitted_to_WAV': False, 'waveform_shift': False,
        'original_analysis_terminal': terminal,
        'source_sha256': {p.as_posix(): sha(p) for p in [Path(__file__), prior_path, coverage_path,
                           pins, wav_path, projection, Path('tools/diagnose_dac_waveform_origin.py')]},
        'evidence_sha256': {p.as_posix(): sha(p) for p in [low_path, host/'launch.json', host/'terminal.json',
                           host/'stdout.log', host/'stderr.log', Path('_checks/run_sn_mixed_waveform_host.py')]},
        'whole_audio_gate_pass': False,
        'limits': ['These are timestamp-quantization diagnostics, not an exact-time capture or a selected physical timing correction.',
                   'No SN signal is expected before the recorded first trigger. A passing bound explains that prefix only.',
                   'The complete mixed WAV retains its measured residual; no full-reference pass or native OS receipt repair follows.'],
    }
    output = Path('docs/evidence/sheriff_dac_timestamp_bounds.json')
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'report': output.as_posix(), 'nominal': report['printed_timestamp_nominal_upper_index'],
                      'lower_bound': report['all_ambiguous_edges_lower_index']}))


if __name__ == '__main__':
    main()
