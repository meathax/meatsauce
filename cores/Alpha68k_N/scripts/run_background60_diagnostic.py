"""Actual CPU field60 write/pixel diagnosis; reuse the real reset reference input."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_background60_diagnostic"

def save(suffix, value):
    (ROOT / "research" / (NAME + suffix + ".json")).write_text(json.dumps(value, indent=2) + "\n")

def main():
    record = {"worker_pid": os.getpid(), "started": time.time(), "frames": 61,
              "scope": "Actual CPU backdrop-write diagnosis; not a broad graphics pass",
              "source_parent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    save("_job", record)
    with (ROOT / "research" / (NAME + "_build.log")).open("w") as log:
        result = subprocess.run(["/usr/bin/bash", "sim/build_system.sh"], cwd=ROOT,
                                stdout=log, stderr=subprocess.STDOUT,
                                env={**os.environ, "ALPHA_BUILD_TMP": "/mnt/d/vibes/fpga/temp"}).returncode
    save("_build_exit", {"exit_code": result, "ended": time.time()})
    if result:
        return
    executable = ROOT / "sim/build/kyros_background60_diagnostic_sim"
    shutil.copyfile(ROOT / "sim/build/alpha68kn_system_sim", executable)
    executable.chmod(0o755)
    shutil.copyfile(ROOT / "sim/build/system_inputs.sha256",
                    ROOT / "research/kyros_background60_diagnostic_inputs.sha256")
    record["executable_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
    record["input_trace_sha256"] = hashlib.sha256((ROOT / "sim/captures/kyros/warm_reset960_refv2/frame_states.csv").read_bytes()).hexdigest()
    record["rom_sha256"] = hashlib.sha256((ROOT / "roms/kyros/download.bin").read_bytes()).hexdigest()
    output = ROOT / "sim/captures/rtl/kyros_background60_diagnostic"
    command = [str(executable), str(ROOT / "roms/kyros/download.bin"), "61", str(output),
               "gameplay", "--inputs", str(ROOT / "sim/captures/kyros/warm_reset960_refv2/frame_states.csv")]
    record["command"] = command
    with (ROOT / "research" / (NAME + "_native.log")).open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        record["simulation_pid"] = process.pid
        save("_job", record)
        result = process.wait()
    record.update(exit_code=result, ended=time.time())
    save("_exit", record)

if __name__ == "__main__":
    main()
