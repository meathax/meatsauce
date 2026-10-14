"""Stage hash-verified whole-frame MAME captures (scripts/mame_gpu_frames.py) for gpu_fabric."""
from pathlib import Path
import hashlib
import json
import os

ROOT = Path(__file__).resolve().parents[1]


def main():
    # CS_FRAMES_REPORT selects another capture record (e.g. docs/mame_gpu_frames_topbladv.json).
    report = json.loads((ROOT / os.environ.get("CS_FRAMES_REPORT", "docs/mame_gpu_frames.json")).read_text())
    lines = []
    for w in report["windows"]:
        d = Path(w["directory"])
        for name, expected in w["files"].items():
            data = (d / name).read_bytes()
            if len(data) != expected["bytes"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
                raise RuntimeError(f"MAME frame capture changed: {d / name}")
        lines.append(d.as_posix())
    out = ROOT / "sim/obj_dir/gpu_fabric"
    out.mkdir(parents=True, exist_ok=True)
    (out / "frames.txt").write_text("\n".join(lines) + "\n")
    print("Verified", len(lines), "whole-frame MAME captures:", ", ".join(f"{w['start']}-{w['end']}" for w in report["windows"]))


if __name__ == "__main__":
    main()
