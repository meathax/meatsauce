"""One root-released paired diagnostic with durable authentic child exits."""
from pathlib import Path
import hashlib,json,os,re,subprocess,sys,time
HERE=Path(__file__).resolve().parent/'paired601'
PREP=HERE/'paired601_commands_admission_preparation.json'
EXPECTED='74239b5b68260cd6c67784c9a95d1b74719a8d9aca58c3530810895bdf29ba89'
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
def write(name,obj):
    path=HERE/name
    assert not path.exists(),str(path)
    path.write_text(json.dumps(obj,indent=2)+'\n')
def main():
    assert pin(PREP)['sha256']==EXPECTED
    j=json.loads(PREP.read_text())
    assert not (HERE/'runtime_admission.json').exists(),'Refuse duplicate paired run'
    pins=[j[k] for k in ['MAME_binary','MAME_observer','MAME_API','native_API','input_reference','ROM','original_reference_import']]
    api=json.loads(Path(j['native_API']['path']).read_text());pins.append(api['ELF'])
    source=json.loads(Path(api['source_preparation']['path']).read_text())
    pins+=source['source_files']
    assert all(pin(Path(x['path']))['sha256']==x['sha256'] for x in pins),'Changed source/input/ROM/API/ELF'
    assert Path(j['ROM']['path']).read_bytes()[5]==1
    ps=subprocess.run(['wsl.exe','-d','Ubuntu','--exec','/bin/ps','-eo','pid,args'],capture_output=True,text=True)
    assert ps.returncode==0,ps.stderr
    duplicates=[x for x in ps.stdout.splitlines() if 'alpha68kn_system_sim' in x and 'japan_ram_divergence_20261011/paired601/native_capture' in x]
    assert not duplicates,duplicates
    windows=subprocess.run(['powershell.exe','-NoProfile','-Command',
        "Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(mame|python|wsl)\\.exe$' -and $_.CommandLine -like '*paired601*' -and $_.ProcessId -ne "+str(os.getpid())+" } | Select-Object ProcessId,Name,CommandLine | ConvertTo-Json -Compress"],capture_output=True,text=True)
    assert windows.returncode==0,windows.stderr
    assert not windows.stdout.strip(),windows.stdout
    for name in ['native_capture','mame_capture']:
        assert not (HERE/name).exists(),'Existing runtime capture namespace'
        (HERE/name).mkdir()
    write('runtime_admission.json',dict(authorized_by='Root reviewed commands74239/APIbd8f1fde+6de973; approve ONE paired601 runtime now.',
        started=time.time(),supervisor_pid=os.getpid(),commands=pin(PREP),worker=pin(Path(__file__)),
        pinned_source_files=len(source['source_files']),all_source_ROM_input_ELF_hashes_exact=True,
        native_duplicate_matches=duplicates,owned_Windows_process_matches=windows.stdout.strip(),
        requested_fields=601,original_references_immutable=True,strict_work_gate_preserved=True))
    at=j['native_command'].index('--exec')
    native=j['native_command'][:at+1]+['/bin/bash','-c','printf "native_linux_pid=%s\\n" "$$"\nexec "$@"','paired601_native']+j['native_command'][at+1:]
    env=os.environ.copy();env.update(j['MAME_environment'])
    with (HERE/'native.log').open('wb') as nf,(HERE/'mame.log').open('wb') as mf:
        n=subprocess.Popen(native,stdout=nf,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
        write('native_job.json',dict(pid=n.pid,supervisor_pid=os.getpid(),started=time.time(),command=native,ELF=api['ELF']))
        m=subprocess.Popen(j['MAME_command'],env=env,cwd=str(Path(j['ROM']['path']).parents[2]),
            stdout=mf,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
        write('mame_job.json',dict(pid=m.pid,supervisor_pid=os.getpid(),started=time.time(),command=j['MAME_command'],environment=j['MAME_environment'],binary=j['MAME_binary']))
        print(json.dumps(dict(supervisor_pid=os.getpid(),native_WSL_pid=n.pid,MAME_pid=m.pid,namespace=str(HERE))),flush=True)
        mc=m.wait()
        write('mame_exit.json',dict(exit_code=mc,finished=time.time(),pid=m.pid,log=pin(HERE/'mame.log')))
        nc=n.wait()
        match=re.search(r'native_linux_pid=(\d+)',(HERE/'native.log').read_text(errors='replace'))
        write('native_exit.json',dict(exit_code=nc,finished=time.time(),WSL_pid=n.pid,Linux_pid=int(match.group(1)) if match else None,
            ELF=pin(Path(api['ELF']['path'])),log=pin(HERE/'native.log')))
    write('paired_terminal.json',dict(native_exit=nc,MAME_exit=mc,finished=time.time(),supervisor_pid=os.getpid(),
        native_receipt=pin(HERE/'native_exit.json'),MAME_receipt=pin(HERE/'mame_exit.json'),no_replay_retry=True))
    return nc if nc else mc
if __name__=='__main__':sys.exit(main())
