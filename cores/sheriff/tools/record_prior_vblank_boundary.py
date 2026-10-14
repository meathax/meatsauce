#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the directly observed pre-vblank ANA/JZ boundary in the frozen model."""
import csv
import hashlib
import json
from decimal import Decimal
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rows(path):
    with Path(path).open() as f:
        return list(csv.DictReader(f))


def main():
    run = Path('_checks/physical-cpu-prior-vblank-20261009')
    native = Path('sim/results/physical-cpu-prior-vblank-rtl-20261009')
    reference = Path('sim/results/prior-vblank-2758-mame-20261009')
    receipt = json.loads((run / 'result.json').read_text(encoding='utf-8-sig'))
    assert receipt['exit_code'] == 0 and receipt['frames_requested'] == 2759
    assert receipt['executable_sha256'].lower() == sha(receipt['executable'])
    assert receipt['inputs_sha256'].lower() == sha(receipt['inputs'])
    bus = rows(native / 'bus.csv')
    edge = 2_259_353_600
    fetches = [r for r in bus if r['kind'] == 'read' and int(r['status']) & 32 and not int(r['status']) & 1]
    final = max((r for r in fetches if int(r['tick']) < edge), key=lambda r: int(r['tick']))
    rom = Path('roms/sheriff.bin').read_bytes()
    assert int(final['address']) == 0x05a0 and rom[0x05a0] == 0xca
    assert int.from_bytes(rom[0x05a1:0x05a3], 'little') == 0x0590
    t1 = int(final['tick']) - 27
    assert t1 == edge - 100
    preceding = max((r for r in fetches if int(r['tick']) < int(final['tick'])), key=lambda r: int(r['tick']))
    assert int(preceding['address']) == 0x059f and rom[0x059f] == 0xa7
    ana_t1 = int(preceding['tick']) - 27
    assert ana_t1 == edge - 200
    rst_t1 = t1 + 10 * 25
    prediction = {'preceding_ANA_A_PC': int(preceding['address']), 'preceding_ANA_A_sampled_t1': ana_t1,
                  'preceding_ANA_A_last_phi2': ana_t1 + 3 * 25 + 19,
                  'JZ_PC': 0x05a0, 'JZ_target': 0x0590, 'JZ_sampled_t1': t1,
                  'JZ_last_phi2': t1 + 9 * 25 + 19, 'RST_sampled_t1': rst_t1,
                  'ACK': rst_t1 + 2, 'stack_high': rst_t1 + 169, 'stack_low': rst_t1 + 244}
    ack = next(r for r in bus if r['kind'] == 'ack' and edge <= int(r['tick']) < edge + 500)
    assert int(ack['tick']) == prediction['ACK']
    stack = [(int(r['tick']), int(r['address']), int(r['data'])) for r in bus
             if r['kind'] == 'write' and prediction['ACK'] < int(r['tick']) < edge + 500
             and int(r['address']) in (0x7ffb, 0x7ffa)]
    assert stack == [(prediction['stack_high'], 0x7ffb, 5), (prediction['stack_low'], 0x7ffa, 0x90)]
    mame = rows(reference / 'irq_program_reads.csv')
    # Atomic operand reads and the following opcode can share a timestamp.
    # Preserve the recorded access order when selecting the last pre-IRQ row.
    before = [r for r in mame if Decimal(r['time']) * 50_400_000 <= edge][-1]
    assert int(before['address']) == int(preceding['address'])
    mana_t1 = Decimal(before['time']) * 50_400_000
    isr = next(r for r in mame if int(r['address']) == 16 and edge < Decimal(r['time']) * 50_400_000 < edge + 500)
    mrst_t1 = Decimal(isr['time']) * 50_400_000 - 11 * 25
    assert abs(mrst_t1 - (mana_t1 + 4 * 25)) < Decimal('0.001')
    assert 124 < mana_t1 - ana_t1 < 125
    original = rows('sim/results/physical-cpu-restart-corners-rtl-20261009/bus.csv')
    overlapping = [r for r in bus if edge <= int(r['tick']) < edge + 819200]
    original_overlap = [r for r in original if edge <= int(r['tick']) < edge + 819200]
    assert overlapping == original_overlap
    files = [run / 'result.json', native / 'bus.csv', reference / 'irq_program_reads.csv',
             Path('docs/evidence/sheriff_prior_vblank_reference.json'),
             Path('docs/evidence/sheriff_cpu_phase_qualification.json'), Path(__file__)]
    report = {'scope': 'Direct saved-model pre-IRQ fetch observation and local independent ISA/clock prediction',
              'terminal_receipt': receipt, 'IRQ_edge': edge,
              'native_prediction': prediction, 'native_stack': stack,
              'MAME_preceding_ANA_A_PC': int(before['address']), 'MAME_ANA_A_fetch_tick': str(mana_t1),
              'MAME_atomic_RST_start': str(mrst_t1), 'MAME_minus_native_ANA_epoch': str(mana_t1 - ana_t1),
              'native_overlapping_bus_rows_exact': len(overlapping),
              'file_sha256': {p.as_posix(): sha(p) for p in files},
              'strict_graphics_gate_pass': False, 'current_worktree_board_qualified': False,
              'limits': ['Pre-edge native ANA A and JZ fetches are now directly observed, not inferred from operand accesses.',
                         'The local epoch gap precedes ANA A. Its upstream origin remains unqualified.',
                         'The leading MAME capture runtime exit is unknown; its transaction/overlap fidelity is independently recorded.',
                         'No raster/reference adjustment, physical memory qualification or graphics waiver follows. Quartus remains on hold.']}
    out = Path('docs/evidence/sheriff_prior_vblank_boundary.json')
    out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'native_exit': 0, 'ANA_PC': prediction['preceding_ANA_A_PC'],
                      'ANA_T1_delta': ana_t1 - edge, 'JZ_T1_delta': t1 - edge,
                      'ACK_delta': int(ack['tick']) - edge, 'MAME_ANA_epoch_gap': str(mana_t1 - ana_t1),
                      'overlap_rows': len(overlapping), 'graphics_pass': False}))


if __name__ == '__main__':
    main()
