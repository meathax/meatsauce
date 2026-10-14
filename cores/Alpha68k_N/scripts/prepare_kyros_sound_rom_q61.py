from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,tempfile,time
R=Path(__file__).resolve().parents[1];N="kyros_sound_rom_q61"
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(n,v):(R/"research"/(N+"_"+n+".json")).write_text(json.dumps(v,indent=2)+"\n")
def once(s,a,b):
 assert s.count(a)==1,a
 return s.replace(a,b,1)
def observed(s):
 s=once(s,"    uint64_t ticks=0;",r"""    uint64_t ticks=0;
    uint64_t ROMchecks=0,T2checks=0,holdchecks=0;
    std::ofstream ROMsamples(output/"sound_rom_samples.csv");
    ROMsamples<<"tick,address,DI,expected,tstate,attrs\n";
""")
 s=once(s,"        top.clk=1;top.eval();ticks++;",r"""        auto *zstate=top.rootp;
        bool active=!top.reset&&!top.cold_reset&&!top.downloading&&!top.pause_game;
        bool ce=zstate->alpha68kn_system__DOT__board__DOT__zphase==0;
        auto a=top.debug_sound_addr;auto at=top.debug_sound_attrs;
        unsigned ts=zstate->alpha68kn_system__DOT__board__DOT__soundcpu__DOT__tstate;
        if(active && ce && a<0xc000 && !(at&8) && !(at&2) && (at&4)) {
            unsigned expected=bytes.at(0x20100+a),actual=top.debug_sound_din;
            if(ROMchecks<32 || actual!=expected)
                ROMsamples<<ticks<<','<<a<<','<<actual<<','<<expected<<','<<ts<<','<<unsigned(at)<<'\n';
            ++ROMchecks;if(ts==2) ++T2checks;
            if(actual!=expected) throw std::runtime_error("actualT80 ROMdata mismatchatCEN");
        }
        top.clk=1;top.eval();ticks++;
        if(active && !ce) {
            ++holdchecks;
            if(top.debug_sound_addr!=a) throw std::runtime_error("T80addresschangedoutsideCEN");
        }
""")
 s=once(s,"    top.reset=1;tick();",r"""    std::ofstream ROMreport(output/"sound_rom_contract.json");
    ROMreport<<"{\"scope\":\"actualCPU candidatehardwarepath readonlychecks\",\"ROM_CEN_checks\":"
             <<ROMchecks<<",\"T2_accept_checks\":"<<T2checks<<",\"address_hold_checks\":"
             <<holdchecks<<",\"mismatch_count\":0}\n";
    if(!ROMchecks || !T2checks || !holdchecks) throw std::runtime_error("vacuousROMcontract");
    top.reset=1;tick();""")
 return s
def main():
 ap=argparse.ArgumentParser();ap.add_argument("--candidate",required=True);ap.add_argument("--candidate-sha",required=True);args=ap.parse_args()
 assert not (R/"research"/(N+"_job.json")).exists(),"Existingjobmustnotrestart"
 if os.name=="nt":
  path=str(Path(args.candidate).resolve()).replace("\\","/");assert path.startswith("D:/")
  path="/mnt/d/"+path[3:]
  cmd=["wsl.exe","-d","Ubuntu","--cd",str(R),"--exec","env","ALPHA_BUILD_TMP=/mnt/d/vibes/fpga/temp","TMPDIR=/mnt/d/vibes/fpga/temp","python3","scripts/prepare_kyros_sound_rom_q61.py","--candidate",path,"--candidate-sha",args.candidate_sha]
  with (R/"research"/(N+"_launcher.log")).open("w") as log:
   ch=subprocess.Popen(cmd,cwd=R,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
  save("launcher",{"actual_wsl_pid":ch.pid,"command":cmd,"started":time.time()});print(ch.pid);return 0
 C=Path("/mnt/d/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N");cand=Path(args.candidate)
 assert sha(cand)==args.candidate_sha
 assert sha(C/"rtl/alpha68kn_board.sv")=="1d96bcb640490b62fbe6f15a9dc0e4fcf8e80b496cc108f14bd91241eb85ca0c"
 refpath=R/"research/kyrosj_current720_curvefixed_exit.json";ref=json.loads(refpath.read_text())
 rom=R/"roms/kyrosj/download.bin";ports=R/"sim/captures/kyrosj/gameplay/frame_states.csv"
 assert ref["exit_code"]==0 and sha(rom)==ref["rom_sha256"] and sha(ports)==ref["ports_sha256"]
 src=R/"sim/captures/diagnostics"/(N+"_source");out=R/"sim/captures/rtl"/N
 assert not src.exists() and not out.exists();src.mkdir()
 host=src/"system_main.cpp";host.write_text(observed((C/"sim/system_main.cpp").read_text()))
 cfg=src/"sound_rom_contract.vlt";cfg.write_text(chr(96)+'verilator_config\npublic_flat_rd -module "alpha68kn_board" -var "zphase"\npublic_flat_rd -module "T80s" -var "tstate"\n')
 build=Path(tempfile.mkdtemp(prefix="alpha68kn-sound-rom-q61.",dir="/mnt/d/vibes/fpga/temp"))
 explicit=["rtl/alpha68kn_"+n+".sv" for n in ["board","renderer","video_rom","gfxmem","system","audio","soundchips","mixer"]]
 paths=[C/x for x in explicit]
 for pattern in ["rtl/vendor/fx68k/*.sv","rtl/vendor/t80/T80s.v","rtl/vendor/jtframe_sdram/*.v","rtl/vendor/jt12/hdl/*.v","rtl/vendor/jt12/jt49/hdl/*.v","rtl/vendor/ay49/hdl/*.v"]:
  found=sorted(C.glob(pattern));assert found;paths.extend(found)
 paths += [C/"sim/sdram_model.h",C/"sim/system_main.cpp",C/"rtl/vendor/fx68k/microrom.mem",C/"rtl/vendor/fx68k/nanorom.mem"]
 pins={str(x.relative_to(C)):sha(x) for x in paths}
 for x in paths:shutil.copyfile(x,build/x.name)
 shutil.copyfile(cand,build/"alpha68kn_board.sv");shutil.copyfile(host,build/"system_main.cpp");shutil.copyfile(cfg,build/cfg.name)
 version=subprocess.check_output(["/usr/local/bin/verilator","--version"],text=True).strip();assert version.startswith("Verilator 5.050 ")
 cmd=["/usr/local/bin/verilator","--cc","--exe","--build","-j","4","-O3","--assert","--no-assert-case","-Wno-fatal","--top-module","alpha68kn_system","--Mdir","obj","-o","alpha68kn_sound_rom_q61_sim",cfg.name]
 cmd += [Path(x).name for x in explicit]+["fx68k.sv","fx68kAlu.sv","uaddrPla.sv"]+[x.name for x in sorted(build.glob("*.v"))]+[str(build/"system_main.cpp"),"-CFLAGS","-O3 -std=c++17"]
 job={"actual_worker_pid":os.getpid(),"started":time.time(),"fields":61,"production_source_pins":pins,"candidate_sha256":sha(cand),"candidate_path":str(cand),"generated_host_sha256":sha(host),"config_sha256":sha(cfg),"script_sha256":sha(Path(__file__)),"build_root":str(build),"build_command":cmd,"input_sha256":sha(ports),"ROM_sha256":sha(rom),"reference_terminal_sha256":sha(refpath),"verilator_version":version,"scope":"One actualCPU Japan61 candidatehardwarepath/read-onlyROM,CEN,holdobservers;no canonicalRTL/CPU/RAMwrites,Quartus orasyncsimulationbypass"}
 with (R/"research"/(N+"_build.log")).open("w") as log:
  ch=subprocess.Popen(cmd,cwd=build,stdout=log,stderr=subprocess.STDOUT);job["actual_build_pid"]=ch.pid;save("job",job);code=ch.wait()
 save("build_exit",dict(job,exit_code=code,ended=time.time()))
 if code:return code
 assert all(sha(C/x)==h for x,h in pins.items()),"Productionchangedduringbuild"
 out.mkdir();binary=out/"alpha68kn_sound_rom_q61_sim";shutil.copyfile(build/"obj/alpha68kn_sound_rom_q61_sim",binary);binary.chmod(0o755)
 job["actual_ELF_sha256"]=sha(binary);cmd=[str(binary),str(rom),"61",str(out),"gameplay","--inputs",str(ports)];job["command"]=cmd
 with (R/"research"/(N+"_run.log")).open("w") as log:
  ch=subprocess.Popen(cmd,cwd=build,stdout=log,stderr=subprocess.STDOUT);job["actual_simulation_pid"]=ch.pid;save("job",job);code=ch.wait()
 save("exit",dict(job,exit_code=code,ended=time.time(),whole_game_acceptance=False));return code
if __name__=="__main__":raise SystemExit(main())
