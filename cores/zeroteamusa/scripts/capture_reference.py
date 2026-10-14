"""Capture one bounded, pristine MAME 0.289 US reference fixture locally.

Raw memory/register dumps stay under ignored sim/results. This fixture is a
reference, not proof of RTL gameplay or a claim that MAME's known gaps are fixed.
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, re

ROOT=Path(__file__).resolve().parents[1]
GUIDE=Path(r'C:\Users\meath\.agents\skills\mister-arcade-core\assets\core\scripts\mame')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--frame',type=int,default=600)
    parser.add_argument('--inputs',help='Raw-port CSV, delivered only through MAME physical input fields')
    parser.add_argument('--label',help='Keep a new named capture without overwriting older evidence')
    parser.add_argument('--sprite-buffer',action='store_true',help='Observe MAME renderer buffer via read-only save items')
    parser.add_argument('--collision-cases',action='store_true',help='Observe gameplay COP collision operands and results without state writes')
    parser.add_argument('--audio',action='store_true',help='Record original MAME sound output privately at the native OPL sample rate')
    parser.add_argument('--audio-backend',choices=['sdl','none'],default='sdl',help='SDL dummy keeps the sound renderer active without playing on the host')
    args=parser.parse_args()
    kind='play' if args.inputs else 'attract'
    suffix='-'+Path(args.inputs).stem if args.inputs else ''
    if args.label:
        assert re.fullmatch(r'[A-Za-z0-9_-]+',args.label)
        suffix+='-'+args.label
    out=ROOT/'sim/results'/f'mame-{kind}-{args.frame}{suffix}'
    if args.label: assert not out.exists(),'Named capture already exists; retain its evidence'
    out.mkdir(parents=True,exist_ok=True)
    lua=ROOT/'sim/mame'; lua.mkdir(parents=True,exist_ok=True)
    for name in ['capture.lua','run.lua']:
        if not (lua/name).exists(): shutil.copy2(GUIDE/name,lua/name)
    (lua/'PROVENANCE.md').write_text('# Capture helper provenance\n\nAdapted from the installed mister-arcade-core skill assets, `assets/core/scripts/mame/capture.lua` and `run.lua`. The run helper is unchanged; the capture helper adds an optional Zero Team read-only export of the buffered sprite save item. The local play helper supplies physical input fields and observes COP, sound, distance and optional stateful collision operations without writing emulated RAM or registers. Original headers are retained. The skill asset license is GPL-3.0-or-later; exact local helper hashes are recorded with each capture.\n')
    env=os.environ.copy()
    env['CORE_COLLISION_CASES']='1' if args.collision_cases else '0'
    env['CORE_AUDIO_STIMULUS']='1' if args.audio and args.inputs else '0'
    env['CORE_SPRITE_BUFFER']='1' if args.sprite_buffer else '0'
    env.update(CORE_CPU=':maincpu',CORE_SPACE='program',CORE_BYTES='2',CORE_BIG='0',
               CORE_FRAME=str(args.frame),CORE_OUT=out.as_posix(),CORE_SCRIPT=(lua/'capture.lua').as_posix(),
               CORE_READ='ivt:0:3ff,work:800:b7ff,bg_src:b800:bfff,fg_src:c000:c7ff,mg_src:c800:cfff,text_src:d000:dfff,pal_src:e000:efff,sprite_src:f000:ffff,upper_work:10000:1ffff',
               CORE_WTAP='cop:400:5ff,crtc:600:63f,sprite_key:640:6ff,sound:700:71f')
    if args.inputs:
        env.update(CORE_INPUTS=str((ROOT/args.inputs).resolve()),
                   CORE_CAPTURE_SCRIPT=(lua/'capture.lua').as_posix(),CORE_SCRIPT=(lua/'play.lua').as_posix())
    exe=Path(r'D:\Arcade\AI\mameexe\mame.exe')
    command=[str(exe),'zeroteam','-noreadconfig','-nodebug','-nowindow','-video','none','-sound','none',
             '-skip_gameinfo','-nothrottle','-autoboot_delay','0','-autoboot_script',str(lua/'run.lua'),
             '-rompath',str(ROOT/'roms/source'),'-cfg_directory',str(ROOT/'sim/results/mame-config'),
             '-nvram_directory',str(ROOT/'sim/results/mame-nvram'),'-seconds_to_run',str(args.frame//55+10)]
    if args.audio:
        command += ['-wavwrite',str(out/'reference.wav'),'-samplerate','49716']
        command[command.index('-sound')+1]=args.audio_backend
        if args.audio_backend=='sdl':env['SDL_AUDIODRIVER']='dummy'
    result=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,errors='replace',
                          creationflags=subprocess.CREATE_NO_WINDOW,timeout=90)
    (out/'capture.log').write_text(result.stdout+result.stderr)
    for name in ['lua_error.txt','ERROR.txt']:
        if (out/name).exists(): raise RuntimeError((out/name).read_text())
    if result.returncode or 'CORE_CAPTURE_OK' not in result.stdout:
        raise RuntimeError(f'MAME capture exit {result.returncode}: '+(result.stdout+result.stderr)[-2500:])
    if not (out/'reference.png').exists(): raise RuntimeError('No reference image produced')
    meta={'set':'zeroteam','frame':args.frame,'mame':'0.289','directory':out.relative_to(ROOT).as_posix(),
          'audio_capture':{'sample_rate':49716,'backend':args.audio_backend,'dummy_device':args.audio_backend=='sdl'} if args.audio else None,
          'pristine_roms':True,'known_reference_limitations':'MAME marks the target not working; sort/priority behavior is incomplete.',
          'files':{p.name:{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
                   for p in out.iterdir() if p.is_file() and p.name!='capture.log'},
           'helper_hashes':{name:hashlib.sha256((lua/name).read_bytes()).hexdigest() for name in ['capture.lua','run.lua']}}
    if args.inputs:
        meta.update(input_schedule=args.inputs,input_sha256=hashlib.sha256((ROOT/args.inputs).read_bytes()).hexdigest(),
                    playback_sha256=hashlib.sha256((lua/'play.lua').read_bytes()).hexdigest(),
                    input_delivery='Physical ioport fields only; no game RAM, ROM or CPU writes')
    if args.sprite_buffer:
        assert (out/'sprite_buffer.bin').stat().st_size==4096
        meta['sprite_render_source']='Buffered sprite device m_buffered; read-only emu.item export'
    (ROOT/'docs/evidence').mkdir(parents=True,exist_ok=True)
    evidence_name='mame-attract-reference.json' if args.frame==600 else f'mame-reference-{args.frame}.json'
    if args.inputs:evidence_name=f'mame-play-reference-{args.frame}{suffix}.json'
    elif args.label:evidence_name=f'mame-reference-{args.frame}-{args.label}.json'
    (ROOT/'docs/evidence'/evidence_name).write_text(json.dumps(meta,indent=2)+'\n')
    print((out/'manifest.txt').read_text().strip())
    print('Captured '+str(len(meta['files']))+' local reference files; target limitations retained.')

if __name__=='__main__': main()
