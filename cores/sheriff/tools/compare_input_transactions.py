#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Locate the first external input-read divergence without rerunning a game."""
import argparse
from collections import deque
import csv
import itertools
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--mame', type=Path, required=True)
parser.add_argument('--rtl', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()

def transactions(path, reference):
    with path.open() as file:
        for row in csv.DictReader(file):
            if row['kind'] != 'in': continue
            yield {'port': int(row['address']) & 0xff, 'data': int(row['data']),
                   'tick': float(row['time']) * 50400000 if reference else int(row['tick']),
                   'frame': int(row['frame']), 'pc': int(row['pc']) if reference else None}

before = deque(maxlen=5)
matched = 0
first = None
sentinel = object()
for left, right in itertools.zip_longest(transactions(args.mame, True), transactions(args.rtl, False), fillvalue=sentinel):
    if left is sentinel or right is sentinel:
        first = {'mame': None if left is sentinel else left, 'rtl': None if right is sentinel else right,
                 'reason': 'stream ended'}
        break
    if (left['port'], left['data']) != (right['port'], right['data']):
        first = {'mame': left, 'rtl': right, 'reason': 'input port/data mismatch'}
        break
    matched += 1
    before.append({'mame': left, 'rtl': right, 'delta_mame_minus_rtl': left['tick'] - right['tick']})
report = {'scope': 'Ordered input port/data reads; timing retained separately',
          'mame': str(args.mame), 'rtl': str(args.rtl), 'matched_prefix': matched,
          'preceding_transactions': list(before), 'first_difference': first,
          'complete_input_stream_equal': first is None,
          'complete_sheriff_gate': False}
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
