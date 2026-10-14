"""Root-approved one-shot hidden launcher; refuses duplicate owned pilot."""
from pathlib import Path
import hashlib,json,subprocess,datetime
HERE=Path(__file__).resolve().parent
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8')
manifest=HERE/'admission_manifest.json'
assert hashlib.sha256(manifest.read_bytes()).hexdigest()=='5dddb782f289a6446f075018712035cd226e685802d6df5bf3ceab10edf10f77'
assert not (HERE/'dispatch_started.json').exists()
assert not (HERE/'reference_pilot_v1').exists()
command="Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'python*' -and $_.CommandLine -like '*audio_pickup_20261011*run_reference_pilot.py*' } | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Compress"
scan=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',command],capture_output=True,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
save(HERE/'owned_scan.json',{'actual_exit_code':scan.returncode,'stdout':scan.stdout,'stderr':scan.stderr,'matching_owned_launchers':json.loads(scan.stdout) if scan.stdout.strip() else [],'time':datetime.datetime.now(datetime.timezone.utc).isoformat()})
assert scan.returncode==0 and not scan.stdout.strip(),'Existing owned launcher or failed scan; no dispatch'
argv=[r'D:\vibes\fpga\toolchains\msys64\ucrt64\bin\python.exe',str(HERE/'run_reference_pilot.py'),'--parent-release','root-20261011-pickup-reference-1']
with (HERE/'dispatch_stdout.log').open('wb') as out,(HERE/'dispatch_stderr.log').open('wb') as err:
 proc=subprocess.Popen(argv,cwd=HERE,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
save(HERE/'dispatch_started.json',{'pid':proc.pid,'argv':argv,'admission_sha256':hashlib.sha256(manifest.read_bytes()).hexdigest(),'root_release':'root-20261011-pickup-reference-1','time':datetime.datetime.now(datetime.timezone.utc).isoformat()})
print(json.dumps({'supervisor_pid':proc.pid,'receipt':str(HERE/'dispatch_started.json')}))
