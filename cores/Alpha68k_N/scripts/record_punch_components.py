"""Add read-only per-channel sound measurements to the proven punch scenario."""
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_punch_release1081_components"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert os.name == "nt", "Run the existing Windows MAME through Windows Python"
    base = json.loads((ROOT / "research/kyros_punch_release1081_exit.json").read_text())
    assert base["capture_integrity_pass"] and base["checks"]["actual_punch_command_35"]
    reference = ROOT / "sim/captures/kyros/punch_release1081"
    output = ROOT / "sim/captures/kyros/punch_release1081_components"
    job = ROOT / "research" / (NAME + "_job.json")
    assert not job.exists() and not output.exists(), "Preserve existing job/capture"
    canonical = ROOT / "sim/mame/capture_punch_release1081.lua"
    assert sha(canonical) == base["lua_sha256"]
    source = ROOT / "sim/mame/trace_sound_components.lua"
    text = source.read_text()
    anchor = '    collect(assert(sound[":speaker"]), {1}, 1.0, "speaker", time)'
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + '''
    -- Read each existing output separately; no input, register or buffer writes.
    for channel = 1, 3 do
        collect(ym, {channel}, 0.30, "ym_ssg_" .. channel, time)
        collect(assert(sound[":aysnd1"]), {channel}, 0.30, "ay1_" .. channel, time)
        collect(assert(sound[":aysnd2"]), {channel}, 0.60, "ay2_" .. channel, time)
    end''')
    script = ROOT / "sim/mame/trace_punch_components.lua"
    assert not script.exists(), "Preserve existing derived observer"
    script.write_text(text, newline="\n")
    command = [v.replace(base["capture"], str(output)) for v in base["command"]]
    command[command.index("-autoboot_script") + 1] = str(script)
    output.mkdir(parents=True)
    env = {**os.environ, "ALPHA_CAPTURE_DIR": str(output), "ALPHA_CAPTURE_FRAMES": "1081",
           "ALPHA_CAPTURE_MODE": "punch_release", "ALPHA_CANONICAL_CAPTURE_SCRIPT": str(canonical)}
    record = {"worker_pid": os.getpid(), "started": time.time(), "command": command,
              "capture": str(output), "canonical_lua_sha256": sha(canonical),
              "observer_source_sha256": sha(source), "observer_sha256": sha(script),
              "source_parent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "scope": "Read-only per-source and individual PSG-channel measurements during identical real MAME CPU inputs; no termination pass inferred"}
    log = ROOT / "research" / (NAME + ".log")
    with log.open("w") as stream:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream,
                                 stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        record["mame_pid"] = child.pid
        job.write_text(json.dumps(record, indent=2) + "\n")
        code = child.wait()
    comparisons = {}
    for name in ["frame_states.csv", "audio.wav", *[p.name for p in reference.glob("frame_*.pix32")]]:
        original, actual = reference / name, output / name
        comparisons[name] = actual.exists() and sha(actual) == sha(original)
    path = output / "sound_components.csv"
    rows = list(csv.DictReader(path.open())) if path.exists() else []
    labels = sorted({r["component"] for r in rows})
    expected = sorted(["fm", "ym_ssg", "ay1", "ay2", "dac", "speaker"] +
                      [f"{chip}_{channel}" for chip in ["ym_ssg", "ay1", "ay2"] for channel in range(1, 4)])
    checks = {
        "mame_exit_zero": code == 0,
        "no_lua_error": "lua error" not in log.read_text().lower() and not (output / "failure.txt").exists(),
        "identical_actual_inputs": comparisons.get("frame_states.csv") is True,
        "identical_wav": comparisons.get("audio.wav") is True,
        "identical_raw_images": bool(comparisons) and all(v for k, v in comparisons.items() if k.endswith(".pix32")),
        "all_channel_labels": labels == expected,
        "finite_channel_statistics": bool(rows) and all(int(r["samples"]) > 0 and
            all(math.isfinite(float(r[k])) for k in ["time_end", "sum", "sum_squared", "minimum", "maximum"]) for r in rows),
    }
    record.update(exit_code=code, ended=time.time(), checks=checks,
                  observer_fidelity_pass=all(checks.values()), channel_rows=len(rows), labels=labels,
                  comparisons=comparisons, components_sha256=sha(path) if path.exists() else None,
                  bug_termination_pass=False)
    (ROOT / "research" / (NAME + "_exit.json")).write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"observer_fidelity_pass": all(checks.values()), "checks": checks,
                      "channel_rows": len(rows), "bug_termination_pass": False}))
    raise SystemExit(0 if all(checks.values()) else 2)


if __name__ == "__main__":
    main()
