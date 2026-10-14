"""Emit the Lanczos-4 fractional-delay table used by ZeroTeam_resample48.

64 phases x 8 taps, Q1.14, each phase normalised to exactly 16384 (unity DC).
Tap a is the sample of age a (a=0 newest); the output instant lies between
ages 4 and 3, f = (phase+0.5)/64 past age 4, so tap a has weight L(f+a-4).
Paste the output between the TABLE markers in rtl/ZeroTeam_audio.sv.
"""
import math

def lanczos(d, a=4):
    if d == 0:
        return 1.0
    if abs(d) >= a:
        return 0.0
    return a * math.sin(math.pi * d) * math.sin(math.pi * d / a) / (math.pi * math.pi * d * d)

lines = []
for ph in range(64):
    f = (ph + 0.5) / 64
    w = [lanczos(f + a - 4) for a in range(8)]
    s = sum(w)
    q = [round(v / s * 16384) for v in w]
    q[max(range(8), key=lambda i: abs(q[i]))] += 16384 - sum(q)
    assert sum(q) == 16384
    for a, v in enumerate(q):
        lines.append(f"        rom[9'd{ph * 8 + a}] = {'-' if v < 0 else ''}16'sd{abs(v)};")
print("\n".join(lines))
