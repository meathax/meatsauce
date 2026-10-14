"""Finite cheated MAME scene discovery, with actual process/terminal receipts."""
from pathlib import Path
import argparse
import csv
import hashlib
import json
import os
import subprocess
import time
from normalize_oracle_display import normalize

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", choices=("kyros", "kyrosj"), default="kyros")
    parser.add_argument("--frames", type=int, default=36000)
    parser.add_argument("--route", choices=("raw-up", "raw-left", "centered-up", "centered-right", "stairs-zigzag", "corridor"), default="raw-up")
    parser.add_argument("--scene", choices=("natural", "candidate-5", "candidate-5-last-room"), default="natural")
    parser.add_argument("--resume-inputs", action="store_true")
    parser.add_argument("--ending", action="store_true")
    args = parser.parse_args()
    if args.ending and args.scene != "candidate-5-last-room":
        parser.error("--ending requires the guarded candidate-5-last-room fixture")
    suffix = "" if args.route == "raw-up" else "_" + args.route.replace("-", "_")
    if args.scene != "natural":
        suffix += "_scene5"
        if args.scene == "candidate-5-last-room":
            suffix += "_lastroom"
    if args.resume_inputs:
        suffix += "_moving"
    if args.ending:
        suffix += "_ending"
    name = f"{args.set}_late_scene_candidates{args.frames}{suffix}"
    out = ROOT / "sim/captures" / args.set / f"late_scene_candidates{args.frames}{suffix}"
    job = ROOT / "research" / f"{name}_job.json"
    if out.exists() or job.exists():
        raise SystemExit("Refusing to replace existing scene discovery evidence")
    out.mkdir(parents=True)
    for directory in ("cfg", "nvram", "states"):
        (out / directory).mkdir()
    identity = json.loads((ROOT / "research/oracle_identity.json").read_text())
    exe = Path(identity["executable"])
    assert exe.read_bytes()[:2] == b"MZ"
    assert sha(exe) == identity["executable_sha256"]
    profile_source = ROOT / "research/kyros_scene_fixture_profiles.json"
    fixture_profile = json.loads(profile_source.read_text())[args.set]
    assert sha(ROOT / "roms" / args.set / "maincpu.bin") == fixture_profile["program_sha256"]
    ending_source = ROOT / "research/kyros_ending_fixture_profile.json"
    if args.ending:
        ending_profile = json.loads(ending_source.read_text())
        rom = (ROOT / "roms" / args.set / "maincpu.bin").read_bytes()
        assert sha(ROOT / "roms" / args.set / "maincpu.bin") == ending_profile["program_sha256"][args.set]
        for block in ending_profile["blocks"]:
            data = bytes.fromhex(block["hex"])
            assert rom[block["address"]:block["address"]+len(data)] == data
    lua = ROOT / "sim/mame/capture_late_scene_candidates.lua"
    command = [str(exe), args.set, "-rompath", str(ROOT / "roms"),
               "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-nothrottle", "-noautoframeskip", "-frameskip", "0",
               "-autoboot_delay", "0", "-autoboot_script", str(lua),
               "-pluginspath", str(exe.parent / "plugins"),
               "-seconds_to_run", str(int(args.frames / 59.185606) + 15),
               "-snapshot_directory", str(out), "-cfg_directory", str(out / "cfg"),
               "-nvram_directory", str(out / "nvram"), "-state_directory", str(out / "states")]
    env = dict(os.environ, ALPHA_CAPTURE_DIR=out.as_posix(),
               ALPHA_CAPTURE_FRAMES=str(args.frames), ALPHA_FIXTURE_ROUTE=args.route,
               ALPHA_FIXTURE_SCENE=args.scene,
               ALPHA_FIXTURE_ENDING="1" if args.ending else "0",
               ALPHA_FIXTURE_RESUME_INPUTS="1" if args.resume_inputs else "0")
    env.update({"ALPHA_FIXTURE_SCENE_ENTRY": str(fixture_profile["scene_entry"]),
                "ALPHA_FIXTURE_ROOM_ENTRY": str(fixture_profile["room_entry"]),
                "ALPHA_FIXTURE_RETURN_PC": str(fixture_profile["return_pc"]),
                "ALPHA_FIXTURE_WAIT_LO": str(fixture_profile["game_wait_lo"]),
                "ALPHA_FIXTURE_WAIT_HI": str(fixture_profile["game_wait_hi"]),
                "ALPHA_FIXTURE_ROOM_TABLE": str(fixture_profile["scene5_table_base"])})
    started = time.time()
    metadata = {"worker_pid": os.getpid(), "started": started, "command": command,
                "source_parent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "source_sha256": {str(lua.relative_to(ROOT)): sha(lua),
                                  str(Path(__file__).relative_to(ROOT)): sha(Path(__file__)),
                                  "research/late_scene_cheat_historical_definitions.json": sha(ROOT / "research/late_scene_cheat_historical_definitions.json")},
                "executable_sha256": sha(exe), "set": args.set, "frames": args.frames,
                "route": args.route,
                "scene": args.scene,
                "resume_inputs": args.resume_inputs,
                "ending": args.ending,
                "fixture_profile": fixture_profile,
                "scope": "MAME scene discovery with explicit fixture RAM writes and optional guarded PC setup; not real RTL CPU gameplay or late-scene acceptance"}
    if args.scene == "candidate-5-last-room":
        metadata["source_sha256"]["research/kyros_scene5_room_descriptors.json"] = sha(ROOT / "research/kyros_scene5_room_descriptors.json")
    metadata["source_sha256"]["research/kyros_scene_fixture_profiles.json"] = sha(profile_source)
    if args.ending:
        metadata["source_sha256"]["research/kyros_ending_fixture_profile.json"] = sha(ending_source)
    with (out / "mame.log").open("w", encoding="utf-8") as log:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        metadata["mame_pid"] = child.pid
        job.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        code = child.wait()
    metadata.update(exit_code=code, ended=time.time())
    exitfile = ROOT / "research" / f"{name}_exit.json"
    exitfile.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    checks = {"exit_zero": code == 0, "completion_marker": (out / "complete.txt").exists(),
              "no_lua_failure": not (out / "failure.txt").exists()}
    if args.scene != "natural":
        setup = out / "fixture_setup.json"
        checks["guarded_scene_setup"] = setup.exists()
        if setup.exists():
            metadata["fixture_setup"] = json.loads(setup.read_text())
            checks["guarded_scene_setup"] = (
                metadata["fixture_setup"]["a6"] == 0x20000 and
                metadata["fixture_setup"]["sp"] == 0x20ff4 and
                metadata["fixture_setup"]["return_address"] == fixture_profile["return_pc"] and
                metadata["fixture_setup"]["selector_after"] == 5 and
                metadata["fixture_setup"]["entry_pc"] == fixture_profile["scene_entry"])
    if args.scene == "candidate-5-last-room":
        setup = out / "late_room_setup.json"
        checks["guarded_late_room_setup"] = setup.exists()
        if setup.exists():
            metadata["late_room_setup"] = json.loads(setup.read_text())
            late = metadata["late_room_setup"]
            checks["guarded_late_room_setup"] = (
                late["a6"] == 0x20000 and late["sp"] == 0x20ff4 and
                late["return_address"] == fixture_profile["return_pc"] and late["entry_pc"] == fixture_profile["room_entry"] and
                late["room_requested"] == 0x0900)
    if args.ending:
        setup = out / "ending_setup.json"
        checks["guarded_ending_setup"] = setup.exists()
        if setup.exists():
            metadata["ending_setup"] = json.loads(setup.read_text())
            ending = metadata["ending_setup"]
            checks["guarded_ending_setup"] = (
                ending["a6"] == 0x20000 and ending["sp"] == 0x20ff4 and
                ending["return_address"] == fixture_profile["return_pc"] and
                ending["pc_redirected"] is False)
    if all(checks.values()):
        checks["all_frames_observed"] = sum(1 for _ in csv.DictReader((out / "frame_states.csv").open())) == args.frames
        normalize(out.resolve())
        pngs = sorted(out.glob("frame_*.png"))
        checks["expected_snapshot_count"] = len(pngs) == ((args.frames - 1) // 300 + 1 + int(args.frames > 179) + int((args.frames - 1) % 300 != 0))
        checks["complete_assets"] = all(
            p.with_suffix(".display.rgb").stat().st_size == 256*224*3 and
            p.with_suffix(".sprites.bin").stat().st_size == 8192 and
            p.with_suffix(".work.bin").stat().st_size == 4096 for p in pngs)
        if args.scene == "candidate-5-last-room":
            observed = []
            for p in pngs:
                field = int(p.stem.split("_")[1])
                data = p.with_suffix(".work.bin").read_bytes()
                if field > metadata["late_room_setup"]["frame"] and data[0x101] == 5 and data[0x110:0x112] == b"\x09\x00":
                    observed.append(field)
            metadata["late_room_observed_fields"] = observed
            checks["late_room_snapshot_present"] = bool(observed)
        if args.ending:
            observed = []
            for p in pngs:
                field = int(p.stem.split("_")[1])
                work = p.with_suffix(".work.bin").read_bytes()
                sprites = p.with_suffix(".sprites.bin").read_bytes()
                staff = bytes(sprites[0x11b0-i*2+1] for i in range(7))
                if field > metadata["ending_setup"]["frame"] and work[0xd10:0xd12] == bytes((5,3)) and staff == b"KAIROSU":
                    observed.append(field)
            metadata["ending_staff_observed_fields"] = observed
            checks["actual_staff_text_present"] = bool(observed)
        metadata["artifacts"] = [{"path": str(p.relative_to(ROOT)), "sha256": sha(p)}
                                 for p in sorted(out.glob("frame_*.*"))]
    metadata.update(checks=checks, passed=all(checks.values()),
                    wall_seconds=time.time()-started)
    (ROOT / "research" / f"{name}_verification.json").write_text(json.dumps(metadata, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"passed": metadata["passed"], "checks": checks}), flush=True)
    return 0 if metadata["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
