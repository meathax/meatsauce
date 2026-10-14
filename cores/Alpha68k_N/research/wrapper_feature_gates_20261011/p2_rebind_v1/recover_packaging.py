import hashlib,json,subprocess,sys,time
from pathlib import Path
OUT=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def put(name,x):(OUT/name).write_text(json.dumps(x,indent=2)+'\n',newline='\n')
assert json.loads((OUT/'build_v3_exit.json').read_text())['actual_exit_code']==1
assert "cp: cannot create regular file" in (OUT/'build_v3.log').read_text()
assert not (OUT/'run_v3_job.json').exists(),'Do not duplicate native runtime'
snapshot=(OUT/'linux_build_directory.txt').read_text().strip()
assert snapshot.startswith('/tmp/alpha68kn-wrapper-p2.') and '..' not in snapshot
output='/mnt/d'+OUT.as_posix()[2:]
script='''#!/usr/bin/env bash
set -euo pipefail
cd SNAPSHOT
make -C obj -f Vemu.mk -j 2
mkdir -p OUTPUT/source/obj
cp obj/alpha68kn_wrapper_profile2_sim OUTPUT/source/obj/alpha68kn_wrapper_profile2_sim
'''.replace('SNAPSHOT',"'"+snapshot+"'").replace('OUTPUT',"'"+output+"'")
(OUT/'recover_packaging.sh').write_text(script,newline='\n')
args=['wsl.exe','-d','Ubuntu','--cd',str(OUT),'--exec','/bin/bash','recover_packaging.sh']
start=time.time()
with (OUT/'native_make_recovery.log').open('wb') as f:
    code=subprocess.run(args,stdout=f,stderr=subprocess.STDOUT).returncode
put('native_make_recovery_exit.json',dict(actual_exit_code=code,elapsed_seconds=time.time()-start,args=args,log_sha256=sha(OUT/'native_make_recovery.log'),cause='Original native build completed, but copying ELF to missing private obj directory failed. Recover the same object graph with make and create the private destination; no HDL/host edits or rerun gameplay. Original actual1 receipt retained.'))
assert code==0
exe=OUT/'source/obj/alpha68kn_wrapper_profile2_sim'
put('elf_v3.json',dict(path=str(exe),sha256=sha(exe),magic=exe.read_bytes()[:4].hex(),bytes=exe.stat().st_size))
runtext=(OUT/'run_job_v3.py').read_text()
a=runtext.index('build=phase(');b=runtext.index("run=phase('run_v3',",a)
runtext=runtext[:a]+runtext[b:]
runtext=runtext.replace('worker_v3','worker_native').replace("'actual_prebuild_source_pins_v3.json'","'actual_prerun_source_pins.json'")
(OUT/'run_recovered.py').write_text(runtext,newline='\n')
qual=(OUT/'qualify.py').read_text()
qual=qual.replace("for name in ['build_v3','run_v3']:","for name in ['native_make_recovery','run_v3']:")
qual=qual.replace("'build_v3_actual_exit0'","'native_make_recovery_actual_exit0'")
qual=qual.replace("'build.sh',","'build.sh','recover_packaging.py','recover_packaging.sh','native_make_recovery_exit.json','native_make_recovery.log','run_recovered.py',")
qual=qual.replace("actual_exit_codes=dict(build=0,run=0)","actual_exit_codes=dict(original_build_recipe=1,native_make_recovery=0,run=0)")
(OUT/'qualify.py').write_text(qual,newline='\n')
print(json.dumps(dict(recovered=True,ELF_sha256=sha(exe))))
sys.exit(subprocess.run([sys.executable,str(OUT/'run_recovered.py'),'--launch']).returncode)
