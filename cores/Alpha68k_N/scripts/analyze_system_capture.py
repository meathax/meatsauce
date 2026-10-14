"""Qualify native capture plumbing; MAME comparisons are diagnostic, not game gates."""
import argparse
import csv
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("exit_receipt", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("--frames", type=int, required=True)
    parser.add_argument("--frame-origin", type=int, choices=[0, 1], default=0,
                        help="0 for the MAME recorder epoch; legacy captures require explicit 1")
    parser.add_argument("--oracle", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    receipt = json.loads(args.exit_receipt.read_text())
    rows = list(csv.DictReader((args.capture / "frames.csv").open()))
    checks = {
        "process_exit_zero": receipt["exit_code"] == 0,
        "all_frames_present": len(rows) == args.frames,
        "frame_sequence": [int(r["frame"]) for r in rows] == list(range(args.frame_origin, args.frames + args.frame_origin)),
        "complete_pixels": bool(rows) and all(int(r["pixels"]) == 57344 for r in rows),
        "no_duplicate_pixels": all(int(r["duplicates"]) == 0 for r in rows),
        "no_renderer_deadlines": all(int(r["deadline_misses"]) == 0 for r in rows),
        "no_renderer_overflows": all(int(r["row_overflows"]) == 0 for r in rows),
        "no_unmapped_cpu_access": all(int(r["unmapped"]) == 0 for r in rows),
        "real_cpu_transactions": bool(rows) and int(rows[-1]["main_transactions"]) > 10,
        "final_capture_present": (args.capture / f"frame_{args.frames + args.frame_origin - 1:06d}.rgb").is_file(),
    }
    images = []
    for path in sorted(args.capture.glob("frame_*.rgb")):
        pixels = path.read_bytes()
        entry = {"path": str(path.resolve()), "sha256": sha(path), "bytes": len(pixels)}
        checks["native_rgb_sizes"] = checks.get("native_rgb_sizes", True) and len(pixels) == 57344 * 3
        if args.oracle:
            reference = args.oracle / path.name.replace(".rgb", ".display.rgb")
            if reference.is_file():
                expected = reference.read_bytes()
                if len(expected) != len(pixels):
                    raise ValueError(f"invalid displayed reference size: {reference}")
                entry["mame_diagnostic"] = {
                    "reference": str(reference.resolve()), "sha256": sha(reference),
                    "different_pixels": sum(pixels[i:i+3] != expected[i:i+3]
                                            for i in range(0, len(pixels), 3)),
                    "scope": "Same frame labels; later CPU/event phase alignment requires separate evidence.",
                }
        images.append(entry)
    report = {
        "scope": "Real fx68k/T80, live strip RAM, RTL renderer/palette/SDRAM controller; external SDRAM model only.",
        "limits": "Boot/capture plumbing only. No audio-chip, gameplay, late-stage, or hardware acceptance implied.",
        "checks": checks, "passed": all(checks.values()), "frames": len(rows),
        "final_counters": rows[-1] if rows else None, "images": images,
        "exit_receipt": receipt,
        "source_manifest": str(root / "sim/build/system_inputs.sha256"),
        "source_manifest_sha256": sha(root / "sim/build/system_inputs.sha256"),
        "evidence_sha256": {name: sha(args.capture / name)
                            for name in ("frames.csv", "bus.csv", "work.bin", "sprites.bin")},
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"report": str(args.report.resolve()), "passed": report["passed"],
                      "frames": len(rows), "comparisons": [i["mame_diagnostic"]["different_pixels"]
                                                           for i in images if "mame_diagnostic" in i]}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
