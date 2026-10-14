"""Read-only actual MAME61 CPU-space IACK observer; immutable prior clocked recorder."""
from pathlib import Path
import csv,hashlib,json,os,subprocess,sys,time
SCRIPT_PATH = Path(__file__).resolve()
# Canonical copies live in core/scripts; original frozen copies live in diagnostics.
DEFAULT_EVIDENCE_ROOT = SCRIPT_PATH.parents[1] if SCRIPT_PATH.parent.name == "scripts" else SCRIPT_PATH.parents[3]
EVIDENCE_ROOT_ARGUMENT = os.environ.get("ALPHA68KN_EVIDENCE_ROOT", str(DEFAULT_EVIDENCE_ROOT))
# An explicit Windows override must also resolve when the worker enters Ubuntu WSL.
if os.name != "nt" and len(EVIDENCE_ROOT_ARGUMENT) > 2 and EVIDENCE_ROOT_ARGUMENT[1] == ":":
    EVIDENCE_ROOT_ARGUMENT = "/mnt/" + EVIDENCE_ROOT_ARGUMENT[0].lower() + EVIDENCE_ROOT_ARGUMENT[2:].replace("\\", "/")
ROOT = Path(EVIDENCE_ROOT_ARGUMENT).resolve()
if "--help" in sys.argv or "--show-root" in sys.argv:
    print(json.dumps({"script": str(SCRIPT_PATH), "evidence_root": str(ROOT),
                      "override": "ALPHA68KN_EVIDENCE_ROOT", "simulation_started": False}))
    raise SystemExit(0)


def sibling_script(name):
    candidate = SCRIPT_PATH.parent / name
    return candidate if candidate.exists() else ROOT / "sim/captures/diagnostics" / name


def wsl_script_path():
    # Windows paths must be translated before an explicit Ubuntu Python invocation.
    if os.name == "nt":
        assert SCRIPT_PATH.drive, "Expected absolute Windows script path"
        return "/mnt/" + SCRIPT_PATH.drive[0].lower() + SCRIPT_PATH.as_posix()[2:]
    return str(SCRIPT_PATH)

NAME="irq_sampling_edge_mame61"
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
 if "--worker" not in sys.argv:
  path=ROOT/"research"/(NAME+"_launcher.json")
  assert not path.exists()
  with (ROOT/"research"/(NAME+"_worker.log")).open("w") as log:
   process=subprocess.Popen([sys.executable,"-X","utf8",str(Path(__file__)),"--worker"],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
  path.write_text(json.dumps({"worker_pid":process.pid,"started":time.time(),"script_sha256":sha(__file__)},indent=2)+"\n")
  print(json.dumps({"worker_pid":process.pid,"launcher":str(path)}))
  return
 original=json.loads((ROOT/"research/kyros_reset_raster361_v4_mame_job.json").read_text())
 source=ROOT/"sim/captures/kyros/reset_raster361_v4/loaded_recorder.lua"
 assert sha(source)==original["observer_sha256"]
 cap=ROOT/"sim/captures/kyros"/NAME
 assert not cap.exists()
 cap.mkdir(parents=True)
 body=source.read_text()
 anchor="local function set_input(tag, mask, active)"
 assert body.count(anchor)==1
 extra="""local irq_cpu_space = assert(main.spaces["cpu_space"], "missing actual CPU-space autovector map")
local irq_observer = open("cpu_space_iack.csv")
irq_observer:write("frame,screen_frame,master_ticks,cpu_ticks,address,data,mask,instruction_pc,next_pc\\n")
handles[#handles+1] = irq_cpu_space:install_read_tap(0xfffff0, 0xffffff, "alpha_irq_cpu_space", function(a,d,m)
    irq_observer:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d\\n", frame, screen:frame_number(), machine.time:as_ticks(48000000), machine.time:as_ticks(6000000), a,d,m, main.state["CURPC"] and main.state["CURPC"].value or -1, pc(main)))
    irq_observer:flush()
end)

"""
 observer=cap/"loaded_recorder.lua"
 observer.write_text(body.replace(anchor,extra+anchor))
 command=list(original["command"])
 command[command.index("-autoboot_script")+1]=str(observer)
 command[command.index("-seconds_to_run")+1]="3"
 for flag,filename in [("-wavwrite","audio.wav"),("-aviwrite","video.avi"),("-mngwrite","video.mng")]:
  if flag in command:command[command.index(flag)+1]=str(cap/filename)
 env={**os.environ,"ALPHA_CAPTURE_DIR":str(cap),"ALPHA_CAPTURE_FRAMES":"61","ALPHA_CAPTURE_MODE":"warm-reset"}
 rec={"worker_pid":os.getpid(),"started":time.time(),"frames":61,"command":command,"capture":str(cap),"base_path":str(source),"base_sha256":sha(source),"observer_sha256":sha(observer),"mame_sha256":sha(command[0]),"input_reference_sha256":sha(ROOT/"sim/captures/kyros/warm_reset960_refv2/frame_states.csv"),"scope":"Read-only actual CPU-space autovector tap; identical existing clocked recorder and61-field warm-reset prefix, no CPU/RAM/input patches"}
 with (ROOT/"research"/(NAME+"_run.log")).open("w") as log:
  child=subprocess.Popen(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
  rec["mame_pid"]=child.pid
  (ROOT/"research"/(NAME+"_job.json")).write_text(json.dumps(rec,indent=2)+"\n")
  exit_code=child.wait()
 log=(ROOT/"research"/(NAME+"_run.log")).read_text(errors="replace")
 frames=list(csv.DictReader((cap/"frame_states.csv").open())) if (cap/"frame_states.csv").exists() else []
 taps=list(csv.DictReader((cap/"cpu_space_iack.csv").open())) if (cap/"cpu_space_iack.csv").exists() else []
 rec.update(exit_code=exit_code,ended=time.time(),lua_error="lua error" in log.lower() or (cap/"failure.txt").exists(),frame_rows=len(frames),cpu_space_rows=len(taps),whole_game_acceptance=False,B16_closure=False)
 (ROOT/"research"/(NAME+"_exit.json")).write_text(json.dumps(rec,indent=2)+"\n")
if __name__=="__main__":main()
