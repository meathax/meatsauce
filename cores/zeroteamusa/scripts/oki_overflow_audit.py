#!/usr/bin/env python3
"""Replay the OKI writes of an observed sound-event CSV through a JT6295-exact
ADPCM/accumulator/4x-FIR model and count the two output defects that the
Seibu-donor JT6295 copy had:
  * ADPCM clamp with a 13-bit intermediate: |predictor +- qn| >= 4096 wraps and
    saturates to the wrong rail (full-scale spike fed back into the predictor).
  * 4x-interpolator scaled x4 then truncated to 14 bits: wraps once the FIR
    output passes +-8191 (about |4-voice sum| > 3250).
Usage: oki_overflow_audit.py sound-events.csv [roms/regions/oki.bin]"""
import csv, sys

LUT = [16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,
       157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,
       1060,1166,1282,1411,1552]
GAIN = [32,22,16,11,8,6,4,3,2,0,0,0,0,0,0,0]
CLK, OKI_HZ = 96_000_000, 96_000_000 * 15 / 1408 / 132

def wrap(x, b):
    m = 1 << b; x &= m - 1
    return x - m if x >= m // 2 else x

def clamp13(snd, sign, qn):              # donor jt6295_adpcm.v (13-bit unlim_V)
    u = wrap(snd - qn if sign else snd + qn, 13)
    b11, b12, s11 = (u >> 11) & 1, (u >> 12) & 1, (snd >> 11) & 1
    ov = (s11 and sign and not b11) or (not s11 and not sign and b11) or b11 != b12
    return (-2048 if b12 else 2047) if ov else wrap(u, 12)

def clamp14(snd, sign, qn):              # upstream jotego/jt6295 7d76b0b
    return max(-2048, min(2047, snd - qn if sign else snd + qn))

class Voice:
    def __init__(s): s.on = False
    def start(s, rom, phrase, att):
        b = rom[phrase * 8: phrase * 8 + 6]
        s.addr = ((b[0] << 16 | b[1] << 8 | b[2]) & 0x3ffff) * 2
        s.end = ((b[3] << 16 | b[4] << 8 | b[5]) & 0x3ffff) * 2 + 1
        s.att, s.on = att, s.addr < s.end
        s.p13 = s.p14 = 0; s.i13 = s.i14 = 0

def step(snd, idx, nib, clamp):
    st = LUT[idx]
    qn = (st >> 3) + (st if nib & 4 else 0) + ((st >> 1) if nib & 2 else 0) + ((st >> 2) if nib & 1 else 0)
    snd = clamp(snd, nib >> 3, qn)
    idx = min(48, idx + (2, 4, 6, 8)[nib & 3]) if nib & 4 else max(0, idx - 1)
    return snd, idx

def main():
    ev = [(int(r['cycle']), int(r['data'])) for r in csv.DictReader(open(sys.argv[1]))
          if int(r['address']) == 0x6000]
    rom = open(sys.argv[2] if len(sys.argv) > 2 else 'roms/regions/oki.bin', 'rb').read()
    coef = [int(x, 16) for x in open('rtl/sound/jt6295/jt6295_up4.hex').read().split()][:69]
    coef = [c - 65536 if c >= 32768 else c for c in coef]
    v = [Voice() for _ in range(4)]
    pend, e = None, 0
    flips = rail_hits = samples = 0
    fir_hist = {4: [0] * 69, 2: [0] * 69}
    wrap4 = wrap2 = 0; peak_sum = peak4 = 0; diverged_samples = 0
    n = 0; sums = []
    while e < len(ev) or any(x.on for x in v):
        t = n * CLK / OKI_HZ; n += 1
        while e < len(ev) and ev[e][0] <= t:
            d = ev[e][1]; e += 1
            if pend is not None:
                for k in range(4):
                    if d >> (4 + k) & 1 and not v[k].on: v[k].start(rom, pend, d & 15)
                pend = None
            elif d & 0x80: pend = d & 0x7f
            else:
                for k in range(4):
                    if d >> (3 + k) & 1: v[k].on = False
        if e >= len(ev) and not any(x.on for x in v): break
        s13 = s14 = 0
        for x in v:
            if not x.on: continue
            byte = rom[x.addr >> 1]; nib = byte >> 4 if not x.addr & 1 else byte & 15
            a, _ = x.p13, x.i13
            x.p13, x.i13 = step(x.p13, x.i13, nib, clamp13)
            x.p14, x.i14 = step(x.p14, x.i14, nib, clamp14)
            if x.p13 != clamp14(a, nib >> 3, 0) and abs(x.p13) >= 2047 and \
               (x.p13 > 0) != (clamp14(a, 0, 0) + (-1 if nib & 8 else 1) > 0):
                flips += 1
            if x.p13 != x.p14: diverged_samples += 1
            if abs(x.p14) >= 2047: rail_hits += 1
            g = GAIN[x.att]
            s13 += (x.p13 * g) >> 5; s14 += (x.p14 * g) >> 5
            x.addr += 1
            if x.addr > x.end: x.on = False
        samples += 1
        peak_sum = max(peak_sum, abs(s14))
        sums.append(s14)
    ph_c = [coef[ph::4] for ph in range(4)]   # zero-stuffed 4x FIR = 4 polyphase branches
    bound = sum(abs(c) for c in coef) / 4 / 16384
    for mul in (4, 2):                     # Q14, sat16, then sound_out = fir_dout[13:0]
        w = pk = 0
        for i in range(len(sums)):
            win = sums[max(0, i - 17):i + 1]
            if max(map(abs, win)) * mul * bound * 1.2 < 8192: continue
            for c in ph_c:
                acc = sum(c[k] * sums[i - k] * mul for k in range(len(c)) if i - k >= 0)
                o = max(-32768, min(32767, acc >> 14))
                pk = max(pk, abs(o)); w += not -8192 <= o <= 8191
        if mul == 4: wrap4, peak4 = w, pk
        else: wrap2 = w
    print(f"OKI writes {len(ev)}, decoded samples {samples} ({samples / OKI_HZ:.1f} s)")
    print(f"ADPCM 13-bit clamp: voice-samples diverging from correct decode {diverged_samples}, "
          f"sign-flipped rail spikes {flips}; correct-decode rail hits {rail_hits}")
    print(f"4-voice sum peak {peak_sum}; FIR x4 peak {peak4}; 14-bit wraps x4(donor) {wrap4}, x2(upstream) {wrap2}")

if __name__ == '__main__':
    main()
