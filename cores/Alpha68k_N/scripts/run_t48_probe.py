from pathlib import Path
import subprocess,hashlib,json,time,os
ROOT=Path(__file__).resolve().parents[1]
def main():
    record={"worker_pid":os.getpid(),"started":time.time(),"scope":"Real8748 firmware probe; artificial external commands, no game pass"}
    inputs=["rtl/alpha68kn_mcu.sv","rtl/vendor/t48/t48_core.v","sim/t48_probe_top.sv","sim/t48_probe_main.cpp","roms/sstingry/alpha8511.bin"]
    record["inputs"]={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in inputs}
    (ROOT/"research/t48_probe_job.json").write_text(json.dumps(record,indent=2)+"\n")
    with (ROOT/"research/t48_probe_build.log").open("w") as log:
        rc=subprocess.run(["/usr/bin/bash","sim/build_t48_probe.sh"],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT).returncode
    (ROOT/"research/t48_probe_build_exit.json").write_text(json.dumps({"exit_code":rc,"ended":time.time()})+"\n")
    if rc: return
    executable=ROOT/"sim/build/alpha68kn_t48_probe"
    record["executable_sha256"]=hashlib.sha256(executable.read_bytes()).hexdigest()
    with (ROOT/"research/t48_probe_result.json").open("w") as log:
        process=subprocess.Popen([str(executable),str(ROOT/"roms/sstingry/alpha8511.bin"),str(ROOT/"research/t48_probe_events.csv")],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
        record["simulation_pid"]=process.pid
        (ROOT/"research/t48_probe_job.json").write_text(json.dumps(record,indent=2)+"\n")
        rc=process.wait()
    record.update(exit_code=rc,ended=time.time())
    (ROOT/"research/t48_probe_exit.json").write_text(json.dumps(record,indent=2)+"\n")
if __name__=="__main__": main()
