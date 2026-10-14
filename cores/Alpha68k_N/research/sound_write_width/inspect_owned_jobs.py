"""Read-only actual native process identity observation; no process is signalled."""
import subprocess,json
from pathlib import Path
cmd="Get-CimInstance Win32_Process -Filter \"Name='quartus_map.exe' OR Name='quartus_fit.exe' OR Name='python.exe'\" | Where-Object {$_.CommandLine -match 'sound_write_width|case2|sound_debug'} | Select-Object ProcessId,ParentProcessId,CommandLine | ConvertTo-Json -Compress"
r=subprocess.run(['powershell.exe','-NoProfile','-Command',cmd],capture_output=True,text=True)
data={'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
Path(__file__).with_name('owned_jobs_observation.json').write_text(json.dumps(data,indent=2)+'\n')
print(json.dumps(data))
