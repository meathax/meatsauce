"""Band-power comparison of native-rate (49.716 kHz) mono s16le PCM captures.

Usage: python scripts/audio_band_compare.py A.pcm B.pcm [...]
Prints, for each file, average power in 0-4, 4-12, 12-20 and 20-24.8 kHz over
all 4096-sample blocks with signal, plus a click count (sample steps above 8192
that are not part of a sustained slope). Pure Python; no numpy required.
"""
import cmath, math, struct, sys

FS = 96e6 * 105 / 2816 / 72
N = 4096
BANDS = [(0, 4000), (4000, 12000), (12000, 20000), (20000, FS / 2)]


def fft(x):
    n = len(x)
    if n == 1:
        return x
    e, o = fft(x[0::2]), fft(x[1::2])
    t = [cmath.exp(-2j * math.pi * k / n) * o[k] for k in range(n // 2)]
    return [e[k] + t[k] for k in range(n // 2)] + [e[k] - t[k] for k in range(n // 2)]


def analyse(path):
    raw = open(path, 'rb').read()
    s = struct.unpack('<%dh' % (len(raw) // 2), raw)
    win = [0.5 - 0.5 * math.cos(2 * math.pi * i / N) for i in range(N)]
    acc = [0.0] * len(BANDS)
    blocks = 0
    for b in range(0, len(s) - N, N):
        blk = s[b:b + N]
        if max(abs(v) for v in blk) < 64:
            continue
        sp = fft([blk[i] * win[i] for i in range(N)])
        for k in range(1, N // 2):
            f = k * FS / N
            p = abs(sp[k]) ** 2
            for i, (lo, hi) in enumerate(BANDS):
                if lo <= f < hi:
                    acc[i] += p
        blocks += 1
    clicks = sum(1 for i in range(2, len(s) - 1)
                 if abs(s[i] - s[i - 1]) > 8192 and abs(s[i - 1] - s[i - 2]) < 2048
                 and abs(s[i + 1] - s[i]) < 2048)
    return blocks, [10 * math.log10(a / max(blocks, 1) + 1e-9) for a in acc], clicks


for p in sys.argv[1:]:
    blocks, db, clicks = analyse(p)
    print(f"{p}: blocks={blocks} " + ' '.join(
        f"{lo/1000:.0f}-{hi/1000:.1f}k={v:.1f}dB" for (lo, hi), v in zip(BANDS, db)) + f" clicks={clicks}")
