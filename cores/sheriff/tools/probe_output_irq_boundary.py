#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Preserve the earliest ordered output timing change without waiving it."""
import argparse
import csv
import json
from pathlib import Path

from qualify_input_scheduler_boundary import digest, is_exact_prefix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, default=Path('sim/results/output-boundary-103-mame-20261009'))
    parser.add_argument('--timelines', type=Path, default=Path('_checks/output-103-adjacent-irqs.json'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    context = json.loads(Path('docs/evidence/sheriff_input_scheduler_boundary.json').read_text())
    first = context['ordered_output_value_prefix_through_1600']['first_changed_timing'][0]
    assert first['ordinal'] == 1786 and first['mame']['frame'] == '103'
    phase_change = float(first['delta_master_clocks']) - float(context['ordered_output_value_prefix_through_1600']['baseline_delta_master_clocks'])
    assert abs(phase_change + 325) < 0.01
    assert is_exact_prefix(args.capture / 'io.csv', Path('sim/results/restart-mame/io.csv'))
    timelines = json.loads(args.timelines.read_text())
    window = next(w for w in timelines['windows'] if w['frame'] == 104 and w['irq'] == 'mid')
    assert window['edge'] == 84_838_400
    pcs = {}
    for name, expected in [('mame', 0x0fef), ('rtl', 0x0ff2)]:
        high, low = window[name][:2]
        assert high['address'] == 0x7ffd and low['address'] == 0x7ffc
        pcs[name] = (high['data'] << 8) | low['data']
        assert pcs[name] == expected
    program = []
    signatures = set()
    with (args.capture / 'irq_program_reads.csv').open(newline='') as source:
        for row in csv.DictReader(source):
            tick = float(row['time']) * 50_400_000
            if abs(tick - window['edge']) <= 1200:
                address = int(row['address'])
                signatures.add((address, int(row['data'])))
                # ROM bytes remain private. This evidence retains access order/PC.
                program.append({'tick_delta': tick - window['edge'], 'address': address, 'pc': int(row['pc'])})
    assert {(0x0fef, 0x3a), (0x0ff2, 0xa7), (0x0ff3, 0xc2)} <= signatures
    with (args.capture / 'states.csv').open(newline='') as source:
        states = list(csv.DictReader(source))
    assert int(states[-1]['frame']) == 106
    files = [args.timelines, args.capture / 'io.csv', args.capture / 'states.csv',
             args.capture / 'video_writes.csv', args.capture / 'irq_program_reads.csv',
             args.capture / 'capture_features.json', Path('docs/evidence/sheriff_input_scheduler_boundary.json'),
             Path('sim/results/restart-phase-ce-rtl/memory_writes.bin'),
             Path(__file__)]
    report = {
        'scope': 'Earliest changed timing of an otherwise matching ordered output-write prefix; IRQ attribution diagnostic',
        'observations_verified': True,
        'reference_io_byte_prefix_equal': True,
        'capture_stop_frame': 106,
        'child_exit_code': None,
        'child_exit_limit': 'The existing launcher does not retain child exit status; terminal state and trace were inspected',
        'first_output_timing_change': first,
        'irq_window': window,
        'return_pc': pcs,
        'reference_program_accesses_near_irq_without_rom_bytes': program,
        'verified_instruction_classes': [{'pc': 0x0fef, 'mnemonic': 'LDA', 't_states': 13}, {'pc': 0x0ff2, 'mnemonic': 'ANA A', 't_states': 4}, {'pc': 0x0ff3, 'mnemonic': 'JNZ 0x0fef', 't_states_taken': 10}],
        'observed_output_phase_change_master_clocks': phase_change,
        'extra_instruction_clocks': 13 * 25,
        'known': 'MAME stacks 0x0fef; RTL stacks 0x0ff2. The first output timing offset changes by exactly one 13-T-state LDA, from approximately +6 to -319 master clocks.',
        'hypothesis': 'Instruction-atomic reference IRQ scheduling versus final-phi2 physical sampling selects opposite sides of this instruction boundary. The physical phase must be independently checked before qualifying the cause.',
        'next_action': 'Derive the final phi2 sampling window at this edge from the observed CPU phase and native bus events; then connect later recurring boundaries to the frame-2760/6780 pixel differences.',
        'cause_qualified': False,
        'pixel_2760_cause_qualified': False,
        'complete_graphics_gate': False,
        'complete_sheriff_gate': False,
        'rtl_changed': False,
        'quartus_executed': False,
        'sha256': {path.as_posix(): digest(path) for path in files},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'observations_verified': True, 'first_output_ordinal': first['ordinal'], 'return_pc': pcs, 'phase_change_master_clocks': -325, 'cause_qualified': False, 'output': args.output.as_posix()}))


if __name__ == '__main__':
    main()
