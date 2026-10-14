"""Verify actual CPU prefix, nonvacuous channel activity and real warm reset."""
import csv
import hashlib
import json
from pathlib import Path

from prepare_kyros_active_noise_reset import NAME, ROOT, observed_host, sha


def rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def numeric_prefix(path, limit):
    with path.open(newline="") as stream:
        result = []
        for row in csv.DictReader(stream):
            if int(row["tick"]) > limit:
                break
            result.append(row)
        return result


def main():
    terminal_path = ROOT / "research" / (NAME + "_exit.json")
    if not terminal_path.exists():
        print(json.dumps({"pending": True, "terminal": str(terminal_path)}))
        return 2
    out = ROOT / "research" / (NAME + "_verification.json")
    assert not out.exists(), "Preserve the first actual terminal qualification"
    terminal = json.loads(terminal_path.read_text())
    job_path = ROOT / "research" / (NAME + "_job.json")
    job = json.loads(job_path.read_text())
    capture = ROOT / "sim/captures/rtl" / NAME
    reference = ROOT / "sim/captures/rtl/kyros_punch_release1081"
    result_path = capture / "active_reset.json"
    result = json.loads(result_path.read_text()) if result_path.exists() else {}
    assert result, "Missing actual reset result; retain failed terminal"
    completed = int(result["completed_fields"])
    assertion = int(result["assert_tick"])
    frame_rows = rows(capture / "frames.csv")
    reference_frames = rows(reference / "frames.csv")[:completed]
    applied = rows(capture / "applied_inputs.csv")
    pre_applied = [row for row in applied if row["boundary"] != "warm_reset"]
    ref_applied = rows(reference / "applied_inputs.csv")[:len(pre_applied)]
    audio_prefix = numeric_prefix(capture / "audio_events.csv", assertion)
    ref_audio_prefix = numeric_prefix(reference / "audio_events.csv", assertion)
    epoch_prefix = numeric_prefix(capture / "epoch_events.csv", assertion)
    ref_epoch_prefix = numeric_prefix(reference / "epoch_events.csv", assertion)
    trace = rows(capture / "active_noise_reset.csv")
    pre = [row for row in trace if row["phase"] == "0"]
    held = [row for row in trace if row["phase"] == "1"]
    post = [row for row in trace if row["phase"] == "2"]
    real_noise_changes = real_b_changes = 0
    for before, after in zip(pre, pre[1:]):
        active = all(int(row["mixer"]) & 2 and not int(row["mixer"]) & 16 and
                     int(row["volume_b"]) & 31 for row in (before, after))
        stable = before["mixer"] == after["mixer"] and before["volume_b"] == after["volume_b"]
        if active and stable and int(after["tick"]) > int(before["tick"]):
            real_noise_changes += before["noise"] != after["noise"]
            real_b_changes += before["channel_b"] != after["channel_b"]
    source = ROOT / "sim/captures/diagnostics" / (NAME + "_source")
    source_mismatches = [path for path, digest in job["source_pins"].items() if sha(ROOT / path) != digest]
    images = []
    for actual in sorted(capture.glob("frame_*.rgb")):
        field = int(actual.name[6:12])
        original = reference / actual.name
        if field < completed and original.exists():
            images.append({"field": field, "exact": actual.read_bytes() == original.read_bytes(),
                           "actual_sha256": sha(actual), "reference_sha256": sha(original)})
    reset_rows = rows(capture / "reset_events.csv")
    held_summary = next((row for row in reset_rows if row["phase"] == "held"), {})
    checks = {
        "actual_terminal_zero": terminal["exit_code"] == 0,
        "same_job_process_handles": terminal["worker_pid"] == job["worker_pid"] and terminal["simulation_pid"] == job["simulation_pid"],
        "frozen_original_source_pins": not source_mismatches,
        "private_host_exact_derivation": sha(source / "system_main.cpp") == job["generated_host_sha256"] and
            (source / "system_main.cpp").read_text() == observed_host((ROOT / "sim/system_main.cpp").read_text()),
        "readonly_retention_config_unchanged": sha(source / "active_noise_reset.vlt") == job["config_sha256"] and
            "public_flat_rw" not in (source / "active_noise_reset.vlt").read_text(),
        "actual_executable_pinned": sha(capture / "alpha68kn_active_noise_reset_sim") == job["executable_sha256"],
        "frozen_ports_and_payload": sha(ROOT / "sim/captures/kyros/punch_release1081/frame_states.csv") == job["input_trace_sha256"] and sha(ROOT / "roms/kyros/download.bin") == job["rom_sha256"],
        "complete_original_frame_metrics_prefix": len(frame_rows) == completed and frame_rows == reference_frames,
        "actual_original_input_application_prefix": bool(pre_applied) and pre_applied == ref_applied,
        "original_accepted_sound_prefix_exact": bool(audio_prefix) and audio_prefix == ref_audio_prefix,
        "original_main_epoch_prefix_exact": bool(epoch_prefix) and epoch_prefix == ref_epoch_prefix,
        "original_actual_rgb_prefix_exact": len(images) >= 40 and all(row["exact"] for row in images),
        "unique_pixels_no_renderer_fault": all(int(row["pixels"]) == 57344 and int(row["duplicates"]) == 0 and
            int(row["deadline_misses"]) == 0 and int(row["row_overflows"]) == 0 and int(row["unmapped"]) == 0 for row in frame_rows),
        "actual_noise_only_nonzero_before_reset": result["pre_active_ticks"] >= 64 and result["pre_nonzero_ticks"] >= 64 and
            real_noise_changes >= 4 and real_b_changes >= 4 and bool(pre) and int(pre[-1]["mixer"]) & 2 and
            not int(pre[-1]["mixer"]) & 16 and int(pre[-1]["volume_b"]) & 31,
        "real_warm_reset64_edges": result["reset_delivered"] and result["held_ticks"] == 64 and
            int(result["release_tick"]) - assertion == 64 and len(held) == 64 and
            all(row["reset"] == "1" for row in held) and int(held[-1]["tick"]) - int(held[0]["tick"]) == 63,
        "rom_sdram_retained_no_cold_download": all(row["cold_reset"] == "0" and row["downloading"] == "0" for row in held + post),
        "actual_held_cpu_audio_state_cleared": bool(held_summary) and all(int(held_summary[key]) == 0 for key in
            ("main_transactions", "sound_transactions", "ym_writes", "dac", "audio_sample")),
        "actual_channel_settles_by64": result["held_final_channel_b"] == 0 and int(held[-1]["channel_b"]) == 0,
        "actual500000_post_ticks_observed": result["post_ticks"] == 500000 and
            int(result["post_end_tick"]) - int(result["release_tick"]) == 500000 and bool(post) and
            int(post[-1]["tick"]) == int(result["post_end_tick"]),
        "no_retained_channel_after_reset": result["post_stale_nonzero_ticks"] == 0 and
            (result["post_ay2_data_writes"] > 0 or result["post_nonzero_ticks"] == 0),
    }
    receipt = {"scope": "Finite actual CPU active punch-noise warm reset with read-only existing AY2-B output, registers and sampled noise transitions; no full B03, all-game graphics or PCM alignment.",
               "checks": checks, "finite_active_noise_cpu_reset_pass": all(checks.values()),
               "full_B03_acceptance": False, "whole_game_acceptance": False, "canonical_graphics_pass": False,
               "actual_reset": result, "source_mismatches": source_mismatches,
               "observed_noise_transitions": real_noise_changes, "observed_channel_b_transitions": real_b_changes,
               "prefix_rgb_images": images, "prefix_sound_rows": len(audio_prefix), "prefix_epoch_rows": len(epoch_prefix),
               "receipt_sha256": {str(path.relative_to(ROOT)): sha(path) for path in (job_path, terminal_path, result_path)},
               "trace_sha256": sha(capture / "active_noise_reset.csv"),
               "limits": ["Held reset has a specified64-master-tick settling window; all nonzero samples before settling are retained.",
                          "Post-release observation is exactly500000 ticks; legitimate fresh chip writes/tone are allowed, not silently muted.",
                          "Original MAME atomic graphics failures remain; byte parity here is to the frozen actual RTL prefix only.",
                          "No Japan, death animation completion, precise MAME/native PCM alignment, fitted timing/resource or physical pass."]}
    out.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"output": str(out), "finite_pass": receipt["finite_active_noise_cpu_reset_pass"],
                      "completed_fields": completed, "failed_checks": [key for key, value in checks.items() if not value],
                      "full_B03_acceptance": False}))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
