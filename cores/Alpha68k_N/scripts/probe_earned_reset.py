"""Measure real ROM score-clear/readiness after legal earned gameplay in MAME."""
from pathlib import Path
import csv
import hashlib
import json
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_earned_reset1041"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = ROOT / "sim/captures/kyros/earned_reset1041"
    if out.exists():
        raise SystemExit("Existing probe: inspect its actual terminal; do not overwrite")
    out.mkdir(parents=True)
    for name in ("cfg", "nvram", "states"):
        (out / name).mkdir()
    identity = json.loads((ROOT / "research/oracle_identity.json").read_text())
    exe = Path(identity["executable"])
    lua = ROOT / "sim/mame/probe_earned_reset.lua"
    assert sha(exe) == identity["executable_sha256"]
    command = [str(exe),"kyros","-rompath",str(ROOT / "roms"),"-noreadconfig",
               "-skip_gameinfo","-video","none","-sound","none","-nothrottle",
               "-noautoframeskip","-frameskip","0","-autoboot_delay","0",
               "-autoboot_script",str(lua),"-pluginspath",str(exe.parent / "plugins"),
               "-seconds_to_run","35","-cfg_directory",str(out / "cfg"),
               "-nvram_directory",str(out / "nvram"),"-state_directory",str(out / "states")]
    record = {"started": time.time(), "command": command,
              "source_parent": subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
              "executable_sha256": sha(exe), "lua_sha256": sha(lua),
              "payload_sha256": sha(ROOT / "roms/kyros/download.bin"),
              "scope": "Legal actual MAME CPU gameplay and soft reset; no RAM/register/PC injection; not native RTL reset qualification"}
    env = dict(os.environ, ALPHA_CAPTURE_DIR=out.as_posix())
    with (out / "mame.log").open("w") as log:
        child = subprocess.Popen(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,
                                 creationflags=subprocess.CREATE_NO_WINDOW)
        record["mame_pid"] = child.pid
        (ROOT / "research" / (NAME+"_job.json")).write_text(json.dumps(record,indent=2)+"\n")
        code = child.wait()
    record.update(exit_code=code, ended=time.time())
    (ROOT / "research" / (NAME+"_exit.json")).write_text(json.dumps(record,indent=2)+"\n")
    with (out / "reset_probe.csv").open(newline="") as stream:
        actual = list(csv.DictReader(stream))
    with (ROOT / "sim/captures/kyros/combat3600_v2/frame_states.csv").open(newline="") as stream:
        expected = list(csv.DictReader(stream))[:901]
    checks = {"exit_zero": code == 0, "no_lua_failure": not (out / "failure.txt").exists(),
              "complete_marker": (out / "complete.txt").exists(),
              "complete_sequence": [int(r["frame"]) for r in actual] == list(range(1041)),
              "exact_legal_input_prefix": len(actual) >= 901 and all(
                  all(int(a[k]) == int(e[k]) for k in ("in0","in1","in2"))
                  for a,e in zip(actual[:901],expected)),
              "actual_earned_best": len(actual) >= 901 and int(actual[900]["best"]) > 0}
    reset = actual[901:]
    cleared = [int(r["frame"])-900 for r in reset if int(r["best"]) == 0]
    ready = [int(r["frame"])-900 for r in reset if int(r["best"]) == 0 and int(r["first"]) == 1 and int(r["last"]) == 2]
    result = {"scope": record["scope"], "checks": checks, "oracle_capture_pass": all(checks.values()),
              "earned_best_raw": int(actual[900]["best"]) if len(actual)>900 else None,
              "first_reset_clear_field_offset": cleared[0] if cleared else None,
              "reset_readiness_field_offsets": ready,
              "failed_native_wait_fields": 20000*1000/(384*264*8),
              "probe_sha256": sha(out / "reset_probe.csv"),
              "reference_ports_sha256": sha(ROOT / "sim/captures/kyros/combat3600_v2/frame_states.csv")}
    (ROOT / "research" / (NAME+"_verification.json")).write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps(result))
    raise SystemExit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()
