"""Completed private actualCPU q61 qualifier; no replay or state mutation."""
from pathlib import Path
import csv,hashlib,json,os
R=Path(__file__).resolve().parents[1];N="kyros_sound_rom_q61"
A=R/"sim/captures/rtl"/N;B=R/"sim/captures/rtl/kyrosj_current720_curvefixed_drive"
def sha(p):
 p=Path(p)
 if os.name=="nt" and str(p).replace("\\","/").startswith("/mnt/d/"):p=Path("D:/"+str(p).replace("\\","/")[7:])
 return hashlib.sha256(p.read_bytes()).hexdigest()
def js(p):return json.loads(p.read_text())
def rows(p):
 with p.open(newline="") as f:return list(csv.DictReader(f))
def before(rs):return [x for x in rs if int(x["frame"])<61]
build=js(R/"research"/(N+"_build_exit.json"));ex=js(R/"research"/(N+"_exit.json"));job=js(R/"research"/(N+"_job.json"))
assert build["exit_code"]==0 and ex["exit_code"]==0,"Authentic build/run mustcomplete0"
frames=rows(A/"frames.csv");reference=before(rows(B/"frames.csv"))
inputs=rows(A/"applied_inputs.csv");reference_inputs=before(rows(B/"applied_inputs.csv"))
audio=rows(A/"audio_events.csv");reference_audio=before(rows(B/"audio_events.csv"))
# Tick positions are part of actual sound/output trace parity.
audio_exact=audio==reference_audio
ep=rows(A/"epoch_events.csv");old_ep=before(rows(B/"epoch_events.csv"))
epoch_exact=ep==old_ep
pics=[p for p in sorted(A.glob("frame_*.rgb")) if int(p.stem.split("_")[1])<61]
rgb=[{"frame":int(p.stem.split("_")[1]),"reference_exists":(B/p.name).exists(),"candidate_sha256":sha(p),"reference_sha256":sha(B/p.name) if (B/p.name).exists() else None,"full_bytes_equal":(B/p.name).exists() and p.read_bytes()==(B/p.name).read_bytes()} for p in pics]
contract=js(A/"sound_rom_contract.json")
samples=rows(A/"sound_rom_samples.csv")
checks={"actualbuild0":build["exit_code"]==0,"actualsimulation0":ex["exit_code"]==0,
"actual_ELF_pin":sha(A/"alpha68kn_sound_rom_q61_sim")==ex["actual_ELF_sha256"],
"pinned_candidate_source":sha(Path(job["candidate_path"]))==job["candidate_sha256"],
"production_frozen":all(sha(Path("/mnt/d/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N")/n)==h for n,h in job["production_source_pins"].items()) if not (Path("D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N")).exists() else all(sha(Path("D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N")/n)==h for n,h in job["production_source_pins"].items()),
"all61_actualframes":len(frames)==61 and [int(x["frame"]) for x in frames]==list(range(61)),
"all_CPU_frame_metrics_exact":frames==reference,"all_actual_inputs_exact":inputs==reference_inputs,
"accepted_chip_and_DAC_rows_tick_exact":audio_exact,
"main_epoch_irq_latch_rows_tick_exact":epoch_exact,
"all_retained_available_native_RGB_exact":bool(rgb) and all(x["full_bytes_equal"] for x in rgb),
"actual_CEN_ROMchecks_nonzero":contract["ROM_CEN_checks"]>0,
"actual_T2_ROMaccept_nonzero":contract["T2_accept_checks"]>0,
"actual_non_CEN_holdchecks_nonzero":contract["address_hold_checks"]>0,
"allROM_hold_mismatches_zero":contract["mismatch_count"]==0,
"retainedsample_bytes_match_ROM":bool(samples) and all(x["DI"]==x["expected"] for x in samples),
"nonconstant_sample_expected":len({x["expected"] for x in samples})>1}
receipt={"scope":"Finite private actualCPU hardware-path soundROM q61 versus existing actualJapan720 prefix; no fullMAMEgraphics/effects/resources/physical acceptance.",
"checks":checks,"all_checks_strict_boolean_true":all(v is True for v in checks.values()),
"actual_terminal":ex,"ROM_contract":contract,"frames":len(frames),"RGB":rgb,
"chip_writes":sum(x["kind"]=="write" for x in audio),"DACwrites":sum(x["kind"]=="dac" for x in audio),"epoch_rows":len(ep),
"first_audio_difference":next(({"index":i,"candidate":x,"reference":y} for i,(x,y) in enumerate(zip(audio,reference_audio)) if x!=y),None),
"candidate_audio_rows":len(audio),"reference_audio_rows":len(reference_audio),
"first_frame_difference":next(({"index":i,"candidate":x,"reference":y} for i,(x,y) in enumerate(zip(frames,reference)) if x!=y),None),
"finite_q61_pass":all(v is True for v in checks.values()),"full_B03_B06_pass":False,"canonical_MAME_graphics_pass":False,
"limits":["Original retainednative same-game prefix parity, not waiver for knownMAMEatomicgraphics mismatch.","No full720replay/wholegame/P5/physical/timing-resource closure.","Read-onlyobserverCPU sampling check uses pinnedunmodified payloadbyte, neverdrivesCPU/ROM/RAM."],
"evidence_pins":[{"path":str(p),"sha256":sha(p),"bytes":p.stat().st_size} for p in [A/"sound_rom_contract.json",A/"sound_rom_samples.csv",A/"frames.csv",A/"audio_events.csv",A/"epoch_events.csv",A/"applied_inputs.csv",Path(__file__)]]}
f=R/"research"/(N+"_verification.json");f.write_text(json.dumps(receipt,indent=2)+"\n")
print(json.dumps({"checks_true":sum(v is True for v in checks.values()),"checks_count":len(checks),"failed":[k for k,v in checks.items() if v is not True],"ROMchecks":contract,"writes":[receipt["chip_writes"],receipt["DACwrites"]],"receipt_sha256":sha(f)}))
raise SystemExit(0 if receipt["finite_q61_pass"] else 1)
