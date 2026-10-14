"""Single officialMAME sound reference; no native replay or state writes."""
import csv,hashlib,json,os,re,subprocess,time
from pathlib import Path
R=Path(__file__).resolve().parents[1]
N="kyrosj_sound_fulltap720"
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(n,j): (R/"research"/(N+n+".json")).write_text(json.dumps(j,indent=2)+"\n",encoding="utf-8")
orig=R/"sim/mame/capture.lua"
assert sha(orig)=="174ed050b8776e11745dfb0211ee42995e582c91f9a5f110665663f368ab8c6c"
exe=R/"tools/mame0289/mame.exe"
assert sha(exe)=="af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3"
ref=json.loads((R/"sim/captures/kyrosj/gameplay/manifest.json").read_text())
native=json.loads((R/"research/kyrosj_current720_curvefixed_exit.json").read_text())
assert ref["set"]=="kyrosj" and native["game"]=="kyrosj" and native["exit_code"]==0
assert sha(R/"roms/kyrosj/download.bin")==native["rom_sha256"]
assert all(sha(R/x["path"])==x["sha256"] for x in ref["rom_regions"])
lua=orig.read_text(encoding="utf-8")
old='if frame < 260 or (frame >= 590 and frame < 610) or (frame >= 1190 and frame < 1210) then'
new='if area == "sound_io" or area == "sound_latch_write" or (area == "sound_memory" and address == 0xe004) then'
assert lua.count(old)==1;lua=lua.replace(old,new)
old='if sample_frames[frame] or frame == total-1 then snapshot() end'
assert lua.count(old)==1;lua=lua.replace(old,'if frame == 60 or frame == 600 or frame == 701 or frame == 719 then snapshot() end')
for line in ['    dump(prefix .. ".work.bin",space:read_range(0x020000,0x020fff,8))\n','    dump(prefix .. ".sprites.bin",space:read_range(0x040000,0x041fff,8))\n']:
 assert lua.count(line)==1;lua=lua.replace(line,'')
script=R/"sim/mame"/(N+".lua");script.write_text(lua,encoding="utf-8")
out=R/"sim/captures/kyrosj"/N
assert not out.exists(),"Preserve any existing capture; no repeat"
out.mkdir()
for x in ["cfg","nvram","states"]:(out/x).mkdir()
cmd=[str(exe),"kyrosj","-rompath",str(R/"roms"),"-noreadconfig","-skip_gameinfo","-video","none","-sound","none","-nothrottle","-noautoframeskip","-frameskip","0","-autoboot_delay","0","-autoboot_script",str(script),"-pluginspath",str(R/"tools/mame0289/plugins"),"-seconds_to_run","20","-snapshot_directory",str(out),"-cfg_directory",str(out/"cfg"),"-nvram_directory",str(out/"nvram"),"-state_directory",str(out/"states"),"-wavwrite",str(out/"audio.wav")]
env=os.environ.copy();env.update(ALPHA_CAPTURE_DIR=str(out),ALPHA_CAPTURE_MODE="gameplay",ALPHA_CAPTURE_FRAMES="720")
job={"scope":"OfficialpinnedMAME KyrosJapan720 unconditional sound/latch/DAC reference; legal original same gameplay controls, read-only observers; no RTL replay","command":cmd,"exe_sha256":sha(exe),"original_script_sha256":sha(orig),"probe_script_sha256":sha(script),"runner_sha256":sha(Path(__file__)),"native_exit_sha256":sha(R/"research/kyrosj_current720_curvefixed_exit.json"),"native_ports_sha256":sha(R/"sim/captures/rtl/kyrosj_current720_curvefixed_drive/applied_inputs.csv"),"original_reference_manifest_sha256":sha(R/"sim/captures/kyrosj/gameplay/manifest.json"),"runtime_profile":"kyrosj","ROM_regions":ref["rom_regions"],"native_download_sha256":native["rom_sha256"],"frames":720,"full_sound_tap_condition":new,"representative_frames":[60,600,701,719],"started":time.time()}
write("_job",job)
with (out/"mame.log").open("w",encoding="utf-8") as log:
 proc=subprocess.Popen(cmd,env=env,cwd=R,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
 job["actual_mame_pid"]=proc.pid;write("_job",job);code=proc.wait()
write("_exit",{"actual_mame_pid":proc.pid,"exit_code":code,"ended":time.time(),"command":cmd,"exe_sha256":sha(exe),"probe_script_sha256":sha(script),"capture":str(out)})
print(json.dumps({"actual_mame_pid":proc.pid,"exit_code":code,"capture":str(out),"job":N+"_job.json"}))
raise SystemExit(code)
