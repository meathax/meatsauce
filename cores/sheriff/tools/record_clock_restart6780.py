#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record terminal replay scope and the corrected-clock second restart corner."""
import csv
import hashlib
import json
from decimal import Decimal
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rows(path):
    with Path(path).open() as f:
        yield from csv.DictReader(f)


def main():
    run = Path('_checks/physical-cpu-restart-corners-20261009')
    native = Path('sim/results/physical-cpu-restart-corners-rtl-20261009')
    ref = Path('sim/results/pixel-6780-irq-before-mame-20261009')
    terminal = json.loads((run / 'result.json').read_text(encoding='utf-8-sig'))
    assert terminal['exit_code'] == 0 and terminal['frames_requested'] == 6781
    assert terminal['executable_sha256'].lower() == sha(run / 'Vn8080_board')
    assert terminal['inputs_sha256'].lower() == sha(run / 'inputs_restart.csv')
    comparison = json.loads((run / 'corner6780-comparison.json').read_text())
    assert comparison['checks'] == [{'frame': 6780, 'mismatch_count': 0, 'first_mismatches': []}]
    receipt = json.loads((run / 'corner6780-comparison-receipt.json').read_text())
    assert receipt['exit_code'] == 0
    negative = json.loads((run / 'corner2760-comparison.json').read_text())
    assert negative['total_mismatch_pixels'] == 1
    snapshots = []
    for frame in (2760, 6780):
        for suffix in ('ppm', 'ram', 'state'):
            name = f'frame_{frame:05d}.{suffix}'
            snapshot = run / f'corner{frame}-pixels' / name
            assert sha(snapshot) == sha(native / name)
            snapshots.append(snapshot)
    edge, sample = 5_553_356_800, 5_553_508_158
    bus = list(rows(native / 'bus.csv'))
    fetches = [r for r in bus if r['kind'] == 'read' and int(r['status']) & 32 and not int(r['status']) & 1]
    last = max((r for r in fetches if int(r['tick']) <= edge), key=lambda r: int(r['tick']))
    rom = Path('roms/sheriff.bin').read_bytes()
    assert int(last['address']) == 0x0a03 and rom[0x0a03] == 0x21
    t1 = int(last['tick']) - 27
    assert t1 == edge - 50
    rst_t1 = t1 + 10 * 25
    prediction = {'opcode': 'LXI H', 'PC': 0x0a03, 'sampled_t1': t1,
                  'last_phi2': t1 + 9 * 25 + 19, 'rst_t1': rst_t1,
                  'ack': rst_t1 + 2, 'stack_high': rst_t1 + 169,
                  'stack_low': rst_t1 + 244, 'return_PC': 0x0a06}
    ack = next(r for r in bus if r['kind'] == 'ack' and int(r['tick']) >= edge)
    assert int(ack['tick']) == prediction['ack']
    stack = [(int(r['tick']), int(r['address']), int(r['data'])) for r in bus
             if r['kind'] == 'write' and prediction['ack'] < int(r['tick']) < edge + 500
             and int(r['address']) in (0x7ff9, 0x7ff8)]
    assert stack == [(prediction['stack_high'], 0x7ff9, 0x0a), (prediction['stack_low'], 0x7ff8, 0x06)]
    pixel = [r for r in bus if r['kind'] == 'write' and int(r['address']) == 0x43eb
             and abs(int(r['tick']) - sample) < 1000]
    assert len(pixel) == 1 and int(pixel[0]['data']) == 128
    assert int(pixel[0]['tick']) == sample + 136
    mstack, mpixel = [], []
    for r in rows(ref / 'video_writes.csv'):
        tick = Decimal(r['time']) * 50_400_000
        address = int(r['address'])
        if edge < tick < edge + 600 and address in (0x7ff9, 0x7ff8):
            mstack.append(r)
        if address == 0x43eb and abs(tick - sample) < 1000:
            mpixel.append({'tick': str(tick), 'delta_sample': str(tick - sample), 'data': int(r['data'])})
    assert len(mstack) == 2 and [int(r['data']) for r in mstack] == [0x0a, 0x06]
    assert len(mpixel) == 1 and mpixel[0]['data'] == 128
    stdout = (run / 'stdout.log').read_text(encoding='utf-8-sig').strip()
    assert stdout == 'frames=6781 writes=4543144 IRQ acknowledges=13412 address=59f'
    files = [run / 'result.json', run / 'model-source.json', run / 'stdout.log',
             run / 'corner6780-comparison.json', run / 'corner6780-comparison-receipt.json',
             run / 'corner2760-comparison.json', native / 'bus.csv', ref / 'video_writes.csv',
             ref / 'io.csv', ref / 'input_sha256.json', run / 'inputs_restart.csv', Path(__file__)] + snapshots
    report = {
        'scope': 'Terminal immutable cb67879-source replay plus one independently compared RGB corner',
        'terminal': terminal, 'terminal_stdout': stdout,
        'model_provenance': json.loads((run / 'model-source.json').read_text(encoding='utf-8-sig')),
        'RGB_comparison': comparison, 'comparison_exit': 0,
        'remaining_negative_corner': {'frame': 2760, 'mismatches': 1,
                                       'evidence': 'docs/evidence/sheriff_clock_restart2760.json',
                                       'frozen_pixels_equal_terminal_pixels': True},
        'IRQ_prediction': prediction, 'native_stack': stack, 'mame_return_PC': 0x0a06,
        'pixel_write': {'address': 0x43eb, 'data': 128, 'sample_tick': sample,
                        'native_tick': int(pixel[0]['tick']), 'native_delta_sample': 136,
                        'mame': mpixel},
        'file_sha256': {p.as_posix(): sha(p) for p in files},
        'strict_graphics_gate_pass': False,
        'current_worktree_board_qualified': False,
        'limits': ['Saved-model field6780 matches; field2760 remains a one-pixel negative result recorded separately.',
                   'All uncaptured fields, current display source, physical DRAM/READY/serializer, audio and release remain unqualified.',
                   'No raster offset, reference adjustment or graphics tolerance introduced. Quartus remains on hold.'],
    }
    out = Path('docs/evidence/sheriff_clock_restart6780.json')
    out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'terminal_exit': 0, 'frames': 6781, 'corner6780_mismatches': 0,
                      'return_PC': '0a06', 'native_write_after_sample': 136,
                      'strict_graphics_pass': False}))


if __name__ == '__main__':
    main()
