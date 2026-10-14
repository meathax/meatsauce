"""Bounded offline diagnostics; this is not live MAME/RTL acceptance."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pixel_diff(a, b):
    if len(a) != 256 * 224 * 3 or len(b) != len(a):
        raise ValueError("expected native 256x224 RGB24 captures")
    locations = [i // 3 for i in range(0, len(a), 3) if a[i:i+3] != b[i:i+3]]
    return {
        "count": len(locations),
        "bounds": ([min(i % 256 for i in locations), min(i // 256 + 16 for i in locations),
                    max(i % 256 for i in locations), max(i // 256 + 16 for i in locations)]
                   if locations else None),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--mame", type=Path, required=True)
    parser.add_argument("--frame", type=int, required=True)
    parser.add_argument("--set", required=True, choices=["kyros", "kyrosj"])
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--render-snapshots", action="store_true")
    args = parser.parse_args()
    args.rtl = args.rtl.resolve()
    args.mame = args.mame.resolve()
    args.report = args.report.resolve()
    prefix = f"frame_{args.frame:06d}"
    with (args.rtl / "frames.csv").open() as f:
        rtl_rows = list(csv.DictReader(f))
    if int(rtl_rows[-1]["frame"]) != args.frame:
        raise ValueError("RTL RAM snapshots belong only to the terminal captured frame")
    with (args.mame / "frame_states.csv").open() as f:
        mame_row = next(row for row in csv.DictReader(f) if int(row["frame"]) == args.frame)
    native = args.rtl / f"{prefix}.rgb"
    oracle = args.mame / f"{prefix}.display.rgb"
    report = {
        "scope": "offline terminal-frame state/render diagnosis; frame alignment unproven",
        "frame": args.frame,
        "rtl_frame_state": rtl_rows[-1],
        "mame_frame_state": mame_row,
        "pixel_diff": pixel_diff(native.read_bytes(), oracle.read_bytes()),
        "inputs": {str(p.relative_to(ROOT)): sha(p) for p in [native, oracle]},
        "ram": {},
    }
    for name, base in [("work", 0x20000), ("sprites", 0x40000)]:
        a = args.rtl / f"{name}.bin"
        b = args.mame / f"{prefix}.{name}.bin"
        raw_a, raw_b = a.read_bytes(), b.read_bytes()
        if len(raw_a) != len(raw_b) or len(raw_a) % 2:
            raise ValueError("RAM snapshot sizes differ")
        words_a = struct.unpack(f">{len(raw_a)//2}H", raw_a)
        words_b = struct.unpack(f">{len(raw_b)//2}H", raw_b)
        differences = [{"index": i, "address": base + 2*i, "rtl": x, "mame": y, "xor": x ^ y}
                       for i, (x, y) in enumerate(zip(words_a, words_b)) if x != y]
        report["ram"][name] = {"bytes": len(raw_a), "count": len(differences), "differences": differences}
        report["inputs"].update({str(p.relative_to(ROOT)): sha(p) for p in [a, b]})
    if args.render_snapshots:
        # This executable runs the real isolated renderer and an independent
        # MAME-structure software renderer against the supplied static RAM.
        # No CPU, live epoch agreement, or whole-game pass is inferred.
        executable = ROOT / "sim/build/alpha68kn_render_fixture_sim"
        report["fixture_executable_sha256"] = sha(executable)
        snapshots = [args.rtl / "sprites.bin", args.mame / f"{prefix}.sprites.bin"]
        report["snapshot_renders"] = []
        for label, snapshot in zip(["rtl", "mame"], snapshots):
            out = ROOT / "sim/captures/renderer" / f"{args.set}_{prefix}_{label}_state"
            out.mkdir(parents=True, exist_ok=True)
            cmd = ["wsl.exe", "-d", "Ubuntu", "--cd", str(ROOT), "--exec",
                   "./sim/build/alpha68kn_render_fixture_sim",
                   f"roms/{args.set}/download.bin", str(snapshot.relative_to(ROOT)).replace("\\", "/"),
                   mame_row["background"], str(out.relative_to(ROOT)).replace("\\", "/"), "0", "-"]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
            (out / "run.log").write_text(result.stdout + result.stderr, encoding="utf-8")
            item = {"state": label, "exit_code": result.returncode, "command": cmd,
                    "output": str(out.relative_to(ROOT)), "stdout": result.stdout.strip(),
                    "stderr": result.stderr.strip()}
            for filename in ["actual.rgb", "expected.rgb"]:
                path = out / filename
                if path.is_file():
                    item[filename] = {"sha256": sha(path),
                                      "vs_live_rtl": pixel_diff(path.read_bytes(), native.read_bytes()),
                                      "vs_mame_display": pixel_diff(path.read_bytes(), oracle.read_bytes())}
            report["snapshot_renders"].append(item)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    compact = {"scope": report["scope"], "pixel_diff": report["pixel_diff"],
               "ram_counts": {k: v["count"] for k, v in report["ram"].items()},
               "renders": [{"state": x["state"], "exit_code": x["exit_code"],
                            "comparisons": x.get("actual.rgb")} for x in report.get("snapshot_renders", [])],
               "report": str(args.report)}
    print(json.dumps(compact, separators=(",", ":")))
    return int(any(x["exit_code"] != 0 for x in report.get("snapshot_renders", [])))


if __name__ == "__main__":
    raise SystemExit(main())
