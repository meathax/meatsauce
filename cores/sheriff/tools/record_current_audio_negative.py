#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Retain current bare-board waveform differences without alignment or padding."""
import array
import json
import math
from pathlib import Path
import sys
import wave
from record_current_gameplay import sha


def main():
    check = Path('_checks/current-gameplay-1201-20261010')
    native_receipt = json.loads((check / 'terminal.json').read_text(encoding='utf-8-sig'))
    assert native_receipt['exit_code'] == 0
    native = Path(native_receipt['runtime_output'])
    reference = Path('sim/results/current-gameplay-1201-mame-20261010')
    reference_receipt = json.loads((reference / 'exit.json').read_text(encoding='utf-8-sig'))
    assert reference_receipt['exit_code'] == 0
    assert native_receipt['frames_requested'] == reference_receipt['frames_requested'] == 1201
    assert sha(Path(native_receipt['model'])) == native_receipt['model_sha256']
    assert sha(Path(native_receipt['inputs'])) == native_receipt['inputs_sha256']
    for name, digest in native_receipt['source_sha256'].items():
        assert sha(Path(name)) == digest
    actual = array.array('h')
    actual.frombytes((native / 'audio.raw').read_bytes())
    assert sys.byteorder == 'little'
    with wave.open(str(reference / 'audio.wav')) as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 48000)
        expected = array.array('h')
        expected.frombytes(wav.readframes(wav.getnframes()))
    common = min(len(actual), len(expected))
    first = next((i for i in range(common) if actual[i] != expected[i]), None)
    errors = [actual[i] - expected[i] for i in range(common)]
    assert first == 0
    paths = [Path(__file__), check / 'terminal.json', reference / 'exit.json',
             native / 'audio.raw', reference / 'audio.wav', native / 'sound.csv',
             Path('rtl/sheriff_sn76477.sv'), Path('rtl/sheriff_sn_constants.svh')]
    result = dict(scope='Current bare-board finite P1 waveform diagnostic; original sample indices.',
                  native_receipt=native_receipt, mame_receipt=reference_receipt,
                  native_samples=len(actual), reference_samples=len(expected),
                  compared_common_prefix_samples=common, first_difference_sample=first,
                  first_native_samples=list(actual[:32]), first_reference_samples=list(expected[:32]),
                  common_prefix_RMS_error=math.sqrt(sum(e*e for e in errors) / common),
                  common_prefix_max_error=max(map(abs, errors)),
                  common_prefix_nonzero_error_samples=sum(e != 0 for e in errors),
                  evidence_sha256={p.as_posix(): sha(p) for p in paths},
                  limitations=['Different file lengths retained; no padding, time shift or reference substitution.',
                               'Native starts at DAC-high level4915; reference starts with a transient. Recording/resampling origin still needs qualification.',
                               'Existing pure-DAC and component tests do not establish whole-waveform equivalence.',
                               'This diagnostic does not invalidate the independently qualified captured RGB fields.'],
                  waveform_equivalence_qualified=False, whole_sound_gate_pass=False,
                  release_qualified=False, rbf_built=False)
    output = Path('docs/evidence/sheriff_current_audio_negative.json')
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(native_samples=len(actual), reference_samples=len(expected),
                          first_difference_sample=first,
                          RMS_error=result['common_prefix_RMS_error'],
                          waveform_equivalence_qualified=False, report=output.as_posix())))


if __name__ == '__main__':
    main()
