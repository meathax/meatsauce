"""Package the completed reference without rerunning or rewriting its receipts."""
from pathlib import Path
import hashlib
import json

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart3901"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    outputs = [HERE / n for n in ("visual_qualification.json", "review.md", "import_manifest.json")]
    if any(p.exists() for p in outputs):
        raise SystemExit("Final reference receipts already exist; preserve them.")
    verification_path = HERE / "verification.json"
    verification = json.loads(verification_path.read_text())
    terminal = json.loads((HERE / "exit.json").read_text())
    assert sha(verification_path) == "0b4e054649d1d9c2248a8ee8caf85fd4fb92d7648c0eed694c2bef41a9380206"
    assert terminal["exit_code"] == 0 and not terminal["failure_file"]
    assert len(verification["checks"]) == 13 and all(verification["checks"].values())
    assert verification["finite_reference_input_and_prefix_pass"]
    assert len(verification["snapshots"]) == 44
    pin_paths = {
        "job": HERE / "job.json", "terminal": HERE / "exit.json",
        "Lua": HERE / "capture_restart.lua", "verifier": HERE / "verify_restart_reference.py",
        "new_frame_states": CAPTURE / "frame_states.csv", "inputs": CAPTURE / "inputs.csv",
    }
    for key, path in pin_paths.items():
        assert sha(path) == verification["source_pins"][key], (key, path)
    snapshots = {x["field"]: x for x in verification["snapshots"]}
    markers = [
        (3360, "GAME OVER", "First game has ended; actual displayed image matches retained original reference."),
        (3600, "Title", "Return to title before the second legal coin/start sequence; original displayed image exact."),
        (3690, "Second stage introduction", "Actual PNG shows 1 STAGE CASTLE SKETCH after the second start, score 0 and credit 0."),
        (3740, "Transition", "Black transition with HUD; the recorded right pulse does not prove player movement."),
        (3770, "Transition", "Black transition with HUD at the right-pulse release boundary."),
        (3900, "Second live gameplay", "Actual PNG shows the courtyard, player sprite and full green status bar after restart, score 0 and credit 0."),
    ]
    observed = []
    for field, label, description in markers:
        item = snapshots[field]
        base = CAPTURE / f"frame_{field:06d}"
        for suffix, key in ((".png", "png_sha256"), (".display.rgb", "canonical_display_sha256"),
                            (".work.bin", "work_sha256"), (".sprites.bin", "sprites_sha256")):
            assert sha(base.with_name(base.name + suffix)) == item[key], (field, suffix)
        observed.append({"field": field, "label": label, "observation": description,
                         "method": "Human visual inspection of actual captured PNG; no RAM semantic inference",
                         "png_path": str(base.with_name(base.name + ".png")),
                         "canonical_display_path": str(base.with_name(base.name + ".display.rgb")),
                         "png_sha256": item["png_sha256"],
                         "canonical_display_sha256": item["canonical_display_sha256"]})
    qualification = {
        "schema": "kyros_legal_restart_reference_v1",
        "scope": "Pinned MAME 0.289 actual CPU legal-input death/restart oracle; native execution separately pending",
        "game": "kyros", "fields": 3901, "in1_dip": 206,
        "input_path": str(CAPTURE / "frame_states.csv"),
        "input_sha256": sha(CAPTURE / "frame_states.csv"),
        "event_path": str(CAPTURE / "inputs.csv"),
        "event_sha256": sha(CAPTURE / "inputs.csv"),
        "canonical_display_transform": verification["display_transform"],
        "state_prefix_rows_exact": 3601,
        "verification_path": str(verification_path), "verification_sha256": sha(verification_path),
        "actual_mame_pid": terminal["mame_pid"], "actual_terminal_exit": terminal["exit_code"],
        "terminal_path": str(HERE / "exit.json"), "terminal_sha256": sha(HERE / "exit.json"),
        "finalizer_sha256": sha(Path(__file__)),
        "markers": observed,
        "reference_restart_lifecycle_pass": True,
        "native_restart_pass": False,
        "full_P5_P7_pass": False,
        "right_pulse_movement_proven": False,
        "successful_jump": "unknown", "enemy_hit": "unknown", "pickup": "unknown",
        "memory_semantics": "Snapshots remain unlabelled; no invented work-offset variables or CPU/RAM edits",
        "limits": ["The reference proves its own lifecycle; it does not substitute for merged native execution.",
                   "Right is applied during transition; successful motion must not be inferred.",
                   "Existing combat image failures and unresolved IRQ ordering remain unchanged."],
    }
    outputs[0].write_text(json.dumps(qualification, indent=2) + "\n")
    outputs[1].write_text(
        "# Legal death and restart reference\n\n"
        "Pinned MAME completed 3901 fields with exit 0. All 13 verifier checks pass: every recorded state row through field 3600 and each retained displayed checkpoint exactly matches the original idle-death reference. Only actual PCB coin, start and right inputs extend the sequence; no CPU or memory changes are used.\n\n"
        "Use `sim/captures/kyros/idle_death_restart3901/frame_states.csv` as the native replay input. It retains IN1=206 (hard difficulty, default lives). Lua changes ports after recording a field, so the actual second coin is present in rows 3621–3626, start in 3661–3666 and right in 3741–3770. Do not manually shift this CSV.\n\n"
        "The decisive displayed checkpoints are GAME OVER at 3360, title at 3600, the second stage introduction at 3690 and courtyard gameplay with the player at 3900. Fields 3740 and 3770 are black transitions: the right pulse proves input application but does not prove movement. Canonical `.display.rgb` files use the transform uniquely qualified against the original byte-exact displayed reference; raw RGB is separately retained.\n\n"
        "`verification.json` preserves all 44 snapshot pins. Work and sprite memory files are actual observations with no guessed semantic offsets. Successful jump, enemy hit and pickup remain unknown; earlier legal controls and score changes do not independently prove these actions.\n\n"
        "This qualifies the MAME oracle only. Native restart, full P5/P7 acceptance and the final combined graphics/resource/timing gates remain pending. Existing combat graphics failures and IRQ ordering evidence are preserved. The parent owns the one merged-core native build and replay.\n"
    )
    portable = ["prepare_restart_reference.py", "verify_restart_reference.py", "finalize_reference.py",
                "capture_restart.lua", "job.json", "launcher.json", "running.json", "exit.json",
                "verification.json", "visual_qualification.json", "scenario.md", "review.md"]
    entries = [{"source": str(HERE / name),
                "destination": "research/kyros_restart_acceptance/" + name,
                "sha256": sha(HERE / name)} for name in portable]
    refs = []
    for name in ["frame_states.csv", "inputs.csv", "complete.txt"]:
        p = CAPTURE / name
        refs.append({"path": str(p), "sha256": sha(p), "scope": "Ignored actual captured evidence; do not publish"})
    for item in verification["snapshots"]:
        for suffix in [".png", ".display.rgb", ".work.bin", ".sprites.bin", ".rgb"]:
            p = CAPTURE / f"frame_{item['field']:06d}{suffix}"
            refs.append({"path": str(p), "sha256": sha(p), "scope": "Ignored actual captured evidence; do not publish"})
    manifest = {"schema": "kyros_restart_import_v1", "entries": entries,
                "capture_references": refs, "capture_root": str(CAPTURE),
                "runtime_scope": "Original old-staging helper paths and job bytes retained; no evidence rerun or receipt rewriting",
                "native_pending": True, "no_new_native_build": True}
    outputs[2].write_text(json.dumps(manifest, indent=2) + "\n")
    assert all(sha(Path(x["source"])) == x["sha256"] for x in entries)
    assert all(sha(Path(x["path"])) == x["sha256"] for x in refs)
    print(json.dumps({"reference_restart_lifecycle_pass": True, "native_restart_pass": False,
                      "input": qualification["input_path"], "input_sha256": qualification["input_sha256"],
                      "qualification_sha256": sha(outputs[0]), "manifest": str(outputs[2]),
                      "manifest_sha256": sha(outputs[2]), "portable_files": len(entries),
                      "capture_references": len(refs), "visual_marker_fields": [x[0] for x in markers]}))


if __name__ == "__main__":
    main()
