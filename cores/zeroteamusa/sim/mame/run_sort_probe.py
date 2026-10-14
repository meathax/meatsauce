import os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
frame=int(sys.argv[1]); inputs=sys.argv[2]
out=ROOT/'sim/results'/f'mame-sort-probe-{frame}'; out.mkdir(parents=True,exist_ok=True)
lua=ROOT/'sim/mame'
env=os.environ.copy()
env.update(CORE_CPU=':maincpu',CORE_SPACE='program',CORE_BYTES='2',CORE_BIG='0',CORE_FRAME=str(frame),
  CORE_OUT=out.as_posix(),CORE_SCRIPT=(lua/'sort_probe.lua').as_posix(),CORE_PLAY=(lua/'play.lua').as_posix(),
  CORE_CAPTURE_SCRIPT=(lua/'capture.lua').as_posix(),CORE_INPUTS=str((ROOT/inputs).resolve()),
  CORE_COLLISION_CASES='0',CORE_AUDIO_STIMULUS='0',CORE_SPRITE_BUFFER='0',
  CORE_READ='work:800:b7ff',CORE_WTAP='cop:400:5ff')
cmd=[r'D:\Arcade\AI\mameexe\mame.exe','zeroteam','-noreadconfig','-nodebug','-nowindow','-video','none','-sound','none',
 '-skip_gameinfo','-nothrottle','-autoboot_delay','0','-autoboot_script',str(lua/'run.lua'),'-rompath',str(ROOT/'roms/source'),
 '-cfg_directory',str(ROOT/'sim/results/mame-config'),'-nvram_directory',str(ROOT/'sim/results/mame-nvram'),'-seconds_to_run',str(frame//55+10)]
r=subprocess.run(cmd,cwd=ROOT,env=env,capture_output=True,text=True,errors='replace',timeout=900)
(out/'capture.log').write_text(r.stdout+r.stderr)
print(r.returncode,r.stdout[-400:])
