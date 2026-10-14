"""Qualify the existing single detached q61 run; never launch or restart simulation."""
from pathlib import Path
import hashlib,json,subprocess,sys,time
R=Path(__file__).resolve().parents[1];N="kyros_sound_rom_q61"
C=Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N")
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(n,j):(R/"research"/(N+"_"+n+".json")).write_text(json.dumps(j,indent=2)+"\n")
terminal=R/"research"/(N+"_exit.json")
deadline=time.time()+1800
while not terminal.exists():
 b=R/"research"/(N+"_build_exit.json")
 if b.exists() and json.loads(b.read_text())["exit_code"]!=0:
  write("finalizer_exit",{"exit_code":2,"reason":"Actual build failed; original receipt retained. No replay restart.","build":json.loads(b.read_text())})
  raise SystemExit(2)
 if time.time()>deadline:
  write("finalizer_exit",{"exit_code":3,"reason":"No actual simulation terminal by bounded observer deadline; worker is not restarted or killed."})
  raise SystemExit(3)
 time.sleep(2)
ex=json.loads(terminal.read_text())
if ex["exit_code"]!=0:
 write("finalizer_exit",{"exit_code":4,"reason":"Actual simulation failed; original receipt retained. No restart.","actual":ex})
 raise SystemExit(4)
verify=R/"scripts/verify_kyros_sound_rom_q61.py"
p=subprocess.run([sys.executable,"-X","utf8",str(verify)],cwd=R,text=True,capture_output=True)
write("check_exit",{"exit_code":p.returncode,"stdout":p.stdout,"stderr":p.stderr,"verifier_sha256":sha(verify),"actual_terminal_sha256":sha(terminal)})
if p.returncode:
 write("finalizer_exit",{"exit_code":p.returncode,"reason":"Actual decisive verifier failed; complete checks/errors retained."})
 raise SystemExit(p.returncode)
v=R/"research"/(N+"_verification.json");j=json.loads(v.read_text())
video=C/"research/video_rom_aligned_candidate/miter_exit.json"
vj=json.loads(video.read_text())
job=json.loads((R/"research"/(N+"_job.json")).read_text())
vs=job["production_source_pins"]["rtl/alpha68kn_video_rom.sv"]
join={"actual_native61_verification_sha256":sha(v),"video_miter_path":str(video),"video_miter_sha256":sha(video),
"video_miter_retained_receipt":vj,"frozen_video_ROM_sha256":vs,
"video_source_join_exact":vj.get("files",{}).get("alpha68kn_video_rom.sv")==vs,
"finite_realCPU61_pass":j["finite_q61_pass"],
"scope":"One coupled realCPU Japan61 replay of exact-cycle soundROM candidate and current functional-video candidate; existing isolated video cycle miter joined. Current isolated video RAM inference FAILED and is not accepted by functional replay.",
"full_sound_acceptance":False,"canonical_MAME_graphics_pass":False,"fitted_resource_timing_pass":False,"RBF_created":False}
write("video_join",join)
write("finalizer_exit",{"exit_code":0,"finite_q61_pass":j["finite_q61_pass"],"video_source_join_exact":join["video_source_join_exact"]})
entries=[]
for x in [R/"scripts/prepare_kyros_sound_rom_q61.py",verify,Path(__file__),v]+sorted((R/"research").glob(N+"_*.json")):
 if x.name==N+"_import_manifest.json":continue
 rel=x.relative_to(R).as_posix()
 if any(a["relative_path"]==rel for a in entries):continue
 entries.append({"relative_path":rel,"sha256":sha(x),"bytes":x.stat().st_size})
write("import_manifest",{"files":entries,"scope":"Finite actual CPU61 and read-only ROM/data/address acceptance only; retained old capture/build roots remain ignored recovery.","capture_root":str(R/"sim/captures/rtl"/N)})
print(json.dumps({"actual_verifier_exit":p.returncode,"strict_true":sum(x is True for x in j["checks"].values()),"checks":len(j["checks"]),"video_source_join_exact":join["video_source_join_exact"],"manifest_sha256":sha(R/"research"/(N+"_import_manifest.json"))}))
