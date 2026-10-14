"""Separate coverage receipt; never backfill or relabel the v5 qualification."""
from pathlib import Path
import csv
import json
import os
from prepare_earned_prefix181 import NAME, STAGING, CANON, observed_host, pins, sha


def rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def main():
    root, canon = STAGING, CANON
    terminal = root / "research" / (NAME + "_exit.json")
    if not terminal.exists():
        print(json.dumps({"pending": True, "terminal": str(terminal)}))
        raise SystemExit(2)
    receipt = root / "research" / (NAME + "_verification.json")
    assert not receipt.exists(), "preserve existing verification"
    end = json.loads(terminal.read_text())
    running = json.loads((root / "research" / (NAME + "_running.json")).read_text())
    source = json.loads((root / "research" / (NAME + "_source.json")).read_text())
    original, current_pins = pins(root, canon)
    out = root / "sim/captures/rtl" / NAME
    v5 = root / "sim/captures/rtl/kyros_earned_wrapper901_v5"
    reference = root / "sim/captures/kyros/combat3600_v2"
    frames = rows(out / "frames.csv")
    ports = rows(out / "applied_gameplay_ports.csv")
    baseline = rows(v5 / "applied_gameplay_ports.csv")[:181]
    old_frames = rows(v5 / "frames.csv")[:181]
    overlap = {}
    for image in out.glob("*.rgb"):
        previous = v5 / image.name
        if previous.exists():
            overlap[image.name] = sha(image) == sha(previous)
    images = {}
    for field in (119, 179):
        actual = out / f"frame_{field:06d}.core.rgb"
        expected = reference / f"frame_{field:06d}.display.rgb"
        a, b = actual.read_bytes(), expected.read_bytes()
        images[str(field)] = {"actual": str(actual), "reference": str(expected), "reference_kind": "MAME canonical displayed RGB, same as v5 qualification",
             "actual_sha256": sha(actual), "reference_sha256": sha(expected),
             "bytes": len(a), "pixel_differences": sum(a[i:i+3] != b[i:i+3] for i in range(0, len(a), 3)) if len(a) == len(b) else None,
             "framework_exact": a == (out / f"frame_{field:06d}.vga.rgb").read_bytes()}
    private = root / "sim/captures/diagnostics/earned_prefix181"
    checks = {"actual_terminal_exit_zero": end["exit_code"] == 0 and end["stage"] == "simulation",
        "terminal_matches_owned_process": end["simulation_pid"] == running["simulation_pid"],
        "complete181_fields": [int(r["frame"]) for r in frames] == list(range(181)),
        "complete181_input_applications": len(ports) == 181 and ports == baseline,
        "all181_frame_stats_match_v5": frames == old_frames,
        "all_overlap_rgb_exact": len(overlap) >= 12 and all(overlap.values()),
        "production_pins_exact_v5_and_content_equivalent_canonical": current_pins == source["source_pins"] and {name: sha(canon / name) for name in current_pins} == source["canonical_byte_pins"],
        "private_host_exact_four_substitutions": (private / "wrapper_main.cpp").read_text() == observed_host((root / original["derived_host"]).read_text()),
        "private_host_pin": sha(private / "wrapper_main.cpp") == source["derived_host_sha256"],
        "executable_pin": sha(out / "alpha68kn_wrapper_earned_prefix181_sim") == end["executable_sha256"],
        "rom_pin": sha(root / "roms/kyros/download.bin") == end["rom_sha256"],
        "ports_pin": sha(reference / "frame_states.csv") == end["ports_sha256"],
        "target_images_actual_full_fields": all(v["bytes"] == 256*224*3 and v["framework_exact"] for v in images.values()),
        "no_post_prefix_score_fixture": not (out / "earned_score.json").exists()}
    result = {"scope": "Distinct actual RTL HPS181-field prefix. Complete overlapping stats, input ticks and RGB must equal frozen v5. New119/179 coverage stays separate; v5 finite/full graphics results remain unchanged.",
        "checks": checks, "observer_prefix_fidelity_pass": all(checks.values()), "images": images, "overlap": overlap,
        "canonical119_179_graphics_pass": all(checks.values()) and all(v["pixel_differences"] == 0 for v in images.values()),
        "full_feature_acceptance": False, "whole_game_acceptance": False,
        "terminal_sha256": sha(terminal), "verifier_sha256": sha(Path(__file__)), "v5_feature_terminal_sha256": sha(root / "research/kyros_earned_wrapper901_v5_feature_terminal.json")}
    receipt.write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"receipt": str(receipt), "fidelity_pass": result["observer_prefix_fidelity_pass"],
        "failed_checks": [k for k,v in checks.items() if not v], "image_differences": {k:v["pixel_differences"] for k,v in images.items()},
        "full_feature_acceptance": False}))
    raise SystemExit(0 if result["observer_prefix_fidelity_pass"] else 1)


if __name__ == "__main__":
    main()
