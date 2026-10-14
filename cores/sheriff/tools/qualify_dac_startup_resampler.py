#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Qualify the recorded DAC startup against MAME 0.289 LOFI step math.

Coefficient/phase equations derived from MAME resampler.cpp (BSD-3-Clause),
copyright Olivier Galibert. Preserve docs/licenses/MAME-BSD-3-Clause.txt.
"""
import array
import hashlib
import json
from pathlib import Path
import struct
import sys
import wave


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def predict(samples):
    # Fixed source-derived parameters, not estimated from the recorded WAV.
    fs, ft, gain = 48000 * 32, 48000, f32(0.15)
    f0, f1 = [0.0] * 4097, [0.0] * 4097
    for i in range(1, 4096):
        p = f32(i / 4096)
        f0[i] = f32(f32(p - f32(f32(p * p) * p)) / 6)
    for i in range(1, 2049):
        p = f32(i / 4096)
        f1[i] = f32(p + f32(f32(f32(p * p) - f32(f32(p * p) * p)) / 2))
    for i in range(2049, 4096):
        f1[i] = f32(1 + f0[i] + f0[4096 - i] - f1[4096 - i])
    f1[4096] = 1.0
    divide = 1 + fs // ft
    step = fs * 0x1000000 // ft // divide
    pos, phase = -4 * divide, 0

    def read(at):
        return sum(1.0 if j >= 0 else 0.0 for j in range(at, at + divide)) / divide

    state = [read(pos + i * divide) for i in range(4)]
    pos += 4 * divide
    result = []
    for _ in range(samples):
        p = phase >> 12
        mix = f32(f32(f32(-state[0] * f0[4096-p]) + f32(state[1] * f1[4096-p]))
                  + f32(state[2] * f1[p]))
        mix = f32(mix - f32(state[3] * f0[p]))
        result.append(int(f32(gain * mix) * 32768))
        phase += step
        if phase & 0x1000000:
            phase &= 0xffffff
            state = state[1:] + [read(pos)]
            pos += divide
    return result


def main():
    reference = Path('sim/results/current-gameplay-1201-mame-20261010')
    native = Path('sim/results/current-gameplay-1201-rtl-20261010/audio.raw')
    receipt = reference / 'exit.json'
    assert json.loads(receipt.read_text(encoding='utf-8-sig'))['exit_code'] == 0
    assert sys.byteorder == 'little'
    with wave.open(str(reference / 'audio.wav')) as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 48000)
        actual = array.array('h')
        actual.frombytes(wav.readframes(32))
    native_start = array.array('h')
    with native.open('rb') as stream:
        native_start.frombytes(stream.read(64))
    predicted = predict(32)
    assert predicted == list(actual)
    assert list(native_start) == [4915] * 32
    sources = [Path('D:/Arcade/AI/mame289/src/emu/resampler.cpp'),
               Path('D:/Arcade/AI/mame289/src/emu/sound.cpp'),
               Path('D:/Arcade/AI/mame289/src/devices/sound/dac.cpp'),
               Path('D:/Arcade/AI/mame289/src/mame/nintendo/n8080_a.cpp')]
    result = dict(scope='Original first32 WAV samples; zero-history DAC-high step and default LOFI math.',
                  source_rate_hz=1536000, output_rate_hz=48000, gain=0.15,
                  source_divide=33, initial_history=0, step_at_source_sample=0,
                  fitted_parameters=False, sample_offset=0, padding_applied=False,
                  predicted_samples=predicted, reference_samples=list(actual),
                  native_raw_samples=list(native_start), exact_samples=32,
                  source_sha256={p.as_posix(): sha(p) for p in sources},
                  evidence_sha256={p.as_posix(): sha(p) for p in
                      [Path(__file__), receipt, reference / 'audio.wav', native]},
                  startup_operator_qualified=True, whole_waveform_equivalence_qualified=False,
                  limitations=['Numeric reproduction of the startup operator, not a new device/pin trace.',
                               'Full mixed sound, event timing and file-length difference remain open.',
                               'Original-index waveform negative is retained without shifting native output.'],
                  whole_sound_gate_pass=False, release_qualified=False, rbf_built=False)
    output = Path('docs/evidence/sheriff_dac_startup_resampler.json')
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(report=output.as_posix(), exact_samples=32,
                          fitted_parameters=False, whole_sound_gate_pass=False)))


if __name__ == '__main__':
    main()
