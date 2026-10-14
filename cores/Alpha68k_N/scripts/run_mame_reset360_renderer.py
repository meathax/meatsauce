"""Run the exact existing renderer ELF with recorded MAME write timing."""
from pathlib import Path
import subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/'sim/captures/diagnostics/reset360_mame_timed_renderer'
receipt=ROOT/'research/kyros_reset360_mame_timed_renderer_job.json'
if receipt.exists():raise SystemExit('Existing job: inspect the same terminal before restarting')
binary=ROOT/'sim/build/alpha68kn_render_timed_sim'
qualified=json.loads((ROOT/'research/kyros_reset360_timed_renderer_v2_exit.json').read_text())
assert hashlib.sha256(binary.read_bytes()).hexdigest()==qualified['executable_sha256']
worker=r"""
from pathlib import Path
import json,subprocess,time,hashlib,os
r=Path('/mnt/d/Arcade/AI/aCORES/Alpha68k N')
out=r/'sim/captures/diagnostics/reset360_mame_timed_renderer'
meta=json.loads((r/'research/kyros_reset360_mame_timed_renderer_preparation.json').read_text())
binary=r/'sim/build/alpha68kn_render_timed_sim'
cmd=[str(binary),str(r/'roms/kyros/download.bin'),str(r/'sim/captures/kyros/reset_raster361_v4/frame_000330.sprites.bin'),'64',str(out),'0',str(r/'sim/captures/rtl/kyros_reset_background421/frame_000360.rgb'),str(out/'writes.csv'),str(meta['elapsed_start']),str(meta['elapsed_end'])]
job={'worker_pid':os.getpid(),'started':time.time(),'command':cmd,'executable_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'scope':'MAME-write timing projected onto actual renderer; no native CPU acceptance'}
with (out/'run.log').open('w') as log:
 p=subprocess.Popen(cmd,cwd=r,stdout=log,stderr=subprocess.STDOUT)
 job['simulation_pid']=p.pid
 (r/'research/kyros_reset360_mame_timed_renderer_worker.json').write_text(json.dumps(job,indent=2)+'\n')
 code=p.wait()
 job.update(exit_code=code,ended=time.time())
 (r/'research/kyros_reset360_mame_timed_renderer_exit.json').write_text(json.dumps(job,indent=2)+'\n')
"""
cmd=['wsl.exe','-d','Ubuntu','--cd',str(ROOT),'--exec','python3','-c',worker]
with (out/'worker.log').open('w') as log:
 p=subprocess.Popen(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
receipt.write_text(json.dumps({'launcher_pid':p.pid,'command':cmd,'qualified_elf_receipt':str(ROOT/'research/kyros_reset360_timed_renderer_v2_exit.json')},indent=2)+'\n')
print(json.dumps({'launcher_pid':p.pid}))
