#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Test first-two-burst control timing using source equations, never shift PCM."""
import array
import argparse
import csv
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import re
import wave
from diagnose_dac_waveform_origin import coefficients, events, f32, project_dac, stats
from diagnose_sn_control_sampling import triggers


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


POS = [0]*9 + [.01,.03,.11,.15,.19,.21,.23,.26,.29,.31,.33,.36,.38,.41,.43,.46,.49,.52,.54,.57,.60,.62,.65,.68,.70,.73,.76,.80,.82,.84,.87,.90,.93,.96,.98,1]
NEG = [0]*9 + [-.01,-.02,-.09,-.13,-.15,-.17,-.19,-.22,-.24,-.26,-.28,-.30,-.32,-.34,-.37,-.39,-.41,-.44,-.46,-.48,-.51,-.53,-.56,-.58,-.60,-.62,-.65,-.67,-.69,-.72,-.74,-.76,-.78,-.81,-.84,-.85]


class Model:
    def __init__(self, constants=None, gain=None):
        self.q = constants
        self.gain = gain
        self.slf = self.vco = constants['SLF_MIN'] if constants else .33
        self.noise = self.ad = self.shot = self.rng = self.count = 0
        self.slfbit = self.vcobit = self.filtered = self.real = self.running = False
        self.enabled = False
        if not constants:
            self.up = dict(SLF_UP=2.04/(.5885*1.5e6*47e-9+.001300)/48000,
                           SLF_DOWN=2.04/(.5413*1.5e6*47e-9+.001343)/48000,
                           VCO_UP=.64*2*2.39/(1.5e6*1e-9)/48000,
                           VCO_UP_5V=.64*2*2.39/(1.5e6*1e-9)/48000/1.64,
                           VCO_DOWN_5V=.64*2*2.39/(1.5e6*1e-9)/48000*1.64,
                           NOISE_UP=5/(.1571*100e3*1e-9+.00001430)/48000,
                           NOISE_DOWN=5/(.1331*100e3*1e-9+.00001734)/48000,
                           SHOT_UP=2.5/(.8024*560e3*47e-9+.002079)/48000,
                           SHOT_DOWN=2.5/(854.7*47e-9+.00001795)/48000,
                           AD_UP=4.44/(20e3*1e-6)/48000,
                           AD_DOWN=4.44/(620e3*1e-6)/48000,
                           SLF_MIN=.33, SLF_MAX=2.37, VCO_OFFSET=.35,
                           VCO_MAX=2.72, VCO_5V_MAX=5.35, NOISE_MAX=5.,
                           NOISE_HIGH=3.35, NOISE_LOW=.74, AD_MAX=4.44, SHOT_MAX=2.5,
                           NOISE_HZ=int(339100000*math.pow(36000., -.8849)))

    def control(self, enabled):
        if enabled and not self.enabled:
            self.ad = 0
            self.running = True
        self.enabled = enabled

    def step(self):
        c = self.q or self.up
        self.slf = max(c['SLF_MIN'], self.slf-c['SLF_DOWN']) if self.slfbit else min(c['SLF_MAX'], self.slf+c['SLF_UP'])
        if self.slf >= c['SLF_MAX']:
            self.slfbit = True
        elif self.slf <= c['SLF_MIN']:
            self.slfbit = False
        top = c['VCO_5V_MAX'] if self.enabled else c['VCO_OFFSET']
        self.vco = max(c['SLF_MIN'], self.vco-c['VCO_DOWN_5V' if self.enabled else 'VCO_UP']) if self.vcobit else min(top, self.vco+c['VCO_UP_5V' if self.enabled else 'VCO_UP'])
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
        self.shot = min(c['SHOT_MAX'], self.shot+c['SHOT_UP']) if self.running else max(0, self.shot-c['SHOT_DOWN'])
        if self.shot >= c['SHOT_MAX']:
            self.running = False
        self.ad = min(c['AD_MAX'], self.ad+c['AD_UP']) if self.running else max(0, self.ad-c['AD_DOWN'])
        if not self.enabled or self.vco > c['VCO_MAX']:
            return 0
        if self.q:
            index = self.ad*10//(1 << 32)
            return self.gain[index+64*int(self.filtered)]
        index = int(self.ad*10)
        gain = (POS if self.filtered else NEG)[index]
        voltage = min(3.51, max(.715, 2.57+(3.818*(47e3/150e3)+.03)*gain))
        return f32(f32((voltage-.715)/(2.57-.715)-1)*f32(.35))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--all-mono1',action='store_true',help='Extend to every mono1 trigger in the frozen recording.')
    args = parser.parse_args()
    suffix = '-all-mono1' if args.all_mono1 else ''
    check = Path('_checks/sn-control-waveform'+suffix+'-20261010')
    check.mkdir(exist_ok=False)
    prior_path = Path('docs/evidence/sheriff_sn_gameplay_replay.json')
    prior = json.loads(prior_path.read_text())
    assert prior['completed_native_receipt']['exit_code'] == 0
    sampling_path = Path('docs/evidence/sheriff_sn_control_sampling.json')
    sampling = json.loads(sampling_path.read_text())
    for path, digest in sampling['evidence_sha256'].items():
        assert sha(path) == digest, path
    pairs = sampling['first_two_bursts']
    count = pairs[1]['source_predicted_reference_expiry_sample']+64
    original = Path('sim/results/current-gameplay-1201-rtl-20261010/io.csv')
    all_triggers = triggers(original)
    if args.all_mono1:
        reference_io = Path('sim/results/current-sound-precision-1201-mame-20261010/io.csv')
        reference_triggers = triggers(reference_io)
        assert len(all_triggers) == len(reference_triggers) == 5
        assert all(t['trigger_bits'] == 16 for t in all_triggers+reference_triggers)
        assert all(int(a['row']['tick']) < int(b['row']['tick']) for a,b in zip(all_triggers,all_triggers[1:]))
        assert all(Decimal(a['row']['time']) < Decimal(b['row']['time']) for a,b in zip(reference_triggers,reference_triggers[1:]))
        pairs = []
        for a,b in zip(all_triggers,reference_triggers):
            assert a['row']['data'] == b['row']['data']
            start = int(a['row']['tick'])+1
            time = Decimal(b['row']['time'])
            pairs.append(dict(native=a,reference=b,
                              source_predicted_native_start_sample=(start+1)//1050,
                              source_predicted_reference_start_sample=int(time*48000)+1,
                              source_predicted_native_expiry_sample=(start+30187080+1)//1050,
                              source_predicted_reference_expiry_sample=int((time+Decimal('0.59895'))*48000)+1))
        # This model intentionally does not approximate retrigger/overlap behavior.
        for prefix in ['native','reference']:
            assert all(a[f'source_predicted_{prefix}_expiry_sample'] < b[f'source_predicted_{prefix}_start_sample'] for a,b in zip(pairs,pairs[1:]))
        count = 936961
    else:
        assert len(all_triggers) == 2 or (int(all_triggers[2]['row']['tick'])+2)//1050 >= count
        assert all(t['trigger_bits'] == 16 for t in all_triggers[:2])
    text = Path('rtl/sheriff_sn_constants.svh').read_text()
    const = {name:int(value) for name,value in re.findall(r'localparam \[35:0\] (\w+) = 36\x27d(\d+)',text)}
    const['NOISE_HZ'] = int(re.search(r'NOISE_HZ = (\d+)',text)[1])
    gain = {int(index):(-1 if minus else 1)*int(value) for index,minus,value in re.findall(r'7\x27d(\d+): gain_sample = (-?)16\x27sd(\d+)',text)}
    fixed, native_float, reference_float = Model(const,gain), Model(), Model()
    def controls(prefix):
        result = {}
        for pair in pairs:
            result[pair[f'source_predicted_{prefix}_start_sample']] = True
            result[pair[f'source_predicted_{prefix}_expiry_sample']] = False
        return result
    nc, mc = controls('native'), controls('reference')
    actual_path = Path('_checks/sn-gameplay-replay-20261010/run-v3/current-sn.raw')
    actual = array.array('h');actual.frombytes(actual_path.read_bytes())
    assert sha(actual_path) == prior['completed_case_source_binding']['evidence_sha256'][actual_path.as_posix()]
    capture = Path('sim/results/current-sound-precision-1201-mame-20261010')
    wav_path, pins_path = capture/'audio.wav', capture/'sound_pins.csv'
    for path in [wav_path,pins_path]:
        assert sha(path) == prior['evidence_sha256'][path.as_posix()]
    with wave.open(str(wav_path)) as wav:
        assert (wav.getnchannels(),wav.getsampwidth(),wav.getframerate()) == (1,2,48000)
        expected = array.array('h');expected.frombytes(wav.readframes(count))
    dac = project_dac(events(pins_path,False),count,coefficients())
    shadow, nf_pcm, mf_pcm, nf_mix, mf_mix = [array.array('h') for _ in range(5)]
    windows = set(range(781180,781201)) | set(range(811948,811958))
    rows = []
    for sample in range(count):
        if sample in nc:
            fixed.control(nc[sample]);native_float.control(nc[sample])
        if sample in mc:
            reference_float.control(mc[sample])
        q, n, m = fixed.step(), native_float.step(), reference_float.step()
        shadow.append(q);nf_pcm.append(int(n*32768));mf_pcm.append(int(m*32768))
        nf_mix.append(int(f32(dac[sample]+n)*32768));mf_mix.append(int(f32(dac[sample]+m)*32768))
        if sample in windows:
            rows.append(dict(sample=sample,native_actual=actual[sample],q32_shadow=q,
                             native_float_pcm=int(n*32768),reference_float_pcm=int(m*32768),
                             reference_WAV=expected[sample],reference_projected_mix=mf_mix[-1],
                             native_float_AD=native_float.ad,reference_float_AD=reference_float.ad,
                             native_float_VCO=native_float.vco,reference_float_VCO=reference_float.vco,
                             native_Q32_VCO=fixed.vco/(1<<32)))
    shadow_stats = stats(shadow,actual,count)
    # This proves the source-derived native controls/equations for the chosen scope.
    assert shadow_stats['nonzero_samples'] == 0, shadow_stats
    artifacts = []
    for name,pcm in [('shadow',shadow),('native-float',nf_pcm),('reference-float',mf_pcm),('native-float-mixed',nf_mix),('reference-float-mixed',mf_mix)]:
        path = check/(name+'.raw');path.write_bytes(pcm.tobytes());artifacts.append(path)
    window = check/'windows.json';window.write_text(json.dumps(rows,indent=2)+'\n');artifacts.append(window)
    sources = [Path(__file__),Path('tools/diagnose_dac_waveform_origin.py'),Path('sim/sn_qualification.cpp'),
               Path('rtl/sheriff_sn76477.sv'),Path('rtl/sheriff_sn_constants.svh'),prior_path,sampling_path,
               actual_path,wav_path,pins_path,original,
               Path('D:/Arcade/AI/mame289/src/devices/sound/sn76477.cpp'),
               Path('D:/Arcade/AI/mame289/src/mame/nintendo/n8080_a.cpp')]
    if args.all_mono1:
        sources.append(reference_io)
    result = dict(scope=('All five mono1 bursts' if args.all_mono1 else 'First two mono1 bursts')+': analytical equations and source-derived control samples, not new native gameplay.',
                  samples=count,q32_shadow_vs_actual=shadow_stats,
                  native_float_PCM_vs_current_chip=stats(nf_pcm,actual,count),
                  native_controls_float_mixed_vs_WAV=stats(nf_mix,expected,count),
                  reference_controls_float_mixed_vs_WAV=stats(mf_mix,expected,count),
                  windows=rows,source_controls=pairs,fitted_parameters=False,
                  audio_shift_applied=0,production_RTL_changed=False,
                  limitations=['Only separated mono1 bursts, with mode0/mixer-noise; mono0, overlapping and other sound classes not modeled.',
                               'Q32 shadow is checked against actual native component output; analytical float projection is not a native or hardware sound gate.',
                               'Exact private MAME SN control timestamps remain source-derived rather than observed.',
                               'Final float mixer and exact DAC projection are applied before PCM conversion; original WAV is unchanged.'],
                  evidence_sha256={p.as_posix():sha(p) for p in [*sources,*artifacts]},
                  whole_sound_gate_pass=False,release_qualified=False,rbf_built=False)
    output = Path('docs/evidence/sheriff_sn_control_waveform'+suffix.replace('-','_')+'.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ['samples','q32_shadow_vs_actual','native_float_PCM_vs_current_chip','native_controls_float_mixed_vs_WAV','reference_controls_float_mixed_vs_WAV','whole_sound_gate_pass']}))


if __name__ == '__main__':
    main()
