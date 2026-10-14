"""Windows worker: record actual MAME reset/restart with the derived Lua script."""
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
NAME = "kyros_warm_reset960_refv2" if SECOND else "kyros_warm_reset960"


def main():
    job = ROOT / "research" / (NAME + "_mame_job.json")
    capture = ROOT / "sim/captures/kyros" / ("warm_reset960_refv2" if SECOND else "warm_reset960")
    if job.exists() or capture.exists():
        raise SystemExit("Existing job/capture: inspect before restarting")
    subprocess.run(["python", "-X", "utf8", str(ROOT / "scripts/make_warm_reset_capture.py")], check=True)
    template = json.loads((ROOT / "research/kyros_idle_death7200_v2_job.json").read_text())
    old_capture = template["capture"]
    command = [item.replace(old_capture, str(capture)) for item in template["command"]]
    command[command.index("-autoboot_script") + 1] = str(ROOT / "sim/mame/capture_warm_reset.lua")
    command[command.index("-seconds_to_run") + 1] = "20"
    capture.mkdir(parents=True)
    env = {**os.environ, "ALPHA_CAPTURE_DIR": str(capture), "ALPHA_CAPTURE_FRAMES": "960", "ALPHA_CAPTURE_MODE": "warm-reset"}
    record = {
        "worker_pid": os.getpid(), "started": time.time(), "command": command,
        "capture": str(capture), "frames_requested": 960, "reset_after_field": 300,
        "scope": "Real MAME CPUs and legal controls; software reset, no RAM/register patches",
        "mame_sha256": hashlib.sha256(Path(command[0]).read_bytes()).hexdigest(),
        "source_sha256": hashlib.sha256((ROOT / "sim/mame/capture_warm_reset.lua").read_bytes()).hexdigest(),
    }
    log = ROOT / "research" / (NAME + "_mame.log")
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        record["mame_pid"] = process.pid
        job.write_text(json.dumps(record, indent=2) + "\n")
        result = process.wait()
    rows, resets = [], []
    if (capture / "frame_states.csv").exists():
        with (capture / "frame_states.csv").open() as stream:
            rows = list(csv.DictReader(stream))
    if (capture / "reset_events.csv").exists():
        with (capture / "reset_events.csv").open() as stream:
            resets = list(csv.DictReader(stream))
    error = "lua error" in log.read_text().lower() or (capture / "failure.txt").exists()
    complete = result == 0 and not error and len(rows) == 960 and [int(x["frame"]) for x in resets] == [300, 301]
    record.update(exit_code=result, ended=time.time(), lua_error=error, state_rows=len(rows), reset_events=resets,
                  reference_complete=complete)
    if rows:
        record["ports_sha256"] = hashlib.sha256((capture / "frame_states.csv").read_bytes()).hexdigest()
    (ROOT / "research" / (NAME + "_mame_exit.json")).write_text(json.dumps(record, indent=2) + "\n")
    raise SystemExit(0 if complete else 2)


if __name__ == "__main__":
    main()
