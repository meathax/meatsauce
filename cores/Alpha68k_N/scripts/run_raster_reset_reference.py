"""Record the same real reset scenario with additional write/beam coordinates."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RECOVER_AUDIO = "--recover-audio" in sys.argv
ATTEMPT = 3 if "--attempt3" in sys.argv else (2 if "--attempt2" in sys.argv else 1)
CAPTURE_NAME = "reset_raster361" + ("_v" + str(ATTEMPT) if ATTEMPT > 1 else "")
NAME = "kyros_reset_audio_recovery960" if RECOVER_AUDIO else ("kyros_" + CAPTURE_NAME)
FRAMES = 960 if RECOVER_AUDIO else 361

def main():
    job = ROOT / "research" / (NAME + "_mame_job.json")
    capture = ROOT / "sim/captures/kyros" / ("reset_audio_recovery960" if RECOVER_AUDIO else CAPTURE_NAME)
    if job.exists() or capture.exists():
        raise SystemExit("Existing job/capture: inspect the same process before restarting")
    original = json.loads((ROOT / "research/kyros_warm_reset960_refv2_mame_job.json").read_text())
    base = ROOT / "sim/mame/capture_warm_reset.lua"
    base_hash = hashlib.sha256(base.read_bytes()).hexdigest()
    if base_hash != original["source_sha256"]:
        raise SystemExit("The original warm-reset recorder changed; refuse to assume equivalence")
    capture.mkdir(parents=True)
    # Add horizontal position inside the original functioning tap callback.
    # MAME0.289 has no hpos/vpos methods. Its existing beam helper returns Y,X.
    body = base.read_text()
    replacements = [
        ('local scan = beam()', 'local scan, horizontal = beam()'),
        ('events:write("frame,screen_frame,area,address,data,mask,vpos\\n")',
         'events:write("frame,screen_frame,area,address,data,mask,vpos,hpos\\n")'),
        ('events:write(string.format("%d,%d,%s,%d,%d,%d,%d\\n",',
         'events:write(string.format("%d,%d,%s,%d,%d,%d,%d,%d\\n",'),
        ('frame, screen:frame_number(), area, address, data, mask, scan))',
         'frame, screen:frame_number(), area, address, data, mask, scan, horizontal))')]
    for before, after in replacements:
        if body.count(before) != 1:
            raise SystemExit("Unexpected original event callback; refuse ambiguous replacement")
        body = body.replace(before, after)
    observer = capture / "loaded_recorder.lua"
    observer.write_text(body)
    command = list(original["command"])
    command[command.index("-autoboot_script") + 1] = str(base if RECOVER_AUDIO else observer)
    # Never reuse a prior recording's output paths when copying a launch recipe.
    for flag, filename in [("-wavwrite", "audio.wav"), ("-aviwrite", "video.avi"), ("-mngwrite", "video.mng")]:
        if flag in command:
            command[command.index(flag) + 1] = str(capture / filename)
    # The original native MAME invocation and real cabinet/reset scenario remain.
    environment = {**os.environ, "ALPHA_CAPTURE_DIR": str(capture),
                   "ALPHA_CAPTURE_FRAMES": str(FRAMES), "ALPHA_CAPTURE_MODE": "warm-reset",
                   "ALPHA_RASTER_BASE_SCRIPT": str(base)}
    record = {"worker_pid": os.getpid(), "started": time.time(), "frames": FRAMES,
              "command": command, "base_sha256": base_hash,
              "observer_sha256": hashlib.sha256(observer.read_bytes()).hexdigest(),
              "scope": "Fresh canonical reset/audio recovery" if RECOVER_AUDIO else "Additional read-only raster write tap; no CPU/RAM/input patches"}
    log = ROOT / "research" / (NAME + "_mame.log")
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=output,
                                   stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        record["mame_pid"] = process.pid
        job.write_text(json.dumps(record, indent=2) + "\n")
        result = process.wait()
    record.update(exit_code=result, ended=time.time(),
                  lua_errors="lua error" in log.read_text(errors="replace").lower()
                  or (capture / "failure.txt").exists())
    if not RECOVER_AUDIO:
        import csv
        with (capture / "events.csv").open() as events:
            rows = list(csv.DictReader(events))
        record["backdrop60_events"] = sum(x["frame"] == "60" and x["area"] == "background_watchdog" for x in rows)
        record["sprite_write_events"] = sum(0x040000 <= int(x["address"]) < 0x042000 for x in rows)
        record["raster_coverage_valid"] = record["backdrop60_events"] > 0 and record["sprite_write_events"] > 0
    (ROOT / "research" / (NAME + "_mame_exit.json")).write_text(json.dumps(record, indent=2) + "\n")

if __name__ == "__main__":
    main()
