"""Replay the observed combat scenario through actual RTL with read-only DAC tracing."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_combat3600"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    job = ROOT / "research" / (NAME + "_native_job.json")
    output = ROOT / "sim/captures/rtl" / NAME
    if job.exists() or output.exists():
        raise SystemExit("Existing job/capture: inspect before restarting")
    reference_path = ROOT / "research/kyros_combat3600_v2_exit.json"
    reference = json.loads(reference_path.read_text())
    assert reference["reference_complete"] and reference["observed_dips"] == [142]
    recovery = json.loads((ROOT / "research/kyros_warm_reset960_build_recovery.json").read_text())
    prepared = ROOT / recovery["executable"]
    assert digest(prepared) == recovery["executable_sha256"]
    assert digest(ROOT / recovery["manifest"]) == recovery["manifest_sha256"]
    executable = ROOT / "sim/build" / (NAME + "_sim")
    shutil.copy2(prepared, executable)
    executable.chmod(0o755)
    ports = ROOT / "sim/captures/kyros/combat3600_v2/frame_states.csv"
    assert digest(ports) == reference["ports_sha256"]
    rom = ROOT / "roms/kyros/download.bin"
    command = [str(executable), str(rom), "3600", str(output), "gameplay", "dac-probe", "--inputs", str(ports)]
    record = {
        "worker_pid": os.getpid(), "started": time.time(), "command": command, "frames": 3600,
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "executable_sha256": digest(executable), "ports_sha256": digest(ports), "rom_sha256": digest(rom),
        "rtl_manifest": recovery["manifest"], "reference": str(reference_path.relative_to(ROOT)),
        "scope": "Real RTL CPUs/graphics/audio; read-only DAC bus/PCM tracing; no game memory patches or reset injection",
    }
    with (ROOT / "research" / (NAME + "_native.log")).open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT / "sim/build", stdout=stream, stderr=subprocess.STDOUT)
        record["simulation_pid"] = process.pid
        job.write_text(json.dumps(record, indent=2) + "\n")
        result = process.wait()
    record.update(exit_code=result, ended=time.time())
    (ROOT / "research" / (NAME + "_native_exit.json")).write_text(json.dumps(record, indent=2) + "\n")
    raise SystemExit(result)


if __name__ == "__main__":
    main()
