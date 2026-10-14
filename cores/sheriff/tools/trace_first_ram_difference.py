#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Find the first ordered RAM-write difference in existing terminal captures.

Timing is recorded, not aligned or corrected. Stop at the first address/data
sequence difference; do not skip stack writes or resynchronize either stream.
"""
import argparse
import csv
import hashlib
import json
import struct
from collections import deque
from decimal import Decimal
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def native_rows(path):
    record = struct.Struct('<QHB')
    with path.open('rb') as stream:
        while raw := stream.read(record.size):
            if len(raw) != record.size:
                raise ValueError('Incomplete terminal native RAM-write record')
            tick, address, data = record.unpack(raw)
            yield {'tick': tick, 'address': address, 'data': data}


def reference_rows(path):
    with path.open(newline='') as stream:
        for row in csv.DictReader(stream):
            address = int(row['address']) & 0x7fff
            if address & 0x4000:
                yield {'tick': str(Decimal(row['time']) * 50_400_000),
                       'address': address, 'data': int(row['data']),
                       'field': int(row['frame']), 'time': row['time']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', type=Path, default=Path(
        'sim/results/physical-cpu-restart-corners-rtl-20261009/memory_writes.bin'))
    parser.add_argument('--mame', type=Path, default=Path(
        'sim/results/prior-vblank-2758-mame-20261009/video_writes.csv'))
    parser.add_argument('--output', type=Path, default=Path(
        'docs/evidence/sheriff_first_ram_difference.json'))
    args = parser.parse_args()
    if args.native.stat().st_size % 11:
        raise ValueError('Incomplete terminal native trace')
    native, mame = native_rows(args.native), reference_rows(args.mame)
    context = deque(maxlen=12)
    matched = 0
    last_ticks = (Decimal(-1), Decimal(-1))
    while True:
        nr, mr = next(native, None), next(mame, None)
        if nr is None or mr is None:
            difference = {'reason': 'end_of_stream', 'native': nr, 'mame': mr}
            break
        ticks = (Decimal(nr['tick']), Decimal(mr['tick']))
        if any(now < previous for now, previous in zip(ticks, last_ticks)):
            raise ValueError('Nonchronological RAM trace')
        last_ticks = ticks
        pair = {'native': nr, 'mame': mr,
                'mame_minus_native_master_ticks': str(ticks[1] - ticks[0])}
        if (nr['address'], nr['data']) != (mr['address'], mr['data']):
            difference = {'reason': 'ordered_address_or_data_difference', **pair}
            break
        context.append(pair)
        matched += 1
    result = {
        'native': {'path': args.native.as_posix(), 'sha256': sha(args.native),
                   'records': args.native.stat().st_size // 11},
        'mame': {'path': args.mame.as_posix(), 'sha256': sha(args.mame)},
        'recorder_sha256': sha(Path(__file__)),
        'matched_write_prefix': matched,
        'preceding_matched_writes': list(context),
        'first_difference': difference,
        'resynchronization_used': False,
        'timing_adjustment_used': False,
        'graphics_gate_qualified': False,
        'scope': 'Ordered RAM writes only; no CPU read, physical RAM timing or current-source qualification.'}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'matched_write_prefix': matched,
                      'first_difference': difference,
                      'evidence': args.output.as_posix()}))


if __name__ == '__main__':
    main()
