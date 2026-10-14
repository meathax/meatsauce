"""Bounded comparison of actual MAME/RTL sound writes, without masking differences.

This compares ordered writes and separately reports callback field differences.
It does not compare PCM phase, certify unsampled effects or claim MAME_EXACT.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path


def read_events(path, frames, source):
    groups = {"sound_io": [], "sound_latch_write": [], "dac_write": []}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream):
            frame = int(row["frame"])
            if frame >= frames:
                break
            if source == "mame":
                area = row["area"]
                if area == "sound_memory" and int(row["address"]) in (0xe004, 0xc104):
                    area = "dac_write"
                if area not in groups:
                    continue
                address, data = int(row["address"]), int(row["data"])
                mask = int(row["mask"])
            elif source == "rtl_io":
                if row["kind"] != "write":
                    continue
                area = "sound_io"
                address, data, mask = int(row["address"]), int(row["data"]), 255
            elif source == "rtl_dac":
                if row["kind"] != "write" or int(row["address"]) not in (0xe004, 0xc104):
                    continue
                area = "dac_write"
                address, data, mask = int(row["address"]), int(row["data"]), 255
            else:
                if int(row["iack"]) or int(row["rw"]) or int(row["address"]) != 0x0e0000:
                    continue
                area = "sound_latch_write"
                address, data = int(row["address"]), int(row["data_out"])
                mask = (0 if int(row["uds_n"]) else 0xff00) | (0 if int(row["lds_n"]) else 0xff)
            groups[area].append({"frame": frame, "address": address, "data": data & mask, "mask": mask})
    return groups


def compare(reference, actual):
    token = lambda item: (item["address"], item["data"], item["mask"])
    first = next((i for i, (a, b) in enumerate(zip(reference, actual)) if token(a) != token(b)), None)
    if first is None and len(reference) != len(actual):
        first = min(len(reference), len(actual))
    return {
        "reference_writes": len(reference), "rtl_writes": len(actual),
        "ordered_writes_equal": first is None,
        "field_label_differences": sum(a["frame"] != b["frame"] for a, b in zip(reference, actual)),
        "first_difference_index": first,
        "reference_first": reference[first] if first is not None and first < len(reference) else None,
        "rtl_first": actual[first] if first is not None and first < len(actual) else None,
        "reference_sequence_sha256": hashlib.sha256(json.dumps([token(x) for x in reference]).encode()).hexdigest(),
        "rtl_sequence_sha256": hashlib.sha256(json.dumps([token(x) for x in actual]).encode()).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument("frames", type=int)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.frames <= 0:
        parser.error("frames must be positive")
    reference = read_events(args.mame / "events.csv", args.frames, "mame")
    actual = read_events(args.rtl / "audio_events.csv", args.frames, "rtl_io")
    actual["sound_latch_write"] = read_events(args.rtl / "epoch_events.csv", args.frames, "rtl_main")["sound_latch_write"]
    dac_path = args.rtl / "sound_bus_events.csv"
    names = ["sound_io", "sound_latch_write"]
    if dac_path.exists():
        actual["dac_write"] = read_events(dac_path, args.frames, "rtl_dac")["dac_write"]
        names.append("dac_write")
    result = {
        "scope": "Finite ordered CPU sound writes; callback labels reported separately; no PCM/effect/physical pass",
        "frames": args.frames, "mame": str(args.mame.resolve()), "rtl": str(args.rtl.resolve()),
        "dac_capture_available": dac_path.exists(),
        "comparisons": {name: compare(reference[name], actual[name]) for name in names},
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({name: {key: value for key, value in data.items() if not key.endswith("sha256")}
                      for name, data in result["comparisons"].items()}))
    return 0 if all(x["ordered_writes_equal"] for x in result["comparisons"].values()) else 2


if __name__ == "__main__":
    raise SystemExit(main())
