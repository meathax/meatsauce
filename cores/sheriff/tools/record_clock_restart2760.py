#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record the unresolved restart corner from frozen partial replay observers."""
import csv
import hashlib
import json
import struct
from decimal import Decimal
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rows(path):
    with Path(path).open(newline='', encoding='utf-8') as source:
        return list(csv.DictReader(source))


def main():
    run = Path('_checks/physical-cpu-restart-corners-20261009')
    reference = Path('sim/results/pixel-2760-irq-before-mame')
    source_path = run / 'model-source.json'
    model = json.loads(source_path.read_text(encoding='utf-8-sig'))
    assert model['revision'].startswith('cb67879')
    assert digest(run / 'Vn8080_board') == model['model_sha256']
    assert digest(run / 'inputs_restart.csv') == model['frozen_input_sha256']
    receipt_path = run / 'corner2760-comparison-receipt.json'
    receipt = json.loads(receipt_path.read_text())
    assert receipt['exit_code'] == 0
    pixels = run / 'corner2760-pixels/frame_02760.ppm'
    assert digest(pixels) == receipt['pixel_sha256']
    comparison_path = run / 'corner2760-comparison.json'
    comparison = json.loads(comparison_path.read_text())
    assert comparison['total_mismatch_pixels'] == 1
    assert len(comparison['checks']) == 1
    assert comparison['checks'][0]['frame'] == 2760
    assert comparison['checks'][0]['first_mismatches'] == [[211, 29, '00ffff', '000000']]
    edge, sample = 2_260_172_800, 2_260_318_918
    bus_path = run / 'corner2760-bus-prefix.csv'
    memory_path = run / 'corner2760-memory-prefix.bin'
    bus = rows(bus_path)
    fetches = [r for r in bus if r['kind'] == 'read' and int(r['status']) & 32 and not int(r['status']) & 1]
    final = max((r for r in fetches if int(r['tick']) <= edge), key=lambda r: int(r['tick']))
    rom = Path('roms/sheriff.bin').read_bytes()
    assert int(final['address']) == 0x0599 and rom[0x0599] == 0xcd
    target = int.from_bytes(rom[0x059a:0x059c], 'little')
    assert target == 0x2175
    call_t1 = int(final['tick']) - 27
    assert call_t1 == edge - 375
    predicted = {'last_phi2': call_t1 + 16 * 25 + 19, 'rst_t1': call_t1 + 17 * 25}
    predicted.update(ack=predicted['rst_t1'] + 2, stack_high=predicted['rst_t1'] + 169, stack_low=predicted['rst_t1'] + 244, return_pc=target)
    ack = next(r for r in bus if r['kind'] == 'ack' and int(r['tick']) >= edge)
    assert int(ack['tick']) == predicted['ack']
    writes = list(struct.iter_unpack('<QHB', memory_path.read_bytes()))
    stack = [r for r in writes if predicted['ack'] < r[0] < edge + 400 and r[1] in (0x7ff9, 0x7ff8)]
    assert stack == [(predicted['stack_high'], 0x7ff9, 0x21), (predicted['stack_low'], 0x7ff8, 0x75)]
    pixel_writes = [r for r in writes if r[1] == 0x43ba and abs(r[0] - sample) < 1000]
    assert pixel_writes == [(sample - 149, 0x43ba, 125)]
    mov = next(r for r in fetches if int(r['tick']) == pixel_writes[0][0] - 117)
    assert int(mov['address']) == 0x12b7 and rom[0x12b7] == 0x77
    mov_t1 = int(mov['tick']) - 27
    assert pixel_writes[0][0] == mov_t1 + 144
    mame_reads = rows(reference / 'irq_program_reads.csv')
    mame_call = next(r for r in mame_reads if int(r['address']) == 0x0599 and abs(Decimal(r['time']) * 50_400_000 - edge) < 1000)
    mame_mov = next(r for r in mame_reads if int(r['address']) == 0x12b7 and abs(Decimal(r['time']) * 50_400_000 - sample) < 1000)
    mame_writes = rows(reference / 'video_writes.csv')
    mame_stack = [r for r in mame_writes if edge < Decimal(r['time']) * 50_400_000 < edge + 500 and int(r['address']) in (0x7ff9, 0x7ff8)]
    assert len(mame_stack) == 2
    assert (int(mame_stack[0]['data']) << 8) | int(mame_stack[1]['data']) == target
    mame_pixel = next(r for r in mame_writes if int(r['address']) == 0x43ba and abs(Decimal(r['time']) * 50_400_000 - sample) < 1000)
    mame_mov_tick = Decimal(mame_mov['time']) * 50_400_000
    mame_write_tick = Decimal(mame_pixel['time']) * 50_400_000
    assert int(mame_pixel['data']) == 125
    epoch_difference = mame_mov_tick - mov_t1
    assert abs(epoch_difference - 125) < Decimal('0.01')
    assert abs((mame_write_tick - mame_mov_tick) - 175) < Decimal('0.01')
    trim_path = run / 'corner2760-prefix-trim.json'
    trim = json.loads(trim_path.read_text())
    files = [Path(__file__), source_path, receipt_path, pixels, comparison_path, bus_path, memory_path, trim_path, reference / 'irq_program_reads.csv', reference / 'video_writes.csv', reference / 'write_pc.csv', reference / 'input_sha256.json']
    report = {
        'scope': 'Partial immutable cb67879-source restart replay, field2760 only; full6781-field run remains pending',
        'model_source': model,
        'comparison_exit_code': receipt['exit_code'],
        'frame': 2760, 'mismatch_pixels': 1, 'x': 211, 'y': 29,
        'native_rgb': '00ffff', 'reference_rgb': '000000',
        'edge': edge, 'sample_tick': sample,
        'IRQ_prediction': {'instruction': 'CALL at 0x0599 to 0x2175, 17 documented T states', 'sampled_t1': call_t1, 'predicted': predicted, 'actual_matches_prediction': True, 'native_and_mame_return_pc': target, 'scope': 'Local sampled-model boundary proof; no global/electrical IRQ qualification'},
        'pixel_write': {'address': 0x43ba, 'data': 125, 'native_tick': pixel_writes[0][0], 'native_delta_sample': -149, 'mame_tick': str(mame_write_tick), 'mame_delta_sample': str(mame_write_tick - sample)},
        'epoch_observation': {'native_CALL_sampled_t1': call_t1, 'mame_CALL_fetch_tick': str(Decimal(mame_call['time']) * 50_400_000), 'native_MOV_sampled_t1': mov_t1, 'mame_MOV_fetch_tick': str(mame_mov_tick), 'mame_minus_native_MOV_epoch': str(epoch_difference), 'native_MOV_write_offset': 144, 'mame_MOV_write_offset': str(mame_write_tick - mame_mov_tick), 'write_position_difference_ideal': 31, 'cause_of_epoch_difference_qualified': False},
        'frozen_observers': {'bus': str(bus_path), 'memory': str(memory_path), 'memory_bytes': memory_path.stat().st_size, 'bus_prefix_trim': trim, 'scope': 'Complete-record prefixes taken after this corner; eight trailing memory bytes and the incomplete final CSV line were omitted. Original CSV snapshot is preserved. This is not a terminal replay receipt.'},
        'reference_input_provenance': json.loads((reference / 'input_sha256.json').read_text(encoding='utf-8-sig')),
        'file_sha256': {p.as_posix(): digest(p) for p in files},
        'limits': ['Old wrong-return-PC diagnosis is superseded for this saved model; the pixel mismatch remains.', '125-clock instruction epoch difference and atomic-versus-bus write placement are observed; no physical READY/DRAM/serializer correction is qualified.', 'No raster offset, image tolerance, adjusted MAME write stream or mismatch waiver is introduced.', 'Current concurrent display source, all uncaptured fields, later restart corner, audio and release remain unqualified.', 'Quartus remains on hold.'],
        'strict_graphics_gate_pass': False,
        'production_rtl_changed': False,
        'quartus_executed': False,
    }
    output = Path('docs/evidence/sheriff_clock_restart2760.json')
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'frame': 2760, 'mismatch_pixels': 1, 'native_and_mame_IRQ_pc': hex(target), 'native_write_delta': -149, 'mame_write_delta': str(mame_write_tick - sample), 'graphics_gate_pass': False, 'report': str(output)}))


if __name__ == '__main__':
    main()
