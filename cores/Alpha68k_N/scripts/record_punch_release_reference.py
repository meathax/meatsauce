"""Capture one legal Kyros punch followed by a finite released-input tail."""
import csv
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_punch_release601"
FIELDS = 601


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert os.name == "nt", "Use the installed Windows MAME executable through Windows Python"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--late", action="store_true", help="Pulse710–723 after observed game initialization; capture1081 fields")
    args = parser.parse_args()
    name = "kyros_punch_release1081" if args.late else NAME
    fields = 1081 if args.late else FIELDS
    punch_first = 710 if args.late else 260
    punch_last = punch_first + 14
    capture = ROOT / "sim/captures/kyros" / name.removeprefix("kyros_")
    job = ROOT / "research" / (name + "_job.json")
    assert not job.exists() and not capture.exists(), "Preserve existing job/capture"
    source = ROOT / "sim/mame/capture_combat.lua"
    text = source.read_text()
    start = text.index("local last_combat_controls = 0")
    end = text.index("local function dump(name, bytes)", start)
    text = text[:start] + '''local last_punch_controls = 0
local function drive_inputs()
    if mode ~= "punch_release" then return end
    if frame == 120 then set_input("IN2",1,true) end
    if frame == 126 then set_input("IN2",1,false) end
    local desired = frame >= 160 and frame < 166 and 0x80 or 0
    if frame >= 260 and frame < 274 then desired = 0x10 end
    for _,mask in ipairs({1,2,4,8,0x10,0x20,0x80}) do
        if (desired & mask) ~= (last_punch_controls & mask) then
            set_input("IN0",mask,(desired & mask) ~= 0)
        end
    end
    last_punch_controls = desired
end

''' + text[end:]
    text = text.replace("frame >= 260 and frame < 274", f"frame >= {punch_first} and frame < {punch_last}")
    assert "space:write" not in text and ":set_state" not in text
    script = ROOT / "sim/mame" / ("capture_punch_release1081.lua" if args.late else "capture_punch_release.lua")
    assert not script.exists(), "Preserve existing derived Lua"
    script.write_text(text, newline="\n")
    template = json.loads((ROOT / "research/kyros_idle_death7200_v2_job.json").read_text())
    command = [v.replace(template["capture"], str(capture)) for v in template["command"]]
    command[command.index("-autoboot_script") + 1] = str(script)
    command[command.index("-seconds_to_run") + 1] = "25" if args.late else "15"
    capture.mkdir(parents=True)
    record = {
        "worker_pid": os.getpid(), "started": time.time(), "command": command,
        "capture": str(capture), "frames_requested": fields,
        "punch_requested_first": punch_first, "punch_requested_last": punch_last - 1,
        "source_parent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": sha(source), "lua_sha256": sha(script),
        "mame_sha256": sha(Path(command[0])),
        "scope": "Real MAME CPUs and legal cabinet inputs; one punch and released tail; no RAM/PC writes; B03 termination is not qualified by capture integrity alone",
    }
    log = ROOT / "research" / (name + ".log")
    env = {**os.environ, "ALPHA_CAPTURE_DIR": str(capture),
           "ALPHA_CAPTURE_FRAMES": str(fields), "ALPHA_CAPTURE_MODE": "punch_release"}
    with log.open("w") as stream:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream,
                                 stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        record["mame_pid"] = child.pid
        job.write_text(json.dumps(record, indent=2) + "\n")
        code = child.wait()
    path = capture / "frame_states.csv"
    rows = list(csv.DictReader(path.open())) if path.exists() else []
    checks = {
        "mame_exit_zero": code == 0,
        "no_lua_error": "lua error" not in log.read_text().lower() and not (capture / "failure.txt").exists(),
        "complete_sequential_fields": [int(r["frame"]) for r in rows] == list(range(fields)),
        "one_actual_punch_pulse": [int(r["frame"]) for r in rows if int(r["in0"]) & 0x10] == list(range(punch_first + 1, punch_last + 1)),
        "actual_released_tail": len(rows) == fields and all(int(r["in0"]) == 0 and int(r["in2"]) == 3 for r in rows[punch_last + 1:]),
        "default_dips": bool(rows) and all(int(r["in1"]) == 142 for r in rows),
    }
    if args.late:
        rg = shutil.which("rg")
        assert rg, "Fast bounded event search required"
        found = subprocess.run([rg, "--max-count", "64", ",sound_latch_write,", str(capture / "events.csv")],
                               capture_output=True, text=True, check=True)
        events = list(csv.reader(found.stdout.splitlines()))
        record["main_sound_commands"] = [{"frame": int(r[0]), "data": int(r[4]), "mask": int(r[5])} for r in events]
        checks["actual_punch_command_35"] = any(
            punch_first < int(r[0]) <= punch_last + 30 and int(r[4]) == 0x3535 and int(r[5]) == 0xff00
            for r in events)
    record.update(exit_code=code, ended=time.time(), checks=checks, capture_integrity_pass=all(checks.values()),
                  ports_sha256=sha(path) if path.exists() else None,
                  bug_termination_pass=False)
    (ROOT / "research" / (name + "_exit.json")).write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"capture_integrity_pass": all(checks.values()), "checks": checks,
                      "fields": len(rows), "bug_termination_pass": False}))
    raise SystemExit(0 if all(checks.values()) else 2)


if __name__ == "__main__":
    main()
