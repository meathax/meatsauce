"""Capture whole real crysking frames from MAME 0.289 for the gpu_fabric bench.

    python -X utf8 scripts/mame_gpu_frames.py [--windows 279-280,1502-1504,2071-2074]

Writes private captures to sim/obj_dir/mame_gpu_frames/<stamp>/w<start>/ and records their
hashes in docs/mame_gpu_frames.json (the bench verifies them before replay).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
MAME = Path(r"D:\Arcade\AI\mameexe\mame.exe")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--windows", default="279-280,1502-1504,2071-2074")
    ap.add_argument("--game", default="crysking", help="crysking (staged roms/) or another set from the MAME 0.289 ROM directory")
    ap.add_argument("--report", default="docs/mame_gpu_frames.json")
    a = ap.parse_args()
    windows = [tuple(int(x) for x in w.split("-")) for w in a.windows.split(",")]
    out = ROOT / "sim/obj_dir/mame_gpu_frames" / time.strftime("%Y%m%d_%H%M%S")
    for sub in ["cfg", "nvram", "states", "snap", "input"]:
        (out / sub).mkdir(parents=True, exist_ok=True)
    script = out / "mame_gpu_frames.lua"
    shutil.copyfile(ROOT / "scripts/mame_gpu_frames.lua", script)
    env = os.environ.copy()
    env["CS_FRAMES_DIRECTORY"] = out.as_posix()
    env["CS_FRAMES_WINDOWS"] = a.windows
    env["CS_FRAMES_GAME"] = a.game
    rompath = ROOT / "roms" if a.game == "crysking" else Path(r"D:\Arcade\AI\MAME 0.289 ROMs (merged)")
    last = max(w[1] for w in windows)
    cmd = [str(MAME), a.game, "-noreadconfig", "-rompath", str(rompath), "-video", "none",
           "-sound", "none", "-nothrottle", "-skip_gameinfo", "-noplugins",
           "-cfg_directory", str(out / "cfg"), "-nvram_directory", str(out / "nvram"),
           "-state_directory", str(out / "states"), "-snapshot_directory", str(out / "snap"),
           "-input_directory", str(out / "input"), "-autoboot_delay", "0",
           "-autoboot_script", str(script), "-seconds_to_run", str(last // 60 + 30)]
    with (out / "stdout.txt").open("w") as so, (out / "stderr.txt").open("w") as se:
        rc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=so, stderr=se,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).returncode
    captures = []
    for start, end in windows:
        d = out / f"w{start:05d}"
        files = {}
        for name in ["texture.bin", "frame.bin", "state.txt", "events.txt"]:
            data = (d / name).read_bytes()
            files[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        events = (d / "events.txt").read_text().splitlines()
        captures.append({"directory": d.as_posix(), "start": start, "end": end, "files": files,
                         "state": (d / "state.txt").read_text().split(),
                         "vblanks": sum(1 for e in events if e == "V"),
                         "register_writes": sum(1 for e in events if e.startswith("R")),
                         "memory_writes": sum(1 for e in events if e.startswith("W"))})
    report = {"scope": f"Whole real {a.game} frames (MAME 0.289, mame_video_usage.lua input script) for GPU-through-fabric render timing; private memory captures",
              "command": cmd, "mame_exit": rc, "windows": captures}
    (ROOT / a.report).write_text(json.dumps(report, indent=2) + "\n")
    print("mame exit", rc, "->", out)
    for c in captures:
        print(c["start"], c["end"], "vblanks", c["vblanks"], "reg", c["register_writes"], "mem", c["memory_writes"], "state", c["state"])


if __name__ == "__main__":
    main()
