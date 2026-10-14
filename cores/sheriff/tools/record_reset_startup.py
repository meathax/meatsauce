#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Observe initial MAME/native ROM-read epochs without altering either clock."""
import csv
import hashlib
import json
from decimal import Decimal
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def reset_pin_model(phase, steps):
    """Source-derived gates through first DBIN, before opcode execution.

    Follows the staged vm80a and generated CE adapter; preserve their
    CC-BY-3.0 attribution in rtl/vendor/vm80a and the project's credits.

    RESET has settled high for many clocks, pin_ready=1, HOLD=0. EOM,
    halt and interrupt start terms are inactive in this initial window.
    Updates are simultaneous, as in the donor's nonblocking assignments.
    """
    state = dict(t404=1, reset=1, t953=1, t1=1, t1f1=0,
                 t2=0, t1011=0, t1124=0, sync=0, dbin=0)
    samples = []
    for tick in range(steps):
        samples.append({'tick': tick, 'phase': phase,
                        'sync': state['sync'], 'dbin': state['dbin']})
        after = state.copy()
        if phase < 5:
            after.update(t404=0, t953=state['reset'],
                         t1f1=state['t1'] & (not state['reset']),
                         t1011=state['t1'] & (not state['reset']),
                         t1124=state['t2'])
        if 8 <= phase < 20:
            after.update(reset=state['t404'], t1=state['t953'],
                         t2=(not state['t953']) & state['t1f1'],
                         sync=state['t1011'], dbin=state['t1124'])
        state, phase = after, (phase + 1) % 25
    return samples


def main():
    native = Path('sim/results/first-ram66-rtl-20261009')
    reference = Path('sim/results/reset-startup-mame-20261009')
    terminal = Path('_checks/first-ram66-20261009/terminal.json')
    native_exit = json.loads(terminal.read_text(encoding='utf-8-sig'))
    mame_exit = json.loads((reference / 'exit.json').read_text(encoding='utf-8-sig'))
    assert native_exit['exit_code'] == mame_exit['exit_code'] == 0
    assert mame_exit['frames_requested'] == 3
    assert sha(Path(native_exit['executable'])) == native_exit['executable_sha256']
    assert sha(Path(native_exit['inputs'])) == native_exit['inputs_sha256']
    assert sha(Path('sim/mame_capture.lua')) == mame_exit['lua_sha256'].lower()
    assert sha(Path('tools/mame_capture.ps1')) == mame_exit['launcher_sha256'].lower()
    # These exact sources produced the saved immutable model. Do not extend
    # its qualification to unrelated current board/display changes.
    provenance_path = Path(native_exit['model_provenance'])
    provenance = json.loads(provenance_path.read_text(encoding='utf-8-sig'))
    assert provenance['model_sha256'] == native_exit['executable_sha256']
    pinned = {p: provenance['source_sha256'][p].lower() for p in (
        'sim/board_harness.cpp', 'rtl/n8080_cpu.sv', 'rtl/n8080_vm80a_ce.v')}
    assert all(sha(Path(p)) == h for p, h in pinned.items())
    # The harness clocks once per ROM byte and another 1000 times in reset;
    # the adapter's phase runs throughout reset. This is a source-model
    # inference, not a measurement of the PCB's absolute clock origin.
    phase_at_release = (0x4800 + 1000) % 25
    predicted = reset_pin_model(phase_at_release, 78)
    with (native / 'cpu_startup.csv').open() as stream:
        startup = [r for r in csv.DictReader(stream) if int(r['tick']) < 78]
    assert len(startup) == len(predicted) == 78
    assert all(int(a['tick']) == b['tick'] and int(a['sync']) == b['sync']
               and int(a['dbin']) == b['dbin'] for a, b in zip(startup, predicted))
    matching_phases = [phase for phase in range(25) if all(
        int(a['sync']) == b['sync'] and int(a['dbin']) == b['dbin']
        for a, b in zip(startup, reset_pin_model(phase, 78)))]
    assert matching_phases == [phase_at_release] == [7]
    predicted_sync = next(r['tick'] for r in predicted if r['sync'])
    predicted_dbin = next(r['tick'] for r in predicted if r['dbin'])
    assert (predicted_sync, predicted_dbin) == (52, 77)
    captured_bus = Path('sim/results/physical-cpu-restart-corners-rtl-20261009/bus.csv')
    residues = {kind: set() for kind in ('read', 'ack', 'write')}
    counts = {kind: 0 for kind in residues}
    with captured_bus.open() as stream:
        for row in csv.DictReader(stream):
            residues[row['kind']].add(int(row['tick']) % 25)
            counts[row['kind']] += 1
    assert residues == {'read': {2}, 'ack': {2}, 'write': {19}}
    with (native / 'bus.csv').open() as stream:
        nr = [r for r in csv.DictReader(stream) if r['kind'] == 'read'
              and int(r['status']) & 128 and int(r['address']) < 0x4000
              and int(r['tick']) < 200_000]
    with (reference / 'irq_program_reads.csv').open() as stream:
        mr = list(csv.DictReader(stream))
    matched, opcodes, difference = 0, [], None
    for n, m in zip(nr, mr):
        if (int(n['address']), int(n['data'])) != (int(m['address']), int(m['data'])):
            difference = {'native_address': int(n['address']),
                          'mame_address': int(m['address']),
                          'native_tick': int(n['tick']), 'mame_time': m['time']}
            previous = [r for r in nr[:matched] if int(r['status']) & 32][-1]
            pc, opcode = int(previous['address']), int(previous['data'])
            following = nr[matched:matched + 3]
            # Explain the first raw difference without skipping it. MAME's
            # op_jmp/op_call false paths advance PC by2 without operand reads.
            assert opcode & 0xc7 in (0xc2, 0xc4)
            assert [int(r['address']) for r in following] == [pc + 1, pc + 2, pc + 3]
            assert (following[2]['address'], following[2]['data']) == (m['address'], m['data'])
            condition = ('NZ', 'Z', 'NC', 'C', 'PO', 'PE', 'P', 'M')[(opcode >> 3) & 7]
            difference.update(reason='MAME omits two untaken conditional operands',
                              instruction_PC=pc,
                              instruction=('J' if opcode & 0xc7 == 0xc2 else 'C') + condition,
                              skipped_records_for_comparison=0,
                              source_reference='MAME0.289 i8085.cpp op_jmp/op_call, lines821-847')
            break
        matched += 1
        if int(n['status']) & 32:
            t1_tag = int(n['tick']) - 27
            mame_tick = Decimal(m['time']) * 50_400_000
            opcodes.append({'PC': int(n['address']),
                            'native_opcode_DBIN': int(n['tick']),
                            'native_sampled_T1_tag': t1_tag,
                            'mame_fetch_master_ticks': str(mame_tick),
                            'mame_minus_native_tag': str(mame_tick - t1_tag)})
    assert opcodes and opcodes[0]['PC'] == 0
    assert opcodes[0]['native_opcode_DBIN'] == 77
    assert opcodes[0]['native_sampled_T1_tag'] == 50
    assert Decimal(opcodes[0]['mame_fetch_master_ticks']) == 0
    # Verify that the unchanged MAME observer still produces the same initial
    # RAM and I/O bytes. Comparison never modifies or retimes those events.
    prefixes = {}
    previous = Path('sim/results/first-ram66-mame-20261009')
    for name in ('video_writes.csv', 'io.csv'):
        raw = (reference / name).read_bytes()
        with (previous / name).open('rb') as stream:
            assert stream.read(len(raw)) == raw
        prefixes[name] = len(raw)
    result = {
        'native_receipt': native_exit, 'mame_receipt': mame_exit,
        'ordered_ROM_read_prefix': matched,
        'first_sequence_difference_or_none': difference,
        'matched_opcode_fetches': len(opcodes),
        'first_opcode_fetches': opcodes[:16],
        'opcode_epoch_min_master_ticks': str(min(Decimal(r['mame_minus_native_tag']) for r in opcodes)),
        'opcode_epoch_max_master_ticks': str(max(Decimal(r['mame_minus_native_tag']) for r in opcodes)),
        'same_observer_MAME_prefix_bytes': prefixes,
        'source_reset_model': {
            'phase_at_pin_reset_release': phase_at_release,
            'settled_reset_hold_master_clocks': 0x4800 + 1000,
            'matched_pre_opcode_pin_samples': len(predicted),
            'matching_phase_origins_among_25_candidates': matching_phases,
            'first_phi1_after_pin_reset_release': 18,
            'first_M1_phi1_source_model': 43,
            'predicted_first_SYNC': predicted_sync,
            'predicted_first_DBIN': predicted_dbin,
            'sampled_T1_tag_counter_phase': (phase_at_release + 50) % 25,
            'last_phi2_gate_sample_offset_from_final_cycle_T1_tag': 19 - 7,
            'superseded_phase19_tag_offset': 19,
            'full_terminal_capture_bus_event_counts': counts,
            'full_terminal_capture_bus_tick_residues_mod25': {
                kind: sorted(values) for kind, values in residues.items()},
            'physical_absolute_phase_qualified': False,
            'limit': 'Source-derived initial reset gates only, through first opcode DBIN.'},
        'primary_document': {
            'path': '_checks/manuals/intel-8080-user-manual-197509.pdf',
            'sha256': 'd5982f96536b1dbecbeff409d2370970638716296dce7b318624d86221597a9e',
            'url': 'https://www.bitsavers.org/components/intel/MCS80/98-153B_Intel_8080_Microcomputer_Systems_Users_Manual_197509.pdf',
            'page_index': 28, 'printed_page': '2-15', 'figure': '2-13 Reset',
            'interpretation': 'RESET recognition and a recovery interval precede first M1; '
                              'this diagram does not specify the Sheriff raster-to-CPU origin.'},
        'resynchronization_used': False, 'offset_applied': False,
        'sources': {p.as_posix(): sha(p) for p in [Path(__file__), terminal, provenance_path, captured_bus,
            native / 'bus.csv', native / 'cpu_startup.csv', reference / 'irq_program_reads.csv', reference / 'exit.json',
            Path('sim/board_harness.cpp'), Path('rtl/n8080_cpu.sv'),
            Path('rtl/n8080_vm80a_ce.v')]},
        'scope': 'Initial functional opcode epochs versus bus-derived native T1 tags. '
                 'This tag precedes native SYNC by two master ticks; it does not '
                 'assert the physical phi1 cycle origin. No all-domain or hardware equivalence.',
        'physical_reset_timing_qualified': False,
        'graphics_gate_qualified': False, 'current_board_source_qualified': False}
    output = Path('docs/evidence/sheriff_reset_startup.json')
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'matched_reads': matched, 'matched_opcodes': len(opcodes),
                      'first_fetch': opcodes[0], 'epoch_min': result['opcode_epoch_min_master_ticks'],
                      'epoch_max': result['opcode_epoch_max_master_ticks'],
                      'first_sequence_difference': difference,
                      'reset_model_pin_samples': len(predicted),
                      'predicted_SYNC_DBIN': [predicted_sync, predicted_dbin],
                      'evidence': output.as_posix()}))


if __name__ == '__main__':
    main()
