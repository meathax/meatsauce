"""Compare finite per-device moments from MAME hooks and real RTL replay."""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compare(mame_path, rtl_path):
    bins = {}
    with mame_path.open(newline="") as stream:
        for row in csv.DictReader(stream):
            second = math.ceil(float(row["time_end"]) - 1e-9) - 1
            key = second, row["component"]
            totals = bins.setdefault(key, [0, 0.0, 0.0])
            for i, name in enumerate(("samples", "sum", "sum_squared")):
                totals[i] += float(row[name])
    with rtl_path.open(newline="") as stream:
        rtl = {int(row["second"]): row for row in csv.DictReader(stream)}
    windows = []
    for second in (2, 3, 10, 15, 20, 29):
        devices = {}
        for component in ("fm", "ym_ssg", "ay1", "ay2", "dac"):
            count, total, squares = bins[second, component]
            mean = total / count
            rms = math.sqrt(max(0.0, squares / count - mean * mean))
            rtl_mean = float(rtl[second][component + "_mean"])
            rtl_rms = float(rtl[second][component + "_ac_rms"])
            devices[component] = {"mame_samples": int(count), "mame_mean": mean,
                                  "mame_ac_rms": rms, "rtl_mean": rtl_mean,
                                  "rtl_ac_rms": rtl_rms,
                                  "ac_rms_ratio": rtl_rms / rms if rms > 1e-3 else None}
        windows.append({"second": second, "devices": devices})
    missing = [[row["second"], name] for row in windows for name, device in row["devices"].items()
               if device["mame_ac_rms"] > 10 and device["rtl_ac_rms"] == 0]
    return {"scope": "Finite one-second source moments; MAME producer sample rates differ from RTL 48 kHz. Hook callback time bins include source lookahead. No phase, resampler, physical-board or whole-audio exactness claim.",
            "source_activity_ok": not missing, "missing_activity": missing,
            "mame_path": str(mame_path), "mame_sha256": digest(mame_path),
            "rtl_path": str(rtl_path), "rtl_sha256": digest(rtl_path),
            "windows": windows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = compare(args.mame, args.rtl)
    args.output.write_text(json.dumps(result, indent=2) + "\n", newline="\n")
    print(json.dumps({"output": str(args.output), "ym_ssg_ac_ratios": [
        [row["second"], row["devices"]["ym_ssg"]["ac_rms_ratio"]]
        for row in result["windows"]]}))
    if not result["source_activity_ok"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
