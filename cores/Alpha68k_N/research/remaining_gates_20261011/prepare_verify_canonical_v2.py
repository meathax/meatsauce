"""Derive the minimal displayed-RGB consumer revision and execute it once."""
from pathlib import Path
import hashlib, json, subprocess, sys, time

O = Path(__file__).resolve().parent
N = O / "japan_joined720"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def js(p): return json.loads(p.read_text(encoding="utf-8-sig"))
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}
source = O / "run_japan_joined720.py"
assert sha(source) == "77bc52da1f2b75e9cdc622b0c9e3eaf45028ca45acbed2ec851d9c98a48267d4"
lineage_path = N / "oracle_lineage_supplement.json"
assert sha(lineage_path) == "ad1913efa7ca239f1c1bf83903f003d4e5f0d07629b0bfb3117979b38c725949"
lineage = js(lineage_path)
assert lineage["all6_canonical_displayed_PNG_RGB_exact"]
refs = [x[k] for x in lineage["canonical_PNG_comparisons"] for k in ("PNG", "display_sidecar")]
assert len(refs) == 12 and all(sha(Path(x["path"])) == x["sha256"] for x in refs)
v2 = O / "verify_japan_canonical_v2.py"
assert not v2.exists()
text = source.read_text(encoding="utf-8")
changes = [
    ('            b = R / "sim/captures/kyrosj/gameplay" / a.name',
     '            b = R / "sim/captures/kyrosj/gameplay" / (f"frame_{field:06d}.display.rgb" if suffix == "rgb" else a.name)'),
    ('    return p\ndef verify():',
     '    refs = js(N / "canonical_v2_preparation.json")["canonical_reference_pins"]\n    assert len(refs) == 12 and all(sha(Path(x["path"])) == x["sha256"] for x in refs)\n    return p\ndef verify():'),
    ('    events = rows(reference / "events.csv")',
     '    for suffix, label in (("rgb", "RGB"), ("sprites.bin", "strip"), ("work.bin", "work")):\n        group = [x for x in arrays if x["suffix"] == suffix]\n        checks[f"all6_{label}_arrays_exact"] = len(group) == 6 and all(x["different_bytes"] == 0 for x in group)\n    events = rows(reference / "events.csv")'),
    ('    write("verification.json", result)',
     '    result["canonical_reference_pins"] = js(N / "canonical_v2_preparation.json")["canonical_reference_pins"]\n    result["array_class_results"] = {label: {"fields": 6, "passed": checks[f"all6_{label}_arrays_exact"], "arrays": [x for x in arrays if x["suffix"] == suffix]} for suffix, label in (("rgb", "RGB"), ("sprites.bin", "strip"), ("work.bin", "work"))}\n    result["consumer_correction"] = "MAME RGB uses pinned completedPNG-derived display.rgb only; strict work/strip checks are unchanged. Original verifier exit1 and receipt remain immutable."\n    write("verification_canonical_v2.json", result)'),
    ('sha(N / "verification.json")', 'sha(N / "verification_canonical_v2.json")'),
    ('    raise SystemExit({"admit": admit, "supervise": supervise, "verify": verify}[mode]())',
     '    assert mode == "verify", "This separately pinned revision permits verification only; no replay admission or supervision."\n    raise SystemExit(verify())'),
]
for before, after in changes:
    assert text.count(before) == 1, before
    text = text.replace(before, after, 1)
compile(text, str(v2), "exec")
v2.write_text(text, encoding="utf-8")
preparation = N / "canonical_v2_preparation.json"
assert not preparation.exists()
preparation.write_text(json.dumps({"scope": "Separately pinned consumer correction only; no replay, build, RTL or gate loosening.", "source": pin(source), "verifier": pin(v2), "lineage": pin(lineage_path), "canonical_reference_pins": refs, "changes": [{"before": a, "after": b} for a, b in changes]}, indent=2) + "\n", encoding="utf-8")
command = [sys.executable, str(v2), "verify"]
job = N / "verification_canonical_v2_job.json"
assert not job.exists()
log_path = N / "verification_canonical_v2.log"
with log_path.open("wb") as log:
    child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
    job.write_text(json.dumps({"pid": child.pid, "started": time.time(), "command": command, "verifier_sha256": sha(v2), "preparation_sha256": sha(preparation), "original_verification_exit_sha256": sha(N / "verification_exit.json")}, indent=2) + "\n", encoding="utf-8")
    code = child.wait()
exit_path = N / "verification_canonical_v2_exit.json"
assert not exit_path.exists()
exit_path.write_text(json.dumps({"exit_code": code, "finished": time.time(), "pid": child.pid, "log_sha256": sha(log_path)}, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"verifier_exit": code, "exit_receipt": str(exit_path), "exit_receipt_sha256": sha(exit_path), "verifier_sha256": sha(v2), "log": log_path.read_text(errors="replace")}))
