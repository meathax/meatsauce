"""A/B only host compiler optimization, reusing the identical real RTL archive."""
from pathlib import Path
import csv
import hashlib
import json
import os
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_wrapper_host_O3_bench62_v2"
OUT = ROOT / "sim/captures/diagnostics" / NAME


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(suffix, value):
    (ROOT / "research" / (NAME+suffix+".json")).write_text(json.dumps(value,indent=2)+"\n")


def main():
    jobfile = ROOT / "research" / (NAME+"_job.json")
    if os.name == "nt":
        launcher = ROOT / "research" / (NAME+"_launcher.json")
        if launcher.exists() or jobfile.exists():
            raise SystemExit("Existing benchmark: follow the actual owned handles")
        command = ["wsl.exe","-d","Ubuntu","--cd",str(ROOT),"--exec","/usr/bin/python3","scripts/benchmark_wrapper_host.py"]
        with (ROOT / "research" / (NAME+"_worker.log")).open("w") as log:
            child = subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
        save("_launcher",{"started":time.time(),"wsl_pid":child.pid,"command":command})
        print(json.dumps({"wsl_pid":child.pid,"job":str(jobfile)}))
        return
    if jobfile.exists() or OUT.exists():
        raise SystemExit("Existing benchmark source/output: preserve it")
    accepted = json.loads((ROOT / "research/kyros_earned_wrapper901_v3_job.json").read_text())
    build = json.loads((ROOT / "research/kyros_earned_wrapper901_v3_build_exit.json").read_text())
    assert build["exit_code"] == 0
    original = ROOT / "sim/captures/rtl/kyros_earned_wrapper901_v3/alpha68kn_wrapper_earned_v3_sim"
    assert sha(original) == accepted["executable_sha256"]
    manifest = ROOT / "sim/build/earned_wrapper_v3_inputs.sha256"
    assert sha(manifest) == accepted["manifest_sha256"]
    for line in manifest.read_text().splitlines():
        digest, filename = line.split(None,1)
        assert sha(ROOT / filename.lstrip("*")) == digest
    snapshot = Path((ROOT / "sim/build/earned_wrapper_v3_build_dir.txt").read_text().strip())
    obj = snapshot / "obj"
    source = snapshot / "wrapper_main.cpp"
    assert sha(source) == accepted["source"]["derived_host_sha256"]
    commands = [shlex.split(line) for line in (ROOT / "research/kyros_earned_wrapper901_v3_build.log").read_text().splitlines() if line.startswith(("g++ ", "ccache g++ "))]
    # ccache is a known compiler wrapper, not part of the C++ flags or source.
    commands = [a[1:] if a[0] == "ccache" else a for a in commands]
    compile_command = next(a for a in commands if "-c" in a and str(source) in a)
    link_command = next(a for a in commands if "-c" not in a and "-o" in a and a[a.index("-o")+1] == "alpha68kn_wrapper_sim")
    assert [a for a in compile_command if a.startswith("-O")][-1] == "-Os"
    OUT.mkdir(parents=True)
    optimized = OUT / "alpha68kn_wrapper_host_O3_sim"
    hostobj = OUT / "wrapper_host_O3.o"
    candidate_compile = ["-O3" if a == "-Os" else a for a in compile_command if a not in ("-MMD","-MP")]
    candidate_compile[candidate_compile.index("-o")+1] = str(hostobj)
    candidate_link = [str(hostobj) if a == "wrapper_main.o" else a for a in link_command]
    candidate_link[candidate_link.index("-o")+1] = str(optimized)
    # Only the host and new output are written. Original objects/archive/ELF stay intact.
    objects = [obj / a for a in link_command if a.endswith((".o",".a")) and a != "wrapper_main.o"]
    object_pins = {str(p):sha(p) for p in objects}
    record = {"started":time.time(),"worker_pid":os.getpid(),
              "source_parent":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
              "original_elf_sha256":sha(original),"host_sha256":sha(source),
              "manifest_sha256":sha(manifest),"unchanged_model_object_pins":object_pins,
              "original_host_compile":compile_command,"optimized_host_compile":candidate_compile,
              "optimized_link":candidate_link,"runner_sha256":sha(Path(__file__)),
              "scope":"Unchanged real CPU/board/framework RTL and host source. Only host -Os becomes -O3. Two actual normal HPS/ROM boot62 replays; no score/game-state injection, no whole-game or hardware qualification."}
    save("_job",record)
    def run_stage(stage, command, cwd):
        started=time.time()
        with (ROOT / "research" / (NAME+"_"+stage+".log")).open("w") as log:
            child=subprocess.Popen(command,cwd=cwd,stdout=log,stderr=subprocess.STDOUT)
            record.update(active_stage=stage,active_pid=child.pid,active_command=command)
            save("_job",record)
            code=child.wait()
        result={"stage":stage,"pid":child.pid,"exit_code":code,"wall_seconds":time.time()-started,"command":command}
        save("_"+stage+"_exit",result)
        if code:
            save("_exit",dict(record,exit_code=code,ended=time.time(),failed_stage=stage))
            raise SystemExit(code)
        return result
    run_stage("compile",candidate_compile,obj)
    run_stage("link",candidate_link,obj)
    assert all(sha(Path(p)) == digest for p,digest in object_pins.items())
    assert sha(original) == record["original_elf_sha256"]
    record["optimized_elf_sha256"]=sha(optimized)
    payload=ROOT / "roms/kyros/download.bin"
    baseline=run_stage("baseline",[str(original),str(payload),"62",str(OUT / "baseline")],ROOT / "sim/build")
    candidate=run_stage("optimized",[str(optimized),str(payload),"62",str(OUT / "optimized")],ROOT / "sim/build")
    def metrics(directory):
        with (directory / "frames.csv").open(newline="") as stream:
            return list(csv.DictReader(stream))
    left,right=metrics(OUT / "baseline"),metrics(OUT / "optimized")
    images=[]
    for reference in sorted((OUT / "baseline").glob("frame_*.rgb")):
        actual=OUT / "optimized" / reference.name
        images.append({"name":reference.name,"baseline_sha256":sha(reference),
                       "optimized_sha256":sha(actual) if actual.exists() else None,
                       "bytes":reference.stat().st_size,"exact":actual.exists() and reference.read_bytes() == actual.read_bytes()})
    checks={"both_exit_zero":baseline["exit_code"] == candidate["exit_code"] == 0,
            "all62_metric_rows_exact":left == right and [int(r["frame"]) for r in left] == list(range(62)),
            "full_core_coverage":all(int(r["core_pixels"]) == 57344 and int(r["duplicates"]) == 0 for r in left),
            "no_unmapped_or_renderer_failure":all(all(int(r[k]) == 0 for k in ("unmapped","deadlines","overflows")) for r in left),
            "all_captured_rgb_exact":bool(images) and all(i["exact"] for i in images),
            "model_objects_unchanged":all(sha(Path(p)) == digest for p,digest in object_pins.items())}
    result={"scope":record["scope"],"checks":checks,"finite_prefix_pass":all(checks.values()),
            "baseline_wall_seconds":baseline["wall_seconds"],"optimized_wall_seconds":candidate["wall_seconds"],
            "speedup":baseline["wall_seconds"]/candidate["wall_seconds"],"images":images,
            "original_elf_sha256":record["original_elf_sha256"],"optimized_elf_sha256":sha(optimized),
            "model_object_pins":object_pins,"host_sha256":sha(source),
            "adoption_limit":"No canonical builder change or running acceptance job replacement. Speed on later gameplay and actual earned/reset/restore remain unqualified."}
    save("_verification",result)
    save("_exit",dict(record,exit_code=0 if all(checks.values()) else 1,ended=time.time()))
    print(json.dumps({k:result[k] for k in ("finite_prefix_pass","baseline_wall_seconds","optimized_wall_seconds","speedup")}))
    raise SystemExit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()
