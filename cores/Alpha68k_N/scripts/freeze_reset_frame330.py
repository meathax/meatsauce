"""Reproduce the first saved reset difference and freeze real RTL RAM at field 330.

Diagnostic only: reuse the actual RTL executable, preserve legal inputs,
stop after 331 fields, and let its existing end-of-run dump read retained RAM.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_reset_freeze330"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    job = ROOT / "research" / (NAME + "_job.json")
    capture = ROOT / "sim/captures/rtl" / NAME
    if job.exists() or capture.exists():
        raise SystemExit("Existing diagnostic: inspect before restarting")
    recovery = json.loads((ROOT / "research/kyros_warm_reset960_build_recovery.json").read_text())
    reference = json.loads((ROOT / "research/kyros_warm_reset960_refv2_mame_exit.json").read_text())
    assert reference["reference_complete"]
    prepared = ROOT / recovery["executable"]
    assert digest(prepared) == recovery["executable_sha256"]
    assert digest(ROOT / recovery["manifest"]) == recovery["manifest_sha256"]
    executable = ROOT / "sim/build" / (NAME + "_sim")
    shutil.copy2(prepared, executable)
    executable.chmod(0o755)
    ports = ROOT / "sim/captures/kyros/warm_reset960_refv2/frame_states.csv"
    assert digest(ports) == reference["ports_sha256"]
    rom = ROOT / "roms/kyros/download.bin"
    command = [str(executable), str(rom), "331", str(capture), "gameplay", "--inputs", str(ports), "--warm-reset-after", "300"]
    record = {
        "worker_pid": os.getpid(), "started": time.time(), "command": command,
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "executable_sha256": digest(executable), "ports_sha256": digest(ports), "rom_sha256": digest(rom),
        "rtl_manifest": recovery["manifest"], "frames": 331,
        "scope": "Actual CPU/renderer reset reproduction and retained RAM dump; diagnosis, no fidelity pass",
    }
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
