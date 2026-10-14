"""Run crysking in real MAME with scripts/mame_video_usage.lua and summarise VRender0 feature usage.

Output goes to sim/obj_dir/mame_video_usage/<stamp>/ (private, ignored). Usage:
    python -X utf8 scripts/mame_video_usage.py --frames 7200
    python -X utf8 scripts/mame_video_usage.py --summarize <dir>
"""
import argparse
import collections
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
MAME = Path(r"D:\Arcade\AI\mameexe\mame.exe")


def run(frames):
    out = ROOT / "sim/obj_dir/mame_video_usage" / time.strftime("%Y%m%d_%H%M%S")
    for sub in ["cfg", "nvram", "states", "snap", "input"]:
        (out / sub).mkdir(parents=True, exist_ok=True)
    script = out / "mame_video_usage.lua"
    shutil.copyfile(ROOT / "scripts/mame_video_usage.lua", script)
    env = os.environ.copy()
    env["CS_USAGE_DIRECTORY"] = out.as_posix()
    env["CS_USAGE_FRAMES"] = str(frames)
    cmd = [str(MAME), "crysking", "-noreadconfig", "-rompath", str(ROOT / "roms"), "-video", "none",
           "-sound", "none", "-nothrottle", "-skip_gameinfo", "-noplugins",
           "-cfg_directory", str(out / "cfg"), "-nvram_directory", str(out / "nvram"),
           "-state_directory", str(out / "states"), "-snapshot_directory", str(out / "snap"),
           "-input_directory", str(out / "input"), "-autoboot_delay", "0",
           "-autoboot_script", str(script), "-seconds_to_run", str(frames // 60 + 30)]
    with (out / "stdout.txt").open("w") as so, (out / "stderr.txt").open("w") as se:
        rc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=so, stderr=se,
                            creationflags=subprocess.CREATE_NO_WINDOW).returncode
    print("mame exit", rc, "output", out)
    return out


def summarize(out):
    out = Path(out)
    print(json.dumps(json.loads((out / "summary.json").read_text()), indent=1))
    kinds = collections.defaultdict(list)
    with (out / "events.csv").open() as f:
        for r in csv.DictReader(f):
            kinds[r["kind"]].append(r)
    for k, rows in kinds.items():
        print(f"\n== {k}: {len(rows)} (first frame {rows[0]['frame']}, last {rows[-1]['frame']})")
        if k in ("palette_collision",):
            continue
        seen = collections.Counter(r["detail"].split(" pc=")[0] for r in rows)
        for d, n in seen.most_common(12):
            print("  ", n, d[:160])
    print("\n== combos")
    for r in csv.DictReader((out / "combos.csv").open()):
        print(f"  {r['combo']:<70} n={r['count']:>8} first={r['first_frame']:>5} area={r['pixel_area_sum']:>12} maxquad={r['max_quad_area']}")
    rows = list(csv.DictReader((out / "perframe.csv").open()))
    for key in ["draw_quads", "pixel_area", "consumed", "front_draw_quads"]:
        best = max(rows, key=lambda r: int(r[key]))
        print(f"max {key}: {best[key]} at frame {best['frame']}")
    bank_changes = sum(1 for a, b in zip(rows, rows[1:]) if a["display_bank"] != b["display_bank"])
    print("display_bank toggles:", bank_changes, "frames:", len(rows))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=7200)
    ap.add_argument("--summarize")
    a = ap.parse_args()
    summarize(a.summarize if a.summarize else run(a.frames))
