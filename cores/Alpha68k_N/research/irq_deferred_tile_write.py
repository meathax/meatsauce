"""Join actual IRQ contexts with a finite deferred tile-write observation."""
from pathlib import Path
import csv, hashlib, json

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT/'sim/captures/rtl/kyros_instruction60_diagnostic/instruction_events.csv'
MAME = ROOT/'sim/captures/kyros/reset_raster361_v4/events.csv'
CONTEXT = ROOT/'research/kyros_irq59_60_context_comparison.json'
ROM = ROOT/'roms/kyros/maincpu.bin'
OUT = ROOT/'research/irq_deferred_tile_write.json'

def main():
    rom = ROM.read_bytes()
    assert hashlib.sha256(rom).hexdigest() == '6949ea5dc91dfced8c1afccbadee18c2e795ab38d8adbc3795f05a19b8f3b2b3'
    assert rom[0x854:0x85c].hex() == '30fc002051c8fffa'
    with NATIVE.open(newline='') as f:
        n = list(csv.DictReader(f))
    with MAME.open(newline='') as f:
        m = [r for r in csv.DictReader(f) if int(r['frame']) == 59]
    contexts = json.loads(CONTEXT.read_text())
    cases = []
    for c in contexts['comparisons']:
        if c['field'] != 59:
            continue
        reference_stack_tick = c['mame']['pc_low_store_tick']
        candidates = [r for r in m if r['area'].startswith('tiles') and
                      int(r['instruction_pc']) == 0x854 and int(r['data']) == 0x20 and
                      0 < reference_stack_tick - int(r['master_ticks']) <= 176]
        assert len(candidates) == 1
        reference = candidates[0]
        address = int(reference['address'])
        actual_candidates = [r for r in n if r['frame'] == '59' and r['rw'] == '0' and r['iack'] == '0' and
                             int(r['address']) == address and int(r['data_out']) == 0x20]
        assert len(actual_candidates) == 1
        actual = actual_candidates[0]
        assert actual['uds_n'] == actual['lds_n'] == '0'
        subsequent_native = [r for r in n if r['rw'] == '0' and r['iack'] == '0' and
                             int(r['address']) == address+2 and int(r['data_out']) == 0x20 and
                             int(r['tick']) > int(actual['tick'])]
        subsequent_mame = [r for r in m if r['area'].startswith('tiles') and int(r['address']) == address+2 and
                           int(r['data']) == 0x20 and int(r['master_ticks']) > int(reference['master_ticks'])]
        assert subsequent_native and subsequent_mame
        a, b = subsequent_native[0], subsequent_mame[0]
        cases.append({'field': 59, 'level': c['level'], 'address': address, 'value': 0x20,
                      'native_write_tick': int(actual['tick']), 'mame_write_callback_tick': int(reference['master_ticks']),
                      'native_saved_pc': c['native']['saved_pc'], 'mame_saved_pc': c['mame']['saved_pc'],
                      'native_stack_tick': c['native']['pc_low_store_tick'], 'mame_stack_tick': reference_stack_tick,
                      'subsequent_shared_write_address': address+2,
                      'subsequent_native_tick': int(a['tick']), 'subsequent_mame_tick': int(b['master_ticks']),
                      'subsequent_write_native_minus_mame_ticks': int(a['tick'])-int(b['master_ticks']),
                      'stack_write_native_minus_mame_ticks': c['pc_low_store_native_minus_mame_ticks'],
                      'relative_offset_growth_ticks': int(a['tick'])-int(b['master_ticks'])-c['pc_low_store_native_minus_mame_ticks']})
    checks = {
        'two_actual_field59_cases': len(cases) == 2,
        'rom_MOVE_W_immediate_postincrement_and_DBF_bytes_exact': rom[0x854:0x85c].hex() == '30fc002051c8fffa',
        'native_saved_pc_854_mame_858': all(c['native_saved_pc'] == 0x854 and c['mame_saved_pc'] == 0x858 for c in cases),
        'mame_tile_write_before_its_exception_stack': all(c['mame_write_callback_tick'] < c['mame_stack_tick'] for c in cases),
        'native_tile_write_after_its_exception_stack': all(c['native_write_tick'] > c['native_stack_tick'] for c in cases),
        'both_next_write_offsets_75': all(c['subsequent_write_native_minus_mame_ticks'] == 75 for c in cases),
        'both_initial_stack_offsets_minus21': all(c['stack_write_native_minus_mame_ticks'] == -21 for c in cases),
        'both_relative_offset_growth_96': all(c['relative_offset_growth_ticks'] == 96 for c in cases),
    }
    assert all(checks.values()), checks
    result = {'schema': 1, 'sources': [{'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in (NATIVE,MAME,CONTEXT,ROM)],
              'checks': checks, 'cases': cases,
              'scope': 'Two actual writes straddle different sides of the field59 interrupt contexts. Common next-write offsets grow by96masterticks; no semantic instruction-edge or physical timing equivalence is assumed.',
              'limits': ['MAME tile tap completeness requires independent source review; unmatched tile counts are not missing RTL writes.',
                         'This qualifies a software-visible ordering difference, not the physical correctness of either timing model.',
                         'No IRQ phase, clock or CPU-cycle correction follows from these observations alone.'],
              'B16_closure': False, 'timing_fix_established': False, 'whole_game_acceptance': False}
    OUT.write_text(json.dumps(result, indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'receipt':str(OUT),'checks_passed':len(checks),'cases':cases,'B16_closure':False}))

if __name__ == '__main__':
    main()
