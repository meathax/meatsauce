"""Qualify a read-only E/VPA observer without declaring graphics closure."""
import csv
import json
from pathlib import Path

from run_irq_e_phase61 import ROOT, NAME, observed_host, sha


def rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def main():
    terminal = ROOT / "research" / (NAME + "_exit.json")
    if not terminal.exists():
        print(json.dumps({"status": "pending", "terminal": str(terminal)}))
        return 2
    receipt = ROOT / "research" / (NAME + "_verification.json")
    assert not receipt.exists(), "Preserve the original qualification receipt"
    ended = json.loads(terminal.read_text())
    job_path = ROOT / "research" / (NAME + "_job.json")
    job = json.loads(job_path.read_text())
    output = ROOT / "sim/captures/rtl" / NAME
    original = ROOT / "sim/captures/rtl/kyros_instruction60_diagnostic"
    generated = ROOT / "sim/captures/diagnostics" / (NAME + "_source/system_main.cpp")
    frames = rows(output / "frames.csv")
    trace = rows(output / "e_phase.csv")
    instructions = rows(output / "instruction_events.csv")
    pictures = sorted(original.glob("*.rgb"))
    differing = [p.name for p in pictures if not (output / p.name).exists()
                 or p.read_bytes() != (output / p.name).read_bytes()]
    changes = [r for r in trace if r["e_counter_before"] != r["e_counter_after"]]
    by_tick = {r["tick"]: r for r in trace}
    vectors = [r for r in instructions if int(r["address"]) in (0x64, 0x68) and r["rw"] == "1"]
    vector_states = [{"frame": int(v["frame"]), "level": 1 if int(v["address"]) == 0x64 else 2,
                      "tick": int(v["tick"]), "registered_state": by_tick.get(v["tick"])} for v in vectors]
    increments = [int(r["tick"]) for r in changes]
    # Selected windows have large intentional gaps. Count periods only within
    # contiguous recorded windows, not across the omitted game interval.
    gaps = [b - a for a, b in zip(increments, increments[1:]) if b - a <= 80]
    checks = {
        "terminal_exit_zero": ended["exit_code"] == 0,
        "same_owned_simulation": ended["simulation_pid"] == job["simulation_pid"],
        "complete_real_cpu_fields": len(frames) == 61 and all(int(r["frame"]) == i for i, r in enumerate(frames)),
        "complete_unique_pixels_and_no_renderer_failures": bool(frames) and all(
            int(r["pixels"]) == 57344 and int(r["duplicates"]) == 0
            and int(r["deadline_misses"]) == 0 and int(r["row_overflows"]) == 0 for r in frames),
        "all_original_19_images_exact": len(pictures) == 19 and not differing,
        "all_original_instruction_bytes_exact": (output / "instruction_events.csv").read_bytes()
            == (original / "instruction_events.csv").read_bytes(),
        "registered_counter_range": bool(trace) and all(0 <= int(r["e_counter_before"]) <= 9
            and 0 <= int(r["e_counter_after"]) <= 9 for r in trace),
        "all_ten_counter_states_observed": {int(r["e_counter_after"]) for r in trace} == set(range(10)),
        "counter_changes_increment_modulo10": bool(changes) and all(
            int(r["e_counter_after"]) == (int(r["e_counter_before"]) + 1) % 10 for r in changes),
        "observed_e_clock_period80": bool(gaps) and set(gaps) == {8},
        "four_irq_vector_states_observed": len(vector_states) == 4
            and all(v["registered_state"] is not None for v in vector_states),
        "vpa_and_vma_activity_observed": any(r["vpa_latched_after"] == "0" for r in trace)
            and any(r["vma_n_after"] == "0" for r in trace),
        "original_rtl_and_host_pins_unchanged": all(sha(ROOT / p) == h for p, h in job["source_pins"].items()),
        "only_declared_private_host_transformation": generated.read_text() == observed_host(
            (ROOT / "sim/system_main.cpp").read_text()) and sha(generated) == job["generated_host_sha256"],
        "actual_executable_pinned": sha(output / "alpha68kn_irq_e_phase61_sim") == job["executable_sha256"],
    }
    result = {
        "scope": "Observer fidelity and finite actual registered E/VPA/VMA state; no correction, unique physical startup phase, CPU data-sampling edge or whole-game graphics acceptance inferred",
        "checks": checks, "observer_fidelity_pass": all(checks.values()),
        "whole_game_acceptance": False, "B16_closure": False,
        "fields": len(frames), "images": len(pictures), "differing_images": differing,
        "trace_rows": len(trace), "counter_change_spacing_master_ticks": sorted(set(gaps)),
        "e_period_master_ticks": 80 if gaps and set(gaps) == {8} else None,
        "vector_states": vector_states,
        "job_sha256": sha(job_path), "terminal_sha256": sha(terminal),
        "executable_sha256": job["executable_sha256"], "verifier_sha256": sha(__file__),
        "trace_sha256": sha(output / "e_phase.csv"),
        "instruction_sha256": sha(output / "instruction_events.csv"),
        "limits": "Native board-accepted transaction events and MAME memory callbacks are not asserted to be the same CPU sampling edge. Existing timed18-pixel and canonical atomic failures remain open. No clock/phase fit is justified solely by this observer.",
    }
    receipt.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"receipt": str(receipt), "observer_fidelity_pass": all(checks.values()),
                      "failed_checks": [k for k, v in checks.items() if not v],
                      "fields": len(frames), "trace_rows": len(trace),
                      "vector_counter_states": [v["registered_state"]["e_counter_after"]
                          if v["registered_state"] else None for v in vector_states]}))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
