"""Run exactly one justified initial-exchange extension using the existing ELF."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
BASE=HERE/'coupled_boot16'
JOB=HERE/'coupled_boot111'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def wp(p):
    p=Path(p);return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
def save(p,obj):p.write_text(json.dumps(obj,indent=2)+'\n')

def main():
    action=sys.argv[1];assert action in ['launch','run','status']
    if action=='status':
        result={}
        for name in ['worker.json','job.json','exit.json']:
            p=JOB/name
            if p.exists():result[name]=json.loads(p.read_text())
        log=JOB/'run.log'
        if log.exists():
            with log.open('rb') as f:f.seek(max(0,log.stat().st_size-1800));result['log_tail']=f.read().decode(errors='replace')
        print(json.dumps(result));return
    if action=='launch':
        assert not JOB.exists(),'Preserve the original extension job; never restart on observation timeout.'
        JOB.mkdir()
        with (JOB/'worker.log').open('w',encoding='utf8') as log:
            child=subprocess.Popen([sys.executable,'-X','utf8',str(Path(__file__).resolve()),'run'],cwd=HERE,
                stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        save(JOB/'worker.json',{'worker_pid':child.pid,'started':time.time(),'rebuild':False})
        print(json.dumps({'worker_pid':child.pid,'output':str(JOB),'rebuild':False}));return
    verification=BASE/'verification.json'
    assert H(verification)=='fd5d380224dfaab7b7958a4c83577c4665cd5dbf91d7614a29cdedf9b89dde40'
    proof=json.loads(verification.read_text());assert proof['reference_first_command']['frame']=='108'
    assert any(r['frame']=='109' for r in proof['reference_first20_commands'])
    pins=BASE/'source_pins.json';assert H(pins)=='aa85eb67c906bf9fdd73e607dc6b51ba36a4e64c0cef02bffb9dd8800c13f61f'
    source=json.loads(pins.read_text())
    assert all(H(Path(r['path']))==r['actual_private_sha256'] for r in source['source_files'])
    elf=BASE/'source/sim/build/alpha68kn_system_sim'
    assert H(elf)=='c3256c24131196e62b2cfe502b20ea641a88755d1f1d1732de6b3c15c7e0b8f8'
    inputs=BASE/'actual_attract_inputs.csv'
    assert H(inputs)=='4e546640f76078caf5fd8c817f4e13b22c890a6a2b615abd36b8f3c7b41ad2f9'
    contract=HERE/'integration_contract.json';metadata=json.loads(contract.read_text())
    rom=Path(metadata['loader']['download_path']);assert H(rom)==metadata['loader']['sha256']
    lineage={'ELF_path':str(elf),'ELF_sha256':H(elf),'ELF_header':elf.read_bytes()[:4].hex(),
             'source_pins_path':str(pins),'source_pins_sha256':H(pins),'legal_input_path':str(inputs),'legal_input_sha256':H(inputs),
             'ROM_path':str(rom),'ROM_sha256':H(rom),'contract_sha256':H(contract),
             'original16_verification_path':str(verification),'original16_verification_sha256':H(verification),
             'primary_first_command_frame':108,'primary_first_write_frame':109,'requested_fields':111,
             'reason':'Three fields through the first retained MCU command/write windows; the16-field boot ended before those commands.',
             'rebuild':False,'production_edited':False,'full_attract_or_gameplay':False,'launcher_sha256':H(Path(__file__))}
    save(JOB/'lineage.json',lineage)
    command=['wsl.exe','-d','Ubuntu','--cd',str(elf.parent),'--exec','/bin/bash','-c',
             'printf "linux_pid=%s\\n" "$$"; exec ./alpha68kn_system_sim "$@"','coupled_boot111',
             wp(rom),'111',wp(JOB/'capture'),'attract','--inputs',wp(inputs)]
    log=JOB/'run.log'
    with log.open('w',encoding='utf8') as handle:
        child=subprocess.Popen(command,cwd=elf.parent,stdout=handle,stderr=subprocess.STDOUT,
                     creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        save(JOB/'job.json',{'pid':child.pid,'worker_pid':os.getpid(),'started':time.time(),'command':command,
                            'lineage_sha256':H(JOB/'lineage.json')})
        code=child.wait()
    save(JOB/'exit.json',{'exit_code':code,'pid':child.pid,'worker_pid':os.getpid(),'finished':time.time(),
                         'log_path':str(log),'log_sha256':H(log),'ELF_sha256':H(elf),'lineage_sha256':H(JOB/'lineage.json')})

if __name__=='__main__':main()
