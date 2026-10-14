"""Qualify completed officialMAME reference against retained native720; no replay."""
import csv,hashlib,json
from pathlib import Path
R=Path(__file__).resolve().parents[1];N="kyrosj_sound_fulltap720"
M=R/"sim/captures/kyrosj"/N;T=R/"sim/captures/rtl/kyrosj_current720_curvefixed_drive"
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def js(p):return json.loads(p.read_text(encoding="utf-8-sig"))
def rows(p):
 with p.open(encoding="utf-8-sig",newline="") as f:return list(csv.DictReader(f))
def cmp(a,b,key):
 aa,bb=list(map(key,a)),list(map(key,b));i=next((i for i,(x,y) in enumerate(zip(aa,bb)) if x!=y),min(len(aa),len(bb)) if len(aa)!=len(bb) else None)
 return {"reference_rows":len(a),"native_rows":len(b),"ordered_data_equal":aa==bb,"common_prefix_equal":aa[:min(len(a),len(b))]==bb[:min(len(a),len(b))],"field_label_differences":sum(int(x["frame"])!=int(y["frame"]) for x,y in zip(a,b)),"first_difference_index":i,"reference_first":a[i] if i is not None and i<len(a) else None,"native_first":b[i] if i is not None and i<len(b) else None}
ex=js(R/"research"/(N+"_exit.json"));job=js(R/"research"/(N+"_job.json"))
original=js(R/"sim/captures/kyrosj/gameplay/manifest.json");native=js(R/"research/kyrosj_current720_curvefixed_exit.json")
states=rows(M/"frame_states.csv");inputs=rows(T/"applied_inputs.csv");idx={int(x["frame"]):x for x in states}
pairs=[("controls","in0"),("dips","in1"),("coins_n","in2")]
inputdiff=[{"native":x,"mame":idx.get(int(x["frame"]))} for x in inputs if int(x["frame"]) in idx and any(int(x[k])!=int(idx[int(x["frame"])][v]) for k,v in pairs)]
oldstates=rows(R/"sim/captures/kyrosj/gameplay/frame_states.csv")[:720]
oracle_state_equal=states==oldstates
events=rows(M/"events.csv");ne=rows(T/"audio_events.csv")
a=[x for x in events if x["area"]=="sound_io"];b=[x for x in ne if x["kind"]=="write"]
key=lambda x:(int(x["address"]),int(x["data"]))
chips=cmp(a,b,key)
epoch=rows(T/"epoch_events.csv")
ml=[x for x in events if x["area"]=="sound_latch_write"]
nl=[{"frame":x["frame"],"address":x["address"],"data":str(int(x["data_out"])),"mask":str(65280)} for x in epoch if int(x["address"])==0xe0000 and x["iack"]=="0" and x["rw"]=="0" and x["uds_n"]=="0"]
latches=cmp(ml,nl,lambda x:(int(x["address"]),int(x["data"])>>8,int(x["mask"])))
da=[x for x in events if x["area"]=="sound_memory" and int(x["address"])==0xe004]
db=[x for x in ne if x["kind"]=="dac"]
dac=cmp(da,db,lambda x:int(x["data"]))
old=[x for x in rows(R/"sim/captures/kyrosj/gameplay/events.csv") if x["area"]=="sound_io" and int(x["frame"])<720]
covered=lambda x:int(x["frame"])<260 or 590<=int(x["frame"])<610
sparse=cmp(old,[x for x in b if covered(x)],key)
ports=set(int(x["address"]) for x in a+b)
chip_projection={}
for name,ps in [("YM2203",{16,17}),("AY1",{128,129}),("AY2",{144,145})]:
 chip_projection[name]=cmp([x for x in a if int(x["address"]) in ps],[x for x in b if int(x["address"]) in ps],key)
checks={"actual_MAME_terminal_zero":ex["exit_code"]==0,"actual_original_native_terminal_zero":native["exit_code"]==0,
"actual_profile_kyrosj":original["set"]==native["game"]==job["runtime_profile"]=="kyrosj",
"pinned_official_exe":sha(Path(job["command"][0]))==job["exe_sha256"]==original["executable_sha256"],
"probe_source_pin":sha(R/"sim/mame"/(N+".lua"))==job["probe_script_sha256"],
"original_sparse_source_pin":sha(R/"sim/mame/capture.lua")==job["original_script_sha256"]==original["script_sha256"],
"original_native_inputs_unchanged":sha(T/"applied_inputs.csv")==job["native_ports_sha256"],
"native_payload_pin":sha(R/"roms/kyrosj/download.bin")==native["rom_sha256"]==job["native_download_sha256"],
"all_original_MAME_ROM_regions_unchanged":all(sha(R/x["path"])==x["sha256"] for x in original["rom_regions"]),
"720_states_complete":len(states)==720 and [int(x["frame"]) for x in states]==list(range(720)),
"same_observed_ports_all_native_rows":not inputdiff and len(inputs)>=720,
"entire_original_MAME720_state_prefix_equal":oracle_state_equal,
"actual_complete_marker":(M/"complete.txt").read_text().startswith("frames=720\n"),
"no_Lua_failure":not (M/"failure.txt").exists() and "ALPHA_CAPTURE_FAILED" not in (M/"mame.log").read_text(errors="replace"),
"unconditional_sound_tap_source":job["full_sound_tap_condition"] in (R/"sim/mame"/(N+".lua")).read_text(),
"supported_chip_ports_only":ports<={16,17,128,129,144,145},
"original_sparse_covered_windows_equal":sparse["ordered_data_equal"] and sparse["field_label_differences"]==0,
"full720_chip_port_data_equal":chips["ordered_data_equal"],
"full720_chip_field_labels_equal":chips["field_label_differences"]==0,
"full720_main_latch_data_equal":latches["ordered_data_equal"],
"full720_main_latch_field_labels_equal":latches["field_label_differences"]==0,
"full720_DAC_data_equal":dac["ordered_data_equal"],
"full720_DAC_field_labels_equal":dac["field_label_differences"]==0}
paths=[R/"scripts"/("run_"+N+".py"),Path(__file__),R/"sim/mame"/(N+".lua"),R/"research"/(N+"_job.json"),R/"research"/(N+"_exit.json"),M/"events.csv",M/"frame_states.csv",M/"complete.txt",M/"audio.wav",T/"audio_events.csv",T/"epoch_events.csv",T/"applied_inputs.csv",R/"sim/mame/capture.lua",R/"sim/captures/kyrosj/gameplay/manifest.json"]
out={"scope":"Actual officialMAME KyrosJapan720 unconditional sound reference versus existing actualnative720; no native replay, broad sound/effects/PCM/graphics/current-source/physical pass.",
"checks":checks,"checks_true":sum(v is True for v in checks.values()),"checks_count":len(checks),"all_checks_strict_boolean_true":all(v is True for v in checks.values()),
"actual_terminal":ex,"original_native_terminal":native,
"correction_to_initial_sound_audit":{"original":"kyros_sound_acceptance_contract_audit.json","reason":"Original MAME observer source lines54-58 intentionally writes detailed events only frame<260/590-609/1190-1209;114vs406 is uncovered scope, not a full720 sequence failure. Original audit retained.",
"original_source_sha256":job["original_script_sha256"],"explicit_input_mapping":dict(pairs),"original_audit_input_compare_supported":False,"actual_mapped_native_rows":len(inputs),"actual_mapped_input_differences":len(inputdiff),"reference_profile":"kyrosj","sparse_covered_windows":sparse},
"chip_port_writes":chips,"per_chip":chip_projection,"main_latch_writes":latches,"DAC_writes":dac,
"input_first_difference":inputdiff[0] if inputdiff else None,
"original_MAME720_state_prefix_exact":oracle_state_equal,
"finite_Japan720_ordered_sound_data_pass":chips["ordered_data_equal"] and latches["ordered_data_equal"] and dac["ordered_data_equal"],
"full_B03_B06_acceptance":False,"full_P5_acceptance":False,"whole_game_acceptance":False,
"remaining":["Hit/jump/pickup/game-over/restart semantic qualification per approved P5/P7; finite event parity alone is not every effect.",
"720 original native compiled-source lineage still originalparent ff746d2 pluscurve5 adaptation; no unsupported current-source parity.",
"Physical listening P9; phase-identicalPCM not required.","Stingray remains separate; known atomic graphics failures preserved."],
"evidence_pins":[{"relative_path":str(p.relative_to(R)).replace("\\","/"),"sha256":sha(p),"bytes":p.stat().st_size} for p in paths],
"source_derivation":"Original exactpinned174ed050 observer, legalcontrol drive_inputs unchanged; only unconditional sound/latch/DAC event condition, four snapshots and removedRAM/sprite dumps. No RAM/ROM/CPU state writes."}
dest=R/"research"/(N+"_verification.json");dest.write_text(json.dumps(out,indent=2)+"\n",encoding="utf-8")
md=R/"research"/(N+"_correction.md")
md.write_text("# Japan sound reference correction\n\nOriginal MAME is explicitly kyrosj with all pinned ROM regions unchanged. Actual mapped controls/dips/coins_n equal in0/in1/in2 across all native720 applied rows. Original detailed event windows were sparse, so114-versus406 did not establish an RTL failure. Preserve that initial audit; this receipt corrects its scope.\n\nThe one officialMAME unconditional reference completed720 with exit0 and identical original720 CPU-state/port rows. Full chip writes: "+str(chips)+"\n\nMain latch writes: "+str(latches)+"\n\nDAC writes: "+str(dac)+"\n\nNo native replay. Broad effect/graphics/PCM/current-source/physical acceptance remains open.\n",encoding="utf-8")
print(json.dumps({"checks_true":out["checks_true"],"checks_count":len(checks),"failed":[k for k,v in checks.items() if not v],"ports":chips,"latches":latches,"DAC":dac,"verification_sha256":sha(dest),"correction_sha256":sha(md),"verifier_sha256":sha(Path(__file__))}))
raise SystemExit(0 if all(v is True for v in checks.values()) else 1)
