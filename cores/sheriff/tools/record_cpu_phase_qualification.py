#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record actual focused results for the related-board CPU clock enables."""
import csv
import hashlib
import json
import struct
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rows(path):
    with path.open(newline='', encoding='utf-8') as source:
        return list(csv.DictReader(source))


def main():
    run = Path('_checks/physical-cpu-phases-20261009')
    build = Path('sim/build/physical-cpu-phase-20261009')
    native = Path('sim/results/physical-cpu-phase-rtl-20261009')
    receipt = json.loads((run / 'result.json').read_text(encoding='utf-8-sig'))
    assert receipt['build_service_exit_code'] == receipt['run_exit_code'] == 0
    assert receipt['frames'] == 106
    recovery_path = run / 'source-recovery.json'
    recovery = json.loads(recovery_path.read_text()) if recovery_path.exists() else {}
    source_files = []
    for name, expected in receipt['source_sha256'].items():
        actual = Path(name)
        if digest(actual).upper() != expected.upper():
            # Concurrent edits must not be certified by an older executable.
            # Recovery is explicit and still must match the original receipt.
            actual = Path(recovery[name]['snapshot'])
        assert digest(actual).upper() == expected.upper(), name
        source_files.append(actual)
    cpu = rows(build / 'cpu/cpu_qualification.csv')
    assert [int(row['data']) for row in cpu] == [24, 0, 1, 85, 18, 52, 127, 165, 119]
    assert all(row['kind'] == 'out' and int(row['address']) == 0 for row in cpu)
    cadence = rows(build / 'cpu-timing/cpu_timing.csv')
    assert len(cadence) == 486 and all(int(row['pass']) == 1 for row in cadence)
    stdout = (run / 'stdout.log').read_text(encoding='utf-8-sig')
    assert 'PASS: 75 mid-read RAM-service cases, paused bus stable, simultaneous release protected, LDA/OUT byte exact' in stdout
    assert 'frames=106 writes=30052 IRQ acknowledges=162 address=ff5' in stdout
    comparison = json.loads((run / 'video-comparison.json').read_text())
    assert len(comparison['checks']) == 6 and comparison['total_mismatch_pixels'] == 0
    startup = rows(native / 'cpu_startup.csv')
    first_sync = min(int(r['tick']) for r in startup if int(r['sync']))
    first_dbin = min(int(r['tick']) for r in startup if int(r['dbin']))
    assert (first_sync, first_dbin) == (52, 77)
    bus = rows(native / 'bus.csv')
    # Current phase enables start a sampled T state at phase 0. SYNC rises
    # two observer clocks later and opcode DBIN one 25-clock T state later.
    # Calibrate ordinary instructions before observing the IRQ stack.
    assert first_sync % 25 == 2 and first_dbin - first_sync == 25
    fetch_offset = 27
    calibration = {}
    for opcode, name, duration, expected_writes in [(0xcd, 'CALL', 425, [319, 394]), (0x77, 'MOV M,A', 175, [144])]:
        cases = []
        for index, row in enumerate(bus):
            if row['kind'] != 'read' or not int(row['status']) & 32 or int(row['status']) & 1 or int(row['data']) != opcode or int(row['tick']) >= 200_000:
                continue
            following = next(j for j in range(index + 1, len(bus)) if bus[j]['kind'] == 'read' and int(bus[j]['status']) & 32 and not int(bus[j]['status']) & 1)
            start = int(row['tick']) - fetch_offset
            offsets = [int(r['tick']) - start for r in bus[index + 1:following] if r['kind'] == 'write']
            assert start % 25 == 0 and offsets == expected_writes
            assert int(bus[following]['tick']) - int(row['tick']) == duration
            cases.append({'pc': int(row['address']), 'sampled_t1_start': start, 'duration': duration, 'write_offsets': offsets})
            if len(cases) == 3:
                break
        assert len(cases) == 3
        calibration[name] = cases
    edge = 84_838_400
    window = [r for r in bus if abs(int(r['tick']) - edge) < 700 and (r['kind'] == 'ack' or r['kind'] == 'read' and int(r['status']) & 32 and not int(r['status']) & 1)]
    writes = list(struct.iter_unpack('<QHB', (native / 'memory_writes.bin').read_bytes()))
    stack = [w for w in writes if edge <= w[0] < edge + 800 and w[1] in (0x7ffd, 0x7ffc)]
    assert len(stack) == 2
    native_pc = (stack[0][2] << 8) | stack[1][2]
    mame_file = Path('sim/results/output-boundary-103-mame-20261009/video_writes.csv')
    mame_stack = [r for r in rows(mame_file) if int(r['address']) in (0x7ffd, 0x7ffc) and abs(float(r['time']) * 50_400_000 - edge) < 1000]
    assert len(mame_stack) == 2
    mame_pc = (int(mame_stack[0]['data']) << 8) | int(mame_stack[1]['data'])
    assert native_pc == mame_pc == 0x0fef
    fetches = [r for r in bus if r['kind'] == 'read' and int(r['status']) & 32 and not int(r['status']) & 1]
    jnz = max((r for r in fetches if int(r['address']) == 0x0ff3 and int(r['tick']) < edge), key=lambda r: int(r['tick']))
    lda = max((r for r in fetches if int(r['address']) == 0x0fef and int(r['tick']) < int(jnz['tick'])), key=lambda r: int(r['tick']))
    ana = next(r for r in fetches if int(r['tick']) > int(lda['tick']))
    rom = Path('roms/sheriff.bin').read_bytes()
    assert rom[0x0fef] == 0x3a and rom[0x0ff2] == 0xa7 and rom[0x0ff3] == 0xc2
    lda_address = int.from_bytes(rom[0x0ff0:0x0ff2], 'little')
    target = int.from_bytes(rom[0x0ff4:0x0ff6], 'little')
    data_reads = [r for r in bus if r['kind'] == 'read' and int(r['address']) == lda_address and int(lda['tick']) < int(r['tick']) < int(ana['tick'])]
    assert len(data_reads) == 1 and int(data_reads[0]['data']) != 0
    assert int(ana['address']) == 0x0ff2
    assert int(ana['tick']) - int(lda['tick']) == 13 * 25
    assert int(jnz['tick']) - int(ana['tick']) == 4 * 25
    start = int(jnz['tick']) - fetch_offset
    final_phi2 = start + 9 * 25 + 19
    rst_start = start + 10 * 25
    assert start % 25 == 0 and start < edge <= final_phi2 < rst_start
    ack = next(r for r in bus if r['kind'] == 'ack' and int(r['tick']) >= edge)
    predicted = {'ack': rst_start + 2, 'stack_high': rst_start + 169, 'stack_low': rst_start + 244, 'return_pc': target}
    assert (int(ack['tick']), stack[0][0], stack[1][0], native_pc) == (predicted['ack'], predicted['stack_high'], predicted['stack_low'], predicted['return_pc'])
    files = source_files
    if recovery_path.exists():
        files.append(recovery_path)
    files += [Path(__file__), Path('tools/derive_sheriff_clocks.py'), Path('docs/evidence/sheriff_clock_network.json'), run / 'result.json', run / 'stdout.log', run / 'stderr.log', run / 'video-comparison.json', mame_file]
    files += [build / name for name in ['cpu/cpu_qualification.csv', 'cpu/Vn8080_cpu', 'cpu-timing/cpu_timing.csv', 'cpu-timing/Vn8080_cpu', 'service/Vn8080_board', 'board/Vn8080_board']]
    files += [native / name for name in ['bus.csv', 'cpu_startup.csv', 'io.csv', 'memory_writes.bin']]
    report = {
        'scope': 'Related Bandido clock-network enables and focused Sheriff real-ROM qualification',
        'tested_source_recovery': recovery,
        'current_worktree_board_qualified': digest(Path('rtl/n8080_board.sv')).upper() == receipt['source_sha256']['rtl/n8080_board.sv'].upper(),
        'cpu_architectural_observed_out_values': [int(r['data']) for r in cpu],
        'cpu_documented_cadence_cases': len(cadence), 'cpu_csv_checks_pass': True,
        'cpu_command': 'wsl.exe -d Ubuntu --cd D:/Arcade/AI/aCORES/sherrif --exec make -C sim cpu cpu-timing BUILD=/mnt/d/Arcade/AI/aCORES/sherrif/sim/build/physical-cpu-phase-20261009',
        'cpu_terminal_receipt_limit': 'Original successful make/tool output was observed in the chat; no separate terminal stdout receipt was saved. CSVs and executable hashes are retained. No synthetic stdout log is substituted.',
        'service_cases': 75, 'service_and_build_exit_code': receipt['build_service_exit_code'],
        'native_frames': receipt['frames'], 'native_exit_code': receipt['run_exit_code'],
        'captured_rgb_fields': comparison['checks'], 'zero_mismatches_in_six_captured_fields': True,
        'video_reference_scope': comparison['scope'],
        'startup_first_sync_tick': first_sync, 'startup_first_opcode_dbin_tick': first_dbin,
        'sampled_t1_to_opcode_dbin_offset': fetch_offset, 'ordinary_instruction_calibration': calibration,
        'frame_103_irq': {'edge_tick': edge, 'observed_bus': [{k: v for k, v in r.items() if k != 'data'} for r in window], 'stack': [{'tick': t, 'address': a, 'data': v} for t, a, v in stack], 'native_return_pc': native_pc, 'mame_return_pc': mame_pc,
                         'jnz_sampled_t1_start': start, 'jnz_last_sampled_phi2_tick': final_phi2, 'rst_sampled_t1_start': rst_start,
                         'branch_condition_from_pre_irq_ram_read': {'address': lda_address, 'data_nonzero': True, 'ana_sets_zero_flag': False},
                         'predicted_ack_stack_and_return': predicted, 'prediction_anchored_to_irq_stack': False,
                         'sampled_enable_boundary_prediction_pass': True},
        'limits': [
            'Related Bandido Boolean waveform only: exact Sheriff connectivity, absolute CPU/pixel phase and electrical delays remain unqualified.',
            'Frame-103 sampled-enable prediction uses ordinary bus calibration, independent instruction durations and the preceding RAM read. Absolute electrical timing and all other IRQ boundaries remain unqualified.',
            'IRQ and bus timing changed. Older opcode/IRQ and full-wrapper evidence applies to its saved source, not this CPU waveform.',
            'Long-gameplay corners and physical DRAM/video-load/READY timing are still pending.',
            'The scanout oracle still models continuous per-pixel RAM reads; six captured fields do not establish physical byte-fetch timing.',
        ],
        'complete_graphics_gate': False, 'complete_irq_gate': False,
        'complete_sheriff_gate': False, 'quartus_executed': False,
        'sha256': {p.as_posix(): digest(p) for p in files},
    }
    output = Path('docs/evidence/sheriff_cpu_phase_qualification.json')
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'report': output.as_posix(), 'cadence_cases': len(cadence), 'service_cases': 75, 'native_frames': 106, 'captured_fields': 6, 'mismatched_pixels': 0, 'frame103_return_pc': hex(native_pc)}))


if __name__ == '__main__':
    main()
