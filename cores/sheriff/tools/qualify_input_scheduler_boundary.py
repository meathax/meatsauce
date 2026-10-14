#!/usr/bin/env python3
"""Read-only attribution of the first Sheriff restart input-read difference."""
import argparse
import csv
import hashlib
import json
from decimal import Decimal
from pathlib import Path

MASTER = Decimal(50_400_000)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def is_exact_prefix(short, long):
    with short.open('rb') as a, long.open('rb') as b:
        for chunk in iter(lambda: a.read(1 << 20), b''):
            if chunk != b.read(len(chunk)):
                return False
    return True


def input_reads(path):
    with path.open(newline='') as source:
        for row in csv.DictReader(source):
            if row['kind'] == 'in':
                yield row


def output_reads(path):
    with path.open(newline='') as source:
        for row in csv.DictReader(source):
            if row['kind'] == 'out':
                yield row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, default=Path('sim/results/input-boundary-1548-mame-20261009'))
    parser.add_argument('--reference', type=Path, default=Path('sim/results/restart-mame'))
    parser.add_argument('--rtl', type=Path, default=Path('sim/results/restart-phase-ce-rtl'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    observed = args.capture / 'input_observations.csv'
    with observed.open(newline='') as source:
        rows = list(csv.DictReader(source))
    indices = [i for i, row in enumerate(rows) if row['kind'] == 'apply' and row['event_frame'] == '1548']
    assert len(indices) == 1, 'Expected exactly one frame-1548 input application'
    i = indices[0]
    applied = rows[i]
    before = next(row for row in reversed(rows[:i]) if row['kind'] == 'in' and row['address'] == '2')
    after = next(row for row in rows[i+1:] if row['kind'] == 'in' and row['address'] == '2')
    boundary = Decimal(1548 * 819_200)
    ticks = {name: Decimal(row['time']) * MASTER for name, row in [('before', before), ('apply', applied), ('after', after)]}
    prefix_equal = is_exact_prefix(args.capture / 'io.csv', args.reference / 'io.csv')
    assert prefix_equal, 'Observation changed the original MAME I/O prefix'
    assert all(int(a['sequence']) < int(b['sequence']) for a, b in zip(rows, rows[1:])), 'Event order is not strictly increasing'
    assert before['data'] == '1' and applied['p2'] == '0' and after['data'] == '0'
    assert before['frame'] == '1547' and applied['frame'] == after['frame'] == '1548'
    assert int(before['sequence']) < int(applied['sequence']) < int(after['sequence'])
    assert abs(ticks['apply'] - boundary) < Decimal('0.01'), 'Input callback was not on the physical frame boundary'
    assert abs(ticks['before'] - ticks['apply'] - 100) < Decimal('0.01'), 'Expected the observed 100-clock timestamp reversal'
    first = None
    for ordinal, (mame, rtl) in enumerate(zip(input_reads(args.capture / 'io.csv'), input_reads(args.rtl / 'io.csv'))):
        m = (int(mame['address']) & 255, int(mame['data']))
        r = (int(rtl['address']) & 255, int(rtl['data']))
        if m != r:
            first = {'matched_prefix': ordinal, 'mame': mame, 'rtl': rtl}
            break
    assert first is not None and first['matched_prefix'] == 75_823
    assert first['mame']['time'] == before['time'] and first['mame']['data'] == '1'
    assert first['rtl']['tick'] == '1268121681' and first['rtl']['data'] == '0'
    output_prefix = 0
    baseline_delta = None
    changed_output_timing = []
    rtl_outputs = output_reads(args.rtl / 'io.csv')
    for mame in output_reads(args.capture / 'io.csv'):
        rtl = next(rtl_outputs, None)
        assert rtl is not None, 'RTL output stream ended before the reference prefix'
        assert (int(mame['address']) & 255, int(mame['data'])) == (int(rtl['address']) & 255, int(rtl['data'])), 'Output values differ in this scoped prefix'
        delta = Decimal(mame['time']) * MASTER - int(rtl['tick'])
        if baseline_delta is None:
            baseline_delta = delta
        # This threshold selects diagnostic timing context, never acceptance.
        if abs(delta - baseline_delta) > 1 and len(changed_output_timing) < 8:
            changed_output_timing.append({'ordinal': output_prefix, 'mame': mame, 'rtl': rtl, 'delta_master_clocks': str(delta)})
        output_prefix += 1
    with (args.capture / 'states.csv').open(newline='') as source:
        states = list(csv.DictReader(source))
    assert int(states[-1]['frame']) == 1600, 'Capture did not reach its requested stop'
    files = [observed, args.capture / 'io.csv', args.capture / 'states.csv',
             args.reference / 'io.csv', args.rtl / 'io.csv',
             args.capture / 'capture_features.json', args.capture / 'input_sha256.json',
             Path('sim/mame_capture.lua'), Path('tools/mame_capture.ps1'),
             Path(__file__), Path('sim/inputs_restart.csv'),
             Path('D:/Arcade/AI/mame289/src/devices/cpu/i8085/i8085.cpp'),
             Path('D:/Arcade/AI/mameexe/mame.exe')]
    report = {
        'scope': 'Diagnostic attribution of the first ordered restart input-read difference; no RTL correction or comparison waiver',
        'checks_passed': True,
        'capture_stop_frame': 1600,
        'child_exit_code': None,
        'child_exit_limit': 'Launcher did not retain child exit status; process was independently observed missing after the terminal state and closed trace were produced',
        'original_reference_io_byte_prefix_equal': prefix_equal,
        'observed_window_rows': len(rows),
        'events': {'last_old_read_before_application': before, 'application': applied, 'first_new_read_after_application': after},
        'master_tick_relative_to_frame_1548': {name: str(tick - boundary) for name, tick in ticks.items()},
        'first_input_difference': first,
        'ordered_output_value_prefix_through_1600': {'matched': output_prefix, 'baseline_delta_master_clocks': str(baseline_delta), 'first_changed_timing': changed_output_timing, 'limit': 'A matching value prefix with differing transaction times is not complete I/O equivalence or a proof of the later pixel cause'},
        'known': 'The old-value MAME read executes before the input callback in event order, despite its later CPU-local timestamp. The callback applies the change at the physical frame edge.',
        'source_support': {'path': 'D:/Arcade/AI/mame289/src/devices/cpu/i8085/i8085.cpp', 'execute_run_line': 870, 'cycle_debit_line': 894, 'input_read_line': 1519, 'behavior': 'execute_one debits a whole instruction before issuing the I/O read; execute_run tests the remaining slice budget only after that instruction'},
        'inferred': 'Instruction-atomic MAME execution crosses the pending timer boundary before the frame callback runs, producing an old-pin read with a timestamp after the input edge.',
        'rtl_action': 'Retain the physical input waveform and synthesizable CPU bus timing. Do not delay controls to force agreement with the reference.',
        'pixel_2760_cause_qualified': False,
        'complete_input_stream_equal': False,
        'complete_graphics_gate': False,
        'complete_sheriff_gate': False,
        'quartus_executed': False,
        'sha256': {path.as_posix(): digest(path) for path in files},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'checks_passed': True, 'matched_input_prefix': first['matched_prefix'], 'mame_timestamp_reversal_master_clocks': str(ticks['before'] - ticks['apply']), 'reference_prefix_equal': prefix_equal, 'output': args.output.as_posix()}))


if __name__ == '__main__':
    main()
