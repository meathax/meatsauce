"""Build the retained-BGC fix and replay the actual reset with live RAM observation."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_reset_background421"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    job = ROOT / "research" / (NAME + "_job.json")
    if job.exists():
        raise SystemExit("Existing job: inspect before restarting")
    record = {
        "worker_pid": os.getpid(), "started": time.time(), "frames": 421, "reset_after_field": 300,
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "board_sha256": digest(ROOT / "rtl/alpha68kn_board.sv"), "harness_sha256": digest(ROOT / "sim/system_main.cpp"),
        "scope": "Actual RTL CPUs/rendering with retained background RAM; read-only live RAM snapshots; no Quartus",
    }
    job.write_text(json.dumps(record, indent=2) + "\n")
    with (ROOT / "research" / (NAME + "_build.log")).open("w") as stream:
        result = subprocess.run(["/usr/bin/bash", "sim/build_system.sh"], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                env={**os.environ, "ALPHA_BUILD_TMP": "/mnt/d/vibes/fpga/temp"}).returncode
    (ROOT / "research" / (NAME + "_build_exit.json")).write_text(json.dumps({"exit_code": result, "ended": time.time()}, indent=2) + "\n")
    if result:
        raise SystemExit(result)
    reference = json.loads((ROOT / "research/kyros_warm_reset960_refv2_mame_exit.json").read_text())
    assert reference["reference_complete"]
    ports = ROOT / "sim/captures/kyros/warm_reset960_refv2/frame_states.csv"
    assert digest(ports) == reference["ports_sha256"]
    executable = ROOT / "sim/build" / (NAME + "_sim")
    shutil.copy2(ROOT / "sim/build/alpha68kn_system_sim", executable)
    executable.chmod(0o755)
    manifest = ROOT / "research" / (NAME + "_inputs.sha256")
    shutil.copy2(ROOT / "sim/build/system_inputs.sha256", manifest)
    rom = ROOT / "roms/kyros/download.bin"
    capture = ROOT / "sim/captures/rtl" / NAME
    if capture.exists():
        raise SystemExit("Existing capture: inspect before restarting")
    command = [str(executable), str(rom), "421", str(capture), "gameplay", "--inputs", str(ports), "--warm-reset-after", "300"]
    record.update(command=command, executable_sha256=digest(executable), ports_sha256=digest(ports),
                  rom_sha256=digest(rom), rtl_manifest=str(manifest.relative_to(ROOT)))
    with (ROOT / "research" / (NAME + ".log")).open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT / "sim/build", stdout=stream, stderr=subprocess.STDOUT)
        record["simulation_pid"] = process.pid
        job.write_text(json.dumps(record, indent=2) + "\n")
        result = process.wait()
    record.update(exit_code=result, ended=time.time())
    (ROOT / "research" / (NAME + "_exit.json")).write_text(json.dumps(record, indent=2) + "\n")
    raise SystemExit(result)


if __name__ == "__main__":
    main()
