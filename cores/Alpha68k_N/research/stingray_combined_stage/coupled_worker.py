"""Owned private build/run worker. Linux ELF always uses explicit Ubuntu WSL."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
JOB=HERE/'coupled_boot16'
SOURCE=JOB/'source'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def wsl_path(p):
    p=Path(p);return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
def write(path,obj):path.write_text(json.dumps(obj,indent=2)+'\n')

def main():
    action=sys.argv[1]
    assert action in ['launch-build','build','launch-run','run','status']
    if action=='status':
        result={}
        for stage in ['build','run']:
            for suffix in ['job','exit']:
                p=JOB/(stage+'_'+suffix+'.json')
                if p.exists():result[p.name]=json.loads(p.read_text())
            log=JOB/(stage+'.log')
            if log.exists():
                with log.open('rb') as f:f.seek(max(0,log.stat().st_size-1800));result[log.name+'_tail']=f.read().decode(errors='replace')
        print(json.dumps(result));return
    if action.startswith('launch-'):
        stage=action[7:];assert not (JOB/(stage+'_job.json')).exists() and not (JOB/(stage+'_worker.json')).exists(),'Observe existing job instead of restarting.'
        with (JOB/(stage+'_worker.log')).open('w',encoding='utf8') as worker_log:
            child=subprocess.Popen([sys.executable,'-X','utf8',str(Path(__file__).resolve()),stage],
                                   cwd=HERE,stdout=worker_log,stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        write(JOB/(stage+'_worker.json'),{'worker_pid':child.pid,'stage':stage,'started':time.time()})
        print(json.dumps({'worker_pid':child.pid,'stage':stage}));return
    if action=='build':
        args=['wsl.exe','-d','Ubuntu','--cd',str(SOURCE),'--exec','/bin/bash','-c',
              'printf "linux_pid=%s\\n" "$$"; exec /bin/bash sim/build_system.sh']
    else:
        build=json.loads((JOB/'build_exit.json').read_text());assert build['exit_code']==0
        rom=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N/roms/sstingry/download.bin')
        contract=json.loads((HERE/'integration_contract.json').read_text());assert H(rom)==contract['loader']['sha256']
        args=['wsl.exe','-d','Ubuntu','--cd',str(SOURCE/'sim/build'),'--exec','/bin/bash','-c',
              'printf "linux_pid=%s\\n" "$$"; exec ./alpha68kn_system_sim "$@"','coupled_boot16',
              wsl_path(rom),'16',wsl_path(JOB/'capture'),'attract','--inputs',wsl_path(JOB/'actual_attract_inputs.csv')]
    log=JOB/(action+'.log')
    with log.open('w',encoding='utf8') as handle:
        child=subprocess.Popen(args,cwd=SOURCE,stdout=handle,stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        write(JOB/(action+'_job.json'),{'pid':child.pid,'worker_pid':os.getpid(),'command':args,'started':time.time(),
                'source_pins_sha256':H(JOB/'source_pins.json'),'reference_sha256':H(JOB/'reference_provenance.json')})
        code=child.wait()
    receipt={'exit_code':code,'pid':child.pid,'worker_pid':os.getpid(),'finished':time.time(),'log_path':str(log),
             'log_sha256':H(log),'source_pins_sha256':H(JOB/'source_pins.json')}
    elf=SOURCE/'sim/build/alpha68kn_system_sim'
    if elf.exists():receipt['ELF_sha256']=H(elf);receipt['ELF_header']=elf.read_bytes()[:4].hex()
    write(JOB/(action+'_exit.json'),receipt)

if __name__=='__main__':main()
