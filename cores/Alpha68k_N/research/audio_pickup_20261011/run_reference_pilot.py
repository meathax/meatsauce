"""One bounded official-MAME pilot. No native replay; no guest state writes."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,subprocess
HERE=Path(__file__).resolve().parent
OLD=HERE.parents[1]
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8')
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--parent-release',required=True);args=ap.parse_args()
 assert args.parent_release.strip()
 manifest=json.loads((HERE/'admission_manifest.json').read_text())
 for row in manifest['files']+manifest['source_pins']:
  p=Path(row['path']);p=p if p.is_absolute() else HERE/p
  assert sha(p)==row['sha256'],str(p)
 output=HERE/'reference_pilot_v1'
 output.mkdir() # Refuse a duplicate dispatch, including after a transport failure.
 for name in ('cfg','nvram','states'):(output/name).mkdir()
 argv=[str(OLD/'tools/mame0289/mame.exe'),'kyros','-rompath',str(OLD/'roms'),'-noreadconfig','-nocheat','-skip_gameinfo','-video','none','-sound','none','-nothrottle','-noautoframeskip','-frameskip','0','-autoboot_delay','0','-autoboot_script',str(HERE/'pickup_pilot.lua'),'-pluginspath',str(OLD/'tools/mame0289/plugins'),'-seconds_to_run','55','-snapshot_directory',str(output),'-cfg_directory',str(output/'cfg'),'-nvram_directory',str(output/'nvram'),'-state_directory',str(output/'states')]
 env=os.environ.copy();env['ALPHA_CAPTURE_DIR']=str(output)
 save(output/'job.json',{'argv':argv,'cwd':str(OLD),'parent_release':args.parent_release,'manifest_sha256':sha(HERE/'admission_manifest.json'),'native_acceptance':False,'state_writes':0})
 with (output/'stdout.log').open('wb') as out,(output/'stderr.log').open('wb') as err:
  proc=subprocess.Popen(argv,cwd=OLD,env=env,stdout=out,stderr=err,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
  save(output/'started.json',{'pid':proc.pid,'time':datetime.datetime.now(datetime.timezone.utc).isoformat()});print(json.dumps({'pid':proc.pid,'output':str(output)}),flush=True)
  rc=proc.wait()
 complete=output/'complete.json';failed=(output/'failure.txt').exists()
 save(output/'exit.json',{'actual_native_exit_code':rc,'complete_present':complete.exists(),'failure_present':failed,'native_acceptance':False})
 raise SystemExit(rc or (0 if complete.exists() and not failed else 1))
if __name__=='__main__':main()
