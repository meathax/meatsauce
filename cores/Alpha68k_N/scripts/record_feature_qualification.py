"""Record bounded, reproducible feature qualification; never invoke Quartus."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))

def verified_inputs(name):
    path = ROOT / "sim/build" / name
    records = []
    for line in path.read_text().splitlines():
        expected, relative = line.split("  ", 1)
        assert digest(ROOT / relative) == expected, f"changed since build: {relative}"
        records.append({"path": relative, "sha256": expected})
    return {"manifest": str(path.relative_to(ROOT)), "sha256": digest(path), "files": records}

def qualification(name, features=False):
    base = ROOT / "sim/captures/rtl" / name
    result = read_json(base / "result.json")
    assert result["passed"]
    output = {"path": str(base.relative_to(ROOT)), "result": result}
    if features:
        output["features"] = read_json(base / "features.json")
        assert output["features"]["passed"]
    else:
        assert result["frames"] == 8
    return output

assert (ROOT / "sim/build/features_final_lint.exit").read_text().strip() == "0"
for name in ("kyros", "kyrosj"):
    assert (ROOT / f"sim/build/features_final_{name}.exit").read_text().strip() == "0"
assert read_json(ROOT / "sim/build/features_protocol8_exit.json")["exit_code"] == 0
records = {
    "date": "2026-10-09",
    "base_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "scope": "MiSTer features in the current development checkout; real RTL/HPS with ideal PLL and DDR acceptance. Synthetic score protocol fixture is not earned gameplay proof.",
    "build_snapshot": (ROOT / "sim/build/wrapper_build_dir.txt").read_text().strip(),
    "elf_sha256": digest(ROOT / "sim/build/alpha68kn_wrapper_sim"),
    "inputs": verified_inputs("wrapper_inputs.sha256"),
    "lint_inputs": verified_inputs("wrapper_lint_inputs.sha256"),
    "production_elaboration": {"native": 0, "framebuffer": 0, "logs": "sim/build/wrapper_lint_{native,framebuffer}.log"},
    "runs": [qualification("features_protocol8", True), qualification("features_final_kyros"), qualification("features_final_kyrosj")],
    "mra_validation": read_json(ROOT / "research/feature_mra_validation.json"),
    "limits": ["Stingray real 8748/maps remain P6; profile is intentionally rejected and its action names remain provisional.", "All-game non-default DIP, cocktail, long gameplay and earned-score reload remain unqualified.", "First framework field remains 57602 samples; native crop is 57344 and settled fields are checked from field 4.", "CRT H-Size cadence and sync boundaries passed simulation; DAC/Y-C/direct-video/CRT lock and original PCB sync pulse positions are not measured.", "V-Size is bypassed in direct video; its altered line frequency still needs chassis testing.", "Quartus hold: complete-design fit/resources/timing and RBF/hardware gates pending; no Quartus or RBF build performed."],
}
(ROOT / "research/feature_qualification.json").write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
trials = {}
for name in ("features_protocol", *[f"features_protocol{i}" for i in range(2, 9)]):
    log = ROOT / "sim/build" / f"{name}.log"
    receipt = ROOT / "sim/build" / f"{name}_exit.json"
    if not log.exists():
        continue
    try:
        result = read_json(receipt)
    except (ValueError, FileNotFoundError):
        result = {"receipt_parse_error": True, "raw": receipt.read_text() if receipt.exists() else "missing"}
    trials[name] = {"log": str(log.relative_to(ROOT)), "exit": result, "last_lines": log.read_text(errors="replace").splitlines()[-12:]}
(ROOT / "research/feature_runtime_trials.json").write_text(json.dumps(trials, indent=2) + "\n", encoding="utf-8")
(ROOT / "research/feature_runtime_latest.json").write_text(json.dumps(records["runs"][0], indent=2) + "\n", encoding="utf-8")
print("Final qualification recorded: feature fixture, both 8-field ROM boots, native/framebuffer elaboration, all input hashes verified.")
