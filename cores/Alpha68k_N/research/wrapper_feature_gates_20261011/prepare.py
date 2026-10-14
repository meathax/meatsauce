import hashlib,json,shutil,difflib
from pathlib import Path

OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
CAN=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
OUT=OLD/'research/wrapper_feature_gates_20261011'
JOIN=OLD/'research/stingray_combined_stage/next_coupled_scope_v2'
SRC=OUT/'source'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def copy(p,d):
    d.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,d)
    return dict(original_path=str(p),path=str(d),sha256=sha(d),bytes=d.stat().st_size)

assert not SRC.exists(),'Do not duplicate a prepared snapshot'
entries=[]
closure=json.loads((JOIN/'source_closure.json').read_text())
for e in closure['source_files']:
    p=Path(e['path']);assert sha(p)==e['combined_sha256']
    rel=p.relative_to(JOIN/'source')
    if rel.parts[0]=='rtl': entries.append(copy(p,SRC/rel))
for rel in ['Alpha68k_N.sv','sim/sdram_model.h','sim/normalize_framework_scope.py','sys/video_freak.sv','sys/math.sv','sys/emu_ports.vh','sys/hps_io.sv','sys/arcade_video.v','sys/video_mixer.sv','sys/gamma_corr.sv','sys/scandoubler.v','sys/hq2x.sv','sys/video_freezer.sv','sys/sys_top.v']:
    entries.append(copy(CAN/rel,SRC/rel))
for p in (CAN/'rtl/vendor/mister_features').glob('*'):
    if p.suffix in ('.v','.sv'):entries.append(copy(p,SRC/p.relative_to(CAN)))
wrapper=(SRC/'Alpha68k_N.sv').read_text()
assert wrapper.count('board_load_data[15:8]<=1')==1
wrapper=wrapper.replace('board_load_data[15:8]<=1','board_load_data[15:8]<=2')
ports='''    ,output wire SIM_MCU_SHARED,SIM_MCU_PENDING
    ,output wire [31:0] SIM_MCU_TICKS
'''
wrapper=wrapper.replace('    ,output wire SIM_HS_RESTORING,SIM_HS_EXTRACTING\n','    ,output wire SIM_HS_RESTORING,SIM_HS_EXTRACTING\n'+ports)
obs='''    assign SIM_MCU_SHARED=system.board.sting_mcu_shared_write;
    assign SIM_MCU_PENDING=system.board.sting_mcu.p2_pending;
    assign SIM_MCU_TICKS=system.board.sting_mcu.core_ticks;
'''
wrapper=wrapper.replace('    assign SIM_HS_EXTRACTING=hi.extracting_dump;\n','    assign SIM_HS_EXTRACTING=hi.extracting_dump;\n'+obs)
(SRC/'Alpha68k_N.sv').write_text(wrapper,newline='\n')
(OUT/'wrapper_integration.patch').write_text(''.join(difflib.unified_diff((CAN/'Alpha68k_N.sv').read_text().splitlines(True),wrapper.splitlines(True),fromfile='canonical/Alpha68k_N.sv',tofile='private/Alpha68k_N.sv')),newline='\n')
host=(CAN/'sim/wrapper_main.cpp').read_text()
host=host.replace('    bool features=argc==5 && std::string(argv[4])=="--features";','    bool features=argc==5 && std::string(argv[4])=="--features";')
start=host.index('    if(features) {\n')
finish=host.index('    std::ofstream result(output/"result.json");',start)
fixture=r'''    if(features) {
        auto idle=[&](unsigned n) {for(unsigned i=0;i<n;i++) tick();};
        auto status=[&](uint32_t value) {user(0x1e,{uint16_t(value),uint16_t(value>>16),0,0,0,0,0,0});idle(20);};
        auto require=[&](bool ok,const char* message) {if(!ok) throw std::runtime_error(message);};
        require(top.SIM_PROFILE==2 && top.SIM_ROM_LOADED && !top.SIM_GAME_RESET,"profile2 wrapper release failed");
        top.OSD_STATUS=1;idle(12);require(top.SIM_PAUSED,"OSD pause did not drain MCU");
        auto tx=top.SIM_MAIN_TX,mt=top.SIM_MCU_TICKS;auto x=top.SIM_RAW_X;
        idle(10000);require(top.SIM_MAIN_TX==tx && top.SIM_MCU_TICKS==mt && top.SIM_RAW_X!=x && !top.SIM_MCU_SHARED,"paused MCU/CPU did not freeze independently of raster");
        // Borrow existing game bytes read-only; no synthetic score or state writes.
        std::vector<uint8_t> before(512),after(512);
        auto read=[&](std::vector<uint8_t>& bytes) {
            for(unsigned i=0;i<bytes.size();i++) {
                top.SIM_TEST_HS_ACCESS=1;top.SIM_TEST_HS_WRITE=0;
                top.SIM_TEST_HS_ADDR=0x20000+i;idle(3);bytes[i]=top.SIM_HS_DATA;
            }
            top.SIM_TEST_HS_ACCESS=0;idle(4);
        };
        read(before);idle(1000);read(after);require(before==after,"MCU changed shared RAM during read-only borrow");
        top.OSD_STATUS=0;idle(10000);require(!top.SIM_PAUSED && top.SIM_MAIN_TX>tx && top.SIM_MCU_TICKS>mt,"OSD borrow release stalled CPU/MCU");
        // Catch an actual registered P2 observation in the real firmware.
        unsigned await=0;for(;await<2*811008 && !top.SIM_MCU_PENDING;await++) tick();
        require(top.SIM_MCU_PENDING,"no real MCU pending P2 event observed for drain fixture");
        top.OSD_STATUS=1;idle(12);require(top.SIM_PAUSED && !top.SIM_MCU_SHARED,"in-flight P2 pause drain failed");
        mt=top.SIM_MCU_TICKS;tx=top.SIM_MAIN_TX;read(before);idle(1000);read(after);
        require(before==after && top.SIM_MAIN_TX==tx && top.SIM_MCU_TICKS==mt,"pending-write borrower raced live CPU/MCU");
        top.OSD_STATUS=0;idle(10000);require(!top.SIM_PAUSED && top.SIM_MAIN_TX>tx && top.SIM_MCU_TICKS>mt,"pending-write borrow release failed");
        user(0x02,{0x100,0});user(0x02,{0,0});idle(12);require(top.SIM_PAUSED && top.SIM_USER_PAUSE,"user pause toggle failed");
        status(3);require(top.SIM_GAME_RESET && !top.SIM_PAUSED && !top.SIM_USER_PAUSE,"reset did not revoke pause and borrow");
        status(2);idle(10000);require(!top.SIM_GAME_RESET && !top.SIM_PAUSED && top.SIM_ROM_LOADED,"soft reset release lost ROM or pause");
        std::ofstream feature_result(output/"features.json");
        feature_result<<"{\"passed\":true,\"profile\":2,\"read_only_shared_bytes\":512,\"pending_event_wait_ticks\":"<<await<<",\"osd_pause\":true,\"mcu_drain\":true,\"cpu_mcu_resume\":true,\"reset_revokes_pause\":true,\"limit\":\"Pre-MCU-functional-fix integration candidate; read-only borrower is a RAM arbitration fixture, not earned-score donor acceptance. Physical clocks/interfaces, final gameplay and final corrected MCU pipeline remain unqualified.\"}\n";
    }
'''
host=host[:start]+fixture+host[finish:]
# An invalid format/profile header must not arm the loaded gate. Only the header
# is sent; full accepted image subsequently uses the unchanged actual HPS loader.
needle='    checking_load=true;word(true,0x54);\n'
assert host.count(needle)==1
invalid=r'''    word(true,0x54);for(unsigned i=0;i<6;i++) word(true,i==5?3:rom[i]);end();
    word(true,0x53);word(true,0);end();
    for(unsigned i=0;i<1000;i++) tick();
    if(top.SIM_ROM_LOADED || !top.SIM_GAME_RESET) throw std::runtime_error("invalid/incomplete profile header released reset");
    word(true,0x53);word(true,1);word(true,0);word(true,0);end();
'''
host=host.replace(needle,invalid+needle)
(SRC/'sim/wrapper_main.cpp').write_text(host,newline='\n')
sys_top=(SRC/'sys/sys_top.v').read_text();a=sys_top.index('module sync_fix');b=sys_top.index('endmodule',a)+len('endmodule')
(SRC/'sys/sync_fix.v').write_text(sys_top[a:b]+'\n',newline='\n')
(SRC/'build_id.v').write_text('`define BUILD_DATE "simulation"\n',newline='\n')
build='''#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/source"
mkdir -p obj
python3 sim/normalize_framework_scope.py sys/video_mixer.sv ../scope_adapter.json
cp rtl/vendor/fx68k/{microrom,nanorom}.mem .
mapfile -t hdl < <(find rtl -type f \\( -name '*.sv' -o -name '*.v' \\) ! -name 'alpha68kn_pll.sv' | sort)
CCACHE_DISABLE=1 /usr/local/bin/verilator --cc --exe --build -j 2 -O3 --assert --no-assert-case -Wno-fatal -Wno-PROCASSWIRE --top-module emu --Mdir obj -o alpha68kn_wrapper_profile2_sim -I. -Irtl/vendor/fx68k -DALPHA_EMU_SIM -DMISTER_FB -DMISTER_FB_PALETTE Alpha68k_N.sv "${hdl[@]}" sys/{sync_fix,arcade_video}.v sys/{video_freak,math,hps_io,video_mixer,gamma_corr,scandoubler,hq2x,video_freezer}.sv sim/wrapper_main.cpp -CFLAGS '-O3 -std=c++17'
'''
# Framework donor suffixes are exact; generate explicit list rather than infer names.
build=build.replace('sys/{video_freak,math,hps_io,video_mixer,gamma_corr,scandoubler,hq2x,video_freezer}.sv','sys/video_freak.sv sys/math.sv sys/hps_io.sv sys/video_mixer.sv sys/gamma_corr.sv sys/scandoubler.v sys/hq2x.sv sys/video_freezer.sv')
(OUT/'build.sh').write_text(build,newline='\n')
records=[]
for p in SRC.rglob('*'):
    if p.is_file(): records.append(dict(path=str(p),sha256=sha(p),bytes=p.stat().st_size))
(OUT/'preparation.json').write_text(json.dumps(dict(schema='private_profile2_wrapper_preparation_v1',scope='Joined P6 MCU/T48 source closure plus real canonical emu/HPS/framework; <=2 admission integration candidate only; read-only observer ports and borrower; no production edits',parent_closure_sha256=sha(JOIN/'source_closure.json'),canonical_wrapper_sha256=sha(CAN/'Alpha68k_N.sv'),source_pins=records,original_copies=entries,limits=['MCU coinage P2 functional correction pending separately','No score writes; genuine earned donor save/reset/restore not closed','No Quartus/RBF/hardware changes']),indent=2)+'\n',newline='\n')
print(json.dumps({'prepared':True,'source_files':len(records),'canonical_wrapper_unchanged':sha(CAN/'Alpha68k_N.sv'),'output':str(OUT)}))
