"""Qualify finite live Kyros features; retain all canonical image differences."""
import argparse
import csv
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def compare(reference, actual, unit=1):
    expected, observed = reference.read_bytes(), actual.read_bytes()
    return {"reference": reference.as_posix(), "actual": actual.as_posix(),
            "reference_sha256": sha(reference), "actual_sha256": sha(actual),
            "reference_bytes": len(expected), "actual_bytes": len(observed),
            "different_units": sum(expected[i:i+unit] != observed[i:i+unit]
                                   for i in range(0, len(expected), unit))
            if len(expected) == len(observed) else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("cocktail", "earned"))
    parser.add_argument("--earned-version", choices=("v2", "v3", "v4", "v5"), default="v2")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    cocktail = args.mode == "cocktail"
    version = args.earned_version
    name = "kyros_cocktail1801_v2_native" if cocktail else "kyros_earned_wrapper901_" + version
    earned_executable = "alpha68kn_wrapper_earned_sim" if version == "v2" else f"alpha68kn_wrapper_earned_{version}_sim"
    capture = root / "sim/captures/rtl" / ("kyros_cocktail1801_v2" if cocktail else name)
    reference = root / "sim/captures/kyros" / ("cocktail1801_v2" if cocktail else "combat3600_v2")
    count = 1801 if cocktail else 901
    receipt_path = root / "research" / (name + "_exit.json")
    # A running job is never qualified or restarted by this verifier.
    receipt = json.loads(receipt_path.read_text())
    job_path = root / "research" / (name + "_job.json")
    job = json.loads(job_path.read_text())
    metrics = rows(capture / "frames.csv")
    applied_path = capture / ("applied_inputs.csv" if cocktail else "applied_gameplay_ports.csv")
    applied = rows(applied_path)
    if cocktail:
        applied = [r for r in applied if r["boundary"] == "after_frame"]
    expected = rows(reference / "frame_states.csv")[:count]
    input_frame = "frame" if cocktail else "after_frame"
    checks = {
        "terminal_exit_zero": receipt["exit_code"] == 0,
        "complete_field_sequence": [int(r["frame"]) for r in metrics] == list(range(count)),
        "complete_input_sequence": [int(r[input_frame]) for r in applied] == list(range(count)),
        "exact_observed_port_application": len(applied) == len(expected) == count and all(
            (int(a["controls"]), int(a["dips"]), int(a["coins_n"])) ==
            (int(e["in0"]), int(e["in1"]), int(e["in2"]) & 3)
            for a, e in zip(applied, expected)),
        "pinned_oracle_ports": sha(reference / "frame_states.csv") == job["ports_sha256"],
        "pinned_executable": sha(capture / (earned_executable if not cocktail else "../kyros_combat_hud3301/alpha68kn_system_sim")) == job["executable_sha256"],
    }
    failures = ("unmapped", "deadline_misses", "row_overflows") if cocktail else ("unmapped", "deadlines", "overflows")
    pixel_key = "pixels" if cocktail else "core_pixels"
    checks["complete_unique_pixels_and_no_renderer_failures"] = bool(metrics) and all(
        int(r[pixel_key]) == 57344 and int(r["duplicates"]) == 0 and
        all(int(r[k]) == 0 for k in failures) for r in metrics)
    checks["actual_cpu_activity"] = bool(metrics) and int(metrics[-1]["main_transactions"]) > 0
    images = []
    for image in sorted(reference.glob("frame_*.display.rgb")):
        field = int(image.name.split(".")[0].split("_")[1])
        if field >= count:
            continue
        native = capture / (f"frame_{field:06d}.rgb" if cocktail else f"frame_{field:06d}.core.rgb")
        item = {"field": field, "available": native.exists()}
        if native.exists():
            item.update(compare(image, native, 3))
        images.append(item)
    checks["all_canonical_images_available"] = bool(images) and all(i["available"] for i in images)
    evidence = {}
    if cocktail:
        flips = rows(reference / "native_flip.csv")
        checks["oracle_player2_flip_observed"] = any(int(r["flip"]) for r in flips)
        checks["continued_player2_actions"] = any(int(r["controls"]) & 0x7f00 for r in applied[1140:])
        # Complete actual Player2 checkpoint, not a clipped or shifted image.
        checkpoint = {kind: compare(reference / f"frame_001140.{kind}.bin",
                                     capture / f"frame_001140.{kind}.bin") for kind in ("sprites", "work")}
        checkpoint["rgb"] = compare(reference / "frame_001140.display.rgb", capture / "frame_001140.rgb", 3)
        checks["player2_checkpoint_exact"] = all(i["different_units"] == 0 for i in checkpoint.values()) and all(
            checkpoint[k]["reference_bytes"] == size for k,size in (("rgb",172032),("sprites",8192),("work",4096)))
        evidence = {"player2_checkpoint": checkpoint,
                    "flip_timestamp_limit": "Native diagnostic journals exclude late MCU writes; no accepted-write timestamp claimed."}
        source_mismatches = [p for p, digest in job["source_pins"].items() if sha(root / p) != digest]
    else:
        score_path = capture / "earned_score.json"
        score = json.loads(score_path.read_text()) if score_path.exists() else {}
        checks["actual_earned_save_reset_restore"] = (
            score.get("passed") is True and score.get("earned_best_raw", 0) > 0 and
            score.get("saved_bytes") == 178 and score.get("synthetic_ram_writes") == 0 and
            all(score.get(k) is True for k in ("cpu_reset_cleared_best", "hps_upload_exact", "hps_restore_exact")))
        saved = capture / "earned.nvm"
        checks["saved_score_artifact"] = saved.exists() and saved.stat().st_size == 178
        checks["settled_vga_coverage"] = all(int(r["vga_pixels"]) == 57344 for r in metrics[4:])
        manifest = root / ("sim/build/earned_wrapper_inputs.sha256" if version == "v2" else f"sim/build/earned_wrapper_{version}_inputs.sha256")
        checks["pinned_build_manifest"] = sha(manifest) == job["manifest_sha256"]
        source_mismatches = []
        for line in manifest.read_text().splitlines():
            digest, filename = line.split(None, 1)
            filename = filename.lstrip("*")
            if sha(root / filename) != digest:
                source_mismatches.append(filename)
        evidence = {"earned_score": score, "saved_sha256": sha(saved) if saved.exists() else None,
                    "framework_limit": "First startup VGA field retained separately; real framework with ideal PLL/peripheral interfaces, not physical output."}
        if version in ("v4", "v5"):
            restored = capture / "restored.nvm"
            checks["restored_score_artifact_exact"] = (
                saved.exists() and restored.exists() and saved.stat().st_size == 178 and
                restored.read_bytes() == saved.read_bytes() and
                int.from_bytes(saved.read_bytes()[-4:], "big") == score.get("earned_best_raw"))
            reset_path = capture / "reset_probe.csv"
            restore_path = capture / "restore_probe.csv"
            reset_rows = list(csv.DictReader(reset_path.open())) if reset_path.exists() else []
            restore_rows = list(csv.DictReader(restore_path.open())) if restore_path.exists() else []
            checks["observed_actual_reset_clear"] = bool(reset_rows) and int(reset_rows[-1]["best"]) == 0
            checks["observed_real_donor_completion"] = (
                len(restore_rows) >= 2 and any(int(r["restoring"]) == 1 for r in restore_rows[:-1]) and
                int(restore_rows[-1]["restoring"]) == 0 and
                all(int(a["tick"]) < int(b["tick"]) for a, b in zip(restore_rows, restore_rows[1:])))
            evidence.update(restored_sha256=sha(restored) if restored.exists() else None,
                            reset_probe_sha256=sha(reset_path) if reset_path.exists() else None,
                            restore_probe_sha256=sha(restore_path) if restore_path.exists() else None)
    checks["current_pinned_sources"] = not source_mismatches
    graphics_pass = checks["all_canonical_images_available"] and all(i.get("different_units") == 0 and i.get("reference_bytes") == 172032 for i in images)
    result = {"scope": "Finite actual RTL CPU feature replay; no synthetic game/score behavior, image masks or frame shifts. Unsampled frames, full-game correctness, fitted resources/timing and physical hardware remain unqualified.",
              "mode": args.mode, "fields": len(metrics), "checks": checks,
              "finite_feature_pass": all(checks.values()), "canonical_graphics_pass": graphics_pass,
              "full_acceptance_pass": all(checks.values()) and graphics_pass,
              "source_mismatches": source_mismatches, "canonical_images": images,
              "evidence": evidence, "job_sha256": sha(job_path), "terminal_sha256": sha(receipt_path),
              "metrics_sha256": sha(capture / "frames.csv"), "applied_ports_sha256": sha(applied_path)}
    output = root / "research" / (name + "_feature_terminal.json")
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"output": output.name, "finite_feature_pass": result["finite_feature_pass"],
                      "canonical_graphics_pass": graphics_pass,
                      "failed_checks": [k for k,v in checks.items() if not v],
                      "image_differences": [{"field": i["field"], "different_pixels": i.get("different_units")} for i in images if i.get("different_units") != 0]}))
    return 0 if result["full_acceptance_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
