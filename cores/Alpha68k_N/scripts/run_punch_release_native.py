"""Replay the single-punch oracle through the already qualified real CPU model."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_punch_release601_native"
REF = ROOT / "sim/captures/kyros/punch_release601"
OUT = ROOT / "sim/captures/rtl/kyros_punch_release601"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(suffix, record):
    (ROOT / "research" / (NAME + "_" + suffix + ".json")).write_text(json.dumps(record, indent=2) + "\n")


def main():
    global NAME, REF, OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--late", action="store_true", help="Replay the nonvacuous1081-field punch oracle")
    args = parser.parse_args()
    if args.late:
        NAME = "kyros_punch_release1081_native"
        REF = ROOT / "sim/captures/kyros/punch_release1081"
        OUT = ROOT / "sim/captures/rtl/kyros_punch_release1081"
    fields = 1081 if args.late else 601
    job = ROOT / "research" / (NAME + "_job.json")
    launcher = ROOT / "research" / (NAME + "_launcher.json")
    assert not job.exists(), "Follow existing job; never restart from observation timeout"
    oracle = json.loads((ROOT / "research" / (NAME.removesuffix("_native") + "_exit.json")).read_text())
    assert oracle["capture_integrity_pass"] and oracle["frames_requested"] == fields
    if args.late:
        assert oracle["checks"]["actual_punch_command_35"], "Do not run a vacuous action scenario"
    assert sha(REF / "frame_states.csv") == oracle["ports_sha256"]
    if os.name == "nt":
        assert not launcher.exists(), "Preserve existing launcher"
        from normalize_oracle_display import normalize
        normalize(REF)
        command = ["wsl.exe", "-d", "Ubuntu", "--cd", str(ROOT), "--exec", "/usr/bin/python3",
                   "scripts/run_punch_release_native.py", *sys.argv[1:]]
        with (ROOT / "research" / (NAME + "_worker.log")).open("w") as log:
            child = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
        save("launcher", {"started": time.time(), "wsl_pid": child.pid, "command": command})
        print(json.dumps({"wsl_pid": child.pid, "job": str(job)}))
        return
    baseline = json.loads((ROOT / "research/kyros_cocktail1801_v2_native_job.json").read_text())
    mismatches = [name for name, digest in baseline["source_pins"].items() if sha(ROOT / name) != digest]
    assert not mismatches, "Existing executable source pins differ: " + repr(mismatches)
    executable = ROOT / "sim/captures/rtl/kyros_combat_hud3301/alpha68kn_system_sim"
    assert sha(executable) == baseline["executable_sha256"]
    assert not OUT.exists(), "Preserve existing capture"
    OUT.mkdir(parents=True)
    command = [str(executable), str(ROOT / "roms/kyros/download.bin"), str(fields), str(OUT),
               "gameplay", "--inputs", str(REF / "frame_states.csv")]
    record = {"worker_pid": os.getpid(), "started": time.time(), "frames": fields,
              "source_parent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "source_pins": baseline["source_pins"], "executable_sha256": sha(executable),
              "input_sha256": sha(REF / "frame_states.csv"), "command": command,
              "runtime_rom_sha256": sha(ROOT / "roms/kyros/download.bin"),
              "runner_sha256": sha(Path(__file__)),
              "scope": "Actual combined RTL CPUs, same qualified executable and current source pins; legal one-punch input replay. No rebuild, synthetic behavior or sound termination waiver."}
    with (ROOT / "research" / (NAME + "_run.log")).open("w") as log:
        child = subprocess.Popen(command, cwd=ROOT / "sim/build", stdout=log, stderr=subprocess.STDOUT)
        record["simulation_pid"] = child.pid
        save("job", record)
        code = child.wait()
    terminal = dict(record, exit_code=code, ended=time.time())
    save("exit", terminal)
    if code:
        raise SystemExit(code)
    commands = [
        [sys.executable, "scripts/verify_long_gameplay_capture.py", str(REF), str(OUT),
         str(ROOT / "research" / (NAME + "_exit.json")), str(fields),
         str(ROOT / "research" / (NAME + "_verification.json"))],
        [sys.executable, "scripts/diagnose_sound_interleaving.py", str(REF), str(OUT), str(fields),
         "/mnt/d/Arcade/AI/mame289/src/mame/alpha/alpha68k_n.cpp",
         str(ROOT / "research" / (NAME + "_sound_interleaving.json"))],
    ]
    for index, command in enumerate(commands):
        with (ROOT / "research" / (NAME + f"_check{index}.log")).open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        save(f"check{index}_exit", {"command": command, "exit_code": result.returncode,
                                    "scope": "No image mismatch masks or sound-effect acceptance inferred from register matching alone"})


if __name__ == "__main__":
    main()
