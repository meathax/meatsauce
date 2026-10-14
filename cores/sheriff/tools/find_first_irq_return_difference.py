# SPDX-License-Identifier: GPL-2.0-or-later
"""Locate the earliest saved IRQ return-PC difference without another replay."""
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import struct


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    native = Path('sim/results/physical-cpu-restart-corners-rtl-20261009')
    reference = Path('sim/results/restart-mame')
    journal = native / 'io.csv'
    acknowledgements = []
    with journal.open(newline='') as f:
        for r in csv.DictReader(f):
            if r['kind'] == 'ack':
                acknowledgements.append({k: int(r[k]) for k in ('tick', 'frame', 'y', 'x', 'address')})
                if len(acknowledgements) == 200:
                    break
    assert len(acknowledgements) == 200
    end = acknowledgements[-1]['tick'] + 1000
    memory = native / 'memory_writes.bin'
    writes = {}
    with memory.open('rb') as f:
        while b := f.read(11 * 65536):
            assert len(b) % 11 == 0
            done = False
            for tick, address, data in struct.iter_unpack('<QHB', b):
                if tick > end:
                    done = True
                    break
                if address >= 0x7fc0:
                    writes[tick] = (address, data)
            if done:
                break
    for ack in acknowledgements:
        tick = ack['tick']
        high, low = writes[tick+167], writes[tick+242]
        assert high[0] == low[0]+1
        pc = high[1]*256 + low[1]
        assert pc == ack['address'], (ack, high, low)
        ack.update(stack_high_address=high[0], return_PC=pc,
                   stack_high_tick=tick+167, stack_low_tick=tick+242)
    ref_memory = reference / 'video_writes.csv'
    ref_writes = []
    with ref_memory.open(newline='') as f:
        for r in csv.DictReader(f):
            t = Decimal(r['time']) * 50_400_000
            if t > end:
                break
            a = int(r['address'])
            if a >= 0x7fc0:
                ref_writes.append((t, a, int(r['data'])))
    cases, first_difference, first_ambiguous = [], None, None
    for ack in acknowledgements:
        edge = ack['frame'] * 819200 + (460800 if ack['y'] == 128 else 0)
        assert ack['y'] in (128, 240) and 0 <= ack['tick']-edge < 1000
        pairs = []
        for hi, lo in zip(ref_writes, ref_writes[1:]):
            if edge <= hi[0] < edge+1000 and hi[0] == lo[0] \
                    and hi[1] == ack['stack_high_address'] and lo[1] == hi[1]-1:
                pairs.append(dict(tick=str(hi[0]), return_PC=hi[2]*256+lo[2],
                                  stack_high_address=hi[1], stack_low_address=lo[1]))
        case = dict(native=ack, request_edge=edge, reference_candidates=pairs)
        cases.append(case)
        if len(pairs) != 1:
            first_ambiguous = case
            break
        case['return_PC_equal'] = ack['return_PC'] == pairs[0]['return_PC']
        if not case['return_PC_equal']:
            first_difference = case
            break
    report = dict(scope='First saved IRQ return-PC comparison using native ACKs plus actual stack writes; reference pair selection remains an explicit timing/address inference.',
                  compared_cases=cases, first_difference=first_difference,
                  first_ambiguous_case=first_ambiguous,
                  equal_prefix_count=sum(c.get('return_PC_equal', False) for c in cases),
                  native_scan_limit_ACKs=200,
                  evidence_sha256={p.as_posix(): sha(p) for p in [Path(__file__), journal, memory, ref_memory]},
                  graphics_gate_pass=False, physical_IRQ_qualified=False,
                  limits=['Reference IRQ identity is inferred from the unique same-time stack pair within the request window, not an independently captured IRQ acknowledgement.',
                          'No stack-pair ambiguity is skipped, no stream shifted and no whole-game equivalence claimed.',
                          'No new native or MAME campaign, state forcing or production RTL change.'])
    path = Path('docs/evidence/sheriff_first_irq_return_difference.json')
    path.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(dict(report=path.as_posix(), compared=len(cases),
                          equal_prefix=report['equal_prefix_count'],
                          first_difference=first_difference, first_ambiguous=first_ambiguous)))


if __name__ == '__main__':
    main()
