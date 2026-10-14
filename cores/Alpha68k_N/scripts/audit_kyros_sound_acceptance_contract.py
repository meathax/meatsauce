"""Bounded retained evidence audit; no replay or production changes."""
import csv,hashlib,json
from pathlib import Path
R=Path(__file__).resolve().parents[1]
C=Path(r"D:\\Arcade\\AI\\aCORES\\meatsauce-alpha68kn\\cores\\Alpha68k_N")
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def js(n):return json.loads((R/n).read_text(encoding="utf-8-sig"))
def csvs(n):
 with (R/n).open(encoding="utf-8-sig",newline="") as f:return list(csv.DictReader(f))
def num(s):
 try:return int(s,0)
 except ValueError:return int(s)
ev=["research/kyros_punch_release1081_native_sound_interleaving.json","research/kyros_idle_death3601_sound_comparison.json","research/kyros_combat_hud3301_sound_interleaving.json","research/kyros_death_marker_post_depletion_composition.json","research/kyros_active_noise_reset_v3_terminal_qualification.json","research/mixer_ymfm_contract_manifest.json","research/audio_ymcurve_fixed1800_qualification.json","research/soundchips_contracts.json","research/kyrosj_current720_curvefixed_exit.json","research/kyrosj_current720_qualification.json","research/current_system720_curvefixed_build_exit.json","sim/captures/rtl/kyros_combat_hud3301/audio.json","sim/captures/rtl/kyrosj_current720_curvefixed_drive/audio.json","sim/captures/rtl/kyrosj_current720_curvefixed_drive/audio_events.csv","sim/captures/rtl/kyrosj_current720_curvefixed_drive/applied_inputs.csv","sim/captures/kyrosj/gameplay/events.csv","sim/captures/kyrosj/gameplay/frame_states.csv"]
allref=csvs(ev[-2]);a=[x for x in allref if x["area"]=="sound_io" and num(x["frame"])<720]
b=[x for x in csvs(ev[-4]) if x["kind"]=="write" and num(x["frame"])<720]
key=lambda x:(num(x["address"]),num(x["data"]))
sa,sb=list(map(key,a)),list(map(key,b))
first=next((i for i,(x,y) in enumerate(zip(sa,sb)) if x!=y),min(len(a),len(b)) if len(a)!=len(b) else None)
ref=csvs(ev[-1]);act=csvs(ev[-3]);fk=next((k for k in ("frame","field") if k in act[0]),None)
cols=[k for k in ("in0","in1","in2") if k in ref[0] and k in act[0]]
idx={num(x["frame"]):x for x in ref if num(x["frame"])<720};diff=[]
if fk and len(cols)==3:
 for x in act:
  y=idx.get(num(x[fk]))
  if y is not None and any(num(x[k])!=num(y[k]) for k in cols):
   diff.append({"field":num(x[fk]),"native":{k:x[k] for k in cols},"reference":{k:y[k] for k in cols}})
selected=[]
for n in ("rtl/alpha68kn_soundchips.sv","rtl/alpha68kn_audio.sv","rtl/alpha68kn_mixer.sv"):
 p=C/n
 selected.append({"path":n,"sha256":sha(p),"selected_source":[{"line":i+1,"text":s.strip()} for i,s in enumerate(p.read_text(encoding="utf-8-sig").splitlines()) if any(t.lower() in s.lower() for t in ("2 MHz","48 MHz","irq","nmi","vblank","1263071","40'sd","SSG_COMP","SEL","CLKDIV","ce_"))][:40]})
audit={"scope":"Approved P5 B03-B06 sound audit; exact retained Japan720 input/port prefix diagnostic. No broad bug closure, new replay or production change.",
"canonical_parent":"ad6d6800bee52a64c9a0057cc757d0aa9dde2557",
"approved_contract":{"plan":"P5 items1-5/P7 item1","required_actions":["swing/hit","jump","pickup","death","game-over/reset","sustained PSG/noise","DAC"],"comparisons":["command/latch/IRQ/NMI/register","tone rates","route balance/clipping","short WAV"],"phase_identical_PCM_required":False,"precise_unsampled_death_animation_edge_required":False,"rates_hz":{"main_cpu":6000000,"sound_cpu":4000000,"three_sound_chips":2000000,"master":48000000},"MAME_routes":{"YM":0.30,"AY1":0.30,"AY2":0.60,"DAC":0.50}},
"finite_covered":{"punch":"1081 actualCPU fields;2750 exact port bytes+field labels;noiseon715 cleanup733.",
"depletion":"ROM-qualified energy depletion bound(1260,1290],lives3to2 by1380;accepted AY2 noise disabled, legitimate tone allowed; not exact animation edge.",
"active_noise_CPU_reset":"Actualbuild/sim/postcheck0;20strict Booleanchecks;70 actual pre-noise/B transitions;64reset ticks;500000postticks; no retained channel. No repeat.",
"combat_chip_events":js(ev[2])["chips"],"combat_global_order_equal":js(ev[2])["global_order_equal"],
"combat_actual_CPU_audio":js(ev[11]),
"mixer":"Seven current YMFM float golden vectors/35samples,saturation/reset/cadence; prior six-vector normalization superseded.",
"component_replay":"37908 actualCPU-derived writes,1800fields,1459814samples,zero rails; correctedSSGcurve write-only donor replay, notCPUactionacceptance.",
"chip_contract":"Isolated actual donor registers/AYmode/tone/envelope/timer/reset finite baseline; preserve original scope/source pins."},
"Japan720":{"actual_terminal_exit":js(ev[8])["exit_code"],"original_source_parent":js(ev[8])["base_revision"],"original_local_adaptation":js(ev[8])["local_adaptation"],"actual_ELF_sha256":js(ev[8])["executable_sha256"],"audio":js(ev[12]),"reference_chip_writes":len(a),"native_chip_writes":len(b),"reference_last_chip_field":max(num(x["frame"]) for x in a),"common_bytes_prefix_equal":sa[:min(len(a),len(b))]==sb[:min(len(a),len(b))],"full720_chip_sequence_equal":sa==sb,"first_sequence_difference_index":first,"first_extra_native":b[first] if first is not None and first<len(b) else None,"reference_all_chip_frame_range":[min(num(x["frame"]) for x in allref if x["area"]=="sound_io"),max(num(x["frame"]) for x in allref if x["area"]=="sound_io")],"native_input_columns":list(act[0]),"input_compare_supported":bool(fk and len(cols)==3),"input_diff_rows":len(diff),"first_input_difference":diff[0] if diff else None,"source_limit":"720 build receipt onlyexit/time; originalparent+localcurve5 andELF pins do not establish current compiled-source parity.","interpretation":"Retained oracle/epoch/input relation must be established before RTL audio diagnosis; sampledRGB/exit0/zero rails are not full720sound-event equality."},
"actions_still_unqualified":{"hit":"No specific hit semantic marker qualified; combat writes do not identify effect.",
"jump":"No source-qualified jump action receipt in bounded action namespace audit.",
"pickup":"No source-qualified pickup action receipt in bounded action namespace audit.",
"game_over_restart":"idle_death3601 ordered14802ports+30latchesexact; runname is not source-qualified game-over/restart marker; no DAC observer there.",
"DAC_comparison":"ActualCPU combat contains32091 DAC rows; compare retained MAME accepted DAC-address/data sequence rather than infer success from DAC activity."},
"next_actions":[
"Resolve Japan reference input epoch from original frame_states/applied_inputs/source receipts; if mismatched, capture focused officialMAME reference using exact native720 legal inputs and read-only observers, preserving original prefix. Do not repeat native720.",
"Bind hit/jump/pickup/game-over/restart ROM callsites or workRAM transitions to retained combat/idle sound events; compare only semantic windows and DAC data, export existing WAV snippets.",
"Only if an action is truly absent, capture one legal missing-action officialMAME sequence and one affected finite realCPU replay. Reuse qualified punch/depletion/reset/chip/mixer evidence."],
"scope_limits":["B03-B06 remain broad-open; no fullP5/wholegame/graphics/physical pass.","Do not require bit-identical PCM or blanket silence when legitimate tones remain.","Spectral nearest peaks remain diagnostics, not automatic frequency passes.","Japan720 current-source lineage remains unqualified pending compiled manifest."],
"source_pins":selected,"contract_pins":[{"relative_path":n,"sha256":sha(C/n)} for n in ("plan.md","mamebug.md","docs/bug_coverage.json","docs/SOUND_HARDWARE.md","docs/AUDIO_NORMALIZATION.md")],
"evidence_pins":[{"relative_path":n,"sha256":sha(R/n),"bytes":(R/n).stat().st_size} for n in ev]}
out=R/"research/kyros_sound_acceptance_contract_audit.json";out.write_text(json.dumps(audit,indent=2)+"\n",encoding="utf-8")
md=R/"research/kyros_sound_acceptance_contract_audit.md"
md.write_text("""# Kyros sound acceptance audit
P5 requires one source-qualified action sequence, command/latch/IRQ/NMI/register events, tone rates, numerical balance/clipping and a short WAV. It explicitly excludes phase-identical MAME/JT PCM. An unsampled exact death-animation edge is not an additional gate.

World finite swing/cleanup, ROM-qualified depletion/lives consumption and nonvacuous actualCPU active-noise reset remain covered. Combat3301 actualCPU output contains2677137 samples at48000Hz with zero clipping. AY1/AY2 writes and field labels agree; YM bytes agree but seven field-label differences/global reorder remain. Independent current seven-vector mixer and corrected1800 component replay qualify finite calibration only.

Japan720 exits0 and produces583925 samples/48000Hz without clipping. However retained MAME before720 contains114 port writes versus native406; common bytes agree. This is a concrete reference/input epoch gap requiring diagnosis before an RTL fix or repeated replay. Exact applied-input comparison and first additional native write are in the JSON.

Hit/jump/pickup/game-over/restart need source-qualified semantic windows. Reuse retained combat/idle RAM/events first, compare DAC writes, and export existing WAV snippets. Capture one legal missing-action/profile sequence only if retained evidence lacks it. Do not repeat qualified punch/depletion/reset. Broad B03-B06/P5/graphics/physical acceptance remains open.
""",encoding="utf-8")
print(json.dumps({"japan_counts":[len(a),len(b)],"input_diff_rows":len(diff),"first_input_difference":diff[0] if diff else None,"json_sha256":sha(out),"md_sha256":sha(md),"script_sha256":sha(Path(__file__))}))
