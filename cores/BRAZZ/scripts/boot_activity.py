#!/usr/bin/env python3
"""Bounded summary/structural checks for private natural-RTL boot observations.

This is not an attract/gameplay acceptance verifier or a restorable checkpoint.
The caller must verify a process/session is live before interpreting live output.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "sim/obj_dir/boot_probe/activity"


def file_sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def complete_frame(state, stem):
    metadata = state.get("complete_scanout")
    if metadata is None:
        return None  # older observer models intentionally record only a partial image
    assert metadata["width"] == 320 and metadata["height"] == 240, "qualified game capture geometry"
    assert metadata["completed"] >= 0 and metadata["rejected"] >= 0
    assert metadata["image_saved"] == (metadata["completed"] > 0), "complete frame availability mismatch"
    path = stem / "scanout_complete.ppm"
    if not metadata["image_saved"]:
        assert not path.exists(), "stale complete image without a completed frame"
        return {"available": False}
    assert 0 <= metadata["start_clock"] < metadata["end_clock"] <= state["clock"], "invalid complete frame clock window"
    data = path.read_bytes()
    header = b"P6\n320 240\n255\n"
    assert data.startswith(header) and len(data) == len(header) + 320 * 240 * 3, "incomplete complete-frame PPM"
    return {"available": True, "width": 320, "height": 240,
            "start_clock": metadata["start_clock"], "end_clock": metadata["end_clock"],
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def inspect(require_terminal=False, run_id=None):
    if run_id is None:
        pointer = json.loads((BASE / "latest_run.json").read_text(encoding="utf-8"))
    else:
        assert run_id.isdecimal(), "invalid run identity"
        pointer = {"run_id": run_id, "directory": str((BASE / run_id).relative_to(ROOT))}
    directory = (ROOT / pointer["directory"]).resolve()
    assert directory.is_relative_to(BASE.resolve()), "run directory escapes private activity root"
    with (directory / "progress.csv").open(encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    assert rows, "no complete activity rows"
    for index, row in enumerate(rows):
        for key, value in row.items():
            if key in ("pc", "sr", "sp", "er"):
                int(value, 16)
            else:
                assert value is not None, "incomplete activity row"
                int(value)
        assert sum(int(row[k]) for k in ("cpu_memory", "dma_memory", "gpu_memory", "spu_memory", "scanout_memory")) == int(row["memory_requests"]), "memory ownership count mismatch"
        if index:
            for key in ("clock", "instructions", "architectural_accesses", "memory_requests", "raster_frames"):
                assert int(row[key]) >= int(rows[index - 1][key]), f"counter regressed: {key}"
    last = rows[-1]
    terminal_path = directory / "terminal/state.json"
    state_path = terminal_path if terminal_path.is_file() else directory / "latest/state.json"
    state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.is_file() else None
    if require_terminal:
        assert terminal_path.is_file(), "terminal snapshot is missing"
    if state:
        assert state["run_id"] == pointer["run_id"], "stale snapshot from another run"
        assert state["natural_rtl_observation"] and not state["restorable_checkpoint"]
        assert sum(state["access_latency_histogram"]) == state["architectural_accesses"], "latency histogram count mismatch"
        assert state["enabled_accesses"] + state["disabled_accesses"] == state["architectural_accesses"], "cache access classification mismatch"
        assert state["enabled_cycles"] + state["disabled_cycles"] == state["access_cycles"], "cache latency sum mismatch"
        if terminal_path.is_file():
            for key in ("clock", "instructions", "architectural_accesses", "gpu_packets", "gpu_pixels"):
                assert state[key] == int(last[key]), f"terminal/activity mismatch: {key}"
    memories = {}
    if terminal_path.is_file():
        for name, size in (("workram.bin", 0x800000), ("texture.bin", 0x800000),
                           ("framebuffer.bin", 0x800000), ("nvram.bin", 0x10000),
                           ("reset_ram.bin", 0x34)):
            p = terminal_path.parent / name
            assert p.stat().st_size == size, f"snapshot size mismatch: {name}"
            memories[name] = {"bytes": size, "sha256": file_sha256(p)}
    traces = {}
    if terminal_path.is_file():
        for name, counter in (("gpu_bus.csv", "gpu_trace_requests"),
                              ("video_mmio.csv", "video_trace_writes"),
                              ("concurrent_graphics_writes.csv", "concurrent_trace_writes")):
            p = directory / name
            if not p.is_file():
                continue  # older observer snapshots have no graphics context log
            with p.open(encoding="utf-8", newline="") as f:
                records = sum(1 for _ in csv.DictReader(f))
            assert records == state[counter], f"context trace counter mismatch: {name}"
            traces[name] = {"records": records, "bytes": p.stat().st_size,
                            "sha256": file_sha256(p)}
        if "gpu_bus.csv" in traces:
            if state.get("context_trace_closed", False):
                first = json.loads((directory / "first_gpu_packet/state.json").read_text(encoding="utf-8"))
                assert first["run_id"] == state["run_id"] and first["context_trace_closed"]
                assert first["clock"] <= state["clock"] and first["gpu_packets"] >= 1
                assert traces["gpu_bus.csv"]["records"] <= int(last["gpu_memory"]), "bounded GPU trace exceeds client count"
                for name, counter in (("gpu_bus.csv", "gpu_trace_requests"),
                                      ("video_mmio.csv", "video_trace_writes"),
                                      ("concurrent_graphics_writes.csv", "concurrent_trace_writes")):
                    assert traces[name]["records"] == first[counter], "bounded trace changed after first draw: " + name
            else:
                assert traces["gpu_bus.csv"]["records"] == int(last["gpu_memory"]), "GPU trace/client count mismatch"
    cabinet = None
    cabinet_path = directory / "cabinet_inputs.csv"
    if terminal_path.is_file() and cabinet_path.is_file():
        with cabinet_path.open(encoding="utf-8", newline="") as stream:
            events = list(csv.DictReader(stream))
        assert len(events) == state["cabinet_commands"] + state["cabinet_releases"], "cabinet event count mismatch"
        assert sum(e["event"] == "apply" for e in events) == state["cabinet_commands"]
        assert sum(e["event"] == "release" for e in events) == state["cabinet_releases"]
        previous_clock = 0
        for event in events:
            assert previous_clock <= int(event["clock"]) <= state["clock"], "cabinet event clock order"
            previous_clock = int(event["clock"])
            assert int(event["sequence"]) > 0
            assert all(0 <= int(event[k], 16) <= limit for k, limit in
                       (("p1_p2_n", 0xffffffff), ("p3_p4_n", 0xffffffff), ("system_n", 0xff), ("dips_n", 0xff)))
        cabinet = {"events": len(events), "commands": state["cabinet_commands"], "releases": state["cabinet_releases"],
                   "bytes": cabinet_path.stat().st_size, "sha256": file_sha256(cabinet_path)}
    frame = complete_frame(state, state_path.parent) if state else None
    windows = []
    for before, after in zip(rows, rows[1:]):
        clocks = int(after["clock"]) - int(before["clock"])
        instructions = int(after["instructions"]) - int(before["instructions"])
        accesses = int(after["architectural_accesses"]) - int(before["architectural_accesses"])
        latency = int(after["access_cycles"]) - int(before["access_cycles"])
        if not clocks:
            continue
        windows.append({"from_clock": int(before["clock"]), "to_clock": int(after["clock"]),
                        "instructions": instructions, "system_clocks_per_instruction": clocks / instructions if instructions else None,
                        "mean_architectural_access_latency": latency / accesses if accesses else None,
                        "architectural_wait_fraction": latency / clocks,
                        "pc_at_end": after["pc"], "gpu_packets": int(after["gpu_packets"]),
                        "raster_frames": int(after["raster_frames"]), "scanout_reads": int(after["scanout_memory"]),
                        "audio_nonzero": int(after["audio_nonzero"])})
    return {"schema": 1, "run_id": pointer["run_id"], "private_directory": str(directory.relative_to(ROOT)).replace("\\", "/"),
            "terminal_snapshot": terminal_path.is_file(), "structural_checks": "pass", "activity_rows": len(rows),
            "last_activity": last, "recent_windows": windows[-4:],
            "observed_state": state, "terminal_memory_hashes": memories, "graphics_context_traces": traces,
            "complete_scanout_image": frame,
            "cabinet_input_history": cabinet,
            "acceptance": "natural RTL boot diagnostic only; does not prove attract/gameplay or physical memory timing"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-terminal", action="store_true")
    parser.add_argument("--write-report", action="store_true")
    parser.add_argument("--run-id")
    args = parser.parse_args()
    result = inspect(args.require_terminal, args.run_id)
    if args.write_report:
        assert result["terminal_snapshot"], "refusing a final public report for a live/nonterminal run"
        target = ROOT / "docs/boot_activity_report.json"
        target.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
