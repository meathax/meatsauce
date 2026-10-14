#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record the terminal saved-source replay at the first third-round corner."""
import csv
import hashlib
import json
import struct
from decimal import Decimal
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rows(path):
    with path.open(newline='', encoding='utf-8') as source:
        return list(csv.DictReader(source))


def main():
    run = Path('_checks/physical-cpu-round2400-20261009')
    receipt_path = run / 'result.json'
    receipt = json.loads(receipt_path.read_text(encoding='utf-8-sig'))
    assert receipt['exit_code'] == 0 and receipt['frames_requested'] == 2401
    assert receipt['bus_windows'] == [2398, 2399]
    native = Path(receipt['output'])
    executable = Path(receipt['executable'])
    assert digest(executable).upper() == receipt['source_sha256'][executable.as_posix()]
    assert digest(Path(receipt['inputs'])).upper() == receipt['source_sha256'][receipt['inputs']]
    short = json.loads(Path('docs/evidence/sheriff_cpu_phase_qualification.json').read_text())
    recovery = short['tested_source_recovery']
    for name in ['rtl/n8080_board.sv', 'rtl/n8080_cpu.sv', 'rtl/n8080_vm80a_ce.v', 'sim/board_harness.cpp']:
        assert digest(Path(recovery[name]['snapshot'])).upper() == receipt['source_sha256'][name]
    comparison_path = run / 'video-comparison.json'
    comparison = json.loads(comparison_path.read_text())
    assert len(comparison['checks']) == 45 and comparison['total_mismatch_pixels'] == 0
    assert {c['frame'] for c in comparison['checks']} >= {2400, 2401}
    baseline_path = Path('docs/evidence/sheriff_rounds_pixel_2400_boundary.json')
    baseline = json.loads(baseline_path.read_text())
    sample = int(baseline['sample_tick'])
    edge = 1_965_260_800
    bus = rows(native / 'bus.csv')
    fetches = [r for r in bus if r['kind'] == 'read' and int(r['status']) & 32 and not int(r['status']) & 1]
    final = max((r for r in fetches if int(r['tick']) <= edge + 27), key=lambda r: int(r['tick']))
    pc = int(final['address'])
    rom = Path('roms/sheriff.bin').read_bytes()
    assert pc == 0x0890 and rom[pc] == 0xa7  # ANA A, four documented T states.
    start = int(final['tick']) - short['sampled_t1_to_opcode_dbin_offset']
    last_phi2 = start + 3 * 25 + 19
    rst = start + 4 * 25
    assert start % 25 == 0 and start < edge <= last_phi2 < rst
    ack = next(r for r in bus if r['kind'] == 'ack' and int(r['tick']) >= edge)
    with (native / 'memory_writes.bin').open('rb') as source:
        raw = source.read()
    stack = []
    pixel_writes = []
    for tick, address, data in struct.iter_unpack('<QHB', raw):
        if edge <= tick < edge + 400 and address >= 0x6000:
            stack.append((tick, address, data))
        if abs(tick - sample) < 1000 and address == 0x4424:
            pixel_writes.append((tick, address, data))
    assert len(stack) == 2 and stack[0][1] == stack[1][1] + 1
    predicted = {'ack_tick': rst + 2, 'stack_high_tick': rst + 169, 'stack_low_tick': rst + 244, 'return_pc': pc + 1}
    native_pc = (stack[0][2] << 8) | stack[1][2]
    assert (int(ack['tick']), stack[0][0], stack[1][0], native_pc) == tuple(predicted.values())
    assert pixel_writes == [(sample - 69, 0x4424, 0)]
    mame = Path(baseline['mame_capture'])
    mame_stack = [r for r in rows(mame / 'video_writes.csv') if edge <= Decimal(r['time']) * 50_400_000 < edge + 400 and int(r['address']) >= 0x6000]
    assert len(mame_stack) == 2
    mame_pc = (int(mame_stack[0]['data']) << 8) | int(mame_stack[1]['data'])
    assert mame_pc == native_pc == 0x0891
    files = [Path(__file__), receipt_path, run / 'stdout.log', run / 'stderr.log', comparison_path, executable, Path(receipt['inputs']), baseline_path, Path('docs/evidence/sheriff_cpu_phase_qualification.json'), native / 'bus.csv', native / 'memory_writes.bin', native / 'io.csv', mame / 'video_writes.csv', mame / 'io.csv', native / 'frame_02400.ppm', native / 'frame_02401.ppm']
    report = {
        'scope': 'Saved cb67879 source, corrected CPU waveform, first third-round frame-2400 corner',
        'terminal_exit_code': receipt['exit_code'], 'frames_requested': receipt['frames_requested'],
        'revision': receipt['revision'], 'source_sha256_at_launch': receipt['source_sha256'],
        'tested_source_recovery': recovery,
        'current_worktree_board_qualified': digest(Path('rtl/n8080_board.sv')).upper() == receipt['source_sha256']['rtl/n8080_board.sv'],
        'rgb_fields_compared': len(comparison['checks']), 'total_mismatch_pixels': 0,
        'captured_fields': [c['frame'] for c in comparison['checks']],
        'reference_uses_fpga_ram_or_pixels': comparison['reference_uses_fpga_ram_or_pixels'],
        'pixel_corner': {'frame': 2400, 'x': 33, 'y': 33, 'address': 0x4424, 'sample_tick': sample, 'old_native_clear_delta': baseline['rtl_writes'][0]['delta_from_sample'], 'mame_clear_delta': baseline['mame_writes'][0]['delta_from_sample'], 'new_native_clear_delta': -69, 'strict_current_scanout_corner_pass': True},
        'preceding_irq': {'edge_tick': edge, 'last_instruction': 'ANA A', 'pc': pc, 'opcode_dbin_tick': int(final['tick']), 'sampled_t1_start': start, 'last_sampled_phi2_tick': last_phi2, 'rst_sampled_t1_start': rst, 'predicted': predicted, 'actual_ack_tick': int(ack['tick']), 'actual_stack_ticks': [w[0] for w in stack], 'stack_addresses': [w[1] for w in stack], 'native_return_pc': native_pc, 'mame_return_pc': mame_pc, 'prediction_uses_irq_stack_as_anchor': False, 'sampled_boundary_prediction_pass': True},
        'limits': [
            '45 captured fields pass, including the old first differing corner; intervening uncaptured fields and later scenarios are not hereby qualified.',
            'This uses the existing continuous-RAM scanout oracle, not a completed physical serializer/DRAM-load timing model.',
            'Clock levels came from the connected related-board network, not a fitted IRQ/raster offset or image tolerance.',
            'Current IRQ prediction explains the saved model. Exact Sheriff net identity, absolute/electrical clock timing and memory arbitration remain open.',
            'Older source lacked the pre-IRQ opcode window; no retrospective independent reconstruction of that window is claimed.',
            'Concurrent board/display edits are preserved and are not qualified by this immutable executable.',
            'Later restart/round/color/audio, full-wrapper, exact-source Quartus and hardware release gates remain pending.',
        ],
        'complete_graphics_gate': False, 'complete_sheriff_gate': False, 'quartus_executed': False,
        'sha256': {f.as_posix(): digest(f) for f in files},
    }
    output = Path('docs/evidence/sheriff_clock_round2400.json')
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'native_frames': 2401, 'exit_code': 0, 'rgb_fields': 45, 'mismatch_pixels': 0, 'irq_prediction_pass': True, 'return_pc': hex(native_pc), 'report': output.as_posix()}))


if __name__ == '__main__':
    main()
