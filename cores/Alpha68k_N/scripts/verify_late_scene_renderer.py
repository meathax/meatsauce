"""Compare guarded MAME scene snapshots with the qualified real RTL renderer."""
from pathlib import Path
import argparse
import csv
import hashlib
import json
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pins(path):
    return {name: digest for digest, name in
            (line.split(None, 1) for line in path.read_text().splitlines())}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", choices=("kyros", "kyrosj"), default="kyros")
    parser.add_argument("--capture", required=True)
    parser.add_argument("--label", default="candidate5_entry_renderer")
    parser.add_argument("--fields", nargs="+", type=int)
    args = parser.parse_args()
    capture = (ROOT / args.capture).resolve()
    assert capture.is_relative_to(ROOT / "sim/captures" / args.set)
    mame_receipt = ROOT / "research" / f"{args.set}_{capture.name}_verification.json"
    mame = json.loads(mame_receipt.read_text())
    assert mame["passed"] and mame["scene"].startswith("candidate-5")
    setup = mame["fixture_setup"]
    fixture_profile = mame.get("fixture_profile", {"scene_entry": 0x1a66})
    assert setup["selector_after"] == 5 and setup["entry_pc"] == fixture_profile["scene_entry"]
    reference_setup = mame.get("late_room_setup", setup)
    saved_assets = {str((ROOT / a["path"]).resolve()): a["sha256"] for a in mame["artifacts"]}
    binary = ROOT / "sim/captures/diagnostics/combat_hud_prewrite_fixtures/alpha68kn_render_fixture_sim"
    fixture_receipt = ROOT / "research/combat_hud_prewrite_fixtures_verification.json"
    fixture = json.loads(fixture_receipt.read_text())
    assert fixture["passed"] and sha(binary) == fixture["executable_sha256"]
    assert binary.open("rb").read(4) == b"\x7fELF"
    manifest = ROOT / "research/combat_hud_prewrite_fixtures_inputs.sha256"
    fixture_pins = pins(manifest)
    assert all(sha(ROOT / name) == digest for name, digest in fixture_pins.items())
    native_pins = pins(ROOT / "research/kyros_combat_hud3301_inputs.sha256")
    relation = json.loads((ROOT / "research/combat_hud_prewrite_fixtures_source_relation.json").read_text())
    shared = relation["shared_source_paths"]
    assert all(fixture_pins[name] == native_pins[name] for name in shared)
    assert args.label.replace("_", "").isalnum()
    name = f"{args.set}_{args.label}"
    out = ROOT / "sim/captures/renderer" / name
    jobfile = ROOT / "research" / f"{name}_job.json"
    if out.exists() or jobfile.exists():
        raise SystemExit("Refusing to overwrite an existing renderer comparison")
    out.mkdir(parents=True)
    rows = list(csv.DictReader((capture / "states.csv").open()))
    rows = [r for r in rows if int(r["frame"]) >= reference_setup["frame"] + 300]
    if args.fields:
        rows = [r for r in rows if int(r["frame"]) in args.fields]
        assert {int(r["frame"]) for r in rows} == set(args.fields)
    assert rows
    payload = ROOT / "roms" / args.set / "download.bin"
    started = time.time()
    job = {"worker_pid": os.getpid(), "started": started,
           "source_parent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
           "runner_sha256": sha(Path(__file__)), "executable_sha256": sha(binary),
           "fixture_source_sha256": fixture_pins, "shared_native_dut_paths": shared,
           "mame_receipt_sha256": sha(mame_receipt), "payload_sha256": sha(payload),
           "scope": "Complete isolated real renderer/SDRAM fields from guarded MAME selector5 snapshots; no real RTL CPU, whole-game or late-scene identity acceptance"}
    jobfile.write_text(json.dumps(job, indent=2) + "\n", encoding="utf-8")
    results = []
    for row in rows:
        frame = int(row["frame"])
        prefix = capture / f"frame_{frame:06d}"
        ram = prefix.with_suffix(".sprites.bin")
        oracle = prefix.with_suffix(".display.rgb")
        assert len(ram.read_bytes()) == 8192 and len(oracle.read_bytes()) == 57344*3
        assert all(sha(p) == saved_assets[str(p.resolve())] for p in (ram, oracle))
        destination = out / f"field_{frame:06d}"
        command = ["wsl.exe", "-d", "Ubuntu", "--cd", str(ROOT), "--exec",
                   "/mnt/d/Arcade/AI/aCORES/Alpha68k N/" + binary.relative_to(ROOT).as_posix(),
                   payload.relative_to(ROOT).as_posix(), ram.relative_to(ROOT).as_posix(),
                   row["background"], destination.relative_to(ROOT).as_posix(), "0",
                   oracle.relative_to(ROOT).as_posix()]
        run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (out / f"field_{frame:06d}.log").write_text(run.stdout + run.stderr, encoding="utf-8")
        values = [json.loads(line) for line in run.stdout.splitlines() if line.startswith("{")]
        result = values[-1] if values else {}
        actual = destination / "actual.rgb"
        actual_bytes = actual.read_bytes() if actual.exists() else b""
        expected_bytes = oracle.read_bytes()
        mismatches = (sum(actual_bytes[i:i+3] != expected_bytes[i:i+3]
                          for i in range(0, len(expected_bytes), 3))
                      if len(actual_bytes) == len(expected_bytes) else None)
        passed = (run.returncode == 0 and result.get("result") == "pass" and
                  result.get("oracle_compared") is True and mismatches == 0 and
                  result.get("deadline_misses") == result.get("row_overflows") == 0)
        results.append({"field": frame, "background": int(row["background"]),
                        "exit_code": run.returncode, "result": result, "passed": passed,
                        "complete_rgb_mismatches": mismatches, "command": command,
                        "ram_sha256": sha(ram), "oracle_sha256": sha(oracle),
                        "actual_sha256": sha(actual) if actual.exists() else None})
        (ROOT / "research" / f"{name}_partial.json").write_text(json.dumps(results, indent=2)+"\n", encoding="utf-8")
    job.update(results=results, passed=all(r["passed"] for r in results),
               ended=time.time(), wall_seconds=time.time()-started)
    (ROOT / "research" / f"{name}_verification.json").write_text(json.dumps(job, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"passed": job["passed"], "cases": [
        {"field": r["field"], "mismatches": r["complete_rgb_mismatches"],
         "color_ff_tiles": r["result"].get("color_ff_tiles")} for r in results]}), flush=True)
    return 0 if job["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
