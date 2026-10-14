#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Analyze original DAC event times through MAME's output operator.

LOFI equations derived from MAME0.289 resampler.cpp (BSD-3-Clause),
copyright Olivier Galibert. Preserve docs/licenses/MAME-BSD-3-Clause.txt.
Projections are diagnostics, never replacement native audio or release gates.
"""
import array
from bisect import bisect_right
import csv
import hashlib
import json
import math
from pathlib import Path
import struct
import wave


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def coefficients():
    f0, f1 = [0.0] * 4097, [0.0] * 4097
    for i in range(1, 4096):
        p = f32(i / 4096)
        f0[i] = f32(f32(p - f32(f32(p*p)*p)) / 6)
    for i in range(1, 2049):
        p = f32(i / 4096)
        f1[i] = f32(p + f32(f32(f32(p*p) - f32(f32(p*p)*p)) / 2))
    for i in range(2049, 4096):
        f1[i] = f32(1 + f0[i] + f0[4096-i] - f1[4096-i])
    f1[4096] = 1.0
    return f0, f1


def events(path, native):
    result, previous = [], None
    for row in csv.DictReader(path.open()):
        bit = int(row['dac'])
        if bit == previous:
            continue
        if native:
            tick = int(row['tick'])
            index = 0 if tick == 0 else tick * 1536000 // 50400000 + 1
        else:
            attoseconds = int(row['time_seconds']) * 10**18 + int(row['time_attoseconds'])
            index = 0 if attoseconds == 0 else attoseconds * 1536000 // 10**18 + 1
        result.append((index, bit))
        previous = bit
    assert result[0] == (0, 1)
    assert all(a[0] < b[0] for a, b in zip(result, result[1:]))
    return result


def project_dac(event, count, table):
    f0, f1 = table
    divide, phase, position = 33, 0, -132
    step = 1536000 * 0x1000000 // 48000 // divide
    indices = [e[0] for e in event]
    high_prefix = [0]
    for previous, current in zip(event, event[1:]):
        high_prefix.append(high_prefix[-1] + (current[0] - previous[0]) * previous[1])

    def integral(at):
        if at <= 0:
            return 0
        i = bisect_right(indices, at) - 1
        return high_prefix[i] + (at - event[i][0]) * event[i][1]

    def read():
        nonlocal position
        end = position + divide
        high = integral(end) - integral(position)
        position = end
        return f32(high / divide)

    result = array.array('f')
    for index in range(count):
        # sound_manager's fixed50Hz timer renders through the current sample:
        # first block0..960, then960 samples. apply() initializes phase from
        # absolute destination index on each call, rather than carrying its
        # rounded m_step through the whole recording.
        if index == 0 or (index >= 961 and (index-1) % 960 == 0):
            source_index = index * 32
            delta = source_index % divide
            phase = ((delta << 12) // divide) << 12
            position = source_index - delta - 4*divide
            state = [read() for _ in range(4)]
        p = phase >> 12
        mix = f32(f32(f32(-state[0]*f0[4096-p]) + f32(state[1]*f1[4096-p]))
                  + f32(state[2]*f1[p]))
        mix = f32(mix - f32(state[3]*f0[p]))
        result.append(f32(f32(0.15) * mix))
        phase += step
        if phase & 0x1000000:
            phase &= 0xffffff
            state = state[1:] + [read()]
    return result


def stats(actual, expected, count):
    errors = [int(actual[i]) - int(expected[i]) for i in range(count)]
    first = next((i for i, e in enumerate(errors) if e), None)
    return dict(samples=count, RMS_error=math.sqrt(sum(e*e for e in errors)/count),
                max_error=max(map(abs, errors)), nonzero_samples=sum(e != 0 for e in errors),
                first_difference=None if first is None else
                    dict(sample=first, actual=int(actual[first]), expected=int(expected[first])))


def main():
    output = Path('docs/evidence/sheriff_dac_waveform_origin.json')
    original_projection = Path('_checks/current-sound-pins-20261010/dac-origin-continuous-first.json')
    if output.exists() and not original_projection.exists():
        original_projection.write_bytes(output.read_bytes())
    rounded_projection = Path('_checks/current-sound-pins-20261010/dac-origin-block-rounded.json')
    if output.exists() and not rounded_projection.exists():
        rounded_projection.write_bytes(output.read_bytes())
    bound = Path('docs/evidence/sheriff_current_sound_pins.json')
    prior = json.loads(bound.read_text())
    assert prior['comparison_receipt']['exit_code'] == 0
    native = Path(prior['native_receipt']['runtime_output'])
    reference = Path('sim/results/current-sound-pins-1201-mame-20261010')
    for path in [native/'sound.csv', native/'audio.raw', reference/'sound_pins.csv', reference/'audio.wav']:
        assert sha(path) == prior['evidence_sha256'][path.as_posix()]
    precision_receipt = Path('_checks/sound-pin-precision-20261010/terminal.json')
    precision = json.loads(precision_receipt.read_text())
    assert precision['receipt']['exit_code'] == 0
    assert all(precision['observer_unchanged'].values())
    assert precision['original_sound_columns_unchanged'] and precision['canonical_lua_unchanged']
    precise_pins = Path('sim/results/current-sound-precision-1201-mame-20261010/sound_pins.csv')
    assert sha(precise_pins) == precision['evidence_sha256'][precise_pins.resolve().as_posix()]
    raw = array.array('h')
    raw.frombytes((native/'audio.raw').read_bytes())
    with wave.open(str(reference/'audio.wav')) as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 48000)
        expected = array.array('h')
        expected.frombytes(wav.readframes(wav.getnframes()))
    count = min(len(raw), len(expected))
    native_pins = [(int(r['tick']), int(r['dac'])) for r in csv.DictReader((native/'sound.csv').open())]
    bit, j, first_sn = 1, 0, None
    sn = array.array('h')
    for i, sample in enumerate(raw[:count]):
        tick = 1049 + i * 1050
        while j < len(native_pins) and native_pins[j][0] <= tick:
            bit = native_pins[j][1]
            j += 1
        value = sample - (4915 if bit else 0)
        sn.append(value)
        if value != 0 and first_sn is None:
            first_sn = i
    assert first_sn is not None
    table = coefficients()
    mame_events, native_events = events(precise_pins, False), events(native/'sound.csv', True)
    mame_dac = project_dac(mame_events, count, table)
    native_dac = project_dac(native_events, count, table)
    mame_dac_pcm = array.array('h', (int(v*32768) for v in mame_dac))
    native_dac_pcm = array.array('h', (int(v*32768) for v in native_dac))
    projected_mix = array.array('h', (int(f32(native_dac[i]+f32(sn[i]/32768))*32768) for i in range(count)))
    assert list(mame_dac_pcm[:32]) == list(expected[:32])
    reference_sn_residual = array.array('h', (expected[i]-mame_dac_pcm[i] for i in range(count)))
    first_reference_sn = next((i for i, value in enumerate(reference_sn_residual) if value), None)
    assert first_reference_sn is not None
    first_larger_sn = next((i for i in range(count) if abs(sn[i]-reference_sn_residual[i]) > 1), None)
    onset_start = max(0, min(first_sn, first_reference_sn)-4)
    onset_stop = min(count, max(first_sn, first_reference_sn)+12)
    result = dict(scope='Original-index event-to-output DAC diagnostics, full shared prefix; no game/audio substitution.',
                  source_rate_hz=1536000, output_rate_hz=48000, source_divide=33, gain=0.15,
                  source_derived_render_cadence_hz=50, first_render_samples=961,
                  subsequent_render_samples=960,
                  update_rule='Nonzero timestamp: floor(time*source_rate)+1, from sound_stream::update and DAC set_value; zero-time step at0.',
                  timestamp_note='MAME integer seconds and attoseconds; source indices calculated with exact integer arithmetic.',
                  precision_capture_receipt=precision,
                  native_samples=len(raw), reference_samples=len(expected), common_prefix=count,
                  first_native_nonzero_SN_sample=first_sn,
                  first_reference_non_DAC_PCM_sample=first_reference_sn,
                  native_SN_vs_reference_PCM_residual=stats(sn, reference_sn_residual, count),
                  first_SN_residual_difference_exceeding1LSB=None if first_larger_sn is None else
                      dict(sample=first_larger_sn, native_SN=int(sn[first_larger_sn]),
                           reference_PCM_residual=int(reference_sn_residual[first_larger_sn])),
                  SN_onset_context=[dict(sample=i,native_SN=int(sn[i]),reference_PCM_residual=int(reference_sn_residual[i]))
                                    for i in range(onset_start,onset_stop)],
                  SN_reference_route='MAME sound.cpp:637-641 bypasses resampling for equal-rate48kHz SN route.',
                  raw_vs_reference=stats(raw, expected, count),
                  mame_DAC_operator_vs_reference_before_native_SN=stats(mame_dac_pcm, expected, first_sn),
                  native_DAC_operator_vs_mame_DAC_operator=stats(native_dac_pcm, mame_dac_pcm, count),
                  diagnostic_native_mix_projection_vs_reference=stats(projected_mix, expected, count),
                  fitted_parameters=False, sample_offset=0, padding_applied=False,
                  original_audio_unchanged=True, native_audio_replaced=False,
                  evidence_sha256={p.as_posix():sha(p) for p in [Path(__file__), bound, precision_receipt, precise_pins,
                      native/'sound.csv',native/'audio.raw',reference/'sound_pins.csv',reference/'audio.wav']},
                  source_sha256={p:sha(p) for p in ['D:/Arcade/AI/mame289/src/emu/sound.cpp',
                      'D:/Arcade/AI/mame289/src/emu/sound.h',
                      'D:/Arcade/AI/mame289/src/emu/resampler.cpp','D:/Arcade/AI/mame289/src/devices/sound/dac.h']},
                  limitations=['Projection is analytical evidence only; it is not the native produced waveform.',
                                'Native SN residual retains its original sample indices and quantization.',
                                'Reference PCM residual subtracts quantized DAC output; final mixer rounding can contribute1LSB and is not a direct SN-stream capture.',
                               'The before-native-SN scope is determined from native data, not an independent MAME SN-pin timestamp.',
                               'Render blocks use the source-derived fixed50Hz graph-update baseline; no private live render-call trace is asserted.',
                               'No claim of physical event timing, whole mixed sound or end-of-recording equivalence.'],
                  whole_sound_gate_pass=False, release_qualified=False, rbf_built=False)
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(report=output.as_posix(), first_native_SN=first_sn,
                          mame_DAC_prefix=result['mame_DAC_operator_vs_reference_before_native_SN'],
                          native_DAC_difference=result['native_DAC_operator_vs_mame_DAC_operator'],
                          projected_mix=result['diagnostic_native_mix_projection_vs_reference'],
                          first_reference_SN=first_reference_sn,
                          SN_residual=result['native_SN_vs_reference_PCM_residual'],
                          first_larger_SN=result['first_SN_residual_difference_exceeding1LSB'],
                          SN_onset=result['SN_onset_context'],
                          whole_sound_gate_pass=False)))


if __name__ == '__main__':
    main()
