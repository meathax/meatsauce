"""Join explicitly labelled actual IRQ request/latch/callback boundaries; no phase fitting."""
from pathlib import Path
import csv,json,hashlib
import os
import sys
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

def rows(p):return list(csv.DictReader(Path(p).open()))
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
 q=ROOT/"research/irq_sampling_edge_latch61_verification.json"
 if not q.exists():print('pending latch qualification');return 2
 v=json.loads(q.read_text())
 if not v["observer_fidelity_pass"]:print('latch fidelity failed; stop temporal diagnosis');return 1
 cap=ROOT/"sim/captures/rtl/irq_sampling_edge_latch61"
 native=rows(cap/"instruction_events.csv")
 mcap=ROOT/"sim/captures/kyros/irq_sampling_edge_mame61"
 mtaps=rows(mcap/"cpu_space_iack.csv")
 mevents=rows(mcap/"events.csv")
 bounds=[]
 for field in [59,60]:
  for address in [0x64,0x66,0x68,0x6a]:
   latch=[x for x in v["vector_word_latch_rows"] if int(x["frame"])==field and int(x["address_before"])==address]
   request=[x for x in native if int(x["frame"])==field and int(x["address"])==address]
   callback=[x for x in mevents if int(x["frame"])==field and int(x["address"])==address and x["area"]=="main_vector_read"]
   bounds.append({"field":field,"address":address,"native_accepted_request_rows":request,"native_qualified_phi2_input_latch_rows":latch,"mame_program_space_vector_callback_rows":callback})
 obj={"qualification_receipt_path":str(q),"qualification_sha256":sha(q),"labelled_vector_boundaries":bounds,"iack_cpu_space_callback_rows":[x for x in mtaps if int(x["frame"]) in [59,60]],"scope":"Different explicitly named observation boundaries; no subtraction interpreted as equal-edge timing. Ordinary vector request acceptance is distinct from CPU Phi2 input latch, CPU-space IACK tap and ordinary program-space MAME vector tap.","B16_closure":False}
 out=ROOT/"research/irq_sampling_edge_latch61_boundaries.json"
 assert not out.exists()
 out.write_text(json.dumps(obj,indent=2)+"\n")
 print(json.dumps({"output":str(out),"bounds":[{"field":b["field"],"address":b["address"],"native_request_ticks":[x.get("tick") for x in b["native_accepted_request_rows"]],"native_latch_ticks":[x["tick"] for x in b["native_qualified_phi2_input_latch_rows"]],"mame_callback_ticks":[x["master_ticks"] for x in b["mame_program_space_vector_callback_rows"]]} for b in bounds]},indent=2))
 return 0
if __name__=="__main__":raise SystemExit(main())
