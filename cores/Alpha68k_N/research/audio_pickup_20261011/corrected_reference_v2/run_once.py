"""One root-reviewed observer-corrected official MAME pilot, reference only."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,subprocess
HERE=Path(__file__).resolve().parent
BASE=HERE.parent
OLD=BASE.parents[1]
FIX=BASE/'observer_fix_v2'
EXPECTED='9908c4ffde6c829ba93bd89caa36cd452677879663581c53c27deda444cbdf49'
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8')
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--worker',action='store_true');args=ap.parse_args()
 expected_manifest=FIX/'import_manifest.json'
 assert sha(expected_manifest)==EXPECTED
 source=json.loads(expected_manifest.read_text())
 for x in source['files']+source['source_pins']:
  assert sha(Path(x['path']))==x['sha256'],x['path']
 if not args.worker:
  assert not (HERE/'started.json').exists() and not (HERE/'output').exists()
  command="Get-CimInstance Win32_Process | Where-Object { ($_.Name -like 'python*' -and $_.CommandLine -like '*corrected_reference_v2*run_once.py*--worker*') -or ($_.Name -like 'mame*' -and $_.CommandLine -like '*observer_fix_v2*pickup_pilot.lua*') } | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Compress"
  scan=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',command],capture_output=True,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
  save(HERE/'owned_scan.json',{'actual_exit_code':scan.returncode,'stdout':scan.stdout,'stderr':scan.stderr,'matching_owned_workers':json.loads(scan.stdout) if scan.stdout.strip() else [],'time':datetime.datetime.now(datetime.timezone.utc).isoformat()})
  assert scan.returncode==0 and not scan.stdout.strip(),'Existing owned worker or failed scan'
  argv=[r'D:\vibes\fpga\toolchains\msys64\ucrt64\bin\python.exe',str(Path(__file__)),'--worker']
  with (HERE/'supervisor_stdout.log').open('wb') as out,(HERE/'supervisor_stderr.log').open('wb') as err:
   proc=subprocess.Popen(argv,cwd=HERE,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
  save(HERE/'started.json',{'pid':proc.pid,'argv':argv,'root_release':'root-20261011-corrected-pickup-reference-2','observer_manifest_sha256':EXPECTED,'time':datetime.datetime.now(datetime.timezone.utc).isoformat()})
  print(json.dumps({'supervisor_pid':proc.pid,'receipt':str(HERE/'started.json')}));return
 output=HERE/'output';output.mkdir()
 for name in ('cfg','nvram','states'):(output/name).mkdir()
 save(HERE/'admission.json',{'root_release':'root-20261011-corrected-pickup-reference-2','observer_manifest_sha256':EXPECTED,'source_pins':[{'path':x['path'],'sha256':sha(Path(x['path']))} for x in source['files']+source['source_pins']],'worker_sha256':sha(Path(__file__)),'prior_failed_pilot_preserved':sha(BASE/'import_manifest.json')=='5a348f2b60691b409fd8e8cd8937f1780c962f363da91c7bbffd11ef97c76a04','native_acceptance':False})
 argv=[str(OLD/'tools/mame0289/mame.exe'),'kyros','-rompath',str(OLD/'roms'),'-noreadconfig','-nocheat','-skip_gameinfo','-video','none','-sound','none','-nothrottle','-noautoframeskip','-frameskip','0','-autoboot_delay','0','-autoboot_script',str(FIX/'pickup_pilot.lua'),'-pluginspath',str(OLD/'tools/mame0289/plugins'),'-seconds_to_run','55','-snapshot_directory',str(output),'-cfg_directory',str(output/'cfg'),'-nvram_directory',str(output/'nvram'),'-state_directory',str(output/'states')]
 env=os.environ.copy();env['ALPHA_CAPTURE_DIR']=str(output)
 save(output/'job.json',{'argv':argv,'cwd':str(OLD),'root_release':'root-20261011-corrected-pickup-reference-2','native_acceptance':False})
 with (output/'stdout.log').open('wb') as out,(output/'stderr.log').open('wb') as err:
  proc=subprocess.Popen(argv,cwd=OLD,env=env,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
  save(output/'started.json',{'pid':proc.pid,'time':datetime.datetime.now(datetime.timezone.utc).isoformat()});print(json.dumps({'mame_pid':proc.pid,'output':str(output)}),flush=True)
  rc=proc.wait()
 complete=output/'complete.json';failed=(output/'failure.txt').exists()
 save(output/'exit.json',{'actual_MAME_exit_code':rc,'complete_present':complete.exists(),'failure_present':failed,'native_acceptance':False})
 terminal=rc or (0 if complete.exists() and not failed else 1)
 save(HERE/'worker_exit.json',{'actual_exit_code':terminal,'actual_MAME_exit_code':rc,'native_acceptance':False})
 raise SystemExit(terminal)
if __name__=='__main__':main()
