"""Wait for the already admitted pair, qualify once, freeze small import/recovery pins."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,time
HERE=Path(__file__).resolve().parent/'paired601'
PY=Path(r'C:\Users\meath\AppData\Local\Programs\Python\Python312\python.exe')
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
def write(name,obj):
    p=HERE/name;assert not p.exists(),str(p);p.write_text(json.dumps(obj,indent=2)+'\n')
def main():
    assert (HERE/'runtime_admission.json').exists()
    assert not (HERE/'finish_job.json').exists(),'An admitted finisher exists'
    verifier=Path(__file__).resolve().parent/'qualify_paired601.py'
    write('finish_job.json',dict(pid=os.getpid(),started=time.time(),worker=pin(Path(__file__)),
        waiting_for=str(HERE/'paired_terminal.json'),verifier=pin(verifier),no_new_simulation=True))
    while not (HERE/'paired_terminal.json').exists():time.sleep(10)
    assert pin(verifier)['sha256']==json.loads((HERE/'finish_job.json').read_text())['verifier']['sha256']
    with (HERE/'verification.log').open('wb') as log:
        child=subprocess.Popen([str(PY),str(verifier)],stdout=log,stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW)
        write('verification_job.json',dict(pid=child.pid,supervisor_pid=os.getpid(),started=time.time(),verifier=pin(verifier)))
        code=child.wait()
    write('verification_exit.json',dict(exit_code=code,finished=time.time(),actual_child_pid=child.pid,log=pin(HERE/'verification.log')))
    small=[pin(p) for p in sorted(HERE.iterdir()) if p.is_file() and p.suffix in ['.json','.lua','.log']]
    small += [pin(verifier),pin(Path(__file__)),pin(HERE.parent/'run_paired601.py'),pin(HERE.parent/'qualify_observer601_API.py')]
    captures=[pin(p) for folder in ['native_capture','mame_capture'] for p in sorted((HERE/folder).rglob('*')) if p.is_file()]
    result=dict(scope='One centrally released paired601 with authentic terminal and one strict consumer; no acceptance relaxation.',
        terminal=json.loads((HERE/'paired_terminal.json').read_text()),actual_verifier_exit=code,
        small_import_files=small,capture_recovery_pins=captures,
        limitations='Strict work result and original invariance preconditions remain decisive; no inferred stale-stack acceptance.')
    if (HERE/'verification.json').exists():
        v=json.loads((HERE/'verification.json').read_text())
        result.update(checks=v['checks'],invariant_precondition_pass=v['invariant_precondition_pass'],strict_work_gate=v['strict_work_gate'])
    write('terminal_import_manifest.json',result)
    write('finish_exit.json',dict(exit_code=code,finished=time.time(),manifest=pin(HERE/'terminal_import_manifest.json')))
    print(json.dumps(dict(actual_verifier_exit=code,terminal_manifest=pin(HERE/'terminal_import_manifest.json'))),flush=True)
    return code
if __name__=='__main__':sys.exit(main())
