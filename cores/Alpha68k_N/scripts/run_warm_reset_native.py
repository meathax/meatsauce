"""Ubuntu worker: build and run actual Kyros RTL with a real warm-reset pulse."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = "kyros_warm_reset960"
REUSE = "--reuse-prepared" in sys.argv
NAME = BASE + "_v2" if REUSE else BASE


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    job = ROOT / "research" / (NAME + "_native_job.json")
    if job.exists():
        raise SystemExit("Existing native job: inspect before restarting")
    record = {"worker_pid": os.getpid(), "started": time.time(), "frames": 960, "reset_after_field": 300,
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "harness_sha256": digest(ROOT / "sim/system_main.cpp"),
              "scope": "Real RTL CPUs/chips; game reset only, ROM/SDRAM retained; no Quartus"}
    job.write_text(json.dumps(record, indent=2) + "\n")
    if REUSE:
        recovery = json.loads((ROOT / "research" / (BASE + "_build_recovery.json")).read_text())
        assert digest(ROOT / "sim/system_main.cpp") == recovery["harness_sha256"]
        assert digest(ROOT / recovery["executable"]) == recovery["executable_sha256"]
        assert digest(ROOT / recovery["manifest"]) == recovery["manifest_sha256"]
        record["reused_build"] = BASE + "_build_recovery.json"
        prepared_elf = ROOT / recovery["executable"]
        prepared_manifest = ROOT / recovery["manifest"]
    else:
        with (ROOT / "research" / (NAME + "_build.log")).open("w") as stream:
            result = subprocess.run(["/usr/bin/bash", "sim/build_system.sh"], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                    env={**os.environ, "ALPHA_BUILD_TMP": "/mnt/d/vibes/fpga/temp"}).returncode
        (ROOT / "research" / (NAME + "_build_exit.json")).write_text(json.dumps({"exit_code": result, "ended": time.time()}, indent=2) + "\n")
        if result:
            raise SystemExit(result)
        prepared_elf = ROOT / "sim/build/alpha68kn_system_sim"
        prepared_manifest = ROOT / "sim/build/system_inputs.sha256"
    reference_name = BASE + ("_refv2_mame_exit.json" if REUSE else "_mame_exit.json")
    reference = json.loads((ROOT / "research" / reference_name).read_text())
    if not reference["reference_complete"]:
        raise SystemExit("MAME reset reference incomplete; native run not launched")
    executable = ROOT / "sim/build" / (NAME + "_sim")
    shutil.copy2(prepared_elf, executable)
    executable.chmod(0o755)
    manifest = ROOT / "research" / (NAME + "_inputs.sha256")
    shutil.copy2(prepared_manifest, manifest)
    ports = ROOT / "sim/captures/kyros" / ("warm_reset960_refv2" if REUSE else "warm_reset960") / "frame_states.csv"
    assert digest(ports) == reference["ports_sha256"]
    rom = ROOT / "roms/kyros/download.bin"
    output = ROOT / "sim/captures/rtl" / NAME
    if output.exists():
        raise SystemExit("Existing native capture: inspect before restarting")
    command = [str(executable), str(rom), "960", str(output), "gameplay", "--inputs", str(ports), "--warm-reset-after", "300"]
    record.update(command=command, executable_sha256=digest(executable), ports_sha256=digest(ports),
                  rom_sha256=digest(rom), rtl_manifest=str(manifest.relative_to(ROOT)), reference=reference_name)
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
