"""Finite, phase-independent WAV comparisons; never a whole-game audio gate."""
import argparse
import array
import cmath
import hashlib
import json
import math
from pathlib import Path
import sys
import wave


def fft(values):
    n = len(values)
    out = [complex(x) for x in values]
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            out[i], out[j] = out[j], out[i]
    width = 2
    while width <= n:
        step = cmath.exp(-2j * math.pi / width)
        for start in range(0, n, width):
            factor = 1 + 0j
            for k in range(width // 2):
                a, b = out[start + k], out[start + k + width // 2] * factor
                out[start + k], out[start + k + width // 2] = a + b, a - b
                factor *= step
        width *= 2
    return out


def peaks(data, rate):
    n = len(data)
    mean = sum(data) / n
    spectrum = fft([(x - mean) * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)))
                    for i, x in enumerate(data)])
    power = [abs(x) ** 2 for x in spectrum[:n // 2]]
    candidates = [i for i in range(2, len(power) - 1)
                  if 20 <= i * rate / n <= 10000 and power[i] > power[i - 1] and power[i] >= power[i + 1]]
    selected = []
    for i in sorted(candidates, key=lambda i: power[i], reverse=True):
        if any(abs(i - p["bin"]) < 4 for p in selected):
            continue
        left, center, right = [math.log(max(1e-30, power[k])) for k in [i - 1, i, i + 1]]
        denom = left - 2 * center + right
        offset = 0.5 * (left - right) / denom if denom else 0
        selected.append(dict(bin=i, hz=(i + offset) * rate / n, power=power[i]))
        if len(selected) == 12:
            break
    return dict(mean=mean, ac_rms=math.sqrt(sum((x - mean) ** 2 for x in data) / n), peaks=selected)


def read(path):
    with wave.open(str(path), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, 48000):
            raise ValueError("48 kHz mono signed16 WAV required")
        data = array.array("h", w.readframes(w.getnframes()))
    if sys.byteorder != "little":
        data.byteswap()
    return data


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mame", type=Path)
    p.add_argument("rtl", type=Path)
    p.add_argument("report", type=Path)
    args = p.parse_args()
    a, b = read(args.mame), read(args.rtl)
    n = 32768
    calibration = peaks([math.sin(2 * math.pi * 1000 * i / 48000) for i in range(n)], 48000)
    error = abs(calibration["peaks"][0]["hz"] - 1000)
    if error > 0.1:
        raise ValueError("FFT frequency calibration failed")
    windows = []
    for start in [2, 3, 20, 29]:
        first = start * 48000
        if min(len(a), len(b)) < first + n:
            raise ValueError("WAV interval unavailable")
        x, y = peaks(a[first:first + n], 48000), peaks(b[first:first + n], 48000)
        matches = [dict(rtl_hz=q["hz"], mame_hz=min(x["peaks"], key=lambda z: abs(z["hz"] - q["hz"]))["hz"])
                   for q in y["peaks"][:6]]
        for q in matches:
            q["difference_hz"] = q["rtl_hz"] - q["mame_hz"]
        windows.append(dict(start_seconds=start, duration_seconds=n / 48000,
                            mame=x, rtl=y, ac_rms_ratio=y["ac_rms"] / x["ac_rms"], nearest_peaks=matches))
    result = dict(scope="four finite absolute-time windows; nearest spectral peaks are diagnostic, not automatic passes",
                  no_time_offset_applied=True, hann_samples=n, bin_hz=48000 / n,
                  calibration_error_hz=error, hashes={str(x): hashlib.sha256(x.read_bytes()).hexdigest()
                                                     for x in [args.mame, args.rtl]}, windows=windows)
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(dict(report=str(args.report), calibration_error_hz=error,
                          windows=[dict(start=x["start_seconds"], ac_rms_ratio=x["ac_rms_ratio"],
                                        nearest_peaks=x["nearest_peaks"]) for x in windows])))


if __name__ == "__main__":
    main()
