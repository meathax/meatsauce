"""Owned finite worker: qualify the single existing native61 terminal, never restart."""
from pathlib import Path
import hashlib,json,subprocess,sys,time
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

NAME="irq_sampling_edge_latch61_postcheck"
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
paths=[sibling_script(n) for n in ["verify_irq_sampling_edge_latch61.py","join_irq_sampling_edge61.py"]]
pins={str(p):sha(p) for p in paths}
receipt=ROOT/"research"/(NAME+"_exit.json")
assert not receipt.exists()
deadline=time.time()+1800
while not (ROOT/"research/irq_sampling_edge_latch61_exit.json").exists() and time.time()<deadline:time.sleep(10)
record={"finished_wait":time.time(),"source_pins":pins,"qualified_existing_terminal_only":True,"B16_closure":False}
if not (ROOT/"research/irq_sampling_edge_latch61_exit.json").exists():
 record.update(state="timeout",exit_code=2)
else:
 assert all(sha(p)==h for p,h in pins.items())
 codes=[]
 for path in paths:
  result=subprocess.run([sys.executable,"-X","utf8",str(path)],cwd=ROOT)
  codes.append(result.returncode)
  if result.returncode:break
 record.update(state="complete",check_exit_codes=codes,exit_code=max(codes))
receipt.write_text(json.dumps(record,indent=2)+"\n")
