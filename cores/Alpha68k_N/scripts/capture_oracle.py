"""Run finite MAME reference recordings and fingerprint the resulting artifacts."""
from pathlib import Path
import argparse
import csv
import hashlib
import json
import os
import subprocess
import sys
import time
from normalize_oracle_display import normalize

ROOT=Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(setname, mode, frames):
    identity=json.loads((ROOT/'research/oracle_identity.json').read_text())
    executable=Path(identity['executable'])
    output=ROOT/'sim/captures'/setname/mode
    output.mkdir(parents=True,exist_ok=True)
    metadata=output/'manifest.json'
    script=ROOT/'sim/mame/capture.lua'
    script_hash=sha(script)
    rom_identity=json.loads((ROOT/'research/rom_manifest.json').read_text())[setname]
    if metadata.exists():
        prior=json.loads(metadata.read_text())
        if (prior['frames']==frames and prior['script_sha256']==sha(script)
            and prior['executable_sha256']==identity['executable_sha256']
            and all((output/p['path']).exists() and sha(output/p['path'])==p['sha256'] for p in prior['artifacts'])):
            normalize(output)
            print('REUSE',setname,mode,frames,flush=True)
            return prior
        raise RuntimeError(f'Existing capture differs; preserve it and select a new run directory: {output}')
    env=dict(os.environ,ALPHA_CAPTURE_DIR=str(output).replace('\\','/'),
             ALPHA_CAPTURE_MODE=mode,ALPHA_CAPTURE_FRAMES=str(frames))
    args=[str(executable),setname,'-rompath',str(ROOT/'roms'),'-noreadconfig','-skip_gameinfo',
          '-video','none','-sound','none','-nothrottle','-noautoframeskip','-frameskip','0',
          '-autoboot_delay','0','-autoboot_script',str(script),'-pluginspath',str(executable.parent/'plugins'),
          '-seconds_to_run',str(int(frames/59.185606)+15),'-snapshot_directory',str(output),
          '-cfg_directory',str(output/'cfg'),'-nvram_directory',str(output/'nvram'),
          '-state_directory',str(output/'states'),'-wavwrite',str(output/'audio.wav')]
    for directory in ['cfg','nvram','states']:(output/directory).mkdir(exist_ok=True)
    start=time.monotonic()
    print('START',setname,mode,frames,flush=True)
    with (output/'mame.log').open('w',encoding='utf-8') as log:
        child=subprocess.Popen(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        (ROOT/'research/capture_live.json').write_text(json.dumps({'pid':child.pid,'set':setname,'mode':mode,'output':str(output),'started':time.time()},indent=2)+'\n')
        try:
            code=child.wait(timeout=180)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
            raise
    content=(output/'mame.log').read_text(errors='replace')
    if code or not (output/'complete.txt').exists() or (output/'failure.txt').exists() or 'Error in' in content or 'error:' in content.lower():
        raise RuntimeError(f'{setname}/{mode} exit={code}; completion={bool((output/"complete.txt").exists())}; log={output/"mame.log"}; {content[-1800:]}')
    assert f'frames={frames}' in (output/'complete.txt').read_text()
    normalize(output)
    snapshots=[]
    for rgb in sorted(output.glob('frame_*.rgb')):
        if '.display.' in rgb.name: continue
        assert rgb.stat().st_size==256*224*3
        prefix=rgb.with_suffix('')
        for suffix,size in [('.pix32',256*224*4),('.work.bin',4096),('.sprites.bin',8192)]:
            assert prefix.with_suffix(suffix).stat().st_size==size
        assert prefix.with_suffix('.png').exists()
        snapshots.append({'frame':int(rgb.stem.split('_')[1]),'drawing_rgb_sha256':sha(rgb), 'display_rgb_sha256':sha(rgb.with_suffix('.display.rgb'))})
    states=list(csv.DictReader((output/'states.csv').open()))
    assert len(states)==len(snapshots) and len(states)>3
    frame_states=list(csv.DictReader((output/'frame_states.csv').open()))
    assert len(frame_states)==frames
    assert [int(s['screen_frame']) for s in frame_states]==list(range(frames))
    histogram=list(csv.DictReader((output/'write_histogram.csv').open()))
    assert histogram and all(0<=int(row['scanline'])<264 for row in histogram)
    if mode=='gameplay':
        actions=list(csv.DictReader((output/'inputs.csv').open()))
        assert any(a['port']=='IN2' and a['active']=='1' for a in actions)
        assert any(a['port']=='IN0' and a['mask']=='128' and a['active']=='1' for a in actions)
    files=[p for p in output.iterdir() if p.is_file() and p.name!='manifest.json']
    result={'set':setname,'mode':mode,'frames':frames,'elapsed_seconds':round(time.monotonic()-start,3),
            'exe_version':identity['version'],'executable_sha256':identity['executable_sha256'],
            'driver_sha256':identity['driver_sha256'],'script_sha256':script_hash,'command':args,
            'rom_regions':[{'name':x['name'],'path':x['path'],'sha256':x['sha256'],'bytes':x['bytes']} for x in rom_identity['regions']],
            'dip_state':{'port':'IN1','value':int(frame_states[0]['in1']),'configuration':'isolated default DIP settings'},
            'beam_convention':'time_until_pos(0,0), screen period and half-pixel rounding; 384x264 raster',
            'native_pixels':{'width':256,'height':224,'layout':'row-major RGB8, unrotated visible area',
                'canonical_source':'displayed texture PNG, inverse pinned ROT90; .display.rgb',
                'diagnostic_source':'screen:pixels drawing buffer; original .rgb/.pix32 retained'},
            'snapshots':snapshots,'artifacts':[{'path':p.name,'bytes':p.stat().st_size,'sha256':sha(p)} for p in files],
            'state_observer':'frame-complete notifier; input changes applied after snapshot for the next frame',
            'write_sweep':'CPU address-space taps; firmware/direct C++ RAM changes require frame-state comparison',
            'limits':['Vector reads observe interrupt service, not physical IRQ pin edges','Gameplay input injection alone does not prove live gameplay; inspect RAM/state/images','Late-stage/ending and non-default DIP/cocktail fixtures remain pending']}
    assert sha(script)==script_hash, 'Recorder changed during capture'
    metadata.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('DONE',setname,mode,len(snapshots),'snapshots',result['elapsed_seconds'],'seconds',flush=True)
    return result


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--sets',nargs='+',default=['kyros','kyrosj','sstingry'])
    parser.add_argument('--modes',nargs='+',default=['attract','gameplay'])
    parser.add_argument('--frames',type=int,default=1800)
    options=parser.parse_args()
    results=[]
    try:
        for name in options.sets:
            for mode in options.modes:results.append(record(name,mode,options.frames))
        summary={'status':'recorded','runs':[{'set':r['set'],'mode':r['mode'],'frames':r['frames'],'snapshots':r['snapshots']} for r in results]}
        (ROOT/'research/capture_status.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8',newline='\n')
    except Exception as error:
        (ROOT/'research/capture_status.json').write_text(json.dumps({'status':'failed','error':str(error)},indent=2)+'\n',encoding='utf-8',newline='\n')
        raise


if __name__=='__main__':main()
