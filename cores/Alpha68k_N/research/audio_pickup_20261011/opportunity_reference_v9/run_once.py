from pathlib import Path
import argparse,datetime,hashlib,json,os,subprocess,sys
D=Path(__file__).resolve().parent;OLD=D.parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def check():
 a=json.loads((D/'preparation.json').read_text());assert sha(D/'opportunity.lua')==a['lua_sha256']
 for x in a['source_pins']:assert sha(Path(x['path']))==x['sha256'],x['path']
 return a
ap=argparse.ArgumentParser();ap.add_argument('--worker',action='store_true');args=ap.parse_args();a=check()
if not args.worker:
 assert not (D/'started.json').exists() and not (D/'output').exists()
 scan=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',"@(Get-Process -Name mame -ErrorAction SilentlyContinue) | ForEach-Object { $_.Id }"],capture_output=True,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
 save(D/'owned_scan.json',{'actual_exit_code':scan.returncode,'stdout':scan.stdout,'stderr':scan.stderr,'time':datetime.datetime.now(datetime.timezone.utc).isoformat()})
 assert scan.returncode==0 and not scan.stdout.strip(),'MAME live or process scan failed'
 argv=[sys.executable,str(Path(__file__)),'--worker']
 with (D/'supervisor_stdout.log').open('wb') as out,(D/'supervisor_stderr.log').open('wb') as err:
  proc=subprocess.Popen(argv,cwd=D,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
 save(D/'started.json',{'pid':proc.pid,'argv':argv,'root_release':a['root_release'],'preparation_sha256':sha(D/'preparation.json')});print(json.dumps({'supervisor_pid':proc.pid}));sys.exit(0)
R=D/'output';R.mkdir()
for n in ['cfg','nvram','states']:(R/n).mkdir()
save(D/'admission.json',{'preparation_sha256':sha(D/'preparation.json'),'source_pins':a['source_pins'],'lua_sha256':a['lua_sha256'],'root_release':a['root_release'],'worker_sha256':sha(Path(__file__)),'native_acceptance':False})
argv=[str(OLD/'tools/mame0289/mame.exe'),'kyros','-rompath',str(OLD/'roms'),'-noreadconfig','-nocheat','-skip_gameinfo','-video','none','-sound','none','-nothrottle','-noautoframeskip','-frameskip','0','-autoboot_delay','0','-autoboot_script',str(D/'opportunity.lua'),'-pluginspath',str(OLD/'tools/mame0289/plugins'),'-seconds_to_run','40','-samplerate','48000','-wavwrite',str(R/'production.wav'),'-snapshot_directory',str(R),'-cfg_directory',str(R/'cfg'),'-nvram_directory',str(R/'nvram'),'-state_directory',str(R/'states')]
env=os.environ.copy();env['ALPHA_CAPTURE_DIR']=str(R);save(R/'job.json',{'argv':argv,'cwd':str(OLD),'root_release':a['root_release']})
with (R/'stdout.log').open('wb') as out,(R/'stderr.log').open('wb') as err:
 proc=subprocess.Popen(argv,cwd=OLD,env=env,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
 save(R/'started.json',{'pid':proc.pid,'time':datetime.datetime.now(datetime.timezone.utc).isoformat()});print(json.dumps({'mame_pid':proc.pid}),flush=True)
 rc=proc.wait()
complete=(R/'complete.json').exists();failure=(R/'failure.txt').exists();terminal=rc or (0 if complete and not failure else 1)
save(R/'exit.json',{'actual_MAME_exit_code':rc,'complete_present':complete,'failure_present':failure,'native_acceptance':False})
save(D/'worker_exit.json',{'actual_exit_code':terminal,'actual_MAME_exit_code':rc,'native_acceptance':False});sys.exit(terminal)
