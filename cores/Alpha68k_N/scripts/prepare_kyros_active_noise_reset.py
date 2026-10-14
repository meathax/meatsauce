"""Private actual-CPU punch warm reset; original RTL and captures stay frozen."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = "kyros_active_noise_reset_v3"
MAX_FIELDS = 740
POST_TICKS = 500000


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(suffix, value):
    (ROOT / "research" / (NAME + "_" + suffix + ".json")).write_text(json.dumps(value, indent=2) + "\n")


def replace_once(source, before, after):
    assert source.count(before) == 1, "Private observer anchor is not unique"
    return source.replace(before, after, 1)


def observed_host(base):
    base = replace_once(base, '    std::ofstream applied_inputs(output/"applied_inputs.csv");', r'''    std::ofstream active_trace(output/"active_noise_reset.csv");
    active_trace<<"tick,frame,phase,reset,cold_reset,downloading,mixer,volume_b,noise,channel_b,main_transactions,sound_transactions,ay2_writes\n";
    bool active_reset_done=false,active_previous=false;
    unsigned last_mix=0,last_vol=0,last_noise=0,last_b=0;
    uint64_t pre_active_ticks=0,pre_nonzero_ticks=0,pre_noise_changes=0,pre_b_changes=0,last_observed_tick=~uint64_t(0);
    uint64_t held_nonzero_ticks=0,post_nonzero_ticks=0,post_stale_nonzero_ticks=0,post_data_writes=0;
    std::ofstream applied_inputs(output/"applied_inputs.csv");''')
    base = replace_once(base, '    auto inputs=[&](unsigned f) {', r'''    auto active_observe=[&](unsigned observation_phase,bool force=false) {
        auto *r=top.rootp;
        unsigned mix=r->alpha68kn_system__DOT__audio__DOT__chips__DOT__ay2__DOT__regarray[7];
        unsigned vol=r->alpha68kn_system__DOT__audio__DOT__chips__DOT__ay2__DOT__regarray[9];
        unsigned noise=r->alpha68kn_system__DOT__audio__DOT__chips__DOT__ay2__DOT__noise;
        unsigned channel=r->alpha68kn_system__DOT__audio__DOT__chips__DOT__ay2__DOT__B;
        bool noise_only=(mix&2) && !(mix&16) && (vol&31);
        bool new_edge=(last_observed_tick!=ticks);
        if(new_edge && observation_phase==0 && noise_only) {
            pre_active_ticks++;pre_nonzero_ticks+=(channel!=0);
            if(active_previous && mix==last_mix && vol==last_vol) {
                pre_noise_changes+=(noise!=last_noise);
                pre_b_changes+=(channel!=last_b);
            }
        }
        if(new_edge && observation_phase==1) held_nonzero_ticks+=(channel!=0);
        if(new_edge && observation_phase==2) {
            post_nonzero_ticks+=(channel!=0);
            post_stale_nonzero_ticks+=(channel!=0 && (vol&31)==0);
            post_data_writes+=(top.sound_io_wr && top.sound_io_addr==0x90);
        }
        if(force || mix!=last_mix || vol!=last_vol || noise!=last_noise || channel!=last_b) {
            active_trace<<ticks-started<<','<<frame<<','<<observation_phase<<','<<unsigned(top.reset)<<','
                <<unsigned(top.cold_reset)<<','<<unsigned(top.downloading)<<','<<mix<<','<<vol<<','
                <<noise<<','<<channel<<','<<top.main_transactions<<','<<top.sound_transactions<<','
                <<r->alpha68kn_system__DOT__audio__DOT__chips__DOT__ay2_writes<<'\n';
        }
        active_previous=noise_only;last_mix=mix;last_vol=vol;last_noise=noise;last_b=channel;last_observed_tick=ticks;
        return noise_only && pre_active_ticks>=64 && pre_nonzero_ticks>=64 && pre_noise_changes>=4 && pre_b_changes>=4;
    };
    auto inputs=[&](unsigned f) {''')
    base = replace_once(base, '        tick();\n        if(top.audio_sample_ce) {',
                        '        tick();\n        if(frame>=711) active_observe(0);\n        if(top.audio_sample_ce) {')
    base = replace_once(base, '        if(frame==warm_reset_after) {',
                        '        if(frame>=warm_reset_after && active_observe(0,true) && !active_reset_done) {')
    base = replace_once(base, '            for(unsigned i=0;i<64;i++) tick();', r'''            active_reset_done=true;
            uint64_t reset_assert_tick=ticks-started;
            for(unsigned i=0;i<64;i++) {tick();active_observe(1,true);}
            unsigned held_b=last_b;
            if(held_b!=0) throw std::runtime_error("AY2-B did not settle within64 warm-reset ticks");''')
    base = replace_once(base, '            applied_inputs<<"warm_reset,"<<frame<<\',\'<<ticks-started<<",0,"', r'''            uint64_t reset_release_tick=ticks-started;
            active_observe(2,true);
            for(unsigned i=0;i<500000;i++) {
                tick();active_observe(2,i==499999);
                if(top.sound_io_wr) audio_events<<ticks-started<<','<<frame<<",write,"
                    <<unsigned(top.sound_io_addr)<<','<<unsigned(top.sound_io_data)<<'\n';
            }
            active_trace.flush();audio_events.flush();
            std::ofstream active_result(output/"active_reset.json");
            active_result<<"{\"reset_delivered\":true,\"completed_fields\":"<<frame+1
                <<",\"trigger_field\":"<<frame<<",\"assert_tick\":"<<reset_assert_tick
                <<",\"release_tick\":"<<reset_release_tick<<",\"post_end_tick\":"<<ticks-started
                <<",\"held_ticks\":64,\"post_ticks\":500000,\"pre_active_ticks\":"<<pre_active_ticks
                <<",\"pre_nonzero_ticks\":"<<pre_nonzero_ticks<<",\"pre_noise_changes\":"<<pre_noise_changes
                <<",\"pre_channel_b_changes\":"<<pre_b_changes<<",\"held_nonzero_ticks\":"<<held_nonzero_ticks
                <<",\"held_final_channel_b\":"<<held_b<<",\"post_nonzero_ticks\":"<<post_nonzero_ticks
                <<",\"post_stale_nonzero_ticks\":"<<post_stale_nonzero_ticks
                <<",\"post_ay2_data_writes\":"<<post_data_writes<<",\"whole_game_acceptance\":false}\n";
            active_result.flush();
            applied_inputs<<"warm_reset,"<<frame<<','<<reset_release_tick<<",0,"''')
    base = replace_once(base, '                <<unsigned(top.dips)<<",3\\n";\n        }',
                        '                <<unsigned(top.dips)<<",3\\n";\n            ++frame;break;\n        }')
    base = replace_once(base, '    bool ran=top.main_transactions>10',
                        '    if(!active_reset_done) throw std::runtime_error("No nonvacuous active-noise reset trigger by field limit");\n    bool ran=top.main_transactions>10')
    return base


def main():
    job = ROOT / "research" / (NAME + "_job.json")
    launcher = ROOT / "research" / (NAME + "_launcher.json")
    assert not job.exists(), "Follow existing job; never restart on observation failure"
    if os.name == "nt":
        assert not launcher.exists(), "Preserve existing launcher"
        command = ["wsl.exe", "-d", "Ubuntu", "--cd", str(ROOT), "--exec", "/usr/bin/python3",
                   "scripts/prepare_kyros_active_noise_reset.py"]
        with (ROOT / "research" / (NAME + "_worker.log")).open("w") as log:
            child = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
        save("launcher", {"started": time.time(), "wsl_pid": child.pid, "command": command})
        print(json.dumps({"wsl_pid": child.pid, "job": str(job)}))
        return 0
    reference_path = ROOT / "research/kyros_punch_release1081_native_exit.json"
    reference = json.loads(reference_path.read_text())
    assert reference["exit_code"] == 0
    ports = ROOT / "sim/captures/kyros/punch_release1081/frame_states.csv"
    rom = ROOT / "roms/kyros/download.bin"
    input_pins = [value for key, value in reference.items() if ("input" in key or "port" in key) and isinstance(value, str)]
    assert sha(ports) in input_pins, "Frozen input digest is absent/mismatched in original terminal"
    # The punch terminal pins input/source/executable but has no payload digest.
    # Its exact payload path is the already-qualified warm-reset payload; retain
    # that explicit provenance bridge instead of inventing a missing punch pin.
    warm_pin_path = ROOT / "research/kyros_warm_reset960_v2_native_exit.json"
    warm_pin = json.loads(warm_pin_path.read_text())
    assert warm_pin["exit_code"] == 0 and sha(rom) == warm_pin["rom_sha256"]
    assert reference["command"][1] == warm_pin["command"][1] == str(rom)
    source = ROOT / "sim/captures/diagnostics" / (NAME + "_source")
    output = ROOT / "sim/captures/rtl" / NAME
    assert not source.exists() and not output.exists()
    source.mkdir(parents=True)
    generated = source / "system_main.cpp"
    generated.write_text(observed_host((ROOT / "sim/system_main.cpp").read_text()))
    # Official control-file syntax retains only the existing output B and register
    # array for read access. No forceable signal, writable interface or RTL edits.
    config = source / "active_noise_reset.vlt"
    config.write_text('`verilator_config\npublic_flat_rd -module "a68n_ay49" -var "B"\npublic_flat_rd -module "a68n_ay49" -var "regarray"\npublic_flat_rd -module "alpha68kn_soundchips" -var "ay2_writes"\n')
    build = Path(tempfile.mkdtemp(prefix="alpha68kn-active-noise-reset.", dir="/mnt/d/vibes/fpga/temp"))
    explicit = ["rtl/alpha68kn_" + n + ".sv" for n in
                ["board", "renderer", "video_rom", "gfxmem", "system", "audio", "soundchips", "mixer"]]
    paths = [ROOT / path for path in explicit]
    for pattern in ["rtl/vendor/fx68k/*.sv", "rtl/vendor/t80/T80s.v", "rtl/vendor/jtframe_sdram/*.v",
                    "rtl/vendor/jt12/hdl/*.v", "rtl/vendor/jt12/jt49/hdl/*.v", "rtl/vendor/ay49/hdl/*.v"]:
        found = sorted(ROOT.glob(pattern));assert found, pattern;paths.extend(found)
    paths += [ROOT / "sim/sdram_model.h", ROOT / "sim/system_main.cpp",
              ROOT / "rtl/vendor/fx68k/microrom.mem", ROOT / "rtl/vendor/fx68k/nanorom.mem"]
    pins = {str(path.relative_to(ROOT)): sha(path) for path in paths}
    for path, digest in pins.items():
        if path.startswith("rtl/") and path.endswith((".sv", ".v")):
            assert reference["source_pins"].get(path) == digest, "Production RTL changed: " + path
    origins = {}
    for path in paths:
        shutil.copyfile(path, build / path.name);origins[path.name] = str(path.relative_to(ROOT))
    shutil.copyfile(generated, build / "system_main.cpp")
    shutil.copyfile(config, build / config.name)
    origins["system_main.cpp"] = str(generated.relative_to(ROOT))
    origins[config.name] = str(config.relative_to(ROOT))
    version = subprocess.check_output(["/usr/local/bin/verilator", "--version"], text=True).strip()
    assert version.startswith("Verilator 5.050 ")
    command = ["/usr/local/bin/verilator", "--cc", "--exe", "--build", "-j", "4", "-O3",
               "--assert", "--no-assert-case", "-Wno-fatal", "--top-module", "alpha68kn_system",
               "--Mdir", "obj", "-o", "alpha68kn_active_noise_reset_sim", config.name]
    command += [Path(path).name for path in explicit] + ["fx68k.sv", "fx68kAlu.sv", "uaddrPla.sv"]
    command += [path.name for path in sorted(build.glob("*.v"))]
    command += [str(build / "system_main.cpp"), "-CFLAGS", "-O3 -std=c++17"]
    record = {"worker_pid": os.getpid(), "started": time.time(), "maximum_fields": MAX_FIELDS,
              "source_parent": reference["source_parent"], "source_pins": pins,
              "generated_host_sha256": sha(generated), "config_sha256": sha(config),
              "compile_file_origins": origins, "build_root": str(build),
              "input_trace_sha256": sha(ports), "rom_sha256": sha(rom),
              "reference_terminal_sha256": sha(reference_path), "payload_pin_receipt_sha256": sha(warm_pin_path), "verilator_version": version,
              "build_command": command, "script_sha256": sha(Path(__file__)),
              "scope": "Real CPU active punch warm reset; only private read-only AY2-B observers and existing legitimate warm-reset input; no RTL/ROM/CPU/RAM writes or Quartus",
              "documentation": "https://verilator.org/guide/latest/control.html"}
    with (ROOT / "research" / (NAME + "_build.log")).open("w") as log:
        child = subprocess.Popen(command, cwd=build, stdout=log, stderr=subprocess.STDOUT)
        record["build_pid"] = child.pid;save("job", record);code = child.wait()
    save("build_exit", dict(record, exit_code=code, ended=time.time()))
    if code:return code
    assert all(sha(ROOT / path) == digest for path, digest in pins.items())
    output.mkdir(parents=True)
    binary = output / "alpha68kn_active_noise_reset_sim"
    shutil.copyfile(build / "obj/alpha68kn_active_noise_reset_sim", binary);binary.chmod(0o755)
    record["executable_sha256"] = sha(binary)
    command = [str(binary), str(rom), str(MAX_FIELDS), str(output), "gameplay", "--inputs", str(ports), "--warm-reset-after", "711"]
    record["command"] = command
    with (ROOT / "research" / (NAME + "_run.log")).open("w") as log:
        child = subprocess.Popen(command, cwd=build, stdout=log, stderr=subprocess.STDOUT)
        record.update(simulation_pid=child.pid, run_started=time.time());save("job", record);code = child.wait()
    save("exit", dict(record, exit_code=code, ended=time.time(), whole_game_acceptance=False))
    if code == 0:
        check = ["/usr/bin/python3", "scripts/verify_kyros_active_noise_reset.py"]
        with (ROOT / "research" / (NAME + "_check.log")).open("w") as log:
            completed = subprocess.run(check, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        save("check_exit", {"command": check, "exit_code": completed.returncode})
    return code


if __name__ == "__main__":
    raise SystemExit(main())
