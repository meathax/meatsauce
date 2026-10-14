"""A separate, actual-MAME legal extension; frozen3901 evidence is immutable."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = ROOT / "research/kyros_restart_acceptance"
CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart_actions4401"
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def worker():
    job = json.loads((HERE / "job.json").read_text())
    env = os.environ.copy()
    env.update(ALPHA_CAPTURE_DIR=str(CAPTURE), ALPHA_CAPTURE_MODE="idle-death", ALPHA_CAPTURE_FRAMES="4401")
    with (HERE / "mame.log").open("w", encoding="utf8") as log:
        p = subprocess.Popen(job["command"], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                             creationflags=subprocess.CREATE_NO_WINDOW)
        (HERE / "running.json").write_text(json.dumps({"worker_pid": os.getpid(), "mame_pid": p.pid,
                                                       "started": time.time()}, indent=2) + "\n")
        code = p.wait()
    (HERE / "exit.json").write_text(json.dumps({"exit_code": code, "mame_pid": p.pid, "ended": time.time(),
        "job_sha256": H(HERE / "job.json"), "log_sha256": H(HERE / "mame.log"),
        "failure_file": (CAPTURE / "failure.txt").exists(),
        "complete": (CAPTURE / "complete.txt").read_text() if (CAPTURE / "complete.txt").exists() else None}, indent=2) + "\n")


def prepare():
    if CAPTURE.exists() or (HERE / "job.json").exists():
        raise SystemExit("Existing job; observe without restarting.")
    v = BASE / "verification.json"
    assert H(v) == "0b4e054649d1d9c2248a8ee8caf85fd4fb92d7648c0eed694c2bef41a9380206"
    frozen = json.loads(v.read_text())
    lua = BASE / "capture_restart.lua"
    assert H(lua) == frozen["source_pins"]["Lua"]
    text = lua.read_text()
    old = '        return\n    end -- enemies drive first death naturally'
    new = '''        -- Only legal PCB controls after actual courtyard gameplay3900.
        if frame == 3920 then set_input("IN0",4,true) end
        if frame == 3960 then set_input("IN0",4,false) end
        if frame == 3980 then set_input("IN0",0x20,true) end
        if frame == 3984 then set_input("IN0",0x20,false) end
        if frame == 4040 then set_input("IN0",0x10,true) end
        if frame == 4054 then set_input("IN0",0x10,false) end
        -- Actual4101 still showed GET READY; original effective punch711+3500 anchors active4211+.
        if frame == 4220 then set_input("IN0",4,true) end
        if frame == 4260 then set_input("IN0",4,false) end
        if frame == 4280 then set_input("IN0",0x20,true) end
        if frame == 4284 then set_input("IN0",0x20,false) end
        if frame == 4340 then set_input("IN0",0x10,true) end
        if frame == 4354 then set_input("IN0",0x10,false) end
        return
    end -- enemies drive first death naturally'''
    assert text.count(old) == 1
    text = text.replace(old, new)
    old = 'or frame == 3810 or frame == 3840 or frame == total-1 then snapshot() end'
    new = 'or frame == 3810 or frame == 3840 or (frame >= 3900 and frame % 5 == 0) or frame == total-1 then snapshot() end'
    assert text.count(old) == 1
    text = text.replace(old, new)
    derived = HERE / "capture_restart_actions.lua"
    derived.write_text(text, encoding="utf8", newline="\n")
    job = json.loads((BASE / "job.json").read_text())
    assert H(Path(job["command"][0])) == job["mame_sha256"]
    command = job["command"][:]
    command[command.index("-autoboot_script") + 1] = str(derived)
    command[command.index("-seconds_to_run") + 1] = "82"
    for option, suffix in [("-snapshot_directory", ""), ("-cfg_directory", "cfg"),
                           ("-nvram_directory", "nvram"), ("-state_directory", "states"), ("-wavwrite", "audio.wav")]:
        command[command.index(option) + 1] = str(CAPTURE / suffix)
    CAPTURE.mkdir(parents=True)
    source = Path("D:/Arcade/AI/mame289/src/mame/alpha/alpha68k_n.cpp")
    (HERE / "job.json").write_text(json.dumps({"command": command, "fields_requested": 4401,
        "mame_sha256": job["mame_sha256"], "frozen3901_verification_sha256": H(v),
        "frozen3901_lua_sha256": H(lua), "derived_lua_sha256": H(derived),
        "helper_sha256": H(Path(__file__)), "mame_driver_path": str(source), "mame_driver_sha256": H(source),
        "control_source": "alpha68k_n.cpp574-582/628-631: active-high P1 RIGHT4/BUTTON1=16/BUTTON2=32; no assumed hit or jump success",
        "extension_events": [[3920,"IN0",4,1],[3960,"IN0",4,0],[3980,"IN0",32,1],[3984,"IN0",32,0],[4040,"IN0",16,1],[4054,"IN0",16,0],[4220,"IN0",4,1],[4260,"IN0",4,0],[4280,"IN0",32,1],[4284,"IN0",32,0],[4340,"IN0",16,1],[4354,"IN0",16,0]],
        "scope": "Actual MAME CPUs, legal cabinet inputs only; no CPU or RAM modification; frozen3901 unchanged"}, indent=2) + "\n")
    p = subprocess.Popen([sys.executable,"-X","utf8",str(Path(__file__)),"--worker"],
                         creationflags=subprocess.CREATE_NO_WINDOW, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (HERE / "launcher.json").write_text(json.dumps({"worker_pid": p.pid,"started":time.time(),
                                                   "job_sha256":H(HERE / "job.json")}, indent=2) + "\n")
    print(json.dumps({"worker_pid":p.pid,"fields":4101,"capture":str(CAPTURE)}))


if __name__ == "__main__":
    worker() if "--worker" in sys.argv else prepare()
