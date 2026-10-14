"""Private real-CPU wrapper prefix; preserves the completed v5 capture."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time

NAME = "kyros_earned_prefix181"
STAGING = Path("D:/Arcade/AI/aCORES/Alpha68k N") if os.name == "nt" else Path("/mnt/d/Arcade/AI/aCORES/Alpha68k N")
CANON = Path("D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N") if os.name == "nt" else Path("/mnt/d/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observed_host(base):
    changes = [
        ('bool earned=argc==6 && std::string(argv[4])=="--earned-score";',
         'bool prefix=argc==6 && std::string(argv[4])=="--earned-prefix";\n    bool earned=argc==6 && (prefix || std::string(argv[4])=="--earned-score");'),
        ('if(frame==0 || frame%30==0 || frame+1==requested) {save("core",core);save("vga",vga);}',
         'if(frame==0 || frame%30==0 || frame==119 || frame==179 || frame+1==requested) {save("core",core);save("vga",vga);}'),
        ('if(earned && (requested<901 || ports.size()<requested))',
         'if(earned && ((prefix ? requested!=181 : requested<901) || ports.size()<requested))'),
        ('if(earned) {\n        auto idle=', 'if(earned && !prefix) {\n        auto idle='),
    ]
    for before, after in changes:
        assert base.count(before) == 1, before
        base = base.replace(before, after)
    return base


def pins(root, canon):
    source = json.loads((root / "research/kyros_earned_wrapper_source_v5.json").read_text())
    manifest = root / "sim/build/earned_wrapper_v5_inputs.sha256"
    result = {}
    for line in manifest.read_text().splitlines():
        expected, name = line.split(None, 1)
        name = name.lstrip("*")
        assert sha(root / name) == expected, ("staging input changed", name)
        if name != source["derived_host"]:
            assert (canon / name).read_bytes().replace(b"\r\n", b"\n") == (root / name).read_bytes().replace(b"\r\n", b"\n"), ("canonical content differs", name)
            result[name] = expected
    for name in ("microrom.mem", "nanorom.mem"):
        relative = "rtl/vendor/fx68k/" + name
        expected = sha(root / relative)
        assert (canon / relative).read_bytes().replace(b"\r\n", b"\n") == (root / relative).read_bytes().replace(b"\r\n", b"\n"), relative
        result[relative] = expected
    assert sha(root / source["derived_host"]) == source["derived_host_sha256"]
    assert sha(root / source["derived_builder"]) == source["derived_builder_sha256"]
    return source, result


def save(root, suffix, value):
    path = root / "research" / (NAME + suffix + ".json")
    assert not path.exists(), ("preserve receipt", path)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--launch", action="store_true")
    parser.add_argument("--worker", action="store_true")
    args = parser.parse_args()
    root, canon = STAGING, CANON
    source, original_pins = pins(root, canon)
    private = root / "sim/captures/diagnostics/earned_prefix181"
    out = root / "sim/captures/rtl" / NAME
    runtime = private / "runtime"
    if os.name == "nt":
        assert args.launch, "Use --launch to start the owned WSL worker"
        for suffix in ("_launcher", "_job", "_exit"):
            assert not (root / "research" / (NAME + suffix + ".json")).exists(), "existing job; observe it"
        host = observed_host((root / source["derived_host"]).read_text())
        (private / "wrapper_main.cpp").write_text(host, encoding="utf-8")
        build = (root / source["derived_builder"]).read_text()
        build = build.replace("sim/captures/diagnostics/earned_wrapper_v5/wrapper_main.cpp", "sim/captures/diagnostics/earned_prefix181/wrapper_main.cpp")
        build = build.replace("sim/build/", "sim/captures/diagnostics/earned_prefix181/runtime/")
        build = build.replace('mkdir -p "$snapshot/sys" sim/build', 'mkdir -p "$snapshot/sys" sim/captures/diagnostics/earned_prefix181/runtime')
        (private / "build.sh").write_text(build, encoding="utf-8", newline="\n")
        runtime.mkdir(parents=True, exist_ok=True)
        save(root, "_source", {"source": source, "source_pins": original_pins,
            "canonical_byte_pins": {name: sha(canon / name) for name in original_pins},
            "canonical_equivalence": "Exact bytes except explicit CRLF/LF normalization; actual build retains all original v5 byte pins.",
            "derived_host_sha256": sha(private / "wrapper_main.cpp"),
            "derived_builder_sha256": sha(private / "build.sh"),
            "generator_sha256": sha(Path(__file__)), "canonical_root": str(canon),
            "changes": "Four guarded substitutions: distinct prefix flag, exact181 limit, extra119/179 captures and suppress post-prefix score protocol. Existing tick/HPS/input operations unchanged.",
            "scope": "Actual real CPU/HPS prefix only; no score protocol or full-game acceptance."})
        linux_script = str(Path(__file__).resolve()).replace("D:\\", "/mnt/d/").replace("\\", "/")
        command = ["wsl.exe", "-d", "Ubuntu", "--cd", str(root), "--exec", "/usr/bin/python3", linux_script, "--worker"]
        with (root / "research" / (NAME + "_worker.log")).open("w", encoding="utf-8") as log:
            child = subprocess.Popen(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        save(root, "_launcher", {"started": time.time(), "wsl_pid": child.pid, "command": command})
        print(json.dumps({"wsl_pid": child.pid, "job": str(root / "research" / (NAME + "_job.json")), "canonical_pins": len(original_pins)}))
        return
    assert args.worker
    assert not out.exists(), "existing capture; preserve it"
    generated = json.loads((root / "research" / (NAME + "_source.json")).read_text())
    assert generated["source_pins"] == original_pins
    assert (private / "wrapper_main.cpp").read_text() == observed_host((root / source["derived_host"]).read_text())
    assert sha(private / "build.sh") == generated["derived_builder_sha256"]
    out.mkdir(parents=True)
    ports = root / "sim/captures/kyros/combat3600_v2/frame_states.csv"
    v5 = json.loads((root / "research/kyros_earned_wrapper901_v5_exit.json").read_text())
    assert v5["exit_code"] == 0 and sha(ports) == v5["ports_sha256"]
    rom = root / "roms/kyros/download.bin"
    assert sha(rom) == v5["rom_sha256"]
    record = {"worker_pid": os.getpid(), "started": time.time(), "source": generated,
              "ports_sha256": sha(ports), "rom_sha256": sha(rom), "runner_sha256": sha(Path(__file__))}
    command = ["/usr/bin/bash", str(private / "build.sh")]
    with (root / "research" / (NAME + "_build.log")).open("w") as log:
        child = subprocess.Popen(command, cwd=root, env=dict(os.environ, ALPHA68KN_BUILD_ROOT="/mnt/d/vibes/fpga/temp"), stdout=log, stderr=subprocess.STDOUT)
        record.update(build_pid=child.pid, build_command=command)
        save(root, "_job", record)
        code = child.wait()
    save(root, "_build_exit", dict(record, exit_code=code, ended=time.time()))
    if code:
        save(root, "_exit", dict(record, exit_code=code, ended=time.time(), stage="build"))
        raise SystemExit(code)
    pins(root, canon)
    executable = out / "alpha68kn_wrapper_earned_prefix181_sim"
    shutil.copy2(runtime / "alpha68kn_wrapper_earned_v5_sim", executable)
    assert executable.read_bytes()[:4] == b"\x7fELF"
    command = [str(executable), str(rom), "181", str(out), "--earned-prefix", str(ports)]
    record.update(executable_sha256=sha(executable), command=command, run_started=time.time())
    # Deliberate new receipt, preserving the original build job receipt.
    with (root / "research" / (NAME + "_run.log")).open("w") as log:
        child = subprocess.Popen(command, cwd=runtime, stdout=log, stderr=subprocess.STDOUT)
        record.update(simulation_pid=child.pid)
        save(root, "_running", record)
        code = child.wait()
    save(root, "_exit", dict(record, exit_code=code, ended=time.time(), stage="simulation"))
    raise SystemExit(code)


if __name__ == "__main__":
    main()
