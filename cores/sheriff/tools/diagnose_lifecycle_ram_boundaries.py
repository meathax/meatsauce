"""Explain saved RAM observation boundaries without modifying either capture."""
from pathlib import Path
from decimal import Decimal
from bisect import bisect_right
import csv
import hashlib
import json
import re
import struct


def sha(p):
    return hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()


def main():
    evidence = Path('docs/evidence/sheriff_gameplay_lifecycle.json')
    original = json.loads(evidence.read_text())
    native = Path('sim/results/physical-cpu-restart-corners-rtl-20261009')
    reference = Path(original['reference_capture'])
    rows = original['snapshot_comparisons']
    snapshots = []
    targets = set()
    sources = [evidence, Path(__file__)]
    for row in rows:
        f = row['field']
        np = native / f'frame_{f:05d}.ram'
        rp = reference / np.name
        nb, rb = np.read_bytes(), rp.read_bytes()
        assert len(nb) == len(rb) == 0x4000
        diffs = [(i + 0x4000, n, r) for i, (n, r) in enumerate(zip(nb, rb)) if n != r]
        assert len(diffs) == row['full_RAM_difference_bytes']
        sp = native / f'frame_{f:05d}.state'
        tick = int(re.search(r'tick=(\d+)', sp.read_text()).group(1))
        snapshots.append((f, tick, diffs))
        targets.update(a for a, _, _ in diffs)
        sources += [np, rp, sp]
    nw = {a: [] for a in targets}
    rw = {a: [] for a in targets}
    nm = native / 'memory_writes.bin'
    with nm.open('rb') as stream:
        while chunk := stream.read(11 * 65536):
            assert len(chunk) % 11 == 0
            for tick, a, data in struct.iter_unpack('<QHB', chunk):
                if a in targets:
                    nw[a].append((tick, data))
    rm = reference / 'video_writes.csv'
    with rm.open(newline='') as stream:
        for row in csv.DictReader(stream):
            a = int(row['address'])
            if a in targets:
                rw[a].append((Decimal(row['time']) * 50_400_000, int(row['data'])))
    states = reference / 'states.csv'
    with states.open(newline='') as stream:
        mt = {int(r['frame']): Decimal(r['time']) * 50_400_000 for r in csv.DictReader(stream)}
    times = {side: {a: [x[0] for x in values] for a, values in writes.items()}
             for side, writes in [('native', nw), ('reference', rw)]}

    def neighborhood(side, a, t, observed):
        values = nw[a] if side == 'native' else rw[a]
        i = bisect_right(times[side][a], t)
        def event(j):
            if not 0 <= j < len(values):
                return None
            tick, value = values[j]
            return dict(index=j, tick=str(tick), delta_snapshot_master_clocks=str(tick-t), value=value)
        before, after = event(i-1), event(i)
        return dict(snapshot_tick=str(t), snapshot_value=observed,
                    last_write=before, next_write=after,
                    snapshot_matches_last_logged_write=bool(before and before['value'] == observed))

    results = []
    for f, nt, diffs in snapshots:
        for a, n, r in diffs:
            results.append(dict(field=f, address=f'{a:04x}',
                                native=neighborhood('native', a, nt, n),
                                reference=neighborhood('reference', a, mt[f], r)))
    work = [x for x in results if x['address'] == '6856']
    assert len(work) == 1 and work[0]['field'] == 6240
    report = dict(scope='Per-address logged writes adjacent to saved RAM snapshots; no capture edits or timing waiver.',
                  differences=results, work_RAM_6856=work[0],
                  all_snapshot_values_match_last_logged_write=all(
                      x[s]['snapshot_matches_last_logged_write'] for x in results for s in ('native', 'reference')),
                  source_sha256={p.as_posix(): sha(p) for p in sources + [nm, rm, states]},
                  graphics_gate_pass=False, gameplay_gate_pass=False,
                  limits=['Logged write times have their original source semantics; this does not equate atomic MAME writes to physical bus edges.',
                          'Stack differences are retained individually; neither unused bytes nor near-boundary timing is an automatic waiver.',
                          'No RAM/CPU state forcing, reference shift, native campaign rerun or production RTL change.'])
    out = Path('docs/evidence/sheriff_lifecycle_ram_boundaries.json')
    out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(report=out.as_posix(), differences=len(results), work_RAM_6856=work[0],
                          all_snapshot_values_match_last_logged_write=report['all_snapshot_values_match_last_logged_write'])))


if __name__ == '__main__':
    main()
