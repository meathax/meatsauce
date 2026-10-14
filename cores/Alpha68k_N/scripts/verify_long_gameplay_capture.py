"""Record finite real-CPU coverage and every available canonical RGB comparison."""
import argparse
import csv
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("capture", type=Path)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("fields", type=int)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    receipt = json.loads(args.receipt.read_text())
    with (args.capture / "frames.csv").open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    checks = {
        "exit_zero": receipt.get("exit_code") == 0,
        "field_sequence": [int(row["frame"]) for row in rows] == list(range(args.fields)),
        "complete_unique_pixels": bool(rows) and all(int(row["pixels"]) == 57344 and int(row["duplicates"]) == 0 for row in rows),
        "no_unmapped_or_renderer_failures": bool(rows) and all(all(int(row[key]) == 0 for key in ("unmapped", "deadline_misses", "row_overflows")) for row in rows),
        "cpu_activity": bool(rows) and int(rows[-1]["main_transactions"]) > 0 and int(rows[-1]["strip_writes"]) > 0,
    }
    comparisons = []
    for reference in sorted(args.reference.glob("frame_*.display.rgb")):
        field = int(reference.name.split(".")[0].split("_")[1])
        if field >= args.fields:
            continue
        actual = args.capture / f"frame_{field:06d}.rgb"
        if not actual.exists():
            comparisons.append({"field": field, "available": False})
            continue
        expected, observed = reference.read_bytes(), actual.read_bytes()
        item = {"field": field, "available": True, "reference_sha256": digest(reference), "rtl_sha256": digest(actual), "expected_bytes": len(expected), "observed_bytes": len(observed)}
        item["different_pixels"] = sum(expected[i:i+3] != observed[i:i+3] for i in range(0, len(expected), 3)) if len(expected) == len(observed) == 172032 else None
        comparisons.append(item)
    all_images_available = bool(comparisons) and all(item["available"] for item in comparisons)
    graphics_pass = all_images_available and all(item.get("different_pixels") == 0 for item in comparisons)
    result = {
        "scope": "Finite actual RTL CPU replay; every available canonical displayed image, without masks or frame shifts. Sampled images do not qualify unsampled frames, all effects, physical timing or whole-game correctness.",
        "terminal_receipt": receipt, "reference": str(args.reference.resolve()), "capture": str(args.capture.resolve()),
        "fields": len(rows), "metric_checks": checks, "metrics_pass": all(checks.values()),
        "worst_line_cycles": max((int(row["worst_line_cycles"]) for row in rows), default=None),
        "all_reference_images_available": all_images_available,
        "canonical_graphics_pass": graphics_pass, "comparisons": comparisons,
        "ram_scope": "Only final unlabelled RTL RAM dumps available in these runs; no checkpoint RAM equivalence claimed.",
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "fields": len(rows), "metrics_pass": result["metrics_pass"], "images": len(comparisons), "graphics_pass": graphics_pass, "failures": [{"field": x["field"], "different_pixels": x.get("different_pixels")} for x in comparisons if x.get("different_pixels") != 0]}))
    return 0 if all(checks.values()) and graphics_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
