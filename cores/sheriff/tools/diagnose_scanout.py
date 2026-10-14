"""Bounded causal evidence for native pixels that differ from timed MAME writes.

Reports actual bus writes around each pixel sample. This diagnostic does not
waive differences or qualify the original PCB's DRAM arbitration schedule.
"""
import argparse
import csv
import json
import struct
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--mame', type=Path, required=True)
parser.add_argument('--rtl', type=Path, required=True)
parser.add_argument('--comparison', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--frame', type=int, help='Limit observation to one captured frame')
args = parser.parse_args()
report = json.loads(args.comparison.read_text())
samples = []
for check in report['checks']:
    if args.frame is not None and check['frame'] != args.frame:
        continue
    for x, y, actual, expected in check['first_mismatches']:
        samples.append(dict(frame=check['frame'], x=x, y=y,
            sample_tick=(check['frame']-1)*819200+(((y-240)&255)*320+x)*10+8,
            reference_rgb=expected, rtl_rgb=actual, flip=0))
if not samples:
    raise ValueError('No differing pixels at the selected captured frame')
last_sample_tick = max(sample['sample_tick'] for sample in samples)

with (args.mame/'io.csv').open() as stream:
    for row in csv.DictReader(stream):
        if row['kind'] == 'out' and (int(row['address']) & 7) == 6:
            tick = round(float(row['time'])*50400000)
            if tick > last_sample_tick:
                break
            for sample in samples:
                if tick <= sample['sample_tick']:
                    sample['flip'] = (int(row['data']) >> 5) & 1
for sample in samples:
    x, y = sample['x'], sample['y']
    if sample['flip']:
        x, y = x ^ 255, y ^ 255
    sample['address'] = 0x4000 + y*32 + (x >> 3)
    sample['bit'] = x & 7
    sample['writes'] = {name: {'before': None, 'after': None} for name in ('mame', 'rtl')}

by_address = {}
for sample in samples:
    by_address.setdefault(sample['address'], []).append(sample)
pending_after = {name: len(samples) for name in ('mame', 'rtl')}

def observe(name, tick, address, data):
    for sample in by_address.get(address, ()):
        event = dict(tick=tick, data=data, distance_ticks=tick-sample['sample_tick'])
        window = sample['writes'][name]
        if tick <= sample['sample_tick']:
            window['before'] = event
        elif window['after'] is None:
            window['after'] = event
            pending_after[name] -= 1

with (args.mame/'video_writes.csv').open() as stream:
    for row in csv.DictReader(stream):
        observe('mame', round(float(row['time'])*50400000), int(row['address']) & 0x7fff, int(row['data']))
        if not pending_after['mame']:
            break
with (args.rtl/'memory_writes.bin').open('rb') as stream:
    while chunk := stream.read(11*65536):
        for tick, address, data in struct.iter_unpack('<QHB', chunk):
            observe('rtl', tick, address, data)
            if not pending_after['rtl']:
                break
        if not pending_after['rtl']:
            break
for sample in samples:
    for window in sample['writes'].values():
        value = window['before']['data'] if window['before'] else 0
        window['bit_at_sample'] = (value >> sample['bit']) & 1
    sample['address'] = hex(sample['address'])
result = dict(scope='Diagnostic write-to-scanout timing; release qualification remains pending',
    master_hz=50400000, sample_count=len(samples), pixels=samples,
    limits=['MAME writes are instruction-atomic; RTL writes are physical bus edges',
            'No threshold or mismatch waiver is applied'])
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result, indent=2))
