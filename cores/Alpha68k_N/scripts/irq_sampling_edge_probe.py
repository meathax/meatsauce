"""Owned private read-only FX68K E/VPA observer; production sources stay pinned."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

import sys
SCRIPT_PATH = Path(__file__).resolve()
# Canonical copies live in core/scripts; original frozen copies live in diagnostics.
DEFAULT_EVIDENCE_ROOT = SCRIPT_PATH.parents[1] if SCRIPT_PATH.parent.name == "scripts" else SCRIPT_PATH.parents[3]
EVIDENCE_ROOT_ARGUMENT = os.environ.get("ALPHA68KN_EVIDENCE_ROOT", str(DEFAULT_EVIDENCE_ROOT))
# An explicit Windows override must also resolve when the worker enters Ubuntu WSL.
if os.name != "nt" and len(EVIDENCE_ROOT_ARGUMENT) > 2 and EVIDENCE_ROOT_ARGUMENT[1] == ":":
    EVIDENCE_ROOT_ARGUMENT = "/mnt/" + EVIDENCE_ROOT_ARGUMENT[0].lower() + EVIDENCE_ROOT_ARGUMENT[2:].replace("\\", "/")
ROOT = Path(EVIDENCE_ROOT_ARGUMENT).resolve()
if "--help" in sys.argv or "--show-root" in sys.argv:
    print(json.dumps({"script": str(SCRIPT_PATH), "evidence_root": str(ROOT),
                      "override": "ALPHA68KN_EVIDENCE_ROOT", "simulation_started": False}))
    raise SystemExit(0)


def sibling_script(name):
    candidate = SCRIPT_PATH.parent / name
    return candidate if candidate.exists() else ROOT / "sim/captures/diagnostics" / name


def wsl_script_path():
    # Windows paths must be translated before an explicit Ubuntu Python invocation.
    if os.name == "nt":
        assert SCRIPT_PATH.drive, "Expected absolute Windows script path"
        return "/mnt/" + SCRIPT_PATH.drive[0].lower() + SCRIPT_PATH.as_posix()[2:]
    return str(SCRIPT_PATH)

NAME = "irq_sampling_edge_latch61"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(suffix, value):
    (ROOT / "research" / (NAME + "_" + suffix + ".json")).write_text(
        json.dumps(value, indent=2) + "\n")


def replace_once(text, before, after):
    assert text.count(before) == 1, "Observer source anchor is not unique"
    return text.replace(before, after, 1)


def observed_host(base):
    base = replace_once(base, '    std::ofstream applied_inputs(output/"applied_inputs.csv");',
        """    std::ofstream e_phase(output/"e_phase.csv");
    e_phase<<"tick,frame,raster_x_before,raster_y_before,address_before,attrs_before,attrs_after,e_counter_before,e_counter_after,vpa_latched_before,vpa_latched_after,vma_n_before,vma_n_after,main_transactions_after\\n";
    std::ofstream latch_phase(output/"latch_phase.csv");
    latch_phase<<"tick,frame,address_before,attrs_before,attrs_after,phi2_before,to_irc_before,to_dbin_before,din_before,irc_before,irc_after,dbin_before,dbin_after,dtack_latched_before,dtack_latched_after,cpu_phase_before,e_counter_before,main_transactions_before,main_transactions_after\\n";
    uint64_t e_follow_until=0;
    std::ofstream applied_inputs(output/"applied_inputs.csv");""")
    before = '        tick();\n        if(top.audio_sample_ce) {'
    after = """        bool e_window=(frame>=59 && frame<=60) || ticks-started<128;
        unsigned e_before=0,vpa_before=0,vma_before=0;
        unsigned phi2_before=0,to_irc_before=0,to_dbin_before=0;
        unsigned din_before=0,irc_before=0,dbin_before=0,dtack_before=0,cpu_phase_before=0;
        uint32_t tx_before=top.main_transactions;
        if(e_window) {
            auto *p=top.rootp;
            e_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__eCntr;
            vpa_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Vpai;
            vma_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__rVma;
            // Exact packed s_clks order: clk, extReset, pwrUp, enPhi1, enPhi2.
            phi2_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Clks & 1;
            to_irc_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__excUnit__DOT__dataIo__DOT__xToIrc;
            to_dbin_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__excUnit__DOT__dataIo__DOT__xToDbin;
            din_before=top.debug_main_din;
            irc_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Irc;
            dbin_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__excUnit__DOT__dbin;
            dtack_before=p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__rDtack;
            cpu_phase_before=p->alpha68kn_system__DOT__board__DOT__cpu_phase;
        }
        tick();
        if(e_window) {
            if((attrs | top.debug_main_attrs)&8) e_follow_until=ticks-started+256;
            if(ticks-started<128 || ticks-started<=e_follow_until) {
                auto *p=top.rootp;
                e_phase<<ticks-started<<','<<frame<<','<<raster_x<<','<<raster_y<<','
                    <<address<<','<<unsigned(attrs)<<','<<unsigned(top.debug_main_attrs)<<','
                    <<e_before<<','<<unsigned(p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__eCntr)<<','
                    <<vpa_before<<','<<unsigned(p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Vpai)<<','
                    <<vma_before<<','<<unsigned(p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__rVma)<<','
                    <<top.main_transactions<<'\\n';
                latch_phase<<ticks-started<<','<<frame<<','<<address<<','<<unsigned(attrs)<<','
                    <<unsigned(top.debug_main_attrs)<<','<<phi2_before<<','<<to_irc_before<<','<<to_dbin_before<<','
                    <<din_before<<','<<irc_before<<','<<unsigned(p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Irc)<<','
                    <<dbin_before<<','<<unsigned(p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__excUnit__DOT__dbin)<<','
                    <<dtack_before<<','<<unsigned(p->alpha68kn_system__DOT__board__DOT__maincpu__DOT__rDtack)<<','
                    <<cpu_phase_before<<','<<e_before<<','<<tx_before<<','<<top.main_transactions<<'\\n';
            }
        }
        if(top.audio_sample_ce) {"""
    return replace_once(base, before, after)



def main():
    job = ROOT / "research" / (NAME + "_job.json")
    launcher = ROOT / "research" / (NAME + "_launcher.json")
    assert not job.exists(), "Follow the existing job; do not restart"
    if os.name == "nt":
        assert not launcher.exists(), "Preserve the existing launcher"
        command = ["wsl.exe", "-d", "Ubuntu", "--cd", str(ROOT),
                   "--exec", "/usr/bin/python3", wsl_script_path()]
        with (ROOT / "research" / (NAME + "_worker.log")).open("w") as log:
            child = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
        save("launcher", {"started": time.time(), "wsl_pid": child.pid, "command": command})
        print(json.dumps({"wsl_pid": child.pid, "job": str(job)}))
        return 0
    source = ROOT / "sim/captures/diagnostics" / (NAME + "_source")
    output = ROOT / "sim/captures/rtl" / NAME
    assert not source.exists() and not output.exists(), "Preserve existing captures"
    old = json.loads((ROOT / "research/kyros_instruction60_diagnostic_exit.json").read_text())
    frozen=json.loads((ROOT / "research/kyros_irq_e_phase61_job.json").read_text())
    assert all(sha(ROOT/p)==h for p,h in frozen["source_pins"].items()), "Frozen sourcebytes changed"
    ports = ROOT / "sim/captures/kyros/warm_reset960_refv2/frame_states.csv"
    rom = ROOT / "roms/kyros/download.bin"
    assert sha(ports) == old["input_trace_sha256"] and sha(rom) == old["rom_sha256"]
    source.mkdir(parents=True)
    host = observed_host((ROOT / "sim/system_main.cpp").read_text())
    generated = source / "system_main.cpp"
    generated.write_text(host)
    build = Path(tempfile.mkdtemp(prefix="alpha68kn-latch-phase61.", dir="/mnt/d/vibes/fpga/temp"))
    explicit = ["rtl/alpha68kn_" + n + ".sv" for n in
                ["board", "renderer", "video_rom", "gfxmem", "system", "audio", "soundchips", "mixer"]]
    paths = [ROOT / p for p in explicit]
    for pattern in ["rtl/vendor/fx68k/*.sv", "rtl/vendor/t80/T80s.v",
                    "rtl/vendor/jtframe_sdram/*.v", "rtl/vendor/jt12/hdl/*.v",
                    "rtl/vendor/jt12/jt49/hdl/*.v", "rtl/vendor/ay49/hdl/*.v"]:
        found = sorted(ROOT.glob(pattern))
        assert found, pattern
        paths.extend(found)
    paths += [ROOT / "sim/sdram_model.h", ROOT / "sim/system_main.cpp",
              ROOT / "rtl/vendor/fx68k/microrom.mem", ROOT / "rtl/vendor/fx68k/nanorom.mem"]
    pins = {str(p.relative_to(ROOT)): sha(p) for p in paths}
    origins = {}
    for path in paths:
        shutil.copyfile(path, build / path.name)
        origins[path.name] = str(path.relative_to(ROOT))
    shutil.copyfile(generated, build / "system_main.cpp")
    origins["system_main.cpp"] = str(generated.relative_to(ROOT))
    version = subprocess.check_output(["/usr/local/bin/verilator", "--version"], text=True).strip()
    assert version.startswith("Verilator 5.050 "), version
    command = ["/usr/local/bin/verilator", "--cc", "--exe", "--build", "-j", "4", "-O3",
               "--assert", "--no-assert-case", "-Wno-fatal", "--top-module", "alpha68kn_system",
               "--Mdir", "obj", "-o", "alpha68kn_irq_sampling_edge_latch61_sim"]
    command += [Path(p).name for p in explicit]
    command += ["fx68k.sv", "fx68kAlu.sv", "uaddrPla.sv"]
    command += [p.name for p in sorted(build.glob("*.v"))]
    command += [str(build / "system_main.cpp"), "-CFLAGS", "-O3 -std=c++17"]
    record = {"worker_pid": os.getpid(), "started": time.time(), "frames": 61,
              "source_parent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "source_pins": pins, "generated_host_sha256": sha(generated),
              "compile_file_origins": origins, "build_root": str(build),
              "input_trace_sha256": sha(ports), "rom_sha256": sha(rom),
              "verilator_version": version, "build_command": command,
              "scope": "Read-only registered E/VPA/VMA and accepted-Phi2/IRC/DBIN latch observations around genuine CPU IRQ59/60; no RTL/frequency/phase/input/CPU-state changes"}
    with (ROOT / "research" / (NAME + "_build.log")).open("w") as log:
        child = subprocess.Popen(command, cwd=build, stdout=log, stderr=subprocess.STDOUT)
        record["build_pid"] = child.pid
        save("job", record)
        code = child.wait()
    save("build_exit", dict(record, exit_code=code, ended=time.time()))
    if code:
        return code
    assert all(sha(ROOT / p) == h for p, h in pins.items())
    output.mkdir(parents=True)
    binary = output / "alpha68kn_irq_sampling_edge_latch61_sim"
    shutil.copyfile(build / "obj/alpha68kn_irq_sampling_edge_latch61_sim", binary)
    binary.chmod(0o755)
    record["executable_sha256"] = sha(binary)
    command = [str(binary), str(rom), "61", str(output), "gameplay", "--inputs", str(ports)]
    record["command"] = command
    with (ROOT / "research" / (NAME + "_run.log")).open("w") as log:
        child = subprocess.Popen(command, cwd=build, stdout=log, stderr=subprocess.STDOUT)
        record.update(simulation_pid=child.pid, run_started=time.time())
        save("job", record)
        code = child.wait()
    save("exit", dict(record, exit_code=code, ended=time.time(), whole_game_acceptance=False))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
