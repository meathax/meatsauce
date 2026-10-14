"""Freeze an already-completed registered replay; never rerun its verifier/simulation."""
from pathlib import Path
import hashlib, json, sys

O = Path(__file__).resolve().parent
N = O / "japan_joined720"
def sha(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()
def load(p): return json.loads(p.read_text(encoding="utf-8-sig"))
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}

native = load(N / "run_exit.json")
verifier = load(N / "verification_exit.json")
supervisor = load(N / "supervisor_exit.json")
verification = load(N / "verification.json")
assert native["exit_code"] == supervisor["run_exit_code"]
assert verifier["exit_code"] == supervisor["verification_exit_code"]
assert (verifier["exit_code"] == 0) == verification["all_checks_strict_true"]
assert verifier["log_sha256"] == sha(N / "verification.log")
assert native["log_sha256"] == sha(N / "run.log")
preparation = load(O / "japan_joined720_preparation.json")
assert sha(O / "japan_joined720_preparation.json") == verification["prepared_source_manifest_sha256"]
closure = load(Path(preparation["existing_source_closure"]["path"]))
assert len(closure["source_files"]) == 75
assert all(sha(Path(x["path"])) == x["combined_sha256"] for x in closure["source_files"])
assert sha(Path(preparation["ELF"]["path"])) == native["ELF_sha256"] == preparation["ELF"]["sha256"]
files = [O / x for x in ("prepare_japan_reuse.py", "japan_joined720_preparation.json", "run_japan_joined720.py", "freeze_japan_terminal.py", "remaining_gates.md", "wrapper_gates.md")]
files += [N / x for x in ("admission.json", "supervisor.json", "run_job.json", "run_exit.json", "verification_job.json", "verification_exit.json", "supervisor_exit.json", "verification.json", "verification.log", "run.log")]
capture = N / "capture"
recovery = [pin(x) for x in sorted(capture.iterdir()) if x.is_file()]
result = {
    "schema": "actual_joined_Japan720_terminal_import_v1",
    "scope": verification["scope"],
    "actual_native_exit": native["exit_code"], "actual_verifier_exit": verifier["exit_code"],
    "all_checks_strict_true": verification["all_checks_strict_true"],
    "checks_count": len(verification["checks"]), "failed_checks": verification["failed_checks"],
    "fields": verification["fields"], "worst_line_cycles": verification["worst_line_cycles"],
    "arrays": verification["arrays"],
    "sound_writes_reference_native": verification["sound_writes_reference_native"],
    "DAC_writes_reference_native": verification["DAC_writes_reference_native"],
    "latches_reference_native": verification["latches_reference_native"],
    "source_closure": preparation["existing_source_closure"], "source_files": 75,
    "ELF": preparation["ELF"], "ROM": preparation["ROM"], "inputs": preparation["inputs"],
    "reference_artifacts": preparation["reference_artifacts"],
    "small_import_files": [pin(x) for x in files],
    "large_recovery_files": recovery,
    "limitations": verification["limitations"] + ["No additional replay, build, source edit, RBF, hardware qualification or broad P7/P8 acceptance occurred during this freeze."],
}
output = N / "import_manifest.json"
assert not output.exists()
output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"path": str(output), "sha256": sha(output), "actual_native_exit": native["exit_code"], "actual_verifier_exit": verifier["exit_code"], "checks": len(verification["checks"]), "failed_checks": verification["failed_checks"], "import_files": len(files), "recovery_files": len(recovery)}))
