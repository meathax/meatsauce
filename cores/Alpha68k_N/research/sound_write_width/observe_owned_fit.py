"""Read-only native fit status. Append-only observations, no signals or job launch."""
from pathlib import Path
import subprocess,json,datetime
base=Path(__file__).resolve().parent/'case2_fit_sta'
cmd="Get-CimInstance Win32_Process -Filter \"Name='quartus_fit.exe'\" | Where-Object {$_.CommandLine -match 'sound_write_width/case2_full_map'} | ForEach-Object { $p=Get-Process -Id $_.ProcessId; [PSCustomObject]@{ProcessId=$_.ProcessId;ParentProcessId=$_.ParentProcessId;CommandLine=$_.CommandLine;CPUSeconds=$p.CPU;StartTime=$p.StartTime.ToString('o');WorkingSet=$p.WorkingSet64} } | ConvertTo-Json -Compress"
r=subprocess.run(['powershell.exe','-NoProfile','-Command',cmd],capture_output=True,text=True)
now=datetime.datetime.now(datetime.timezone.utc)
record={'utc':now.isoformat(),'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
path=base/('fit_observation_'+now.strftime('%Y%m%dT%H%M%S')+'.json')
path.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'path':str(path),**record}))
