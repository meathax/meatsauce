"""Preserve failed v2 and derive one bounded, observed reset-protocol repair."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim/captures/diagnostics/earned_wrapper_v3"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if OUT.exists():
        raise SystemExit("Existing repaired harness: preserve and follow its owned job")
    source = json.loads((ROOT / "research/kyros_earned_wrapper_source.json").read_text())
    for key in ("host", "builder"):
        assert sha(ROOT / source["derived_"+key]) == source["derived_"+key+"_sha256"]
    failed = json.loads((ROOT / "research/kyros_earned_wrapper901_v2_exit.json").read_text())
    probe = json.loads((ROOT / "research/kyros_earned_reset1041_verification.json").read_text())
    assert failed["exit_code"] == 1 and probe["oracle_capture_pass"]
    assert probe["first_reset_clear_field_offset"] == 57 and probe["reset_readiness_field_offsets"] == [69]
    OUT.mkdir(parents=True)
    host = (ROOT / source["derived_host"]).read_text()
    old = "for(;reset_steps<1000;reset_steps++) {"
    assert host.count(old) == 1
    host = host.replace(old, "std::ofstream reset_probe(output/\"reset_probe.csv\");\n        reset_probe<<\"step,best,first,last,game_reset,paused\\n\";\n        for(;reset_steps<6000;reset_steps++) {")
    old = "            initialized=best()==0;"
    assert host.count(old) == 1
    host = host.replace(old, "            auto reset_best=best();\n            reset_probe<<reset_steps<<','<<reset_best<<','<<unsigned(ram(0x20e00))<<','<<unsigned(ram(0x20ead))<<','<<unsigned(top.SIM_GAME_RESET)<<','<<unsigned(top.SIM_PAUSED)<<'\\n';\n            reset_probe.flush();\n            initialized=reset_best==0;")
    (OUT / "wrapper_main.cpp").write_text(host, newline="\n")
    builder = (ROOT / source["derived_builder"]).read_text()
    builder = builder.replace("diagnostics/earned_wrapper/", "diagnostics/earned_wrapper_v3/")
    runner = (ROOT / "scripts/run_earned_wrapper.py").read_text()
    assert 'NAME = "kyros_earned_wrapper901_v2"' in runner
    runner = runner.replace('NAME = "kyros_earned_wrapper901_v2"', 'NAME = "kyros_earned_wrapper901_v3"')
    runner = runner.replace(".parents[1]", ".parents[4]")
    runner = runner.replace("scripts/run_earned_wrapper.py", "sim/captures/diagnostics/earned_wrapper_v3/runner.py")
    runner = runner.replace("research/kyros_earned_wrapper_source.json", "research/kyros_earned_wrapper_source_v3.json")
    for old,new in (("earned_wrapper_inputs.sha256","earned_wrapper_v3_inputs.sha256"),
                    ("earned_wrapper_build_dir.txt","earned_wrapper_v3_build_dir.txt"),
                    ("earned_wrapper_scope_adapter.json","earned_wrapper_v3_scope_adapter.json"),
                    ("alpha68kn_wrapper_earned_sim","alpha68kn_wrapper_earned_v3_sim")):
        builder = builder.replace(old,new)
        runner = runner.replace(old,new)
    (OUT / "build.sh").write_text(builder, newline="\n")
    (OUT / "runner.py").write_text(runner, newline="\n")
    record = dict(source)
    for key,filename in (("host","wrapper_main.cpp"),("builder","build.sh"),("runner","runner.py")):
        record["derived_"+key] = (OUT / filename).relative_to(ROOT).as_posix()
        record["derived_"+key+"_sha256"] = sha(OUT / filename)
    record.update(parent_source_sha256=sha(ROOT / "research/kyros_earned_wrapper_source.json"),
                  reset_probe_sha256=sha(ROOT / "research/kyros_earned_reset1041_verification.json"),
                  reset_limit_steps=6000, reset_step_ticks=20000,
                  change="Only private host wait bound and read-only reset journal; unchanged real production RTL/HPS/CPUs and score assertions. Separate v3 manifest, executable and job; failed v2 preserved.")
    (ROOT / "research/kyros_earned_wrapper_source_v3.json").write_text(json.dumps(record,indent=2)+"\n")
    print(json.dumps({"prepared":True,"source":"research/kyros_earned_wrapper_source_v3.json","reset_limit_fields":6000*20000/(384*264*8)}))


if __name__ == "__main__":
    main()
