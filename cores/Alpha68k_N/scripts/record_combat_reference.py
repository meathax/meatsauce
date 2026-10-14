"""Record legal Kyros forward/punch/jump inputs through the real MAME CPUs.

The input sequence starts at field 260, after the field-240 castle sketch. Captures
must establish actual hit/pickup outcomes before any coverage claim is made.
"""
from pathlib import Path
import csv
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SECOND = "--attempt2" in sys.argv
NAME = "kyros_combat3600_v2" if SECOND else "kyros_combat3600"


def derive():
    source = ROOT / "sim/mame/capture.lua"
    text = source.read_text()
    start = text.index("local function drive_inputs()")
    end = text.index("local function dump(name, bytes)", start)
    text = text[:start] + '''local last_combat_controls = 0
local function drive_inputs()
    if mode ~= "combat" then return end
    if frame == 120 then set_input("IN2",1,true) end
    if frame == 126 then set_input("IN2",1,false) end
    local desired = frame >= 160 and frame < 166 and 0x80 or 0
    if frame >= 260 then
        local phase = (frame-260)%600
        desired = phase < 360 and 1 or (phase < 420 and 4 or (phase < 540 and 1 or 8))
        if (frame-260)%18 < 14 then desired = desired | 0x10 end
        if frame >= 480 and (frame-480)%180 < 4 then desired = desired | 0x20 end
    end
    for _,mask in ipairs({1,2,4,8,0x10,0x20,0x80}) do
        if (desired & mask) ~= (last_combat_controls & mask) then
            set_input("IN0",mask,(desired & mask) ~= 0)
        end
    end
    last_combat_controls = desired
end

''' + text[end:]
    assert text.count("local function dump(name, bytes)") == 1
    anchor = 'if frame < 260 or (frame >= 590 and frame < 610) or (frame >= 1190 and frame < 1210) then'
    assert text.count(anchor) == 1
    text = text.replace(anchor, 'if true then -- complete finite sound observations')
    anchor = 'if sample_frames[frame] or frame == total-1 then snapshot() end'
    assert text.count(anchor) == 1
    text = text.replace(anchor, 'if sample_frames[frame] or frame%60 == 0 or frame == total-1 then snapshot() end')
    script = ROOT / "sim/mame/capture_combat.lua"
    script.write_text(text)
    metadata = {
        "canonical_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "derived_sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
        "scope": "Legal cabinet inputs only; real MAME CPUs; no game RAM/register patches",
        "controls": {"up": 1, "down": 2, "right": 4, "left": 8, "punch": 16, "jump": 32, "start": 128},
        "input_source": "mame289/src/mame/alpha/alpha68k_n.cpp ALPHA68K_PLAYER_INPUT_SWAP_LR_LSB",
        "active_input_start_field": 260, "fields": 3600,
    }
    (ROOT / "research/kyros_combat_source.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return script, metadata


def main():
    job = ROOT / "research" / (NAME + "_job.json")
    capture = ROOT / "sim/captures/kyros" / ("combat3600_v2" if SECOND else "combat3600")
    if job.exists() or capture.exists():
        raise SystemExit("Existing job/capture: inspect before restarting")
    script, metadata = derive()
    template = json.loads((ROOT / "research/kyros_idle_death7200_v2_job.json").read_text())
    command = [item.replace(template["capture"], str(capture)) for item in template["command"]]
    command[command.index("-autoboot_script") + 1] = str(script)
    command[command.index("-seconds_to_run") + 1] = "65"
    capture.mkdir(parents=True)
    env = {**os.environ, "ALPHA_CAPTURE_DIR": str(capture), "ALPHA_CAPTURE_FRAMES": "3600", "ALPHA_CAPTURE_MODE": "combat"}
    record = {"worker_pid": os.getpid(), "started": time.time(), "command": command,
              "capture": str(capture), "frames_requested": 3600, "source": metadata,
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "mame_sha256": hashlib.sha256(Path(command[0]).read_bytes()).hexdigest()}
    log = ROOT / "research" / (NAME + ".log")
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        record["mame_pid"] = process.pid
        job.write_text(json.dumps(record, indent=2) + "\n")
        result = process.wait()
    rows = []
    if (capture / "frame_states.csv").exists():
        with (capture / "frame_states.csv").open() as stream:
            rows = list(csv.DictReader(stream))
    error = "lua error" in log.read_text().lower() or (capture / "failure.txt").exists()
    complete = result == 0 and not error and [int(x["frame"]) for x in rows] == list(range(3600))
    record.update(exit_code=result, ended=time.time(), lua_error=error, state_rows=len(rows), reference_complete=complete)
    if rows:
        record["ports_sha256"] = hashlib.sha256((capture / "frame_states.csv").read_bytes()).hexdigest()
        record["observed_dips"] = sorted(set(int(x["in1"]) for x in rows))
    (ROOT / "research" / (NAME + "_exit.json")).write_text(json.dumps(record, indent=2) + "\n")
    raise SystemExit(0 if complete else 2)


if __name__ == "__main__":
    main()
