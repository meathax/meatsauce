"""Compare per-IRQ work-RAM traces from the core board sim and MAME.

Each trace is a sequence of records {u32 LE irq index, 65536 LE words covering
0x00000-0x1ffff}. The core records at the IRQ acknowledge, MAME at the first
vector-table read; the stack page differs by construction and is excluded.

Usage: python scripts/compare_ram_trace.py core.bin mame.bin [--offset N]
       [--exclude 0xb700-0xb7ff ...] [--show 40]
Reports, per IRQ, the number of differing words, then details of the first
divergent IRQ (addresses, core and MAME values, and how long each address
stays different).
"""
import argparse, struct

REC = 4 + 2 * 65536


def records(path):
    with open(path, 'rb') as f:
        while True:
            b = f.read(REC)
            if len(b) < REC:
                return
            yield struct.unpack_from('<I', b)[0], b[4:]


def parse_range(s):
    a, b = s.split('-')
    return int(a, 0), int(b, 0)


ap = argparse.ArgumentParser()
ap.add_argument('core'); ap.add_argument('mame')
ap.add_argument('--offset', type=int, default=0, help='mame irq = core irq + offset')
ap.add_argument('--exclude', action='append', default=['0xb700-0xb7ff'])
ap.add_argument('--show', type=int, default=40)
ap.add_argument('--every', type=int, default=50)
ap.add_argument('--first', type=int, default=1, help='first core irq to compare')
a = ap.parse_args()
ex = [parse_range(r) for r in a.exclude]


def keep(addr):
    return not any(lo <= addr <= hi for lo, hi in ex)


mame = {}
for n, d in records(a.mame):
    mame[n] = d
print(f"mame records {len(mame)} (irq {min(mame)}..{max(mame)})")
first = None
history = {}
count = 0
for n, d in records(a.core):
    count += 1
    m = mame.get(n + a.offset)
    if m is None or n < a.first:
        continue
    diffs = [i for i in range(0, len(d), 2) if d[i:i + 2] != m[i:i + 2] and keep(i)]
    if n % a.every == 0 or (diffs and first is None):
        print(f"irq {n}: {len(diffs)} differing words")
    if diffs and first is None:
        first = n
        print(f"FIRST DIVERGENCE at core irq {n} (mame irq {n + a.offset}):")
        for i in diffs[:a.show]:
            c = int.from_bytes(d[i:i + 2], 'little'); x = int.from_bytes(m[i:i + 2], 'little')
            print(f"  {i:05x}: core {c:04x} mame {x:04x}")
print(f"core records {count}")
