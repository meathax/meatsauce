from pathlib import Path
import subprocess,json,time,hashlib,sys
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
WSL_ROOT='/mnt/d/Arcade/AI/aCORES/Alpha68k N'
attempt2=sys.argv[1:]==['--attempt2']
if sys.argv[1:] and not attempt2:raise SystemExit('usage: run_reset360_renderer.py [--attempt2]')
tag='kyros_reset360_timed_renderer_v2' if attempt2 else 'kyros_reset360_timed_renderer'
capture=ROOT/('sim/captures/diagnostics/reset360_timed_renderer_v2' if attempt2 else 'sim/captures/diagnostics/reset360_timed_renderer')
capture.mkdir(parents=True,exist_ok=True)
receipt=ROOT/'research'/(tag+'_job.json')
if receipt.exists():
 raise SystemExit('Existing timed replay job; inspect its terminal state before restarting')
worker=r"""
from pathlib import Path
import json,subprocess,time,hashlib,os
r=Path('/mnt/d/Arcade/AI/aCORES/Alpha68k N')
out=r/'sim/captures/diagnostics/reset360_timed_renderer'
meta=json.loads((r/'research/kyros_reset360_timed_renderer_preparation.json').read_text())
job={'worker_pid':os.getpid(),'started':time.time(),'scope':'Isolated actual renderer replay; no CPU acceptance'}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
with (out/'build.log').open('w') as log:
 cmd=['bash','sim/build_renderer_timed.sh']
 p=subprocess.Popen(cmd,cwd=r,stdout=log,stderr=subprocess.STDOUT)
 job['build_pid']=p.pid;job['build_command']=cmd
 (r/'research/kyros_reset360_timed_renderer_worker.json').write_text(json.dumps(job,indent=2)+'\n')
 code=p.wait()
 (r/'research/kyros_reset360_timed_renderer_build_exit.json').write_text(json.dumps({'exit_code':code,'command':cmd,'ended':time.time()},indent=2)+'\n')
 if code:raise SystemExit(code)
binary=r/'sim/build/alpha68kn_render_timed_sim'
manifest=r/'sim/build/renderer_timed_inputs.sha256'
(r/'research/kyros_reset360_timed_renderer_inputs.sha256').write_bytes(manifest.read_bytes())
cmd=[str(binary),str(r/'roms/kyros/download.bin'),str(r/'sim/captures/rtl/kyros_reset_background421/frame_000330.sprites.bin'),str(meta['background']),str(out),'0',str(r/'sim/captures/rtl/kyros_reset_background421/frame_000360.rgb'),str(out/'writes.csv'),str(meta['elapsed_start']),str(meta['elapsed_end'])]
with (out/'run.log').open('w') as log:
 p=subprocess.Popen(cmd,cwd=r,stdout=log,stderr=subprocess.STDOUT)
 job.update(simulation_pid=p.pid,command=cmd,executable_sha256=sha(binary),started_run=time.time())
 (r/'research/kyros_reset360_timed_renderer_worker.json').write_text(json.dumps(job,indent=2)+'\n')
 code=p.wait()
 job.update(exit_code=code,ended=time.time())
 (r/'research/kyros_reset360_timed_renderer_exit.json').write_text(json.dumps(job,indent=2)+'\n')
"""
if attempt2:
 worker=worker.replace('kyros_reset360_timed_renderer','kyros_reset360_timed_renderer_v2').replace('kyros_reset360_timed_renderer_v2_preparation','kyros_reset360_timed_renderer_preparation')
 worker=worker.replace('diagnostics/reset360_timed_renderer','diagnostics/reset360_timed_renderer_v2')
 source=ROOT/'sim/captures/diagnostics/reset360_timed_renderer/writes.csv'
 target=capture/'writes.csv'
 target.write_bytes(source.read_bytes())
 assert hashlib.sha256(source.read_bytes()).digest()==hashlib.sha256(target.read_bytes()).digest()
cmd=['wsl.exe','-d','Ubuntu','--cd',str(ROOT),'--exec','python3','-c',worker]
with (capture/'worker.log').open('w') as log:
 p=subprocess.Popen(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
d={'launcher_pid':p.pid,'started':time.time(),'source_revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'command':cmd,'preparation':str(ROOT/'research/kyros_reset360_timed_renderer_preparation.json'),'files_sha256':{str(ROOT/n):hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in ['sim/render_timed_main.cpp','sim/render_fixture.sv','sim/build_renderer_timed.sh','rtl/alpha68kn_renderer.sv','rtl/alpha68kn_video_rom.sv','rtl/alpha68kn_gfxmem.sv']}}
receipt.write_text(json.dumps(d,indent=2)+'\n')
print(json.dumps({'launcher_pid':p.pid,'job':str(receipt)}))
