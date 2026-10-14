"""Actual constant-RAM renderer diagnostic; never CPU/game acceptance."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
SCOPE=HERE/'next_coupled_scope_v2'
JOB=SCOPE/'frame0_constant_fixture_recovery_v2'
CAN=Path(r'D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def entry(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
def wp(p):p=Path(p);return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
def main():
    action=sys.argv[1];assert action in ['launch','worker','status']
    if action=='status':
        out={}
        for name in ['worker.json','pins.json','build_job.json','build_exit.json','run_job.json','run_exit.json']:
            p=JOB/name
            if p.exists():
                x=json.loads(p.read_text());out[name]=x if name!='pins.json' else {'sha256':H(p),'source_count':len(x['source_files'])}
        for name in ['build.log','run.log']:
            p=JOB/name
            if p.exists():out[name]=p.read_text(errors='replace')[-2400:]
        print(json.dumps(out));return
    if action=='launch':
        assert not JOB.exists(),'Observe this registered diagnostic; never restart.'
        closure=json.loads((SCOPE/'source_closure.json').read_text());selected=[p for p in closure['source_files'] if
           Path(p['path']).name in ['alpha68kn_renderer.sv','alpha68kn_video_rom.sv','alpha68kn_gfxmem.sv','sdram_model.h'] or
           Path(p['path']).parent.name=='jtframe_sdram']
        assert all(H(Path(p['path']))==p['combined_sha256'] for p in selected)
        JOB.mkdir();source=JOB/'source';source.mkdir();pins=[]
        for p in selected:
            src=Path(p['path']);dest=source/src.relative_to(SCOPE/'source');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest)
            pins.append(dict(entry(dest),frozen181_sha256=p['combined_sha256']))
        for name in ['build_renderer.sh','render_fixture.sv','render_fixture_main.cpp']:
            src=CAN/'sim'/name;dest=source/'sim'/name;shutil.copy2(src,dest)
            pins.append(dict(entry(dest),source=entry(src)))
        # Explicitly bind only the existing diagnostic fixture's rotation input.
        top=source/'sim/render_fixture.sv';text=top.read_text();old='.video_y(video_y),.video_x(video_x),.video_pen(pen),.flip(flip),.stingray(stingray),'
        assert text.count(old)==1;top.write_text(text.replace(old,old+'.rotate180(1\'b0),'),encoding='utf8',newline='\n')
        for p in pins:p['actual_fixture_sha256']=H(Path(p['path']))
        ref=CAN/'sim/captures/sstingry/attract';rom=Path(json.loads((HERE/'integration_contract.json').read_text())['loader']['download_path'])
        native=HERE/'coupled_boot111/capture/frame_000000.sprites.bin'
        assert H(native)==H(ref/'frame_000000.sprites.bin')
        record={'schema':'actual_sstingry_constant_RAM_fixture_v1','source_files':pins,'background':0,'flip':0,'profile':2,
          'ROM':entry(rom),'strip':entry(native),'MAME_RGB':entry(ref/'frame_000000.rgb'),
          'work_native':entry(HERE/'coupled_boot111/capture/frame_000000.work.bin'),
          'work_MAME':entry(ref/'frame_000000.work.bin'),'fixture_top_only_delta':'Bind rotate180=0 explicitly; actual renderer/videoROM/gfxmem/controller HDL unchanged.',
          'no_CPU_no_actual_game_acceptance':True,'zero_to_two_field_observer_not_started':True,'helper_sha256':H(Path(__file__))}
        save(JOB/'pins.json',record)
        with (JOB/'worker.log').open('w') as f:
            child=subprocess.Popen([sys.executable,'-X','utf8',str(Path(__file__)),'worker'],stdout=f,stderr=subprocess.STDOUT,
              creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        save(JOB/'worker.json',{'pid':child.pid,'started':time.time(),'helper_sha256':H(Path(__file__)),'pins_sha256':H(JOB/'pins.json')})
        print(json.dumps({'worker_pid':child.pid,'pins_sha256':H(JOB/'pins.json'),'source_count':len(pins)}));return
    pins=json.loads((JOB/'pins.json').read_text());source=JOB/'source'
    assert all(H(Path(p['path']))==p['actual_fixture_sha256'] for p in pins['source_files'])
    for stage in ['build','run']:
        command=['wsl.exe','-d','Ubuntu','--cd',str(source),'--exec','/bin/bash','-c',
             'printf "linux_pid=%s\\n" "$$"; exec "$@"',stage+'fixture']
        command+=['/bin/bash','sim/build_renderer.sh'] if stage=='build' else [
             './sim/build/alpha68kn_render_fixture_sim',wp(pins['ROM']['path']),wp(pins['strip']['path']),'0',wp(JOB/'capture'),'0',wp(pins['MAME_RGB']['path'])]
        log=JOB/(stage+'.log')
        with log.open('w') as f:
            child=subprocess.Popen(command,stdout=f,stderr=subprocess.STDOUT,
                  creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
            save(JOB/(stage+'_job.json'),{'pid':child.pid,'worker_pid':os.getpid(),'started':time.time(),'command':command,'pins_sha256':H(JOB/'pins.json')})
            code=child.wait()
        elf=source/'sim/build/alpha68kn_render_fixture_sim'
        save(JOB/(stage+'_exit.json'),{'exit_code':code,'pid':child.pid,'finished':time.time(),'log':entry(log),
            'ELF':entry(elf) if elf.exists() else None,'pins_sha256':H(JOB/'pins.json')})
        if code:raise SystemExit(code)

if __name__=='__main__':main()
