"""Current retained chip/mixer evidence with exact compiled hardware source binding; no rerun."""
from pathlib import Path
import json,hashlib
R=Path(__file__).resolve().parents[1];C=Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn/cores/Alpha68k_N")
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def js(p):return json.loads(p.read_text())
cp=R/"research/kyros_punch_noise_chip_contract_exit.json";chip=js(cp)
mp=R/"research/kyros_merged_lifecycle_v2_compiled_exit.json";merged=js(mp)
current=merged["production_source_pins"];bindings=[];missing=[]
for old,h in chip["source_pins"].items():
 if not old.startswith("rtl/"):continue
 matches=[n for n,x in current.items() if x==h and n.startswith("rtl/")]
 if old in matches:target=old
 elif len(matches)==1:target=matches[0]
 else:missing.append({"original":old,"sha256":h,"matches":matches});continue
 bindings.append({"original":old,"current":target,"sha256":h,"current_file_pin_exact":sha(C/target)==h})
log=R/"research/kyros_punch_noise_chip_contract_run.log";lt=log.read_text()
checks={"actual_current_chip_terminal0":chip["exit_code"]==0,
"original_current_chip_checks_all_boolean_true":all(x is True for x in chip["checks"].values()),
"actual_log_pin":sha(log)==chip["run_log_sha256"],
"actual_current_chip_ELF_pin":sha(R/"sim/build/alpha68kn_soundchips_sim")==chip["executable_sha256"],
"actual_current_chip_test_source_pin":sha(R/"sim/soundchips_main.cpp")==chip["host_sha256"],
"every_chip_hardware_pin_bound_to_current_compiled_code":not missing and len(bindings)>40 and all(x["current_file_pin_exact"] is True for x in bindings),
"current_realCPU_build_exit0":merged["exit_code"]==0,
"measured_AY_period0and1_gap384":all(f"tone_period={p} rise_gap_clocks=384" in lt for p in [0,1]),
"measured_AY_period37_gap14208":"tone_period=37 rise_gap_clocks=14208" in lt,
"measured_AY_envelope0and3_gaps192and1152":all(t in lt for t in ["envelope_period=0 levels=16 change_gap_clocks=192","envelope_period=3 levels=16 change_gap_clocks=1152"]),
"measured_YM_timerA_status_and_clear":"ym_timer_A=pass" in lt,
"measured_active_noise_cleanup_and_warmreset":"noise_transitions=118 cleanup_silent_clocks=500000 warm_reset_B=pass" in lt}
previous=js(R/"research/kyros_audio_existing_contract_reuse.json")
checks.update({"current_nominal_mixer_source_ELF_golden_pins":all(x is True for x in previous["nominal_mixer_checks"].values()),
"retained_MAME_and_RTL_component_data_pins":all(x is True for x in previous["retained_component_checks"].values())})
out={"scope":"Current soundchip graph source-bound to actual isolated tone/envelope/timer/noise/reset receipt, current nominal mixer arithmetic and retained per-route waveform moments. No new test/replay.",
"checks":checks,"all_checks_strict_boolean_true":all(x is True for x in checks.values()),
"source_bindings":bindings,"missing_bindings":missing,"chip_clock_Hz":2000000,
"measured_AY_frequency_Hz":{"period0":125000,"period1":125000,"period37":48000000/14208},
"current_chip_receipt_sha256":sha(cp),"current_compiled_production_receipt_sha256":sha(mp),
"mixer_coverage":previous["mixer_coverage"],"retained_per_route_moments":previous["per_route_moments"],
"superseded_reuse_attempt_sha256":sha(R/"research/kyros_audio_existing_contract_reuse.json"),
"corrections":["The older soundchips ELF was superseded by the later actual punch_noise_chip_contract ELF, which retains measured pitch/envelope cases and exact current hardware pins.",
"External AY graph has seven modules; the superseded original-manifest audit's assumed eight-file guard was incorrect and remains recorded as failure.",
"Per-route moment data already exists in corrected1800 command replay; the original punch CPU capture only having mixed PCM is not a project-wide route-data absence."],
"limits":["Measured frequency contracts cover externalAY period0/1/37 and envelope0/3; YM timer status/clear is measured, explicit isolated YMFM/SSG pitch is not asserted by that test.",
"Nominal mixer arithmetic covers seven golden vectors/35samples including saturation/reset/cadence; per-route1800 moments are finite command-replay data, not naturalCPU action acceptance or waveform-bit identity.",
"13.99% short mixed-noise RMS difference is retained descriptive evidence and does not gate mixgain without phase/statistical justification.",
"Source-qualified hit/pickup/game-over/restart/action coverage remains separate; no broad P5/B03–B06, physical or resource closure."],
"fullP5pass":False,"fullB03_B06pass":False}
p=R/"research/kyros_audio_existing_contract_reuse_v2.json";p.write_text(json.dumps(out,indent=2)+"\n")
print(json.dumps({"checks":checks,"bindings":len(bindings),"missing":missing,"all_pass":out["all_checks_strict_boolean_true"],"receipt_sha256":sha(p)}))
raise SystemExit(0 if out["all_checks_strict_boolean_true"] else 1)
