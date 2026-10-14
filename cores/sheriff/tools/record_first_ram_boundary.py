#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Qualify the directly captured field-66 first RAM sequence difference."""
import csv
import hashlib
import json
from decimal import Decimal
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prefix(short, long):
    with short.open('rb') as a, long.open('rb') as b:
        count = 0
        while block := a.read(1024 * 1024):
            assert b.read(len(block)) == block, f'Prefix differs: {short}'
            count += len(block)
    return count


def main():
    root = Path('.')
    check = root / '_checks/first-ram66-20261009'
    native = root / 'sim/results/first-ram66-rtl-20261009'
    reference = root / 'sim/results/first-ram66-mame-20261009'
    receipt = json.loads((check / 'terminal.json').read_text(encoding='utf-8-sig'))
    mame_exit = json.loads((reference / 'exit.json').read_text(encoding='utf-8-sig'))
    assert receipt['exit_code'] == mame_exit['exit_code'] == 0
    assert receipt['frames_requested'] == mame_exit['frames_requested'] == 67
    assert sha(root / receipt['executable']) == receipt['executable_sha256']
    assert sha(root / receipt['inputs']) == receipt['inputs_sha256']
    assert sha(root / 'sim/mame_capture.lua') == mame_exit['lua_sha256'].lower()
    assert sha(root / 'tools/mame_capture.ps1') == mame_exit['launcher_sha256'].lower()
    matches = {
        'native_ram_write_bytes': prefix(native / 'memory_writes.bin', root /
            'sim/results/physical-cpu-restart-corners-rtl-20261009/memory_writes.bin'),
        'mame_ram_write_bytes': prefix(reference / 'video_writes.csv', root /
            'sim/results/prior-vblank-2758-mame-20261009/video_writes.csv'),
        'mame_io_bytes': prefix(reference / 'io.csv', root /
            'sim/results/prior-vblank-2758-mame-20261009/io.csv')}
    with (native / 'bus.csv').open() as stream:
        bus = list(csv.DictReader(stream))
    with (reference / 'irq_program_reads.csv').open() as stream:
        reads = list(csv.DictReader(stream))
    edge = 54_067_200
    ack = next(r for r in bus if r['kind'] == 'ack' and edge <= int(r['tick']) < edge + 100)
    preceding = [r for r in bus if r['kind'] == 'read' and int(r['status']) & 32
                 and int(r['address']) < 0x4000 and int(r['tick']) < int(ack['tick'])][-1]
    assert int(preceding['address']) == 0x0ff2 and int(preceding['data']) == 0xa7
    sampled_t1 = int(preceding['tick']) - 27
    # The bus-derived T1 tag is at counter phase7, not phase0. The final
    # active phi2 gate at phase19 is therefore tag+12. Reset-origin evidence
    # is in sheriff_reset_startup.json; this projects the source gate only.
    reset_evidence_path = root / 'docs/evidence/sheriff_reset_startup.json'
    reset_evidence = json.loads(reset_evidence_path.read_text(encoding='utf-8'))
    phase_model = reset_evidence['source_reset_model']
    assert phase_model['matching_phase_origins_among_25_candidates'] == [7]
    phi2_offset = phase_model['last_phi2_gate_sample_offset_from_final_cycle_T1_tag']
    assert phi2_offset == 12
    final_phi2 = sampled_t1 + (4 - 1) * 25 + phi2_offset
    predicted_rst_t1 = sampled_t1 + 4 * 25
    assert sampled_t1 == edge - 75 and final_phi2 == edge + 12
    assert int(ack['tick']) == predicted_rst_t1 + 2 == edge + 27
    stack = [r for r in bus if r['kind'] == 'write' and
             int(ack['tick']) < int(r['tick']) < int(ack['tick']) + 300][:2]
    assert [(int(r['address']), int(r['data'])) for r in stack] == [(0x7ffd, 0x0f), (0x7ffc, 0xf3)]
    assert [int(r['tick']) - predicted_rst_t1 for r in stack] == [169, 244]
    mame_ana = [r for r in reads if int(r['address']) == 0x0ff2
                and Decimal(r['time']) * 50_400_000 < edge][-1]
    mame_jnz = [r for r in reads if int(r['address']) == 0x0ff3
                and Decimal(r['time']) * 50_400_000 < edge][-1]
    # Read the actual parent ROM locally to guard the instruction and target;
    # do not publish its bytes in the report.
    rom = (root / 'roms/sheriff.bin').read_bytes()
    assert rom[0x0ff3] == 0xc2 and int.from_bytes(rom[0x0ff4:0x0ff6], 'little') == 0x0fef
    isr = next(r for r in reads if int(r['address']) == 0x10 and
               Decimal(r['time']) * 50_400_000 > edge)
    mame_stack = []
    with (reference / 'video_writes.csv').open() as stream:
        for r in csv.DictReader(stream):
            tick = Decimal(r['time']) * 50_400_000
            if edge <= tick <= edge + 700 and int(r['address']) in (0x7ffd, 0x7ffc):
                mame_stack.append(r)
    assert [(int(r['address']), int(r['data'])) for r in mame_stack] == [(0x7ffd, 0x0f), (0x7ffc, 0xef)]
    ana_tick = Decimal(mame_ana['time']) * 50_400_000
    jnz_tick = Decimal(mame_jnz['time']) * 50_400_000
    rst_start = Decimal(isr['time']) * 50_400_000 - 11 * 25
    assert abs((jnz_tick + 10 * 25) - rst_start) < Decimal('0.0001')
    first_fetch = next(r for r in bus if r['kind'] == 'read' and int(r['status']) & 32)
    result = {
        'native_exit_receipt': receipt, 'mame_exit_receipt': mame_exit,
        'exact_prefixes': matches,
        'clock_projection': {'origin_evidence': reset_evidence_path.as_posix(),
                             'sha256': sha(reset_evidence_path),
                             'tag_counter_phase': 7, 'last_phi2_tag_offset': phi2_offset},
        'irq_edge': edge,
        'native': {'instruction': 'ANA A', 'PC': 0x0ff2, 'T_states': 4,
                   'opcode_DBIN_from_edge': int(preceding['tick']) - edge,
                   'sampled_T1_from_edge': sampled_t1 - edge,
                   'final_phi2_from_edge': final_phi2 - edge,
                   'RST_sampled_T1_from_edge': predicted_rst_t1 - edge,
                   'ACK_from_edge': int(ack['tick']) - edge,
                   'stack_writes_from_edge': [int(r['tick']) - edge for r in stack],
                   'return_PC': 0x0ff3,
                   'first_opcode_PC': int(first_fetch['address']),
                   'first_opcode_sampled_T1': int(first_fetch['tick']) - 27},
        'mame': {'ANA_fetch_from_edge': str(ana_tick - edge),
                 'ANA_epoch_minus_native_T1': str(ana_tick - sampled_t1),
                 'JNZ_fetch_from_edge': str(jnz_tick - edge),
                 'JNZ_PC': 0x0ff3, 'taken_target': 0x0fef, 'JNZ_T_states': 10,
                 'atomic_RST_start_from_edge': str(rst_start - edge),
                 'return_PC': 0x0fef, 'RST_predates_request': rst_start < edge},
        'sources': {p.as_posix(): sha(p) for p in [Path(__file__),
            native / 'bus.csv', native / 'memory_writes.bin',
            reference / 'irq_program_reads.csv', reference / 'video_writes.csv',
            check / 'terminal.json', reference / 'exit.json', reset_evidence_path]},
        'reference_offset_or_tolerance_used_for_graphics': False,
        'graphics_gate_qualified': False,
        'current_board_source_qualified': False,
        'scope': 'Direct IRQ ordering and saved-model ISA/clock prediction only. '
                 'Absolute boot/raster phase and electrical memory/READY behavior remain open.'}
    out = root / 'docs/evidence/sheriff_first_ram_boundary.json'
    out.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'native': result['native'], 'mame': result['mame'],
                      'prefixes': matches, 'evidence': out.as_posix()}))


if __name__ == '__main__':
    main()
