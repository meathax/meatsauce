"""Profile the actual real-system ELF under Ubuntu; no RTL/game changes."""
from pathlib import Path
import subprocess,os,json,time,hashlib,shutil,sys
ROOT=Path(__file__).resolve().parents[1]
if os.name!="posix" or not str(ROOT).startswith("/mnt/d/"):
    raise SystemExit("Run explicitly through Ubuntu WSL")
ATTEMPT=5 if sys.argv[1:]==["--attempt5"] else (4 if sys.argv[1:]==["--attempt4"] else (3 if sys.argv[1:]==["--attempt3"] else (2 if sys.argv[1:]==["--attempt2"] else 1)))
if sys.argv[1:] not in ([],["--attempt2"],["--attempt3"],["--attempt4"],["--attempt5"]):raise SystemExit("usage: run_system_profile.py [--attempt2|--attempt3|--attempt4|--attempt5]")
NAME="kyros_system_profile5"+(f"_v{ATTEMPT}" if ATTEMPT>1 else "")
out=ROOT/'sim/captures/diagnostics'/NAME
receipt=ROOT/'research'/f'{NAME}_job.json'
if receipt.exists() or out.exists():raise SystemExit("Existing profile: inspect its terminal before restarting")
out.mkdir(parents=True)
env=os.environ.copy();env["ALPHA_BUILD_TMP"]="/mnt/d/vibes/fpga/temp"
job={"worker_pid":os.getpid(),"started":time.time(),"scope":"Instrumented host performance diagnostic, actual DUT/ROM/legal ports; no timing/gameplay acceptance","frames":5,"source_parent":subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()}
def save(suffix,data):
    (ROOT/'research'/f'{NAME}_{suffix}').write_text(json.dumps(data,indent=2)+"\n")
with (out/'build.log').open('w') as log:
    cmd=['bash','sim/build_system_gprof.sh' if ATTEMPT>=3 else 'sim/build_system_profile.sh']
    p=subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
    job.update(build_pid=p.pid,build_command=cmd);save('job.json',job)
    code=p.wait();save('build_exit.json',{"exit_code":code,"ended":time.time()})
    if code:raise SystemExit(code)
binary=ROOT/('sim/build/alpha68kn_system_gprof_sim' if ATTEMPT>=3 else 'sim/build/alpha68kn_system_profile_sim')
shutil.copyfile(ROOT/('sim/build/system_gprof_inputs.sha256' if ATTEMPT>=3 else 'sim/build/system_profile_inputs.sha256'),ROOT/'research'/f'{NAME}_inputs.sha256')
runtime_hashes={}
for name in ['microrom.mem','nanorom.mem']:
    source=ROOT/'rtl/vendor/fx68k'/name
    target=out/name
    shutil.copyfile(source,target)
    digest=hashlib.sha256(source.read_bytes()).hexdigest()
    assert hashlib.sha256(target.read_bytes()).hexdigest()==digest
    runtime_hashes[name]=digest
job['runtime_rom_sha256']=runtime_hashes
cmd=[str(binary),str(ROOT/'roms/kyros/download.bin'),'5',str(out),'gameplay','--inputs',str(ROOT/'sim/captures/kyros/warm_reset960_refv2/frame_states.csv')]
with (out/'run.log').open('w') as log:
    p=subprocess.Popen(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT)
    job.update(simulation_pid=p.pid,run_started=time.time(),command=cmd,executable_sha256=hashlib.sha256(binary.read_bytes()).hexdigest());save('job.json',job)
    code=p.wait();job.update(exit_code=code,ended=time.time());save('exit.json',job)
if code:raise SystemExit(code)
profiler=shutil.which('gprof')
if profiler and (out/'gmon.out').exists():
    p=subprocess.run([profiler,'-b',str(binary),str(out/'gmon.out')],cwd=out,capture_output=True,text=True)
    (out/'gprof.txt').write_text(p.stdout)
    save('profiler_exit.json',{"exit_code":p.returncode,"stderr":p.stderr,"command":[profiler,'-b',str(binary),str(out/'gmon.out')]})
else:
    save('profiler_exit.json',{"exit_code":None,"reason":"gprof or gmon.out unavailable; preserve actual execution and build receipts"})
