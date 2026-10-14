"""Reuse qualified combined RTL for legal two-player/cocktail CPU execution.

Windows launches a detached Ubuntu worker. Linux ELF is executed only there.
No build, state injection, Quartus or modified RTL is involved.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_cocktail1801_v2"
EXPECTED_ELF = "864ebb2c2e73ca7f743238e4eaf26dd7acd8b5bbaf6845a4a8795b71d203fffa"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(name, value):
    (ROOT / "research" / name).write_text(json.dumps(value, indent=2)+"\n", encoding="utf-8")


def main():
    launcher = ROOT / "research" / (NAME+"_native_launcher.json")
    job = ROOT / "research" / (NAME+"_native_job.json")
    if os.name == "nt":
        if launcher.exists() or job.exists():
            raise SystemExit("Existing native launch: inspect its actual process/terminal")
        oracle = json.loads((ROOT / "research" / (NAME+"_oracle_verification.json")).read_text())
        assert oracle["passed"]
        command = ["wsl.exe", "-d", "Ubuntu", "--cd", str(ROOT), "--exec",
                   "/usr/bin/python3", "scripts/run_cocktail_native.py"]
        with (ROOT / "research" / (NAME+"_native_worker.log")).open("w", encoding="utf-8") as log:
            child = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
        save(NAME+"_native_launcher.json", {"started":time.time(), "wsl_pid":child.pid,
                                          "command":command, "scope":"Owned Ubuntu simulation worker; inspect native job/exit, do not relaunch on polling errors"})
        print(json.dumps({"launched_wsl_pid":child.pid,"job":str(job)}))
        return
    assert str(ROOT).startswith("/mnt/d/"), "Explicit Ubuntu WSL environment required"
    if job.exists():
        raise SystemExit("Existing native job: inspect terminal before restarting")
    oracle_path = ROOT / "research" / (NAME+"_oracle_verification.json")
    oracle = json.loads(oracle_path.read_text())
    assert oracle["passed"] and oracle["frames"] == 1801 and oracle["scenario"]["dips"] == 70
    prior = json.loads((ROOT / "research/kyros_combat_hud3301_verification.json").read_text())
    assert prior["passed"] and prior["executable_sha256"] == EXPECTED_ELF
    executable = ROOT / "sim/captures/rtl/kyros_combat_hud3301/alpha68kn_system_sim"
    assert executable.read_bytes()[:4] == b"\x7fELF" and sha(executable) == EXPECTED_ELF
    manifest = ROOT / "research/kyros_combat_hud3301_inputs.sha256"
    pins = {}
    for line in manifest.read_text().splitlines():
        expected, relative = line.split(None,1)
        relative = relative.lstrip("*")
        assert sha(ROOT / relative) == expected, "Source changed: "+relative
        pins[relative] = expected
    ports = ROOT / "sim/captures/kyros/cocktail1801_v2/frame_states.csv"
    assert sha(ports) == oracle["ports_sha256"]
    rom = ROOT / "roms/kyros/download.bin"
    assert sha(rom) == oracle["rom_sha256"]
    runtime = json.loads((ROOT / "research/kyros_combat_hud3301_job.json").read_text())["runtime_rom_sha256"]
    for name, expected in runtime.items():
        assert sha(ROOT / "sim/build" / name) == expected
    out = ROOT / "sim/captures/rtl" / NAME
    if out.exists():
        raise SystemExit("Existing output: preserve simulation evidence")
    out.mkdir(parents=True)
    command = [str(executable),str(rom),"1801",str(out),"gameplay","dac-probe","--inputs",str(ports)]
    record = {"worker_pid":os.getpid(),"started":time.time(),"command":command,
              "frames":1801,"source_parent":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
              "runner_sha256":sha(Path(__file__)),"executable_sha256":sha(executable),
              "source_manifest":str(manifest.relative_to(ROOT)),"source_manifest_sha256":sha(manifest),
              "source_pins":pins,"runtime_rom_sha256":runtime,"rom_sha256":sha(rom),
              "ports_sha256":sha(ports),"oracle_verification_sha256":sha(oracle_path),
              "scope":"Actual combined RTL CPUs, ROM download, sound and SDRAM/video with legal recorded DIPs/ports; no RAM/register/PC fixtures"}
    with (ROOT / "research" / (NAME+"_native.log")).open("w") as log:
        child = subprocess.Popen(command,cwd=ROOT / "sim/build",stdout=log,stderr=subprocess.STDOUT)
        record["simulation_pid"] = child.pid
        save(NAME+"_native_job.json",record)
        code = child.wait()
    record.update(exit_code=code,ended=time.time())
    save(NAME+"_native_exit.json",record)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
