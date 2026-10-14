# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare a real Sheriff sound-ROM prefix and its integrated DAC levels.

P2's low nibble is a ROM-address bus in the FPGA, whereas MAME exposes its
port latch. Compare P1 and P2's upper output latch, including the actual DAC
bit. This does not claim complete analog sound or every game event class.
"""
import argparse
import array
import csv
import hashlib
import json
import math
import wave
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--mame',type=Path,required=True)
p.add_argument('--rtl',type=Path,required=True)
p.add_argument('--frames',type=int,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--source-label',required=True)
a=p.parse_args()
end_tick=a.frames*819200
end_time=end_tick/50400000
samples=end_tick//1050

def events(path,is_rtl):
    result=[];previous=None;after_scope=False
    for row in csv.DictReader(path.open()):
        t=int(row['tick'])/50400000 if is_rtl else float(row['time'])
        if t>=end_time:after_scope=True;break
        value=(int(row['p1']),int(row['p2'])&0xf0,int(row['dac']))
        if value!=previous:
            result.append((t,value));previous=value
    return result,after_scope

features=json.loads((a.mame/'capture_features.json').read_text())
assert features['sound_probe']
states=list(csv.DictReader((a.mame/'states.csv').open()))
assert int(states[-1]['frame'])>=a.frames
assert 'Average speed:' in (a.mame/'stdout.log').read_text()
mame,_=events(a.mame/'sound_pins.csv',False)
rtl,after_scope=events(a.rtl/'sound.csv',True)
# A live long replay is usable only once its actual trace is past this scope.
assert after_scope or f'frames={a.frames} ' in (a.rtl/'stdout.log').read_text(), 'RTL observation has not reached the complete requested prefix'
n=min(len(mame),len(rtl))
first=next((i for i in range(n) if mame[i][1]!=rtl[i][1]),None)
data_pass=first is None and len(mame)==len(rtl)
deltas=[(rtl[i][0]-mame[i][0])*50400000 for i in range(n) if rtl[i][1]==mame[i][1]]
with wave.open(str(a.mame/'audio.wav')) as wav:
    assert wav.getnchannels()==1 and wav.getsampwidth()==2 and wav.getframerate()==48000
    raw=wav.readframes(samples)
reference=array.array('h');reference.frombytes(raw)
with (a.rtl/'audio.raw').open('rb') as f:raw=f.read(samples*2)
actual=array.array('h');actual.frombytes(raw)
assert len(reference)==len(actual)==samples

def stats(values):
    return {'samples':len(values),'minimum':min(values),'maximum':max(values),
            'rms':math.sqrt(sum(v*v for v in values)/len(values)),
            'clipped_samples':sum(v in (-32768,32767) for v in values)}

levels=[]
for i in range(2,len(mame)-1):
    t,value=mame[i];until=mame[i+1][0]
    if until-t<0.0025:continue
    low=int((t+0.001)*48000);high=int((t+0.002)*48000)
    expected=4915 if value[2] else 0
    # Select actual reference intervals where the SN path contributes zero.
    # This is a real coin-tone test of the combined board output, not a
    # synthetic mirror of the implementation's arithmetic expression.
    if high>samples or not all(abs(v-expected)<=1 for v in reference[low:high]):continue
    actual_values=actual[low:high]
    error=max(abs(v-expected) for v in actual_values)
    levels.append({'dac':value[2],'start_sample':low,'end_sample':high,
                   'expected_level':expected,'actual_min':min(actual_values),
                   'actual_max':max(actual_values),'max_error':error,'pass':error<=1})
    if len(levels)>=12 and all(sum(x['dac']==bit for x in levels)>=3 for bit in (0,1)):break
assert all(sum(x['dac']==bit for x in levels)>=3 for bit in (0,1)), 'No adequate real pure-DAC intervals for both levels'
level_pass=all(x['pass'] for x in levels)
report={
    'scope':'Real Sheriff ROM integrated sound prefix; connected DAC level and output-latch sequence qualification',
    'source_label':a.source_label,'mame':str(a.mame),'rtl':str(a.rtl),'frames':a.frames,
    'sample_count':samples,'mame_port_events':len(mame),'rtl_port_events':len(rtl),
    'compared_output_masks':{'p1':255,'p2':240},
    'p2_low_nibble_excluded_reason':'Physical external-ROM address during fetch, not the MAME stored port latch; DAC is P2 bit 7',
    'pin_sequence_pass':data_pass,'first_pin_difference':None if first is None else {
        'index':first,'reference':mame[first],'actual':rtl[first]},
    'port_timing_delta_master_ticks':{'minimum':min(deltas),'maximum':max(deltas)},
    'pure_dac_intervals':levels,'integrated_dac_levels_pass':level_pass,
    'reference_audio':stats(reference),'actual_audio':stats(actual),
    'whole_sound_gate_pass':False,
    'limits':['Prefix covers these actual coin/start/play commands, not every Sheriff sound class',
              'Port event values are exact; MCU/reference scheduling offsets are retained rather than hidden',
              'The 12 measured pure-DAC windows qualify integration gain/polarity, not all analog oscillators',
              'MAME resampling/startup transient and physical analog calibration remain separate'],
    'input_sha256':{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in
                    (a.mame/'sound_pins.csv',a.mame/'capture_features.json')},
    'pass':data_pass and level_pass}
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'report':str(a.output),'pin_sequence_pass':data_pass,
                  'mame_events':len(mame),'rtl_events':len(rtl),
                  'integrated_dac_levels_pass':level_pass,'pure_dac_intervals':levels,
                  'actual_audio':report['actual_audio']},indent=2))
raise SystemExit(0 if report['pass'] else 1)
