"""Synthetic per-line sprite load scenes for the graphics deadline bench.

Copies a real MAME capture (tiles, palette, CRTC) and replaces its sprite list
with N sprites, 8 tiles (128 px) wide and 1 tile high, all covering lines
100..115, using sprite codes the capture really uses. N*8 = 16-pixel sprite
rows fetched on each of those lines.
"""
from pathlib import Path
import argparse, shutil, struct
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--base', default='sim/results/mame-play-1800-combat-4p-combat4p')
p.add_argument('--counts', default='8,12,16,20,24,28,32')
a = p.parse_args()
base = root/a.base
w = struct.unpack('<2048H', (base/'sprite_buffer.bin').read_bytes())
codes = [w[4*e+1] for e in range(512) if w[4*e+1] and not w[4*e+1] & 0x8000]
assert codes
for n in map(int, a.counts.split(',')):
    out = root/'build/contention/synth'/f'load-{n*8:03d}cols'
    if out.exists(): shutil.rmtree(out)
    shutil.copytree(base, out)
    words = [0]*2048
    for e in range(n):
        x = (e*37) % 320 - 64
        words[4*e:4*e+4] = [(7 << 8) | (e & 63), codes[e % len(codes)], x & 0x1ff, 100]
    (out/'sprite_buffer.bin').write_bytes(struct.pack('<2048H', *words))
    print(out.relative_to(root))
