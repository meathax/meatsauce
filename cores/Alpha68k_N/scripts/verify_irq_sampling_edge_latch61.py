"""Qualify actual private latch observer and matched real MAME IACK capture."""
from pathlib import Path
import csv,hashlib,json,importlib.util,sys
import os
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

NAME="irq_sampling_edge_latch61"
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def rows(p):return list(csv.DictReader(Path(p).open()))
def main():
 terminal=ROOT/"research"/(NAME+"_exit.json")
 if not terminal.exists():print(json.dumps({"state":"pending","terminal":str(terminal)}));return 2
 receipt=ROOT/"research"/(NAME+"_verification.json")
 assert not receipt.exists(),"Preserve qualification receipt"
 job=json.loads((ROOT/"research"/(NAME+"_job.json")).read_text())
 end=json.loads(terminal.read_text())
 cap=ROOT/"sim/captures/rtl"/NAME
 previous=ROOT/"sim/captures/rtl/kyros_irq_e_phase61"
 frames=rows(cap/"frames.csv")
 trace=rows(cap/"latch_phase.csv")
 images=sorted(previous.glob("*.rgb"))
 imagediff=[p.name for p in images if not (cap/p.name).exists() or sha(cap/p.name)!=sha(p)]
 check={
  "actual_native_terminal_exit0":end.get("exit_code")==0,
  "terminal_same_worker_and_simulation":end.get("worker_pid")==job.get("worker_pid") and end.get("simulation_pid")==job.get("simulation_pid"),
  "full61fields":len(frames)==61 and [int(r["frame"]) for r in frames]==list(range(61)),
  "previous19_images_exact":len(images)==19 and not imagediff,
  "instruction_trace_exact":sha(cap/"instruction_events.csv")==sha(previous/"instruction_events.csv"),
  "e_phase_trace_exact":sha(cap/"e_phase.csv")==sha(previous/"e_phase.csv"),
  "applied_inputs_exact":sha(cap/"applied_inputs.csv")==sha(previous/"applied_inputs.csv"),
  "frozen_original_sources_unchanged":all(sha(ROOT/p)==h for p,h in job["source_pins"].items()),
  "executable_pinned":sha(cap/Path(job["command"][0]).name)==job["executable_sha256"],
 }
 spec=importlib.util.spec_from_file_location("owned_observer",sibling_script("irq_sampling_edge_probe.py"))
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 generated=ROOT/job["compile_file_origins"]["system_main.cpp"]
 check["only_declared_private_host"]=generated.read_text()==module.observed_host((ROOT/"sim/system_main.cpp").read_text()) and sha(generated)==job["generated_host_sha256"]
 qualified_irc=[r for r in trace if int(r["phi2_before"]) and int(r["to_irc_before"])]
 qualified_dbin=[r for r in trace if int(r["phi2_before"]) and int(r["to_dbin_before"])]
 vector_dbin=[r for r in qualified_dbin if int(r["address_before"]) in [0x64,0x66,0x68,0x6a] and int(r["attrs_before"])==4]
 check["actual_phi2_enable_equals_unpaused_phase4"]=all(int(r["phi2_before"])==(int(r["cpu_phase_before"])==4) for r in trace)
 check["nonvacuous_irc_latch_qualifiers"]=bool(qualified_irc)
 check["irc_captures_preedge_data"]=all(int(r["irc_after"])==int(r["din_before"]) for r in qualified_irc)
 check["nonvacuous_vector_data_latch"]=len(vector_dbin)>=8
 check["vector_word_data_latches_preedge_data"]=all(int(r["dbin_after"])==int(r["din_before"]) for r in vector_dbin)
 mname="irq_sampling_edge_mame61"
 mt=ROOT/"research"/(mname+"_exit.json")
 mame={"state":"pending"}
 if mt.exists():
  mend=json.loads(mt.read_text())
  mc=ROOT/"sim/captures/kyros"/mname
  mframes=rows(mc/"frame_states.csv")
  oldframes=rows(ROOT/"sim/captures/kyros/reset_raster361_v4/frame_states.csv")
  taps=rows(mc/"cpu_space_iack.csv")
  focus=[r for r in taps if int(r["frame"]) in [59,60]]
  mchecks={"actual_terminal_exit0":mend.get("exit_code")==0,"no_lua_failure":mend.get("lua_error")==False,"complete61fields":len(mframes)==61 and [int(r["frame"]) for r in mframes]==list(range(61)),"unchanged_reference_prefix":mframes==oldframes[:61],"nonvacuous_four_focus_iack_reads":len(focus)==4,"cpu_space_addresses":all(0xfffff0<=int(r["address"])<=0xffffff for r in taps),"observer_pinned":sha(mc/"loaded_recorder.lua")==mend["observer_sha256"],"reference_source_unchanged":sha(mend["base_path"])==mend["base_sha256"],"mame_executable_pinned":sha(mend["command"][0])==mend["mame_sha256"]}
  mame={"qualification_pass":all(mchecks.values()),"checks":mchecks,"focused_iack_events":focus,"all_cpu_space_rows":len(taps)}
 check["mame_iack_observer_fidelity"]=mame.get("qualification_pass")==True
 out={"checks":check,"observer_fidelity_pass":all(check.values()),"fields":len(frames),"images":len(images),"differing_images":imagediff,"latch_rows":len(trace),"qualified_irc_rows":len(qualified_irc),"qualified_dbin_rows":len(qualified_dbin),"vector_word_latch_rows":vector_dbin,"mame":mame,"original_vector_request_boundary":"Board accepted request, distinct from qualified Phi2 latch and IACK deassertion","scope":"Finite actual61-field read-only observer/latch qualification. No phase calibration or B16 fix inferred.","B16_closure":False,"whole_game_acceptance":False}
 receipt.write_text(json.dumps(out,indent=2)+"\n")
 print(json.dumps({"observer_fidelity_pass":out["observer_fidelity_pass"],"failed_checks":[k for k,v in check.items() if not v],"latch_rows":len(trace),"vector_rows":len(vector_dbin),"mame":mame,"receipt":str(receipt)},indent=2))
 return 0 if out["observer_fidelity_pass"] else 1
if __name__=="__main__":raise SystemExit(main())
