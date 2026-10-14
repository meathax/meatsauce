#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Qualify the frame-103 IRQ corner from actual opcode bus events and ISA timing."""
import argparse
import csv
import json
import struct
from decimal import Decimal
from pathlib import Path

from qualify_input_scheduler_boundary import digest, is_exact_prefix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', type=Path, default=Path('sim/results/output-boundary-103-rtl-20261009'))
    parser.add_argument('--mame', type=Path, default=Path('sim/results/output-boundary-103-mame-20261009'))
    parser.add_argument('--receipt', type=Path, default=Path('_checks/output-103-native-20261009/result.json'))
    parser.add_argument('--harness-source', type=Path, default=Path('_checks/output-103-native-20261009/board_harness-caac6cd.cpp'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    receipt = json.loads(args.receipt.read_text(encoding='utf-8-sig'))
    assert receipt['exit_code'] == 0 and receipt['frames_requested'] == 106 and receipt['bus_frame'] == 102
    for name in ['io.csv', 'memory_writes.bin']:
        assert is_exact_prefix(args.rtl / name, Path('sim/results/restart-phase-ce-rtl') / name), 'Fresh native CPU trace changed'
    with (args.rtl / 'cpu_startup.csv').open(newline='') as source:
        startup = list(csv.DictReader(source))
    sync = min(int(r['tick']) for r in startup if int(r['sync']))
    dbin = min(int(r['tick']) for r in startup if int(r['dbin']))
    assert dbin - sync == 25
    epoch = sync - 13
    assert epoch == 18
    fetch_offset = dbin - epoch
    assert fetch_offset == 38
    edge = 84_838_400
    with (args.rtl / 'bus.csv').open(newline='') as source:
        all_bus = list(csv.DictReader(source))
    bus = [r for r in all_bus if abs(int(r['tick']) - edge) < 2000]
    calibration = {'CALL': [], 'MOV M,A': []}
    for i, row in enumerate(all_bus):
        if row['kind'] != 'read' or not int(row['status']) & 0x20 or int(row['status']) & 1 or int(row['tick']) >= 200_000:
            continue
        opcode = int(row['data'])
        name = 'CALL' if opcode == 0xcd else 'MOV M,A' if opcode == 0x77 else None
        if name is None or len(calibration[name]) == 3:
            continue
        phi1 = int(row['tick']) - fetch_offset
        offsets = []
        for following in all_bus[i+1:]:
            if following['kind'] == 'read' and int(following['status']) & 0x20 and not int(following['status']) & 1:
                duration = int(following['tick']) - int(row['tick'])
                break
            if following['kind'] == 'write':
                offsets.append(int(following['tick']) - phi1)
        else:
            raise AssertionError('Calibration instruction has no following opcode')
        assert offsets == ([326, 401] if name == 'CALL' else [151])
        assert duration == (425 if name == 'CALL' else 175)
        calibration[name].append({'opcode_pc': int(row['address']), 'phi1_tick': phi1, 'write_offsets': offsets, 'duration_master_clocks': duration})
    assert all(len(cases) == 3 for cases in calibration.values())
    fetches = [r for r in bus if r['kind'] == 'read' and int(r['status']) & 0x20 and not int(r['status']) & 1]
    jnz = max((r for r in fetches if int(r['address']) == 0x0ff3 and int(r['tick']) < edge), key=lambda r: int(r['tick']))
    lda = next(r for r in fetches if int(r['tick']) > int(jnz['tick']))
    assert int(lda['address']) == 0x0fef
    rom = Path('roms/sheriff.bin').read_bytes()
    assert rom[0x0ff3] == 0xc2 and rom[0x0fef] == 0x3a
    target = int.from_bytes(rom[0x0ff4:0x0ff6], 'little')
    assert target == 0x0fef
    jnz_phi1 = int(jnz['tick']) - fetch_offset
    lda_phi1 = jnz_phi1 + 10 * 25
    assert int(lda['tick']) == lda_phi1 + fetch_offset
    assert (jnz_phi1 - epoch) % 25 == (lda_phi1 - epoch) % 25 == 0
    jnz_phi2_close = jnz_phi1 + 9 * 25 + 24
    lda_phi2_close = lda_phi1 + 12 * 25 + 24
    assert jnz_phi2_close < edge < lda_phi2_close
    rst_phi1 = lda_phi1 + 13 * 25
    predicted = {'ack': rst_phi1 + 13, 'stack_high': rst_phi1 + 7 * 25 + 1, 'stack_low': rst_phi1 + 10 * 25 + 1}
    ack = next(r for r in bus if r['kind'] == 'ack' and int(r['tick']) >= edge)
    assert int(ack['tick']) == predicted['ack']
    writes = list(struct.iter_unpack('<QHB', (args.rtl / 'memory_writes.bin').read_bytes()))
    high = next(w for w in writes if w[0] >= edge and w[1] == 0x7ffd)
    low = next(w for w in writes if w[0] >= edge and w[1] == 0x7ffc)
    assert high[0] == predicted['stack_high'] and low[0] == predicted['stack_low']
    predicted_pc = target + 3
    assert (high[2] << 8) | low[2] == predicted_pc
    with (args.mame / 'video_writes.csv').open(newline='') as source:
        mame_stack = [r for r in csv.DictReader(source) if int(r['address']) in (0x7ffd, 0x7ffc) and abs(Decimal(r['time']) * 50_400_000 - edge) < 1000]
    assert len(mame_stack) == 2
    mame_pc = (int(mame_stack[0]['data']) << 8) | int(mame_stack[1]['data'])
    assert mame_pc == target
    assert mame_stack[0]['time'] == mame_stack[1]['time']
    cpu_as = 10**18 // 2_016_000
    pixel_as = 10**18 // 5_040_000
    cycles = edge // 25
    irq_as = edge // 10 * pixel_as
    old_boundary_as = (cycles - 1) * cpu_as
    residual_as = irq_as - old_boundary_as
    assert 0 < residual_as < cpu_as
    mame_push_as = Decimal(mame_stack[0]['time']) * 10**18
    assert abs(mame_push_as - (cycles + 10) * cpu_as) < 500_500
    files = [args.receipt, args.rtl / 'bus.csv', args.rtl / 'cpu_startup.csv', args.rtl / 'io.csv',
             args.rtl / 'memory_writes.bin', args.mame / 'video_writes.csv',
             Path(receipt['executable']), args.harness_source, Path(__file__),
             Path('docs/evidence/sheriff_output_103_boundary.json')]
    report = {
        'scope': 'Physical final-phi2 IRQ sampling and earliest output timing change at one frame-103 midscreen boundary',
        'boundary_explanation_pass': True,
        'native_exit_code': receipt['exit_code'],
        'native_frames': 106,
        'native_harness_source_recovery': {'revision': 'caac6cd', 'path': 'sim/board_harness.cpp', 'snapshot': args.harness_source.as_posix()},
        'fresh_native_cpu_io_and_memory_byte_prefix_equal': True,
        'raster_edge_tick': edge,
        'startup_phi1_epoch': epoch,
        'opcode_dbin_offset_from_phi1': fetch_offset,
        'independently_observed_instruction_bus_calibration': calibration,
        'native_observed_opcode_fetches': [{'pc': int(r['address']), 'tick': int(r['tick'])} for r in [jnz, lda]],
        'jnz_phi1_tick': jnz_phi1,
        'jnz_final_phi2_close_tick': jnz_phi2_close,
        'lda_phi1_tick': lda_phi1,
        'lda_final_phi2_close_tick': lda_phi2_close,
        'predicted_rst_phi1_tick': rst_phi1,
        'predicted_bus_ticks': predicted,
        'actual_bus_ticks': {'ack': int(ack['tick']), 'stack_high': high[0], 'stack_low': low[0]},
        'predicted_hardware_return_pc': predicted_pc,
        'actual_hardware_return_pc': (high[2] << 8) | low[2],
        'mame_return_pc': mame_pc,
        'prediction_uses_irq_stack_for_instruction_anchor': False,
        'mame_scheduler': {'cpu_cycle_as': cpu_as, 'pixel_cycle_as': pixel_as, 'residual_as': residual_as, 'sub_cycle_deficit_as': cpu_as - residual_as, 'old_local_boundary_nominal_tick': edge - 25, 'atomic_stack_nominal_tick': edge + 250},
        'explanation': 'The JNZ final phi2 aperture closes eight clocks before IRQ. The actual CPU starts LDA seven clocks before IRQ and completes its 13 T states before interrupt entry. MAME processes the timer before resuming at its older instruction boundary, stacking the pre-LDA PC. Independent ISA durations and observed opcode fetches predict actual ACK, both stack writes and the return PC exactly.',
        'manual_url': 'https://bitsavers.org/components/intel/MCS80/Intellec_8_Mod_80/Intel_Intellec_8_Mod_80_Reference_Manual_Feb75.pdf',
        'manual_rule': 'Interrupt Sequences/Figure 2-8: enabled asynchronous INT is reclocked with phi2 in the final instruction state',
        'raw_timing_difference_retained': True,
        'pixel_2760_cause_qualified': False,
        'complete_irq_gate': False,
        'complete_graphics_gate': False,
        'complete_sheriff_gate': False,
        'rtl_changed': False,
        'quartus_executed': False,
        'sha256': {path.as_posix(): digest(path) for path in files},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'boundary_explanation_pass': True, 'jnz_phi2_close_delta': jnz_phi2_close - edge, 'predicted_bus_deltas': {k: v-edge for k, v in predicted.items()}, 'hardware_return_pc': hex(predicted_pc), 'output': args.output.as_posix()}))


if __name__ == '__main__':
    main()
