"""Qualify completed legal-input reference and preserve exact snapshot lineage."""
from pathlib import Path
import csv
import hashlib
import json
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart3901"
BASELINE = ROOT / "sim/captures/kyros/idle_death7200_v2"
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    result_path = HERE / "verification.json"
    if result_path.exists():
        raise SystemExit("Verification receipt exists; preserve it.")
    terminal = json.loads((HERE / "exit.json").read_text())
    job = json.loads((HERE / "job.json").read_text())
    with (CAPTURE / "frame_states.csv").open() as f:
        states = list(csv.DictReader(f))
    with (BASELINE / "frame_states.csv").open() as f:
        prior = list(csv.DictReader(f))
    events = list(csv.DictReader((CAPTURE / "inputs.csv").open()))
    prefixes = [{"field": n, "equal": states[n] == prior[n]} for n in range(3601)]
    checks = {
        "actual_MAME_terminal0": terminal["exit_code"] == 0,
        "no_Lua_failure": not terminal["failure_file"],
        "actual3901_field_rows": len(states) == 3901,
        "actual_stop3901": "frames=3901" in (terminal["complete"] or ""),
        "all3601_full_state_prefix_rows_exact": all(x["equal"] for x in prefixes),
        "DIP_stays_206": {int(x["in1"]) for x in states} == {206},
    }
    expected = [(3620, "IN2", 1, 1), (3626, "IN2", 1, 0),
                (3660, "IN0", 128, 1), (3666, "IN0", 128, 0),
                (3740, "IN0", 4, 1), (3770, "IN0", 4, 0)]
    after = [(int(x["frame"]), x["port"], int(x["mask"]), int(x["active"]))
             for x in events if int(x["frame"]) >= 3601]
    checks["exact_second_legal_input_events"] = after == expected
    checks["second_coin_actual_port_rows"] = all((int(states[f]["in2"]) & 1) == 0
                                                for f in range(3621, 3627))
    checks["second_start_actual_port_rows"] = all((int(states[f]["in0"]) & 128) != 0
                                                 for f in range(3661, 3667))
    checks["post_restart_right_actual_port_rows"] = all((int(states[f]["in0"]) & 4) != 0
                                                       for f in range(3741, 3771))
    # Recover display orientation from byte-exact old canonical image, not
    # guessed rotation or substitution of raw RGB for displayed acceptance.
    choices = {"identity": None, "rotate90": Image.Transpose.ROTATE_90,
               "rotate180": Image.Transpose.ROTATE_180,
               "rotate270": Image.Transpose.ROTATE_270,
               "flip_lr": Image.Transpose.FLIP_LEFT_RIGHT,
               "flip_tb": Image.Transpose.FLIP_TOP_BOTTOM,
               "transpose": Image.Transpose.TRANSPOSE,
               "transverse": Image.Transpose.TRANSVERSE}
    old_png = Image.open(BASELINE / "frame_000720.png").convert("RGB")
    old_display = (BASELINE / "frame_000720.display.rgb").read_bytes()
    matches = [name for name, op in choices.items()
               if (old_png if op is None else old_png.transpose(op)).size == (256, 224)
               and (old_png if op is None else old_png.transpose(op)).tobytes() == old_display]
    checks["one_source_qualified_display_transform"] = len(matches) == 1
    assert checks["one_source_qualified_display_transform"], matches
    transform = matches[0]
    snapshots = []
    for png in sorted(CAPTURE.glob("frame_*.png")):
        im = Image.open(png).convert("RGB")
        op = choices[transform]
        if op is not None:
            im = im.transpose(op)
        assert im.size == (256, 224)
        display = png.with_suffix(".display.rgb")
        with display.open("xb") as f:
            f.write(im.tobytes())
        field = int(png.stem.split("_")[1])
        item = {"field": field, "png_sha256": H(png),
                "canonical_display_sha256": H(display),
                "work_sha256": H(png.with_suffix(".work.bin")),
                "sprites_sha256": H(png.with_suffix(".sprites.bin"))}
        if field <= 3600:
            old = BASELINE / display.name
            item["original_display_exact"] = old.exists() and old.read_bytes() == display.read_bytes()
        snapshots.append(item)
    checks["all_retained_first_lifecycle_display_prefix_exact"] = all(
        x["original_display_exact"] for x in snapshots if x["field"] <= 3600)
    checks["bounded_restart_images_present"] = all((CAPTURE / f"frame_{n:06d}.png").exists()
        for n in [3360, 3600, 3620, 3660, 3670, 3690, 3720, 3740, 3750, 3770, 3840, 3900])
    # Preserve exact bytes; these are unlabelled memory observations. Do not
    # infer life, score, hit, jump or pickup variables from arbitrary offsets.
    result = {"scope": "Actual pinned MAME legal death/restart input oracle; visual restart qualification separate; no native execution",
              "checks": checks, "finite_reference_input_and_prefix_pass": all(checks.values()),
              "display_transform": transform, "source_pins": {
                  "job": H(HERE / "job.json"), "terminal": H(HERE / "exit.json"),
                  "Lua": H(HERE / "capture_restart.lua"), "verifier": H(Path(__file__)),
                  "new_frame_states": H(CAPTURE / "frame_states.csv"),
                  "prior_frame_states": H(BASELINE / "frame_states.csv"),
                  "inputs": H(CAPTURE / "inputs.csv"),
                  "orientation_reference_png": H(BASELINE / "frame_000720.png"),
                  "orientation_reference_display": H(BASELINE / "frame_000720.display.rgb")},
              "second_inputs": expected, "snapshots": snapshots,
              "native_restart_pass": False,
              "jump_hit_pickup_semantics": "Unknown; prior legal controls and score changes do not independently prove these actions.",
              "memory_semantics": "Unlabelled actual work/sprite snapshots; no invented offsets or CPU/RAM edits."}
    result_path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"path": str(result_path), "sha256": H(result_path),
                      "checks": checks, "snapshots": len(snapshots),
                      "capture": str(CAPTURE)}))


if __name__ == "__main__":
    main()
