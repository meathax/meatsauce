#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare actual mixed gameplay WAV to source-derived SN/DAC equations.

MAME 0.289 equations/control setter order: BSD-3-Clause, Olivier Galibert
(resampler) and the authors named in sn76477.cpp/n8080_a.cpp. Preserve
docs/licenses/MAME-BSD-3-Clause.txt. No waveform shifts or fitted parameters.
"""
import array
import csv
from decimal import Decimal
import heapq
import json
import math
from pathlib import Path
import re
import wave
from diagnose_dac_waveform_origin import coefficients, f32, project_dac, sha
from diagnose_sn_control_waveform import Model, POS, NEG


class MixedModel(Model):
    def __init__(self, constants=None, gain=None):
        super().__init__(constants, gain)
        self.mode = self.voltage5 = False
        self.mixer = True

    def controls(self, mono0, mono1):
        self.control(mono0 or mono1)
        self.mode, self.mixer, self.voltage5 = mono0, not mono0, mono1

    def step(self):
        c = self.q or self.up
        self.shot = min(c['SHOT_MAX'], self.shot+c['SHOT_UP']) if self.running else max(0, self.shot-c['SHOT_DOWN'])
        if self.shot >= c['SHOT_MAX']:
            self.running = False
        self.slf = max(c['SLF_MIN'], self.slf-c['SLF_DOWN']) if self.slfbit else min(c['SLF_MAX'], self.slf+c['SLF_UP'])
        if self.slf >= c['SLF_MAX']:
            self.slfbit = True
        elif self.slf <= c['SLF_MIN']:
            self.slfbit = False
        top = self.slf+c['VCO_OFFSET'] if self.mode else c['VCO_5V_MAX'] if self.voltage5 else c['VCO_OFFSET']
        up = c['VCO_UP_5V'] if self.voltage5 else c['VCO_UP']
        down = c['VCO_DOWN_5V'] if self.voltage5 else c['VCO_UP']
        self.vco = max(c['SLF_MIN'], self.vco-down) if self.vcobit else min(top, self.vco+up)
        if self.vco >= top:
            self.vcobit = True
        elif self.vco <= c['SLF_MIN']:
            self.vcobit = False
        if self.count <= c['NOISE_HZ']:
            self.count += 48000
            self.real = ((self.rng >> 28) ^ self.rng) & 1
            if not (self.rng & 0x1000001f):
                self.real = 1
            self.rng = (self.rng >> 1) | (int(self.real) << 30)
        self.count -= c['NOISE_HZ']
        self.noise = min(c['NOISE_MAX'], self.noise+c['NOISE_UP']) if self.real else max(0, self.noise-c['NOISE_DOWN'])
        if self.noise >= c['NOISE_HIGH']:
            self.filtered = False
        elif self.noise <= c['NOISE_LOW']:
            self.filtered = True
        self.ad = min(c['AD_MAX'], self.ad+c['AD_UP']) if self.running else max(0, self.ad-c['AD_DOWN'])
        if not self.enabled or self.vco > c['VCO_MAX']:
            return 0
        bit = self.filtered if self.mixer else self.vcobit
        if self.q:
            return self.gain[self.ad*10//(1 << 32)+64*int(bit)]
        gain = (POS if bit else NEG)[int(self.ad*10)]
        voltage = min(3.51, max(.715, 2.57+(3.818*(47e3/150e3)+.03)*gain))
        return f32(f32((voltage-.715)/(2.57-.715)-1)*f32(.35))


def controls(path, native, ordered):
    pending, sequence, previous = [], 0, 0
    with path.open(newline='') as stream:
        for row in csv.DictReader(stream):
            if row['kind'] != 'out' or int(row['address']) & 7 != 4:
                continue
            data = int(row['data'])
            rising = data & ~previous & 0x14
            previous = data
            if rising:
                time = int(row['tick'])+1 if native else Decimal(row['time'])
                heapq.heappush(pending, (time, sequence, 'write', rising))
                sequence += 1
    duration = 30187080 if native else Decimal('0.59895')
    state, generation = [False, False], [0, 0]
    result, minimum_margin, updates, restarts = {}, Decimal(1), 0, 0
    while pending:
        time, _, kind, value = heapq.heappop(pending)
        if kind == 'expire':
            channel, token = value
            if token != generation[channel]:
                continue
        if native:
            sample = (time+1)//1050
        else:
            position = time*48000
            fraction = position-int(position)
            margin = min(fraction, 1-fraction)
            minimum_margin = min(minimum_margin, margin)
            # Twelve-decimal capture rounding cannot cross this sample boundary.
            assert margin > Decimal('0.0000001'), (time, margin)
            sample = int(position)+1
        changes = []
        before_enabled = any(state)
        if kind == 'expire':
            state[channel] = False
            changes.append(tuple(state))
        else:
            if value & 4:
                state[1] = False
                generation[1] += 1
                if ordered:
                    changes.append(tuple(state))
                state[0] = True
                generation[0] += 1
                heapq.heappush(pending, (time+duration, sequence, 'expire', (0, generation[0])))
                sequence += 1
                if ordered:
                    changes.append(tuple(state))
            if value & 16:
                state[1] = True
                generation[1] += 1
                heapq.heappush(pending, (time+duration, sequence, 'expire', (1, generation[1])))
                sequence += 1
                if ordered:
                    changes.append(tuple(state))
            if not ordered:
                changes.append(tuple(state))
        for change in changes:
            now_enabled = any(change)
            restarts += now_enabled and not before_enabled
            before_enabled = now_enabled
        result.setdefault(sample, []).extend(changes)
        updates += len(changes)
    return result, {'updates': updates, 'envelope_restarts': restarts,
                    'minimum_reference_sample_boundary_margin': str(minimum_margin) if not native else None}


class Error:
    def __init__(self):
        self.squared = self.nonzero = self.maximum = 0
        self.first = None

    def add(self, index, actual, expected):
        error = actual-expected
        self.squared += error*error
        self.maximum = max(self.maximum, abs(error))
        self.nonzero += error != 0
        if error and self.first is None:
            self.first = {'sample': index, 'actual': actual, 'expected': expected}

    def result(self, count):
        return {'samples': count, 'nonzero_samples': self.nonzero,
                'max_error': self.maximum, 'RMS_error': math.sqrt(self.squared/count),
                'first_difference': self.first}


def main():
    check = Path('_checks/sn-mixed-waveform-20261010')
    check.mkdir(exist_ok=False)
    reference = Path('sim/results/rounds-three-mame')
    io, pins, wav_path = [reference/name for name in ['io.csv', 'sound_pins.csv', 'audio.wav']]
    coverage_path = Path('docs/evidence/sheriff_sound_control_coverage.json')
    coverage = json.loads(coverage_path.read_text())
    assert sha(io) == coverage['captures'][2]['sha256']
    mixed_path = Path('docs/evidence/sheriff_sn_mixed_gameplay.json')
    mixed = json.loads(mixed_path.read_text())
    for path, digest in mixed['source_sha256'].items():
        assert sha(path) == digest, path
    native_io = Path('sim/results/current-cocktail-4801-rtl-20261010/io.csv')
    native_pcm = Path('_checks/sn-mixed-gameplay-20261010/run/current-sn.raw')
    assert sha(native_pcm) == mixed['evidence_sha256'][native_pcm.as_posix()]
    actual_native = array.array('h'); actual_native.frombytes(native_pcm.read_bytes())
    text = Path('rtl/sheriff_sn_constants.svh').read_text()
    const = {name: int(value) for name, value in re.findall(r"localparam \[35:0\] (\w+) = 36'd(\d+)", text)}
    const['NOISE_HZ'] = int(re.search(r'NOISE_HZ = (\d+)', text)[1])
    gain = {int(i): (-1 if minus else 1)*int(v) for i, minus, v in re.findall(r"7'd(\d+): gain_sample = (-?)16'sd(\d+)", text)}
    nc, ninfo = controls(native_io, True, False)
    fixed, shadow_error = MixedModel(const, gain), Error()
    for sample, expected in enumerate(actual_native):
        for flags in nc.get(sample, ()):
            fixed.controls(*flags)
        shadow_error.add(sample, fixed.step(), expected)
    native_stats = shadow_error.result(len(actual_native))
    write = lambda p, value: p.write_text(json.dumps(value, indent=2)+'\n')
    write(check/'native-shadow.json', native_stats)
    assert native_stats['nonzero_samples'] == 0, native_stats
    print(json.dumps({'native_shadow': native_stats}), flush=True)
    rc, rinfo = controls(io, False, True)
    ac, ainfo = controls(io, False, False)
    dac_events, previous, lattice_rows = [], None, 0
    with pins.open(newline='') as stream:
        for row in csv.DictReader(stream):
            time = Decimal(row['time'])
            assert time*400000 == (time*400000).to_integral_value(), row
            lattice_rows += 1
            bit = int(row['dac'])
            if bit != previous:
                index = 0 if time == 0 else int(time*1536000)+1
                dac_events.append((index, bit)); previous = bit
    assert dac_events[0] == (0, 1)
    assert all(a[0] < b[0] for a, b in zip(dac_events, dac_events[1:]))
    with wave.open(str(wav_path)) as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 48000)
        count = wav.getnframes()
        expected = array.array('h'); expected.frombytes(wav.readframes(count))
    inputs = [Path(__file__), Path('tools/diagnose_sn_control_waveform.py'),
              Path('tools/diagnose_dac_waveform_origin.py'), coverage_path, mixed_path,
              Path('rtl/sheriff_sn76477.sv'), Path('rtl/sheriff_sn_constants.svh'),
              Path('rtl/n8080_mcs48.sv'), io, pins, wav_path, native_io, native_pcm,
              Path('D:/Arcade/AI/mame289/src/devices/sound/sn76477.cpp'),
              Path('D:/Arcade/AI/mame289/src/mame/nintendo/n8080_a.cpp')]
    before = {p.as_posix(): sha(p) for p in inputs}
    print(json.dumps({'reference_samples': count, 'DAC_events': len(dac_events),
                      'source_control_restarts': rinfo, 'atomic_control_restarts': ainfo}), flush=True)
    dac = project_dac(dac_events, count, coefficients())
    ordered, atomic = MixedModel(), MixedModel()
    ordered_error, atomic_error, ordering_error = Error(), Error(), Error()
    projection = check/'reference-source-mix.raw'
    with projection.open('wb') as stream:
        chunk = array.array('h')
        for sample in range(count):
            for flags in rc.get(sample, ()):
                ordered.controls(*flags)
            for flags in ac.get(sample, ()):
                atomic.controls(*flags)
            o, a = ordered.step(), atomic.step()
            om, am = int(f32(dac[sample]+o)*32768), int(f32(dac[sample]+a)*32768)
            ordered_error.add(sample, om, expected[sample])
            atomic_error.add(sample, am, expected[sample])
            ordering_error.add(sample, om, am)
            chunk.append(om)
            if len(chunk) == 48000 or sample == count-1:
                stream.write(chunk.tobytes()); chunk = array.array('h')
            if sample and sample % 1000000 == 0:
                print(json.dumps({'samples_processed': sample}), flush=True)
    changed = [p for p, digest in before.items() if sha(p) != digest]
    assert not changed, changed
    report = {
        'scope': 'Independent source-equation diagnostic of the complete saved MAME mixed/retrigger WAV, plus actual native mixed-prefix Q32 shadow; not whole-board audio or physical timing qualification.',
        'native_Q32_shadow': native_stats,
        'reference_samples': count,
        'source_ordered_reference_mix': ordered_error.result(count),
        'atomic_reference_mix': atomic_error.result(count),
        'ordered_minus_atomic_mix': ordering_error.result(count),
        'source_ordered_controls': rinfo, 'atomic_controls': ainfo,
        'native_controls': ninfo,
        'covered_MAME_gameplay_classes': coverage['captures'][2]['counts'],
        'DAC_timestamp_proof': {'rows': lattice_rows, 'every_timestamp_on_400kHz_machine_cycle_grid': True,
                               'adjustments': 'None: all printed timestamps already lie exactly on the grid.',
                               'resampler': 'Previously qualified 1.536MHz / divide33 LOFI operator and source 50Hz render cadence.'},
        'source_setter_difference': 'MAME stops mono1, updates all SN setters, then starts mono0 and updates them again. When mono0 was inactive and mono1 active, intermediate disabled->enabled resets AD and starts SN one-shot. Atomic native timer update leaves enable high.',
        'source_sha256': before,
        'evidence_sha256': {p.as_posix(): sha(p) for p in [projection, check/'native-shadow.json']},
        'source_unchanged_during_analysis': True,
        'production_RTL_changed': False, 'sample_shift_or_parameter_fit': False,
        'whole_audio_gate_pass': False,
        'limits': ['Native original OS exit receipt remains missing; shadow identity does not repair it.',
                   'Zero-duration MAME setter pulse is software behaviour; physical mono0/mono1 propagation/glitch behaviour has not been established.',
                   'Compare residuals before selecting any RTL correction; do not add a fabricated enable pulse solely for WAV equivalence.',
                   'Graphics, complete native gameplay and final-source fit/STA/resource gates remain open.'],
    }
    output = Path('docs/evidence/sheriff_sn_mixed_waveform.json')
    write(output, report)
    print(json.dumps({'report': output.as_posix(), 'native_shadow': native_stats,
                      'ordered': report['source_ordered_reference_mix'],
                      'atomic': report['atomic_reference_mix']}), flush=True)


if __name__ == '__main__':
    main()
