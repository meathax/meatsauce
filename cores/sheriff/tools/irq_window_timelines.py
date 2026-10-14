#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract adjacent IRQ stack timelines from existing terminal captures.

Streams MAME once and bisects the ordered RTL binary. Does not rerun a game,
adjust a clock phase, discard events, or qualify a mismatch explanation.
"""
import argparse
import bisect
import csv
import json
import mmap
from pathlib import Path
import struct

parser = argparse.ArgumentParser()
parser.add_argument('--mame', type=Path, required=True)
parser.add_argument('--rtl', type=Path, required=True)
parser.add_argument('--frame', type=int, default=2760)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
frame_ticks = 819200
clock = 50400000
windows = []
for frame in range(args.frame - 3, args.frame + 1):
    for name, offset in [('vblank', 0), ('mid', 460800)]:
        edge = (frame - 1) * frame_ticks + offset
        windows.append({'frame': frame, 'irq': name, 'edge': edge, 'mame': [], 'rtl': []})
lo, hi = windows[0]['edge'] - 5000, windows[-1]['edge'] + 5000
with (args.mame / 'video_writes.csv').open() as file:
    for row in csv.DictReader(file):
        tick = float(row['time']) * clock
        if tick < lo: continue
        if tick > hi: break
        address = int(row['address'])
        if address < 0x7fc0: continue
        for window in windows:
            if abs(tick - window['edge']) <= 5000:
                window['mame'].append({'tick': tick, 'delta': tick - window['edge'],
                                      'address': address, 'data': int(row['data'])})
record = struct.Struct('<QHB')
with (args.rtl / 'memory_writes.bin').open('rb') as file:
    with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as memory:
        assert len(memory) % record.size == 0
        class Ticks:
            def __len__(self): return len(memory) // record.size
            def __getitem__(self, i): return struct.unpack_from('<Q', memory, i * record.size)[0]
        index = bisect.bisect_left(Ticks(), lo)
        while index < len(Ticks()):
            tick, address, data = record.unpack_from(memory, index * record.size)
            if tick > hi: break
            if address >= 0x7fc0:
                for window in windows:
                    if abs(tick - window['edge']) <= 5000:
                        window['rtl'].append({'tick': tick, 'delta': tick - window['edge'],
                                             'address': address, 'data': data})
            index += 1
report = {'scope': 'Adjacent IRQ stack-write timing, diagnostic only',
          'mame': str(args.mame), 'rtl': str(args.rtl), 'windows': windows,
          'cause_qualified': False, 'graphics_gate': False}
args.output.write_text(json.dumps(report, indent=2) + '\n')
for window in windows:
    print(window['frame'], window['irq'], 'edge', window['edge'])
    for source in ('mame', 'rtl'):
        print(source, [(round(row['delta'], 4), hex(row['address']), hex(row['data']))
                       for row in window[source][:12]])
