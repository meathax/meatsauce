"""Reduce the qualified MAME event stream to the five relevant HUD words."""
from pathlib import Path
import csv, hashlib, json, os, sys, time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'sim/captures/kyros/combat3600_clocked'
OWNERSHIP = ROOT / 'research/combat_hud_ownership.json'
WORDS = {0x40EEA, 0x40EEC, 0x40EEE, 0x40EF0, 0x406C2}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if __name__ == '__main__':
    if sys.argv[1:] != ['--attempt2']:
        raise SystemExit('Use --attempt2; first incomplete foreground derivative is preserved')
    qualified = json.loads((ROOT / 'research/kyros_combat3600_clocked_verification.json').read_text())
    if not qualified['passed']:
        raise SystemExit('Exact-clock MAME oracle must be qualified first')
    output = ROOT / 'sim/captures/diagnostics/combat_hud_mame_events_v2.csv'
    if output.exists():
        raise SystemExit('Refuse filtered evidence overwrite')
    output.parent.mkdir(parents=True, exist_ok=True)
    job = {'worker_pid': os.getpid(), 'started': time.time(), 'source_sha256': digest(Path(__file__)),
           'output': str(output.relative_to(ROOT)), 'status': 'running'}
    job_path = ROOT / 'research/combat_hud_mame_extract_v2_job.json'
    if job_path.exists():
        raise SystemExit('Refuse extraction job overwrite')
    job_path.write_text(json.dumps(job, indent=2) + '\n')
    state = {a: 0 for a in WORDS}
    known = {a: 0 for a in WORDS}
    selected = []
    with (SOURCE / 'events.csv').open(newline='') as source, output.open('w', newline='') as target:
        reader = csv.DictReader(source)
        writer = csv.DictWriter(target, fieldnames=reader.fieldnames + ['before', 'after', 'known_before'], lineterminator='\n')
        writer.writeheader()
        for row in reader:
            address = int(row['address'])
            if address not in WORDS:
                continue
            data, mask = int(row['data']), int(row['mask'])
            row.update(before=state[address], known_before=known[address])
            state[address] = ((state[address] & ~mask) | (data & mask)) & 0xFFFF
            known[address] |= mask
            row['after'] = state[address]
            writer.writerow(row)
            selected.append(row)
    cases = []
    ownership = json.loads(OWNERSHIP.read_text())
    with (SOURCE / 'raster_clock.csv').open() as stream:
        markers = {int(row['frame']): int(row['master_ticks']) for row in csv.DictReader(stream)}
    for case in ownership['fields']:
        field = case['field']
        addresses = sorted({p['owner']['tile_address'] for p in case['pixels']})
        ram = (SOURCE / f'frame_{field:06d}.sprites.bin').read_bytes()
        words = []
        for address in addresses + [0x406C2]:
            records = [r for r in selected if int(r['address']) == address and int(r['frame']) <= field]
            final = records[-1] if records else None
            offset = address - 0x40000
            expected = int.from_bytes(ram[offset:offset + 2], 'big')
            changes = [r for r in records if int(r['frame']) == field and int(r['before']) != int(r['after'])]
            words.append({'address': address, 'final_word': expected,
                          'timeline_matches_final_ram': final is not None and int(final['after']) == expected,
                          'changed_writes': changes,
                          'affected_raw_y': sorted({p['raw_y'] for p in case['pixels'] if p['owner']['tile_address'] == address})})
        cases.append({'field': field, 'capture_master_tick': markers[field], 'words': words})
    report = {'passed': all(w['timeline_matches_final_ram'] for c in cases for w in c['words']),
              'selected_writes': len(selected), 'cases': cases,
              'source_sha256': {str(p.relative_to(ROOT)): digest(p) for p in [SOURCE / 'events.csv', SOURCE / 'raster_clock.csv', OWNERSHIP]},
              'filtered_events_sha256': digest(output),
              'filtered_events': str(output.relative_to(ROOT)),
              'scope': 'MAME-only exact-time HUD write reduction and final-RAM reconstruction. Before-values are qualified only where known_before is 65535. Actual native causality/renderer qualification remains pending.'}
    receipt = ROOT / 'research/combat_hud_mame_timing_v2.json'
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print('passed', report['passed'], 'selected writes', len(selected))
    for case in cases:
        print(case['field'], [(hex(w['address']), [(r['before'], r['after'], r['vpos'], r['hpos'], r['known_before']) for r in w['changed_writes']]) for w in case['words'] if w['changed_writes']])
    job.update(status='terminal', ended=time.time(), exit_code=0 if report['passed'] else 1)
    (ROOT / 'research/combat_hud_mame_extract_v2_exit.json').write_text(json.dumps(job, indent=2) + '\n')
    raise SystemExit(0 if report['passed'] else 1)
