"""Run the real Kyros RTL against the legal hard-DIP death reference in Ubuntu.

Invoke through WSL with /usr/bin/python3. The job refuses to overwrite a receipt.
No build, Quartus invocation, CPU substitution or game-memory patches occur.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_idle_death3601"
EXPECTED_ELF = "54529234af5aa50cb1d486d8f037a7dd8496b0da0f83e399b0cf8eb2094498cf"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    job = ROOT / "research" / (NAME + "_job.json")
    if job.exists():
        raise SystemExit("Existing job: inspect its terminal before restarting")
    reference = json.loads((ROOT / "research/kyros_idle_death7200_v2_exit.json").read_text())
    assert reference["reference_complete"] and reference["observed_dips"] == [206]
    build = ROOT / "sim/build"
    source_elf = build / "alpha68kn_system_sim"
    assert digest(source_elf) == EXPECTED_ELF, "Native executable changed; inspect before launch"
    executable = build / (NAME + "_sim")
    shutil.copy2(source_elf, executable)
    executable.chmod(0o755)
    ports = ROOT / "sim/captures/kyros/idle_death7200_v2/frame_states.csv"
    assert digest(ports) == reference["ports_sha256"]
    rom = ROOT / "roms/kyros/download.bin"
    output = ROOT / "sim/captures/rtl" / NAME
    if output.exists():
        raise SystemExit("Existing capture: inspect before restarting")
    command = [str(executable), str(rom), "3601", str(output), "gameplay", "--inputs", str(ports)]
    record = {
        "worker_pid": os.getpid(), "started": time.time(),
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "command": command, "frames": 3601, "executable_sha256": digest(executable),
        "rom_sha256": digest(rom), "ports_sha256": digest(ports),
        "rtl_manifest": "research/current_system720_curvefixed_inputs.sha256",
        "source_equivalence": "research/ym_curve_whitespace_equivalence.json",
        "reference": "research/kyros_idle_death7200_v2_exit.json",
        "scope": "Real RTL CPUs and recorded legal ports; no game-memory patches",
    }
    with (ROOT / "research" / (NAME + ".log")).open("w") as log:
        process = subprocess.Popen(command, cwd=build, stdout=log, stderr=subprocess.STDOUT)
        record["simulation_pid"] = process.pid
        job.write_text(json.dumps(record, indent=2) + "\n")
        result = process.wait()
    record.update(exit_code=result, ended=time.time())
    (ROOT / "research" / (NAME + "_exit.json")).write_text(json.dumps(record, indent=2) + "\n")
    raise SystemExit(result)


if __name__ == "__main__":
    main()
