"""Finite legal-input MAME restart oracle; never modifies CPU or game memory."""
from pathlib import Path
import csv
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart3901"
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def worker():
    job = json.loads((HERE / "job.json").read_text())
    env = os.environ.copy()
    env.update(ALPHA_CAPTURE_DIR=str(CAPTURE), ALPHA_CAPTURE_MODE="idle-death",
               ALPHA_CAPTURE_FRAMES="3901")
    with (HERE / "mame.log").open("w", encoding="utf8") as log:
        process = subprocess.Popen(job["command"], cwd=ROOT, env=env,
                                   stdout=log, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        (HERE / "running.json").write_text(json.dumps({"worker_pid": os.getpid(),
            "mame_pid": process.pid, "started": time.time()}, indent=2) + "\n")
        code = process.wait()
    result = {"mame_pid": process.pid, "exit_code": code,
              "ended": time.time(), "job_sha256": H(HERE / "job.json"),
              "log_sha256": H(HERE / "mame.log"),
              "failure_file": (CAPTURE / "failure.txt").exists(),
              "complete": (CAPTURE / "complete.txt").read_text() if
                  (CAPTURE / "complete.txt").exists() else None}
    (HERE / "exit.json").write_text(json.dumps(result, indent=2) + "\n")


def prepare():
    if CAPTURE.exists() or (HERE / "job.json").exists():
        raise SystemExit("Private restart oracle already exists; observe its handle.")
    source = ROOT / "sim/mame/capture_idle_death.lua"
    if H(source) != "fa38917b4985f541ebd1bc9adb789664a6095d42a579ed8d13f172d23b6e2993":
        raise SystemExit("Frozen idle-death source changed")
    executable = ROOT / "tools/mame0289/mame.exe"
    if H(executable) != "af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3":
        raise SystemExit("Pinned MAME0.289 executable changed")
    text = source.read_text()
    old = 'if mode == "idle-death" then return end -- enemies drive death naturally'
    new = '''if mode == "idle-death" then
        -- Second legal cabinet coin/start after retained title return3600.
        if frame == 3620 then set_input("IN2",1,true) end
        if frame == 3626 then set_input("IN2",1,false) end
        if frame == 3660 then set_input("IN0",0x80,true) end
        if frame == 3666 then set_input("IN0",0x80,false) end
        -- Brief legal movement distinguishes resumed gameplay from a title.
        if frame == 3740 then set_input("IN0",4,true) end
        if frame == 3770 then set_input("IN0",4,false) end
        return
    end -- enemies drive first death naturally'''
    assert text.count(old) == 1
    text = text.replace(old, new)
    old = 'if sample_frames[frame] or (mode == "idle-death" and frame >= 720 and frame % 240 == 0) or frame == total-1 then snapshot() end'
    new = 'if sample_frames[frame] or (mode == "idle-death" and frame >= 720 and frame % 240 == 0) or (frame >= 3600 and frame <= 3780 and frame % 10 == 0) or frame == 3810 or frame == 3840 or frame == total-1 then snapshot() end'
    assert text.count(old) == 1
    text = text.replace(old, new)
    lua = HERE / "capture_restart.lua"
    lua.write_text(text, encoding="utf8", newline="\n")
    CAPTURE.mkdir(parents=True)
    baseline = json.loads((ROOT / "research/kyros_idle_death7200_v2_job.json").read_text())
    command = baseline["command"][:]
    command[command.index("-autoboot_script") + 1] = str(lua)
    command[command.index("-seconds_to_run") + 1] = "72"
    for option, suffix in [("-snapshot_directory", ""), ("-cfg_directory", "cfg"),
                           ("-nvram_directory", "nvram"), ("-state_directory", "states"),
                           ("-wavwrite", "audio.wav")]:
        command[command.index(option) + 1] = str(CAPTURE / suffix)
    job = {"command": command, "capture": str(CAPTURE), "fields_requested": 3901,
           "mame_sha256": H(executable), "original_lua_sha256": H(source),
           "derived_lua_sha256": H(lua), "helper_sha256": H(Path(__file__)),
           "legal_inputs": "coin120..125/start160..165; coin3620..3625/start3660..3665/right3740..3769",
           "DIP": "Original hard0xce/three-lives hardware setting",
           "prefix": "Original idle-death inputs unchanged through3600; verify actual frame-state bytes",
           "scope": "Real pinned MAME CPUs and PCB input fields only; no memory/register edits, no native build"}
    (HERE / "job.json").write_text(json.dumps(job, indent=2) + "\n")
    process = subprocess.Popen([sys.executable, "-X", "utf8", str(Path(__file__)), "--worker"],
                               creationflags=subprocess.CREATE_NO_WINDOW,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (HERE / "launcher.json").write_text(json.dumps({"worker_pid": process.pid,
        "started": time.time(), "job_sha256": H(HERE / "job.json")}, indent=2) + "\n")
    print(json.dumps({"worker_pid": process.pid, "capture": str(CAPTURE),
                      "job": str(HERE / "job.json")}))


if __name__ == "__main__":
    worker() if "--worker" in sys.argv else prepare()
