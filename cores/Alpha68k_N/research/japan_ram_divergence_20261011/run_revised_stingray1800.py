"""Exactly one admitted official-MAME reference; authentic child exit, no retries."""
from pathlib import Path
import hashlib,json,subprocess,datetime,os,sys,traceback
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
HERE=Path(__file__).resolve().parent/'stingray_route1800/revised_reference_v1'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def put(name,value):(HERE/name).write_text(json.dumps(value,indent=2)+'\n')
assert not (HERE/'one_route.claim').exists()
try:
    manifest=json.loads((HERE/'preparation_manifest.json').read_text())
    checked=manifest['files']+[manifest['generator']]
    for p in checked:assert sha(p['path'])==p['sha256'],p['path']
    commands=json.loads((HERE/'commands.json').read_text());exe=Path(commands['MAME_argv'][0])
    assert sha(exe)=='af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3'
    assert sha(ROOT/'roms/sstingry/download.bin')=='9c60564786045834e97f98350e8310ef37a6027dadecc31cf89f1fa8bfe4358d'
    scan=subprocess.run(['powershell.exe','-NoProfile','-Command','Get-Process -Name mame -ErrorAction SilentlyContinue | Select-Object Id,Path,StartTime | ConvertTo-Json -Compress; exit 0'],capture_output=True,text=True)
    assert scan.returncode==0,scan.stderr
    rows=json.loads(scan.stdout) if scan.stdout.strip() else []
    if isinstance(rows,dict):rows=[rows]
    assert not rows,'Another official MAME process is live; hold launch, no interference'
    with (HERE/'one_route.claim').open('x') as f:f.write(utc()+'\n')
    for d in ['nvram','states']:(HERE/'capture'/d).mkdir(exist_ok=True)
    put('runtime_admission.json',dict(time=utc(),authority=manifest['authority'],manifest_sha256=sha(HERE/'preparation_manifest.json'),source_and_ROM_CAS=checked,owned_process_scan=dict(actual_exit=scan.returncode,stderr=scan.stderr,rows=rows),argv=commands['MAME_argv'],env=commands['MAME_env'],no_native_runtime=True,no_guest_state_writes=True,supervisor_pid=os.getpid()))
    env=os.environ.copy();env.update(commands['MAME_env']);started=utc()
    with (HERE/'runtime.stdout.log').open('wb') as out,(HERE/'runtime.stderr.log').open('wb') as err:
        child=subprocess.Popen(commands['MAME_argv'],cwd=ROOT,env=env,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
        put('worker.json',dict(pid=child.pid,started_utc=started,supervisor_pid=os.getpid(),argv=commands['MAME_argv'],status='running'))
        print(json.dumps(dict(worker_pid=child.pid,supervisor_pid=os.getpid(),admission=str(HERE/'runtime_admission.json'))),flush=True)
        actual=child.wait()
    complete=HERE/'capture/complete.txt';failure=HERE/'capture/failure.txt'
    put('runtime_exit.json',dict(actual_exit=actual,pid=child.pid,started_utc=started,finished_utc=utc(),complete=complete.read_text() if complete.exists() else None,callback_failure=failure.read_text() if failure.exists() else None,stdout_sha256=sha(HERE/'runtime.stdout.log'),stderr_sha256=sha(HERE/'runtime.stderr.log')))
    print(json.dumps(dict(actual_exit=actual,complete=complete.exists(),callback_failure=failure.exists(),receipt=str(HERE/'runtime_exit.json'))),flush=True)
    sys.exit(actual)
except BaseException as e:
    if not isinstance(e,SystemExit):put('admission_or_supervisor_failure.json',dict(time=utc(),exception=repr(e),traceback=traceback.format_exc(),no_automatic_repeat=True))
    raise
