"""Reuse retained isolated audio evidence only where exact source/data pins justify its scope."""
from pathlib import Path
import json,hashlib,re
R=Path(__file__).resolve().parents[1];C=Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N")
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def js(p):return json.loads(p.read_text())
def manifest(p):
 d={}
 for l in p.read_text().splitlines():
  h,n=l.split(None,1);d[n.strip()]=h
 return d
def norm(s):return re.sub(r"\s+","",re.sub(r"//[^\n]*","",s))
sm=R/"research/soundchips_inputs.sha256";sr=js(R/"research/soundchips_contracts.json");pins=manifest(sm)
olds=R/"rtl/alpha68kn_soundchips.sv";news=C/"rtl/alpha68kn_soundchips.sv"
oldtext=olds.read_text();newtext=news.read_text()
def phase(s):
 start=s.index("always @(posedge clk) begin");end=s.index("// YM2203",start)
 return s[start:end]
def ay(s):return s[s.index("a68n_ay49 #"):s.index("endmodule")]
ays=[n for n in pins if n.startswith("rtl/vendor/ay49/")]
freq_checks={"actual_original_soundchips_exit0":sr["exit_code"]==0,
"actual_manifest_pin":sha(sm)==sr["source_manifest_sha256"],
"actual_original_ELF_pin":sha(R/"sim/build/alpha68kn_soundchips_sim")==sr["elf_sha256"],
"old_wrapper_matches_original_manifest":sha(olds)==pins["rtl/alpha68kn_soundchips.sv"],
"all8_external_AY_modules_current_exact":len(ays)==8 and all(sha(C/n)==pins[n] for n in ays),
"current_AY_instances_controls_parameters_exact":norm(ay(oldtext))==norm(ay(newtext)),
"current_shared_phase_write_counter_block_exact":norm(phase(oldtext))==norm(phase(newtext))}
log=R/"research/soundchips_contracts.log";lt=log.read_text()
freq_checks["actual_tone_period0_and1_384clocks_recorded"]=all(f"tone_period={n} rise_gap_clocks=384" in lt for n in [0,1])
freq_checks["actual_tone_period37_14208clocks_recorded"]="tone_period=37 rise_gap_clocks=14208" in lt
mixmanifest=R/"research/mixer_ymfm_contract_manifest.json";mix=js(mixmanifest);mi=R/"research/mixer_ymfm_inputs.sha256";mp=manifest(mi)
mixchecks={"actual_current_nominal_mixer_contract_exit0":mix["contract"]["exit_code"]==0,
"actual_current_mixer_manifest_pin":sha(mi)==mix["source_manifest_sha256"],
"actual_original_mixer_ELF_pin":sha(R/"sim/build/alpha68kn_mixer_sim")==mix["executable_sha256"],
"current_production_mixer_exact":sha(C/"rtl/alpha68kn_mixer.sv")==mp["rtl/alpha68kn_mixer.sv"],
"original_golden_test_source_exact":sha(R/"sim/mixer_main.cpp")==mp["sim/mixer_main.cpp"]}
comp=js(R/"research/audio_component_curve_fixed.json");windows=[]
for x in comp["windows"]:
 windows.append({"second":x["second"],"devices":{k:{q:v.get(q) for q in ["mame_mean","mame_ac_rms","rtl_mean","rtl_ac_rms","ac_rms_ratio"]} for k,v in x["devices"].items()}})
paths=[]
for key in ["mame_path","rtl_path"]:
 q=R/comp[key].replace("\\","/");paths.append(q)
componentchecks={"retained_MAME_component_data_pin":sha(paths[0])==comp["mame_sha256"],
"retained_actual_RTL_component_data_pin":sha(paths[1])==comp["rtl_sha256"],
"source_activity_ok":comp["source_activity_ok"] is True}
out={"scope":"Current source-bound externalAY tone contracts, current nominal mixer arithmetic, and retained actual isolated-command per-route moments. No new simulation/compile, no phase-identicalPCM/physical calibration.",
"externalAY_checks":freq_checks,"current_externalAY_tone_reuse_pass":all(x is True for x in freq_checks.values()),
"measured_tone":{"period0and1_gap_masterticks":384,"period0and1_frequency_Hz":48000000/384,"period37_gap_masterticks":14208,"period37_frequency_Hz":48000000/14208},
"nominal_mixer_checks":mixchecks,"current_nominal_mixer_reuse_pass":all(x is True for x in mixchecks.values()),
"mixer_coverage":{"vectors":mix["vectors"],"sample_pulses":mix["sample_pulses"],"scope":mix["scope"],"oracle":mix["oracle"]},
"retained_component_checks":componentchecks,"retained_component_data_reuse":all(x is True for x in componentchecks.values()),
"per_route_moments":windows,
"correction":"Original punch native capture has final mixedPCM only, but existing corrected1800 isolated-command replay DOES retain actual per-chip component moments. ExternalAY pitch and nominal route arithmetic already have isolated contracts; do not demand another capture for those source-valid scopes.",
"limits":["Whole-graph YM FM/SSG current pitch is not implied by the externalAY contract. Current wrapper/readback and YM dependencies differ from the original soundchips manifest; only unchanged externalAY path is reused.",
"Seven-vector nominal mixer arithmetic is byte-identical currentRTL; the per-route1800 data is retained finite command-replay moment evidence, not naturalCPU action acceptance or entire current sound graph equivalence.",
"One 512sample mixed noise RMSdifference13.99% is descriptive, not a mixgain gate without phase/statistical qualification.",
"Broad P5 effects/action semantics and physical analog balance remain open."],
"evidence_pins":[{"path":str(q),"sha256":sha(q)} for q in [sm,R/"research/soundchips_contracts.json",log,olds,news,mixmanifest,mi,R/"sim/mixer_main.cpp",R/"research/audio_component_curve_fixed.json",*paths,Path(__file__)]],
"fullP5pass":False,"fullB03_B06pass":False}
p=R/"research/kyros_audio_existing_contract_reuse.json";p.write_text(json.dumps(out,indent=2)+"\n")
print(json.dumps({"externalAY_checks":freq_checks,"mixer_checks":mixchecks,"component_checks":componentchecks,"per_route_moments":windows,"receipt_sha256":sha(p)}))
# Partial retention is recorded honestly. A failed source pin remains a real reuse limitation.
raise SystemExit(0 if out["current_externalAY_tone_reuse_pass"] and out["current_nominal_mixer_reuse_pass"] and out["retained_component_data_reuse"] else 1)
