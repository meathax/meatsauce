"""Qualify completed native HUD cases without implying a terminal long run."""
from pathlib import Path
import argparse, csv, hashlib, json

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'sim/captures/rtl/kyros_combat_hud3301'
OLD_NATIVE = ROOT / 'sim/captures/rtl/kyros_combat3600'
MAME = ROOT / 'sim/captures/kyros/combat3600_clocked'
TARGETS = [900, 1020, 2100, 2220, 3180, 3300]
WORDS = {0x40EEA, 0x40EEC, 0x40EEE, 0x40EF0, 0x406C2}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def rows(path):
    with path.open(newline='') as stream:
        return list(csv.DictReader(stream))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--through', type=int, required=True, choices=TARGETS)
    args = parser.parse_args()
    report_path = ROOT / f'research/combat_hud_native_causality_through{args.through}.json'
    if report_path.exists():
        raise SystemExit('Refuse prior diagnostic receipt overwrite')
    job = json.loads((ROOT / 'research/kyros_combat_hud3301_job.json').read_text())
    frames = rows(NATIVE / 'frames.csv')
    terminal_path = ROOT / 'research/kyros_combat_hud3301_verification.json'
    terminal_qualified = terminal_path.exists() and json.loads(terminal_path.read_text())['passed']
    if not terminal_qualified and int(frames[-1]['frame']) <= args.through:
        raise SystemExit('Wait for a later completed field or a qualified terminal run')
    mame_timing_path = ROOT / 'research/combat_hud_mame_timing_v2.json'
    fixture_path = ROOT / 'research/combat_hud_prewrite_fixtures_verification.json'
    source_relation = json.loads((ROOT / 'research/combat_hud_prewrite_fixtures_source_relation.json').read_text())
    timing = json.loads(mame_timing_path.read_text())
    fixture = json.loads(fixture_path.read_text())
    if not timing['passed'] or not fixture['passed'] or source_relation['different_shared_sources'] or source_relation['stale_fixture_sources']:
        raise SystemExit('Qualified MAME timeline/current renderer source relation is required')
    ownership = json.loads((ROOT / 'research/combat_hud_ownership.json').read_text())
    state, known = {a: 0 for a in WORDS}, {a: 0 for a in WORDS}
    selected = []
    with (NATIVE / 'epoch_events.csv').open(newline='') as stream:
        for row in csv.DictReader(stream):
            field = int(row['frame'])
            if field > args.through:
                break
            address = int(row['address'])
            if address not in WORDS or int(row['iack']) or int(row['rw']):
                continue
            mask = (0 if int(row['uds_n']) else 0xFF00) | (0 if int(row['lds_n']) else 0xFF)
            data = int(row['data_out'])
            event = {k: int(v) for k, v in row.items()}
            event.update(before=state[address], known_before=known[address], mask=mask)
            state[address] = ((state[address] & ~mask) | (data & mask)) & 0xFFFF
            known[address] |= mask
            event['after'] = state[address]
            selected.append(event)
    checks = {'native_elf_pin': digest(NATIVE / 'alpha68kn_system_sim') == job['executable_sha256']}
    cases = []
    for field in [f for f in TARGETS if f <= args.through]:
        mame_case = next(c for c in timing['cases'] if c['field'] == field)
        pixels = next(c for c in ownership['fields'] if c['field'] == field)['pixels']
        native_ram = (NATIVE / f'frame_{field:06d}.sprites.bin').read_bytes()
        mame_ram = (MAME / f'frame_{field:06d}.sprites.bin').read_bytes()
        native_rgb = NATIVE / f'frame_{field:06d}.rgb'
        previous_rgb = OLD_NATIVE / f'frame_{field:06d}.rgb'
        words = []
        for word in mame_case['words']:
            address = word['address']
            records = [r for r in selected if r['address'] == address and r['frame'] <= field]
            changed = [r for r in records if r['frame'] == field and r['before'] != r['after']]
            offset = address - 0x40000
            final_native = int.from_bytes(native_ram[offset:offset+2], 'big')
            checks[f'{field}_{address:x}_native_final_reconstruction'] = bool(records) and records[-1]['known_before'] == 65535 and records[-1]['after'] == final_native
            checks[f'{field}_{address:x}_final_matches_mame'] = final_native == word['final_word']
            if address == 0x406C2:
                checks[f'{field}_unchanged_position'] = not changed
            else:
                mame_changed = word['changed_writes']
                checks[f'{field}_{address:x}_same_known_earlier_word'] = bool(changed) and changed[0]['known_before'] == 65535 and changed[0]['before'] == int(mame_changed[0]['before'])
                last_affected_y = max(p['raw_y'] for p in pixels if p['owner']['tile_address'] == address)
                checks[f'{field}_{address:x}_all_changed_writes_after_rows'] = bool(changed) and all(r['raster_y'] > last_affected_y for r in changed)
            words.append({'address': address, 'final_native': final_native, 'final_mame': word['final_word'], 'native_changed_writes': changed, 'mame_changed_writes': word['changed_writes']})
        checks[f'{field}_same_actual_cpu_image'] = digest(native_rgb) == digest(previous_rgb)
        checks[f'{field}_complete_assets'] = len(native_ram) == 8192 and native_rgb.stat().st_size == 172032
        cases.append({'field': field, 'words': words, 'native_rgb_sha256': digest(native_rgb),
                      'sprite_ram_different_bytes_vs_mame': sum(a != b for a, b in zip(native_ram, mame_ram)),
                      'native_sprite_ram_sha256': hashlib.sha256(native_ram).hexdigest()})
    result = {'passed': all(checks.values()), 'checks': checks, 'cases': cases,
              'native_executable_sha256': job['executable_sha256'], 'through_field': args.through,
              'last_completed_field_observed': int(frames[-1]['frame']), 'terminal_run_qualified': terminal_qualified,
              'source_receipts_sha256': {str(p.relative_to(ROOT)): digest(p) for p in [mame_timing_path, fixture_path]},
              'scope': 'Completed real CPU checkpoints: accepted native writes reconstruct retained RAM, share independently measured earlier MAME words and occur after the affected rows; actual CPU RGB matches the qualified full-RGB renderer fixture target. This is finite temporal causality, not a terminal-run or whole-game pass; original atomic MAME differences and field60 residual remain.'}
    report_path.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'fields': [c['field'] for c in cases], 'failures': [k for k, v in checks.items() if not v], 'terminal_run_qualified': terminal_qualified}))
    raise SystemExit(0 if result['passed'] else 1)
