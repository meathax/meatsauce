"""Record legal cocktail/player-turn reference and retain terminal evidence."""
from pathlib import Path
import csv
import argparse
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
    parser.add_argument("--version", choices=("v1", "v2"), default="v2")
    parser.add_argument("--frames", type=int, default=1801)
    args = parser.parse_args()
    assert args.frames > 1200
    NAME = f"kyros_cocktail{args.frames}" + ("_v2" if args.version == "v2" else "")
    job = ROOT / "research" / (NAME+"_oracle_job.json")
    out = ROOT / "sim/captures/kyros" / (f"cocktail{args.frames}" + ("_v2" if args.version == "v2" else ""))
    if job.exists() or out.exists():
        raise SystemExit("Existing oracle evidence: inspect its terminal before restarting")
    identity = json.loads((ROOT / "research/oracle_identity.json").read_text())
    source = json.loads((ROOT / "research" / ("kyros_cocktail_source_v2.json" if args.version == "v2" else "kyros_cocktail_source.json")).read_text())
    exe = Path(identity["executable"])
    lua = ROOT / source["derived_source"]
    assert sha(exe) == identity["executable_sha256"] and exe.read_bytes()[:2] == b"MZ"
    assert sha(lua) == source["derived_sha256"]
    out.mkdir(parents=True)
    for name in ("cfg","nvram","states"):
        (out / name).mkdir()
    command = [str(exe), "kyros", "-rompath", str(ROOT / "roms"),
               "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-nothrottle", "-noautoframeskip", "-frameskip", "0",
               "-autoboot_delay", "0", "-autoboot_script", str(lua),
               "-pluginspath", str(exe.parent / "plugins"), "-seconds_to_run", str(int(args.frames/59.185606)+15),
               "-snapshot_directory", str(out), "-cfg_directory", str(out / "cfg"),
               "-nvram_directory", str(out / "nvram"), "-state_directory", str(out / "states"),
               "-wavwrite", str(out / "audio.wav")]
    record = {"worker_pid": os.getpid(), "started": time.time(), "command": command,
              "source_parent": subprocess.check_output(["git","rev-parse","HEAD"], cwd=ROOT, text=True).strip(),
              "executable_sha256": sha(exe), "lua_sha256": sha(lua),
              "runner_sha256": sha(Path(__file__)), "scenario": source,
              "rom_sha256": sha(ROOT / "roms/kyros/download.bin"), "frames": args.frames}
    env = dict(os.environ, ALPHA_CAPTURE_DIR=out.as_posix(), ALPHA_CAPTURE_MODE="cocktail", ALPHA_CAPTURE_FRAMES=str(args.frames))
    with (out / "mame.log").open("w",encoding="utf-8") as log:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                 creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        record["mame_pid"] = child.pid
        job.write_text(json.dumps(record,indent=2)+"\n",encoding="utf-8")
        code = child.wait()
    record.update(exit_code=code, ended=time.time())
    (ROOT / "research" / (NAME+"_oracle_exit.json")).write_text(json.dumps(record,indent=2)+"\n",encoding="utf-8")
    checks = {"exit_zero": code == 0, "completion": (out / "complete.txt").exists(),
              "no_lua_failure": not (out / "failure.txt").exists()}
    if all(checks.values()):
        normalize(out.resolve())
        rows = list(csv.DictReader((out / "frame_states.csv").open()))
        checks["all_fields"] = len(rows) == args.frames and [int(r["frame"]) for r in rows] == list(range(args.frames))
        checks["legal_dips"] = {int(r["in1"]) for r in rows} == {0x46}
        checks["two_player_start"] = any(int(r["in0"]) & 0x8000 for r in rows)
        flips = list(csv.DictReader((out / "native_flip.csv").open()))
        checks["flip_trace_complete"] = len(flips) == args.frames
        record["flipped_fields"] = [int(r["frame"]) for r in flips if int(r["flip"]) == 1]
        checks["player2_cocktail_turn"] = bool(record["flipped_fields"])
        record["ports_sha256"] = sha(out / "frame_states.csv")
        record["artifacts"] = [{"path":str(p.relative_to(ROOT)),"sha256":sha(p)}
                               for p in sorted(out.iterdir()) if p.is_file()]
    record.update(checks=checks, passed=all(checks.values()), wall_seconds=time.time()-record["started"])
    (ROOT / "research" / (NAME+"_oracle_verification.json")).write_text(json.dumps(record,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"passed":record["passed"],"checks":checks,
                      "first_flipped_field":next(iter(record.get("flipped_fields",[])),None)}))
    return 0 if record["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
