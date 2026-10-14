"""Owned private build/run for actual CPU-earned HPS save/reset/restore."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_earned_wrapper901_v2"


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def save(suffix,value):
    (ROOT / "research" / (NAME+suffix+".json")).write_text(json.dumps(value,indent=2)+"\n",encoding="utf-8")


def main():
    job = ROOT / "research" / (NAME+"_job.json")
    launcher = ROOT / "research" / (NAME+"_launcher.json")
    if os.name == "nt":
        if launcher.exists() or job.exists():
            raise SystemExit("Existing owned job: follow its actual process/terminal")
        command = ["wsl.exe","-d","Ubuntu","--cd",str(ROOT),"--exec","/usr/bin/python3","scripts/run_earned_wrapper.py"]
        with (ROOT / "research" / (NAME+"_worker.log")).open("w",encoding="utf-8") as log:
            child = subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
        save("_launcher",{"started":time.time(),"wsl_pid":child.pid,"command":command})
        print(json.dumps({"wsl_pid":child.pid,"job":str(job)}))
        return
    assert str(ROOT).startswith("/mnt/d/")
    if job.exists():
        raise SystemExit("Existing job: never restart on observation timeout")
    source = json.loads((ROOT / "research/kyros_earned_wrapper_source.json").read_text())
    for key in ("host","builder"):
        assert sha(ROOT / source["derived_"+key]) == source["derived_"+key+"_sha256"]
    ports = ROOT / "sim/captures/kyros/combat3600_v2/frame_states.csv"
    combat = json.loads((ROOT / "research/kyros_combat_hud3301_job.json").read_text())
    assert sha(ports) == combat["input_sha256"]
    out = ROOT / "sim/captures/rtl" / NAME
    if out.exists():
        raise SystemExit("Existing capture: preserve it")
    out.mkdir(parents=True)
    record = {"worker_pid":os.getpid(),"started":time.time(),
              "source_parent":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
              "runner_sha256":sha(Path(__file__)),"source":source,"ports_sha256":sha(ports),
              "scope":"Current real wrapper gameplay, actual CPU-earned score, real HPS donor upload, actual reset-cleared score and real HPS restore; no synthetic RAM writes; not a full-game/hardware qualification"}
    command = ["bash",str(ROOT / source["derived_builder"])]
    env = dict(os.environ,ALPHA68KN_BUILD_ROOT="/mnt/d/vibes/fpga/temp")
    with (ROOT / "research" / (NAME+"_build.log")).open("w") as log:
        build = subprocess.Popen(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
        record.update(build_pid=build.pid,build_command=command)
        save("_job",record)
        code = build.wait()
    save("_build_exit",dict(record,exit_code=code,ended=time.time()))
    if code:
        raise SystemExit(code)
    manifest = ROOT / "sim/build/earned_wrapper_inputs.sha256"
    for line in manifest.read_text().splitlines():
        expected,name = line.split(None,1)
        assert sha(ROOT / name.lstrip("*")) == expected, name
    executable = out / "alpha68kn_wrapper_earned_sim"
    shutil.copy2(ROOT / "sim/build/alpha68kn_wrapper_earned_sim",executable)
    assert executable.read_bytes()[:4] == b"\x7fELF"
    record.update(executable_sha256=sha(executable),manifest_sha256=sha(manifest),
                  rom_sha256=sha(ROOT / "roms/kyros/download.bin"),
                  hiscore_config_sha256=sha(ROOT / "roms/kyros/hiscore_config.bin"))
    command = [str(executable),str(ROOT / "roms/kyros/download.bin"),"901",str(out),"--earned-score",str(ports)]
    with (ROOT / "research" / (NAME+"_run.log")).open("w") as log:
        child = subprocess.Popen(command,cwd=ROOT / "sim/build",stdout=log,stderr=subprocess.STDOUT)
        record.update(simulation_pid=child.pid,command=command,run_started=time.time())
        save("_job",record)
        code = child.wait()
    save("_exit",dict(record,exit_code=code,ended=time.time()))
    raise SystemExit(code)


if __name__ == "__main__":
    main()
