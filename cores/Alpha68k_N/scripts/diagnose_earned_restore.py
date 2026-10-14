"""Preserve terminal earned-score evidence and the donor's relevant transitions."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    receipt = json.loads((ROOT / "research/kyros_earned_wrapper901_v3_exit.json").read_text())
    log = (ROOT / "research/kyros_earned_wrapper901_v3_run.log").read_text()
    capture = ROOT / "sim/captures/rtl/kyros_earned_wrapper901_v3"
    rows = (capture / "reset_probe.csv").read_text().splitlines()
    saved = (capture / "earned.nvm").read_bytes()
    donor = ROOT / "rtl/vendor/mister_features/hiscore.v"
    lines = donor.read_text().splitlines()
    host = ROOT / "sim/captures/diagnostics/earned_wrapper_v3/wrapper_main.cpp"
    text = host.read_text()
    assert receipt["exit_code"] == 1
    assert "real donor reload failed after CPU-cleared score" in log
    assert rows[-1].split(",")[1:4] == ["0", "1", "2"]
    assert len(saved) == 178 and saved[-4:] == bytes.fromhex("00002000")
    assert text.index("download(4,saved)") > text.index("status(3)")
    report = {
        "scope": "Completed v3 real-HPS earned-score run; no replay or RAM modification",
        "exit_code": receipt["exit_code"],
        "reset_readiness_observed": rows[-1],
        "saved_bytes": len(saved),
        "saved_best_hex": saved[-4:].hex(),
        "donor_sha256": hashlib.sha256(donor.read_bytes()).hexdigest(),
        "host_sha256": hashlib.sha256(host.read_bytes()).hexdigest(),
        "restore_pass": False,
        "hypothesis": "Test loads the dump after reset release; inspect donor startup and download-completion transitions before changing protocol.",
        "donor_transitions": {str(i + 1): line.strip() for i, line in enumerate(lines)
                              if 373 <= i < 407 or 456 <= i < 550},
    }
    target = ROOT / "research/kyros_earned_wrapper901_v3_restore_diagnosis.json"
    assert not target.exists(), "Preserve existing diagnosis"
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
