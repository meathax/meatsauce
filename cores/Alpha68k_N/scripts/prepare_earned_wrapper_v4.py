"""Correct the real-donor restore protocol; preserve the failed v3 capture."""
import hashlib
import json
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim/captures/diagnostics/earned_wrapper_v4"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", choices=("v4", "v5"), default="v4")
    version = parser.parse_args().version
    out = ROOT / ("sim/captures/diagnostics/earned_wrapper_" + version)
    assert not out.exists(), "Follow an existing job; do not restart it"
    source = json.loads((ROOT / "research/kyros_earned_wrapper_source_v3.json").read_text())
    failure = json.loads((ROOT / "research/kyros_earned_wrapper901_v3_restore_diagnosis.json").read_text())
    donor = ROOT / "rtl/vendor/mister_features/hiscore.v"
    assert sha(donor) == failure["donor_sha256"]
    text = donor.read_text()
    assert "downloaded_dump == 1'b1 && reset_last == 1'b1 && reset == 1'b0" in text
    assert "paused == 1'b0 || pause_cpu == 1'b1" in text
    for key in ("host", "builder", "runner"):
        assert sha(ROOT / source["derived_" + key]) == source["derived_" + key + "_sha256"]
    host = (ROOT / source["derived_host"]).read_text()
    old = "user(0x03,{0,0});status(3);idle(100);status(2);"
    assert host.count(old) == 1
    host = host.replace(old, "download(4,saved);\n        user(0x03,{0,0});status(3);idle(100);status(2);\n        if(!top.SIM_HS_RESTORING) throw std::runtime_error(\"real donor reset did not arm restore\");")
    old = """            for(unsigned i=16;i<cfg.size();i+=8) {
                unsigned a=(unsigned(cfg[i])<<24)|(unsigned(cfg[i+1])<<16)|(unsigned(cfg[i+2])<<8)|cfg[i+3];
                initialized=initialized && ram(a)==cfg[i+5] && ram(a+cfg[i+4]-1)==cfg[i+6];
            }
"""
    assert host.count(old) == 1
    host = host.replace(old, "            // The real donor checks every configured start/end marker before writing.\n            // Observe CPU-cleared best independently, before restoration can replace it.\n")
    old = """        download(4,saved);bool restored=false;unsigned restore_steps=0;
        for(;restore_steps<100;restore_steps++) {idle(50000);if(read()==saved) {restored=true;break;}}
"""
    assert host.count(old) == 1
    host = host.replace(old, """        // Release user pause so the donor's startup/check timers and CPU can run.
        pause();
        bool restored=false;unsigned restore_steps=0;
        std::ofstream restore_probe(output/"restore_probe.csv");
        restore_probe<<"tick,state,restoring,paused\\n";
        unsigned last_state=~0u;
        for(;restore_steps<120000000;restore_steps++) {
            tick();
            unsigned state=top.SIM_HS_STATE;
            if(state!=last_state) {
                restore_probe<<ticks<<','<<state<<','<<unsigned(top.SIM_HS_RESTORING)<<','<<unsigned(top.SIM_PAUSED)<<'\\n';
                restore_probe.flush();last_state=state;
            }
            if(!top.SIM_HS_RESTORING) {
                pause();
                auto observed=read();restored=observed==saved;
                std::ofstream f(output/"restored.nvm",std::ios::binary);
                f.write(reinterpret_cast<const char*>(observed.data()),observed.size());
                break;
            }
        }
""")
    out.mkdir(parents=True)
    (out / "wrapper_main.cpp").write_text(host, newline="\n")
    builder = (ROOT / source["derived_builder"]).read_text()
    runner = (ROOT / source["derived_runner"]).read_text()
    for old, new in (("earned_wrapper_v3", "earned_wrapper_" + version),
                     ("kyros_earned_wrapper901_v3", "kyros_earned_wrapper901_" + version),
                     ("alpha68kn_wrapper_earned_v3_sim", "alpha68kn_wrapper_earned_" + version + "_sim"),
                     ("earned_wrapper_source_v3.json", "earned_wrapper_source_" + version + ".json")):
        builder = builder.replace(old, new)
        runner = runner.replace(old, new)
    assert "research/kyros_earned_wrapper_source_" + version + ".json" in runner
    assert "research/kyros_earned_wrapper_source_v3.json" not in runner
    (out / "build.sh").write_text(builder, newline="\n")
    (out / "runner.py").write_text(runner, newline="\n")
    record = dict(source)
    for key, name in (("host", "wrapper_main.cpp"), ("builder", "build.sh"), ("runner", "runner.py")):
        record["derived_" + key] = (out / name).relative_to(ROOT).as_posix()
        record["derived_" + key + "_sha256"] = sha(out / name)
    record.update(parent_source_sha256=sha(ROOT / "research/kyros_earned_wrapper_source_v3.json"),
                  failure_diagnosis_sha256=sha(ROOT / "research/kyros_earned_wrapper901_v3_restore_diagnosis.json"),
                  change="Private host loads actual earned dump before reset release; observes CPU-cleared best; releases manual pause and waits for real donor completion. Donor validates configured markers. All178 restored bytes and earned best must match; production RTL unchanged.")
    record_path = ROOT / ("research/kyros_earned_wrapper_source_" + version + ".json")
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"prepared": True, "source": record_path.relative_to(ROOT).as_posix(),
                      "runner_launch_syntax": [l.strip() for l in runner.splitlines() if "launch" in l or "sys.argv" in l]}))


if __name__ == "__main__":
    main()
