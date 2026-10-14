#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Test the uniform lower DAC timestamp bound on the complete mixed WAV."""
import array
import csv
from decimal import Decimal
import json
from pathlib import Path
import wave
from diagnose_dac_waveform_origin import coefficients, f32, project_dac, sha
from diagnose_sn_mixed_waveform import controls, MixedModel, Error


def main():
    check = Path('_checks/sn-mixed-timestamp-lower-20261010')
    check.mkdir(exist_ok=False)
    prior_path = Path('docs/evidence/sheriff_sn_mixed_waveform.json')
    bounds_path = Path('docs/evidence/sheriff_dac_timestamp_bounds.json')
    prior, bounds = [json.loads(p.read_text()) for p in [prior_path, bounds_path]]
    assert bounds['all_ambiguous_edges_lower_index']['nonzero_samples'] == 0
    assert bounds['original_analysis_terminal']['exit_code'] == 0
    for path, digest in prior['source_sha256'].items():
        assert sha(path) == digest, path
    reference = Path('sim/results/rounds-three-mame')
    io, pins, wav_path = [reference/name for name in ['io.csv', 'sound_pins.csv', 'audio.wav']]
    sources = [Path(__file__), Path('tools/diagnose_sn_mixed_waveform.py'),
               Path('tools/diagnose_sn_control_waveform.py'), Path('tools/diagnose_dac_waveform_origin.py'),
               prior_path, bounds_path, io, pins, wav_path]
    before = {p.as_posix(): sha(p) for p in sources}
    event, previous, ambiguous = [], None, 0
    with pins.open(newline='') as stream:
        for row in csv.DictReader(stream):
            time, bit = Decimal(row['time']), int(row['dac'])
            if bit == previous:
                continue
            position = time*1536000
            index = 0 if time == 0 else int(position)+1
            if time > 0 and position == int(position):
                index -= 1
                ambiguous += 1
            event.append((index, bit)); previous = bit
    assert event[0] == (0, 1)
    assert all(a[0] < b[0] for a, b in zip(event, event[1:]))
    with wave.open(str(wav_path)) as wav:
        count = wav.getnframes()
        expected = array.array('h'); expected.frombytes(wav.readframes(count))
    changes, info = controls(io, False, True)
    print(json.dumps({'samples': count, 'uniform_lower_bound_edges': ambiguous}), flush=True)
    dac = project_dac(event, count, coefficients())
    model, error = MixedModel(), Error()
    output_pcm = check/'source-ordered-lower-bound-mix.raw'
    with output_pcm.open('wb') as stream:
        chunk = array.array('h')
        for sample in range(count):
            for flags in changes.get(sample, ()):
                model.controls(*flags)
            value = int(f32(dac[sample]+model.step())*32768)
            error.add(sample, value, expected[sample])
            chunk.append(value)
            if len(chunk) == 48000 or sample == count-1:
                stream.write(chunk.tobytes()); chunk = array.array('h')
            if sample and sample % 1000000 == 0:
                print(json.dumps({'samples_processed': sample}), flush=True)
    assert all(sha(p) == digest for p, digest in before.items())
    report = {
        'scope': 'Complete saved MAME mixed/retrigger waveform under the uniform lower DAC timestamp bound and exact source setter order; diagnostic, not measured timing or whole-board qualification.',
        'comparison': error.result(count), 'source_controls': info,
        'uniform_lower_bound_events': ambiguous,
        'sample_shift': False, 'per_event_selection_or_parameter_fit': False,
        'native_shadow_or_atomic_case_rerun': False,
        'source_sha256': before,
        'evidence_sha256': {output_pcm.as_posix(): sha(output_pcm)},
        'source_unchanged_during_analysis': True,
        'whole_audio_gate_pass': False,
        'limits': ['Printed timestamps remain lossy; exact integer seconds/attoseconds are required to establish the actual event indices.',
                   'The uniform bound is motivated by the passing independent DAC-only prefix; no event index was chosen individually against WAV.',
                   'MAME sequential setters still create additional enable/envelope transitions; physical Sheriff propagation remains unqualified.',
                   'No production RTL or reference capture changed; retain the original negative comparison.'],
    }
    output = Path('docs/evidence/sheriff_sn_mixed_timestamp_lower.json')
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'report': output.as_posix(), 'comparison': report['comparison']}), flush=True)


if __name__ == '__main__':
    main()
