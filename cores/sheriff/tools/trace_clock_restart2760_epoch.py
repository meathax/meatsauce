#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Locate opcode-epoch changes in existing terminal native/MAME read streams."""
import csv
import hashlib
import json
from decimal import Decimal
from pathlib import Path


def rows(path):
    with Path(path).open() as f:
        return list(csv.DictReader(f))


def main():
    native = rows('sim/results/physical-cpu-restart-corners-rtl-20261009/bus.csv')
    native = [r for r in native if r['kind'] == 'read' and int(r['status']) & 128
              and int(r['address']) < 0x4000]
    reference = rows('sim/results/pixel-2760-irq-before-mame/irq_program_reads.csv')
    # Align using the identical address/data pair nearest the first reference
    # access. Afterwards compare every ROM access; no opcode-only guessing.
    first = reference[0]
    first_tick = Decimal(first['time']) * 50_400_000
    anchors = [(abs(Decimal(r['tick']) - first_tick), i) for i, r in enumerate(native)
               if r['address'] == first['address'] and r['data'] == first['data']]
    offset = min(anchors)[1]
    native = native[offset:]
    segments, mismatch, matched, omissions = [], None, 0, []
    known_branch_crossing = None
    mid_screen_crossing = None
    mid_screen_crossings = []
    first_sequence_difference = None
    ni = mi = 0
    previous_opcode = None
    while ni < len(native) and mi < len(reference):
        nr, mr = native[ni], reference[mi]
        if (nr['address'], nr['data']) != (mr['address'], mr['data']):
            if first_sequence_difference is None:
                first_sequence_difference = {'index': matched, 'native': nr, 'mame': mr}
            if (mid_screen_crossing is None or mid_screen_crossing['resumed_after_ISR']) and int(nr['address']) == 0x0a22 \
                    and int(mr['address']) == 8 and ni + 2 < len(native):
                assert [int(r['address']) for r in native[ni:ni + 2]] == [0x0a22, 0x0a23]
                assert [int(r['data']) for r in native[ni:ni + 2]] == [0xfe, 3]
                assert (native[ni + 2]['address'], native[ni + 2]['data']) == (mr['address'], mr['data'])
                mid_screen_crossing = {'native_return_PC': 0x0a24, 'mame_return_PC': 0x0a22,
                                       'instruction': 'CPI 3', 'T_states': 7,
                                       'native_pre_IRQ_accesses': 2, 'mame_post_IRQ_accesses': 2,
                                       'matched_access_index_before_crossing': matched,
                                       'resumed_after_ISR': False}
                mid_screen_crossings.append(mid_screen_crossing)
                ni += 2
                continue
            if mid_screen_crossing is not None and not mid_screen_crossing['resumed_after_ISR'] \
                    and int(nr['address']) == 0x0a24 and int(mr['address']) == 0x0a22:
                assert [int(r['address']) for r in reference[mi:mi + 2]] == [0x0a22, 0x0a23]
                assert [int(r['data']) for r in reference[mi:mi + 2]] == [0xfe, 3]
                assert (reference[mi + 2]['address'], reference[mi + 2]['data']) == (nr['address'], nr['data'])
                mid_screen_crossing['resumed_after_ISR'] = True
                mi += 2
                continue
            # At the prior vblank, native already executed JZ 05a0 -> 0590;
            # MAME stacked 05a0 and executes that same branch after the ISR.
            # Record this exact crossing, independently checked below. It is
            # an explained sequence difference, not arbitrary matching repair.
            if known_branch_crossing is None and int(nr['address']) == 0x0590 \
                    and int(mr['address']) == 0x05a0 and mi + 3 < len(reference):
                rom = Path('roms/sheriff.bin').read_bytes()
                assert rom[0x05a0] == 0xca and int.from_bytes(rom[0x05a1:0x05a3], 'little') == 0x0590
                assert [int(r['address']) for r in reference[mi:mi + 3]] == [0x05a0, 0x05a1, 0x05a2]
                assert (reference[mi + 3]['address'], reference[mi + 3]['data']) == (nr['address'], nr['data'])
                known_branch_crossing = {'native_return_PC': 0x0590, 'mame_return_PC': 0x05a0,
                                         'MAME_post_return_branch_PC': 0x05a0, 'target_PC': 0x0590,
                                         'branch_T_states': 10, 'branch_ticks': 250,
                                         'mame_accesses_before_resume': 3,
                                         'matched_access_index_before_crossing': matched}
                mi += 3
                continue
            # MAME 0.289 op_jmp/op_call increments PC by two without reading
            # arguments when the condition is false (i8085.cpp:821-847).
            # Accept precisely two sequential operand accesses followed by
            # the identical sequential opcode. No general resynchronization.
            if previous_opcode is not None and ni + 2 < len(native):
                pc, op = previous_opcode
                after = native[ni + 2]
                if (op & 0xc7) in (0xc2, 0xc4) and int(nr['address']) == pc + 1 \
                        and int(native[ni + 1]['address']) == pc + 2 \
                        and int(after['address']) == pc + 3 \
                        and int(after['status']) & 32 \
                        and (after['address'], after['data']) == (mr['address'], mr['data']):
                    omissions.append({'PC': pc, 'opcode': op, 'native_first_operand_tick': int(nr['tick'])})
                    ni += 2
                    continue
            mismatch = {'index': matched, 'native_index': ni, 'mame_index': mi, 'native': nr, 'mame': mr}
            break
        matched += 1
        if int(nr['status']) & 32:
            previous_opcode = int(nr['address']), int(nr['data'])
            t1 = int(nr['tick']) - 27
            delta = Decimal(mr['time']) * 50_400_000 - t1
            rounded = int(delta.to_integral_value())
            row = {'PC': int(nr['address']), 'opcode': int(nr['data']),
                   'native_t1': t1, 'mame_tick': mr['time'],
                   'epoch_delta_ticks': str(delta), 'matched_access_index': matched - 1}
            if not segments or segments[-1]['rounded_delta'] != rounded:
                segments.append({'rounded_delta': rounded, 'first': row, 'last': row, 'opcode_count': 1})
            else:
                segments[-1]['last'] = row
                segments[-1]['opcode_count'] += 1
        ni += 1
        mi += 1
    assert known_branch_crossing is not None
    # Independently verify the actual prior-IRQ stack values, not only the
    # observed ROM destinations after RET. This occurs at field2758's edge.
    edge = 2_259_353_600
    terminal_bus = rows('sim/results/physical-cpu-restart-corners-rtl-20261009/bus.csv')
    native_stack = [(int(r['tick']), int(r['address']), int(r['data'])) for r in terminal_bus
                    if r['kind'] == 'write' and edge < int(r['tick']) < edge + 500
                    and int(r['address']) in (0x7ffb, 0x7ffa)]
    assert native_stack == [(edge + 319, 0x7ffb, 5), (edge + 394, 0x7ffa, 0x90)]
    mame_stack = []
    with Path('sim/results/pixel-2760-irq-before-mame/video_writes.csv').open() as f:
        for r in csv.DictReader(f):
            tick = Decimal(r['time']) * 50_400_000
            if tick >= edge + 500:
                break
            if edge < tick and int(r['address']) in (0x7ffb, 0x7ffa):
                mame_stack.append({'tick': str(tick), 'address': int(r['address']), 'data': int(r['data'])})
    assert [r['data'] for r in mame_stack] == [5, 0xa0]
    known_branch_crossing.update(native_stack=native_stack, mame_stack=mame_stack,
                                 preceding_IRQ_edge=edge)
    assert mid_screen_crossing is not None and mid_screen_crossing['resumed_after_ISR']
    assert len(mid_screen_crossings) == 2
    for index, crossing in enumerate(mid_screen_crossings):
        mid_edge = edge + 460800 + index * 819200
        assert crossing['resumed_after_ISR']
        cpi = next(r for r in terminal_bus if r['kind'] == 'read' and int(r['address']) == 0x0a22
                   and abs(int(r['tick']) - mid_edge) < 500)
        cpi_t1 = int(cpi['tick']) - 27
        assert cpi_t1 == mid_edge + (-150, -75)[index]
        rst_t1 = cpi_t1 + 7 * 25
        mid_native_stack = [(int(r['tick']), int(r['address']), int(r['data'])) for r in terminal_bus
                            if r['kind'] == 'write' and mid_edge < int(r['tick']) < mid_edge + 500
                            and int(r['address']) in (0x7ff9, 0x7ff8)]
        assert mid_native_stack == [(rst_t1 + 169, 0x7ff9, 0x0a), (rst_t1 + 244, 0x7ff8, 0x24)]
        mid_mame_stack = []
        with Path('sim/results/pixel-2760-irq-before-mame/video_writes.csv').open() as f:
            for r in csv.DictReader(f):
                tick = Decimal(r['time']) * 50_400_000
                if tick >= mid_edge + 500:
                    break
                if mid_edge < tick and int(r['address']) in (0x7ff9, 0x7ff8):
                    mid_mame_stack.append({'tick': str(tick), 'address': int(r['address']), 'data': int(r['data'])})
        assert [r['data'] for r in mid_mame_stack] == [0x0a, 0x22]
        ack = next(r for r in terminal_bus if r['kind'] == 'ack' and mid_edge <= int(r['tick']) < mid_edge + 150)
        assert int(ack['tick']) == rst_t1 + 2
        mame_isr = next(r for r in reference if int(r['address']) == 8
                        and abs(Decimal(r['time']) * 50_400_000 - mid_edge) < 500)
        mame_rst_t1 = Decimal(mame_isr['time']) * 50_400_000 - 11 * 25
        lower, upper = ((-26, -25), (49, 50))[index]
        assert lower < mame_rst_t1 - mid_edge < upper
        crossing.update(IRQ_edge=mid_edge, native_CPI_sampled_t1=cpi_t1,
                        native_final_phi2=cpi_t1 + 6 * 25 + 19,
                        native_ACK=int(ack['tick']), native_stack=mid_native_stack,
                        mame_stack=mid_mame_stack, mame_atomic_RST_start=str(mame_rst_t1),
                        mame_atomic_RST_start_delta_request_ticks=str(mame_rst_t1 - mid_edge),
                        mame_atomic_RST_precedes_request=mame_rst_t1 < mid_edge)
    report = {'scope': 'ROM-read alignment with proven conditional operand omissions and one explicit prior-IRQ branch crossing',
              'native_anchor_offset': offset, 'matched_ROM_accesses': matched,
              'reference_accesses': len(reference), 'first_raw_sequence_difference': first_sequence_difference,
              'unexplained_sequence_mismatch': mismatch,
              'prior_IRQ_branch_crossing': known_branch_crossing,
              'mid_screen_IRQ_CPI_crossings': mid_screen_crossings,
              'reference_accesses_consumed': mi,
              'alignment_complete_for_reference_window': mi == len(reference) and mismatch is None,
              'opcode_epoch_segments': segments,
              'MAME_untaken_operand_omissions': {'count': len(omissions), 'first_16': omissions[:16], 'last_4': omissions[-4:],
                                                'source': 'D:/Arcade/AI/mame289/src/devices/cpu/i8085/i8085.cpp:821-847'},
              'file_sha256': {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in [
                  'sim/results/physical-cpu-restart-corners-rtl-20261009/bus.csv',
                  'sim/results/pixel-2760-irq-before-mame/irq_program_reads.csv',
                  'sim/results/pixel-2760-irq-before-mame/video_writes.csv',
                  'D:/Arcade/AI/mame289/src/devices/cpu/i8085/i8085.cpp', __file__]},
              'strict_graphics_gate_pass': False,
              'limits': ['Stops at the first unexplained sequence difference; only the explicit checked branch crossing is resumed.',
                         'Prior IRQ already has a -125-clock ISR opcode epoch. Its upstream cause is not established.',
                         'The extra post-return MAME JZ accounts for 250 clocks, changing the local epoch to +125.',
                         'Native opcode fetch before the field2758 edge is outside the saved bus windows; do not claim a directly observed pre-edge T1.',
                         'Three explicit IRQ crossings are checked against actual stack bytes; opcode alignment does not prove full state or graphics equivalence.',
                         'At the first mid-screen edge, MAME atomic RST is inferred to start about25 clocks before its request, reproducing the existing MB-18 symptom. The second edge does not predate its request.',
                         'MAME timestamps remain instruction-atomic; no electrical timing or graphics waiver follows. Quartus remains on hold.']}
    out = Path('docs/evidence/sheriff_clock_restart2758_epoch.json')
    out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'matched_reads': matched, 'reference_reads': len(reference),
                      'omitted_operand_pairs': len(omissions),
                      'epoch_segments': [{'delta': s['rounded_delta'], 'opcodes': s['opcode_count'],
                                          'first_PC': s['first']['PC'], 'last_PC': s['last']['PC']} for s in segments],
                      'branch_crossing': known_branch_crossing, 'first_unexplained_mismatch': mismatch}))


if __name__ == '__main__':
    main()
