"""Check the 48 kHz output of ZeroTeam_resample48 against an ideal resample.

Needs numpy and scipy. Inputs are written by sim/audio48_main.cpp. Passes when
the output is mono-length-correct and matches a 16x band-limited reference of
the native 49.716 kHz mix (at the best constant delay) with SNR >= 40 dB; the
old sample-and-hold hand-off measured about 22 dB on game audio.
"""
import sys
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly

root = Path(__file__).resolve().parents[1]
native = np.fromfile(root / 'sim/results/audio48-native.pcm', dtype='<i2').astype(float)
out = np.fromfile(root / 'sim/results/audio48-out.pcm', dtype='<i2').astype(float)
fs, fo = 49716.0, 48000.0
assert len(out) >= 47900 and len(out) <= 48100, f'expected ~48000 outputs, got {len(out)}'
assert native.std() > 100, 'native mix is silent; run is not exercising the sound path'
up = resample_poly(native, 16, 1)
ks = np.arange(2000, len(out) - 2000)
best = (-1e9, 0.0)
for delay in np.arange(0.0, 6.0, 0.02):          # latency in input samples
    ideal = up[np.round((ks / fo * fs - delay) * 16).astype(int)]
    err = out[ks] - ideal
    snr = 10 * np.log10(np.var(ideal) / np.var(err))
    best = max(best, (snr, delay))
print(f'48 kHz output: {len(out)} samples, SNR vs ideal {best[0]:.1f} dB at {best[1]:.2f} input-sample delay')
if best[0] < 40:
    sys.exit('FAIL: resampler error above -40 dB')
print('PASS')
