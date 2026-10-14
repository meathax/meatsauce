from pathlib import Path
import os,json,subprocess,hashlib,time,traceback,shutil
HERE=Path(__file__).resolve().parent;OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
CAP=OLD/'sim/captures/kyros/mame_startup_phase2'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(n,x):(HERE/n).write_text(json.dumps(x,indent=2)+'\n')
try:
 assert (HERE/'ROOT_RELEASED.json').exists(),'Root release required before worker'
 assert not CAP.exists() and not(HERE/'mame_job.json').exists(),'Refuse duplicate capture'
 admitted=json.loads((HERE/'admission.json').read_text())
 assert all(sha(p)==h for p,h in admitted['required_pins'].items())
 build=json.loads((HERE.parent/'build_v5/private_build_exit.json').read_text())
 exe=Path(build['executable']['path']);assert sha(exe)==build['executable']['sha256']
 CAP.mkdir(parents=True)
 for n in ['cfg','nvram','states']:(CAP/n).mkdir()
 cfg=[]
 for p in (OLD/'sim/captures/kyros/warm_reset960_refv2/cfg').glob('*.cfg'):
  shutil.copy2(p,CAP/'cfg'/p.name);cfg.append({'path':str(p),'sha256':sha(p)})
 recorder=CAP/'loaded_recorder.lua';shutil.copy2(HERE/'qualified_recorder.lua',recorder)
 original=json.loads((OLD/'research/irq_sampling_edge_mame61_job.json').read_text())
 command=list(original['command']);command[0]=str(exe)
 overrides={'-autoboot_script':recorder,'-snapshot_directory':CAP,'-cfg_directory':CAP/'cfg','-nvram_directory':CAP/'nvram','-state_directory':CAP/'states','-wavwrite':CAP/'audio.wav','-pluginspath':str(OLD/'tools/mame0289/plugins')+';'+str(HERE/'plugins')}
 for f,v in overrides.items():command[command.index(f)+1]=str(v)
 command+=['-plugins','-plugin','alpha_startup_observer','-log']
 env=os.environ.copy();env.update(ALPHA_CAPTURE_DIR=str(CAP),ALPHA_CAPTURE_FRAMES='1',ALPHA_CAPTURE_MODE='warm-reset',ALPHA_STARTUP_CAPTURE_DIR=str(CAP))
 receipt={'worker_pid':os.getpid(),'command':command,'cwd':str(CAP),'cfg_seeds':cfg,'executable_sha256':sha(exe),'admission_sha256':sha(HERE/'admission.json'),'started':time.time(),'environment':{n:env[n] for n in ['ALPHA_CAPTURE_DIR','ALPHA_CAPTURE_FRAMES','ALPHA_CAPTURE_MODE','ALPHA_STARTUP_CAPTURE_DIR']}}
 with(HERE/'mame_run.log').open('wb')as log:
  child=subprocess.Popen(command,cwd=CAP,env=env,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
  receipt['mame_pid']=child.pid;save('mame_job.json',receipt);code=child.wait()
 save('mame_exit.json',{'exit_code':code,'ended':time.time(),'mame_pid':child.pid,'log_sha256':sha(HERE/'mame_run.log')});raise SystemExit(code)
except Exception as e:
 save('mame_failure.json',{'error':str(e),'traceback':traceback.format_exc()});raise
