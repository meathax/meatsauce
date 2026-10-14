import hashlib,json,os,subprocess,sys,time
from pathlib import Path
OUT=Path(__file__).resolve().parent
ROM=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N\roms\sstingry\download.bin')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def put(name,value):(OUT/name).write_text(json.dumps(value,indent=2)+'\n',newline='\n')
def wsl(p):return '/mnt/'+p.drive[0].lower()+p.as_posix()[2:]
def phase(name,args):
    t=time.time()
    with (OUT/(name+'.log')).open('wb') as f:
        proc=subprocess.Popen(args,stdout=f,stderr=subprocess.STDOUT)
        put(name+'_job.json',dict(args=args,pid=proc.pid,parent_pid=os.getpid(),started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),log=str(OUT/(name+'.log'))))
        result=proc.wait()
    put(name+'_exit.json',dict(actual_exit_code=result,elapsed_seconds=time.time()-t,log_sha256=sha(OUT/(name+'.log'))))
    return result
if sys.argv[-1]=='--launch':
    assert not (OUT/'worker_native_job.json').exists(),'Already admitted; inspect receipt'
    p=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--worker'],stdout=(OUT/'worker_native_stdout.log').open('wb'),stderr=(OUT/'worker_native_stderr.log').open('wb'),creationflags=subprocess.CREATE_NO_WINDOW)
    put('worker_native_job.json',dict(pid=p.pid,argv=[sys.executable,str(Path(__file__).resolve()),'--worker']))
    print(json.dumps(dict(launched=True,pid=p.pid,receipt=str(OUT/'worker_native_job.json'))))
    sys.exit(0)
assert sha(ROM)=='9c60564786045834e97f98350e8310ef37a6027dadecc31cf89f1fa8bfe4358d'
pins=[]
for p in (OUT/'source').rglob('*'):
    if p.is_file():pins.append(dict(path=str(p),sha256=sha(p),bytes=p.stat().st_size))
put('actual_prerun_source_pins.json',dict(source_pins=pins,rom_sha256=sha(ROM),rom_bytes=ROM.stat().st_size))
run=phase('run_v3',['wsl.exe','-d','Ubuntu','--cd',str(OUT/'source'),'--exec','./obj/alpha68kn_wrapper_profile2_sim',wsl(ROM),'2',wsl(OUT/'capture'),'--features'])
sys.exit(run)
