"""Own one read-only observer build and one111-field CPU/MCU diagnostic."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
BASE=HERE/'coupled_boot16'
JOB=HERE/'bank_before_after111'
SOURCE=JOB/'source'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def wp(p):
    p=Path(p);return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def main():
    action=sys.argv[1];assert action in ['launch-build','build','launch-run','run','status']
    if action=='status':
        result={}
        for stage in ['build','run']:
            for name in ['worker','job','exit']:
                p=JOB/(stage+'_'+name+'.json')
                if p.exists():result[p.name]=json.loads(p.read_text())
            log=JOB/(stage+'.log')
            if log.exists():
                with log.open('rb') as f:f.seek(max(0,log.stat().st_size-1600));result[log.name+'_tail']=f.read().decode(errors='replace')
        print(json.dumps(result));return
    if action.startswith('launch-'):
        stage=action[7:];assert not (JOB/(stage+'_worker.json')).exists(),'Observe existing handle instead of restarting.'
        with (JOB/(stage+'_worker.log')).open('w',encoding='utf8') as log:
            child=subprocess.Popen([sys.executable,'-X','utf8',str(Path(__file__).resolve()),stage],cwd=HERE,
                   stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        save(JOB/(stage+'_worker.json'),{'worker_pid':child.pid,'started':time.time(),'stage':stage})
        print(json.dumps({'worker_pid':child.pid,'stage':stage}));return
    pins=json.loads((JOB/'source_pins.json').read_text())
    assert all(H(Path(p['path']))==p['observer_sha256'] for p in pins['source_files'])
    if action=='build':
        command=['wsl.exe','-d','Ubuntu','--cd',str(SOURCE),'--exec','/bin/bash','-c',
                 'printf "linux_pid=%s\\n" "$$"; exec /bin/bash sim/build_system.sh']
    else:
        assert json.loads((JOB/'build_exit.json').read_text())['exit_code']==0
        contract=json.loads((HERE/'integration_contract.json').read_text());rom=Path(contract['loader']['download_path'])
        assert H(rom)==contract['loader']['sha256']
        inputs=Path(pins['required_input']);assert H(inputs)==pins['required_input_sha256']
        command=['wsl.exe','-d','Ubuntu','--cd',str(SOURCE/'sim/build'),'--exec','/bin/bash','-c',
                 'printf "linux_pid=%s\\n" "$$"; exec ./alpha68kn_system_sim "$@"','bank_before_after111',
                 wp(rom),'111',wp(JOB/'capture'),'attract','--inputs',wp(inputs)]
    log=JOB/(action+'.log')
    with log.open('w',encoding='utf8') as handle:
        child=subprocess.Popen(command,cwd=SOURCE,stdout=handle,stderr=subprocess.STDOUT,
              creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        save(JOB/(action+'_job.json'),{'pid':child.pid,'worker_pid':os.getpid(),'started':time.time(),'command':command,
             'source_pins_sha256':H(JOB/'source_pins.json'),'worker_sha256':H(Path(__file__))})
        code=child.wait()
    elf=SOURCE/'sim/build/alpha68kn_system_sim'
    save(JOB/(action+'_exit.json'),{'exit_code':code,'pid':child.pid,'worker_pid':os.getpid(),'finished':time.time(),
          'log_path':str(log),'log_sha256':H(log),'source_pins_sha256':H(JOB/'source_pins.json'),
          'ELF_sha256':H(elf) if elf.exists() else None})

if __name__=='__main__':main()
