"""Compare actual bus work writes; no instruction-dispatch equivalence claim."""
from pathlib import Path
import argparse, csv, difflib, hashlib, json

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'sim/captures/rtl/kyros_instruction60_diagnostic/instruction_events.csv'
MAME = ROOT / 'sim/captures/kyros/reset_raster361_v4/events.csv'
OUT = ROOT / 'research/irq_work_write_alignment.json'

def native(include_tiles=False):
    result = []
    with NATIVE.open(newline='') as f:
        for row in csv.DictReader(f):
            address = int(row['address'])
            in_scope = 0x20000 <= address < 0x21000 or (include_tiles and 0x40000 <= address < 0x42000)
            if row['rw'] != '0' or row['iack'] != '0' or not in_scope:
                continue
            mask = (0xff00 if row['uds_n'] == '0' else 0) | (0xff if row['lds_n'] == '0' else 0)
            if not mask:
                continue
            result.append({'field': int(row['frame']), 'tick': int(row['tick']),
                           'address': address, 'mask': mask, 'value': int(row['data_out']) & mask,
                           'pc_observed_after_request': int(row['pc_after'])})
    return result

def mame(include_tiles=False):
    result = []
    with MAME.open(newline='') as f:
        for row in csv.DictReader(f):
            in_scope = row['area'] == 'work' or (include_tiles and (row['area'].startswith('tiles') or row['area'] == 'positions'))
            if not in_scope or not 59 <= int(row['frame']) <= 60:
                continue
            mask = int(row['mask'])
            result.append({'field': int(row['frame']), 'tick': int(row['master_ticks']),
                           'address': int(row['address']), 'mask': mask, 'value': int(row['data']) & mask,
                           'instruction_pc': int(row['instruction_pc']), 'next_pc': int(row['next_pc'])})
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-tiles', action='store_true')
    args = parser.parse_args()
    n, m = native(args.include_tiles), mame(args.include_tiles)
    out = ROOT / 'research/irq_main_write_alignment_v2.json' if args.include_tiles else OUT
    assert n and m
    key = lambda r: (r['field'], r['address'], r['mask'], r['value'])
    matcher = difflib.SequenceMatcher(None, [key(r) for r in n], [key(r) for r in m], autojunk=False)
    intervals, unequal = [], []
    for tag, a, b, c, d in matcher.get_opcodes():
        if tag != 'equal':
            unequal.append({'kind': tag, 'native_indices': [a, b], 'mame_indices': [c, d],
                            'native': n[a:b], 'mame': m[c:d]})
            continue
        differences = [n[a+i]['tick'] - m[c+i]['tick'] for i in range(b-a)]
        runs = []
        start = 0
        for i in range(1, len(differences)+1):
            if i == len(differences) or differences[i] != differences[start]:
                runs.append({'count': i-start, 'native_minus_mame_ticks': differences[start],
                             'native_first': n[a+start], 'native_last': n[a+i-1],
                             'mame_first': m[c+start], 'mame_last': m[c+i-1]})
                start = i
        intervals.append({'count': b-a, 'native_indices': [a, b], 'mame_indices': [c, d], 'offset_runs': runs})
    result = {'schema': 2, 'include_tiles': args.include_tiles, 'capture_scope': 'work0x20000..0x20fff; optional positions/tiles0x40000..0x41fff matching frozen MAME tap',
              'supersedes_unqualified_scope_receipt': 'irq_main_write_alignment.json' if args.include_tiles else None,
              'scope': 'Actual normalized work/optional position/tile-write bus sequence in retained fields59/60. Request-edge and MAME callback times remain different observer boundaries.',
              'sources': [{'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in (NATIVE, MAME)],
              'native_writes': len(n), 'mame_writes': len(m), 'exact_matched_writes': sum(r['count'] for r in intervals),
              'equal_blocks': intervals, 'unequal_blocks': unequal,
              'B16_closure': False, 'timing_fix_established': False, 'whole_game_acceptance': False}
    out.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'receipt': str(out), 'native_writes': len(n), 'mame_writes': len(m),
                      'matched': result['exact_matched_writes'], 'unequal_blocks': len(unequal),
                      'unequal_samples': [{'kind': block['kind'], 'native': block['native'][:2], 'mame': block['mame'][:2], 'native_count': len(block['native']), 'mame_count': len(block['mame'])} for block in unequal][:10],
                      'offset_runs': [{'count': run['count'], 'offset': run['native_minus_mame_ticks'],
                                       'first_tick': run['native_first']['tick'], 'first_address': run['native_first']['address'],
                                       'last_tick': run['native_last']['tick']} for block in intervals for run in block['offset_runs']][:40]}))

if __name__ == '__main__':
    main()
