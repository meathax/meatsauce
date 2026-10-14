"""Derive a private actual wrapper gameplay/save/reset/reload host harness."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim/captures/diagnostics/earned_wrapper"


def main():
    if OUT.exists():
        raise SystemExit("Existing earned-wrapper source: preserve its build/run evidence")
    OUT.mkdir(parents=True)
    source = ROOT / "sim/wrapper_main.cpp"
    text = source.read_text()
    text = text.replace('#include <vector>', '#include <vector>\n#include <sstream>')
    old = '    if(argc!=4 && argc!=5) return 2;'
    assert text.count(old) == 1
    text = text.replace(old, '''    if(argc!=4 && argc!=5 && argc!=6) return 2;
    bool earned=argc==6 && std::string(argv[4])=="--earned-score";
    if(argc==6 && !earned) return 2;
    struct Ports {unsigned controls,dips,coins;};
    std::vector<Ports> ports;
    if(earned) {
        std::ifstream input(argv[5]);std::string line;
        if(!input || !std::getline(input,line)) throw std::runtime_error("missing recorded ports");
        auto split=[](std::string s) {std::vector<std::string> a;std::string v;std::istringstream f(s);while(std::getline(f,v,',')) a.push_back(v);return a;};
        auto header=split(line);
        auto column=[&](const char* n) {auto i=std::find(header.begin(),header.end(),n);if(i==header.end()) throw std::runtime_error("port column absent");return unsigned(i-header.begin());};
        auto cf=column("frame"),cc=column("in0"),cd=column("in1"),cb=column("in2");
        while(std::getline(input,line)) {
            auto a=split(line);if(a.size()!=header.size() || std::stoul(a[cf])!=ports.size()) throw std::runtime_error("invalid port sequence");
            Ports p{unsigned(std::stoul(a[cc])),unsigned(std::stoul(a[cd])),unsigned(std::stoul(a[cb]))&3u};
            if(p.controls>65535 || p.dips!=0x8e || (p.coins&~3u)) throw std::runtime_error("unexpected scenario ports/DIPs");
            ports.push_back(p);
        }
    }''', 1)
    old = '    while(!finished) tick();'
    assert text.count(old) == 1
    text = text.replace(old, '''    std::ofstream applied(output/"applied_gameplay_ports.csv");
    applied<<"after_frame,tick,controls,dips,coins_n,joy0,joy1\\n";
    if(earned && (requested<901 || ports.size()<requested)) throw std::runtime_error("earned run requires at least901 recorded fields");
    unsigned applied_frame=0xffffffffu;
    while(!finished) {
        tick();
        if(earned && frame && applied_frame!=frame-1) {
            unsigned f=frame-1;applied_frame=f;auto p=ports[f];
            auto joy=[](unsigned c,bool coin) {return ((c&1)?8:0)|((c&2)?4:0)|((c&4)?1:0)|((c&8)?2:0)|(c&0x30)|((c&0x80)?0x40:0)|(coin?0x80:0);};
            auto j0=joy(p.controls&255,!(p.coins&1)),j1=joy(p.controls>>8,!(p.coins&2));
            user(0x02,{uint16_t(j0),0});user(0x03,{uint16_t(j1),0});
            if(top.SIM_CONTROLS!=p.controls || top.SIM_COINS!=p.coins || top.SIM_DIPS!=p.dips) throw std::runtime_error("real HPS gameplay mapping failed");
            applied<<f<<','<<ticks<<','<<p.controls<<','<<p.dips<<','<<p.coins<<','<<j0<<','<<j1<<'\\n';applied.flush();
        }
    }''', 1)
    old = '    if(features) {'
    assert text.count(old) == 1
    block = '''    if(earned) {
        auto idle=[&](unsigned n) {for(unsigned i=0;i<n;i++) tick();};
        auto status=[&](uint32_t v) {user(0x1e,{uint16_t(v),uint16_t(v>>16),0,0,0,0,0,0});idle(100);};
        auto pause=[&]() {user(0x02,{0x100,0});user(0x02,{0,0});idle(100);};
        auto download=[&](unsigned index,const std::vector<uint8_t>& bytes) {
            word(true,0x55);word(true,index);end();word(true,0x53);word(true,1);word(true,0);word(true,0);end();
            word(true,0x54);for(auto b:bytes) word(true,b);end();word(true,0x53);word(true,0);end();
        };
        auto ram=[&](unsigned address) {
            if(!top.SIM_PAUSED) throw std::runtime_error("score observation requires real pause acknowledgement");
            top.SIM_TEST_HS_ACCESS=1;top.SIM_TEST_HS_WRITE=0;top.SIM_TEST_HS_ADDR=address;idle(3);
            auto value=top.SIM_HS_DATA;top.SIM_TEST_HS_ACCESS=0;return uint8_t(value);
        };
        std::ifstream cfgfile(std::filesystem::path(argv[1]).parent_path()/"hiscore_config.bin",std::ios::binary);
        std::vector<uint8_t> cfg{std::istreambuf_iterator<char>(cfgfile),{}};
        if(cfg.size()!=32) throw std::runtime_error("actual Kyros hiscore config required");
        std::vector<unsigned> addresses;
        for(unsigned i=16;i<cfg.size();i+=8) {
            unsigned a=(unsigned(cfg[i])<<24)|(unsigned(cfg[i+1])<<16)|(unsigned(cfg[i+2])<<8)|cfg[i+3];
            for(unsigned b=0;b<cfg[i+4];b++) addresses.push_back(a+b);
        }
        if(addresses.size()!=178) throw std::runtime_error("unexpected score size");
        pause();if(!top.SIM_PAUSED) throw std::runtime_error("gameplay pause failed");
        auto read=[&]() {std::vector<uint8_t> v;for(auto a:addresses) v.push_back(ram(a));return v;};
        auto best=[&]() {return (unsigned(ram(0x20020))<<24)|(unsigned(ram(0x20021))<<16)|(unsigned(ram(0x20022))<<8)|ram(0x20023);};
        auto earned_best=best();if(!earned_best) throw std::runtime_error("no CPU-earned best score; no synthetic fallback");
        auto actual=read();auto tx=top.SIM_MAIN_TX;
        download(3,cfg);if(!top.SIM_HS_CONFIGURED) throw std::runtime_error("real donor config failed");
        unsigned prior=hs_requests;top.OSD_STATUS=1;idle(20000);
        if(hs_requests!=prior+1 || top.SIM_MAIN_TX!=tx) throw std::runtime_error("earned extraction request/pause failed");
        std::vector<uint8_t> saved;
        word(true,0x55);word(true,4);end();word(true,0x53);word(true,0xaa);word(true,0);word(true,0);end();idle(20);word(true,0x54);
        for(unsigned i=0;i<actual.size();i++) {word(true,0);saved.push_back(top.HPS_BUS&255);}
        end();word(true,0x53);word(true,0);end();
        if(saved!=actual) throw std::runtime_error("real HPS earned upload differs from CPU RAM");
        {std::ofstream f(output/"earned.nvm",std::ios::binary);f.write(reinterpret_cast<const char*>(saved.data()),saved.size());}
        top.OSD_STATUS=0;idle(100);pause();if(top.SIM_PAUSED) throw std::runtime_error("user pause release failed");
        user(0x03,{0,0});status(3);idle(100);status(2);
        // Run actual reset ROM until it really clears the earned best score.
        // Never write test RAM or merely compare a still-persistent old value.
        bool initialized=false;unsigned reset_steps=0;
        for(;reset_steps<1000;reset_steps++) {
            idle(20000);pause();
            initialized=best()==0;
            for(unsigned i=16;i<cfg.size();i+=8) {
                unsigned a=(unsigned(cfg[i])<<24)|(unsigned(cfg[i+1])<<16)|(unsigned(cfg[i+2])<<8)|cfg[i+3];
                initialized=initialized && ram(a)==cfg[i+5] && ram(a+cfg[i+4]-1)==cfg[i+6];
            }
            if(initialized) break;pause();
        }
        if(!initialized) throw std::runtime_error("actual reset did not clear score/readiness within limit");
        download(4,saved);bool restored=false;unsigned restore_steps=0;
        for(;restore_steps<100;restore_steps++) {idle(50000);if(read()==saved) {restored=true;break;}}
        if(!restored || best()!=earned_best) throw std::runtime_error("real donor reload failed after CPU-cleared score");
        pause();idle(10000);if(top.SIM_PAUSED) throw std::runtime_error("post-restore CPU release failed");
        std::ofstream result(output/"earned_score.json");
        result<<"{\\"passed\\":true,\\"earned_best_raw\\":"<<earned_best<<",\\"saved_bytes\\":178,\\"cpu_reset_cleared_best\\":true,\\"reset_steps\\":"<<reset_steps<<",\\"restore_steps\\":"<<restore_steps<<",\\"hps_upload_exact\\":true,\\"hps_restore_exact\\":true,\\"synthetic_ram_writes\\":0,\\"limit\\":\\"Ideal PLL/peripheral interfaces; finite Kyros gameplay and score protocol only; no physical qualification\\"}\\n";
    }
'''
    text = text.replace(old, block+old, 1)
    host = OUT / "wrapper_main.cpp"
    host.write_text(text, encoding="utf-8")
    builder = ROOT / "sim/build_wrapper.sh"
    script = builder.read_text()
    old = 'cp Alpha68k_N.sv sim/wrapper_main.cpp sim/sdram_model.h "$snapshot/"'
    assert script.count(old) == 1
    script = script.replace(old, 'cp Alpha68k_N.sv sim/sdram_model.h "$snapshot/"\ncp sim/captures/diagnostics/earned_wrapper/wrapper_main.cpp "$snapshot/wrapper_main.cpp"')
    script = script.replace('sha256sum rtl/', 'sha256sum rtl/', 1).replace('Alpha68k_N.sv sim/wrapper_main.cpp sim/sdram_model.h sim/build_wrapper.sh', 'Alpha68k_N.sv sim/captures/diagnostics/earned_wrapper/wrapper_main.cpp sim/sdram_model.h sim/build_wrapper.sh')
    script = script.replace('wrapper_build_dir.txt','earned_wrapper_build_dir.txt').replace('wrapper_inputs.sha256','earned_wrapper_inputs.sha256').replace('wrapper_scope_adapter.json','earned_wrapper_scope_adapter.json')
    script = script.replace('cp obj/alpha68kn_wrapper_sim "$workspace/sim/build/"', 'cp obj/alpha68kn_wrapper_sim "$workspace/sim/build/alpha68kn_wrapper_earned_sim"')
    (OUT / "build.sh").write_text(script, encoding="utf-8", newline="\n")
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    record = {"canonical_host":source.relative_to(ROOT).as_posix(),"canonical_host_sha256":digest(source),
              "derived_host":host.relative_to(ROOT).as_posix(),"derived_host_sha256":digest(host),
              "canonical_builder_sha256":digest(builder),"derived_builder":(OUT / "build.sh").relative_to(ROOT).as_posix(),
              "derived_builder_sha256":digest(OUT / "build.sh"),
              "scope":"Actual wrapper CPU gameplay via real HPS ports, real donor save, CPU reset clears score then real donor restore. No synthetic RAM writes. No production RTL changes; qualification pending."}
    (ROOT / "research/kyros_earned_wrapper_source.json").write_text(json.dumps(record,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"prepared":True,"host_sha256":record["derived_host_sha256"]}))


if __name__ == "__main__":
    main()
