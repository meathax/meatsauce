#include "Valpha68kn_system.h"
#include "Valpha68kn_system___024root.h"
#include "verilated.h"
#include "sdram_model.h"
#include <algorithm>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Real CPU/renderer/controller execution. Only the external SDRAM is modeled.
struct PortState { uint16_t controls; uint8_t dips,coins; };
static std::vector<PortState> read_port_trace(const std::string& path,unsigned required) {
    std::ifstream file(path);
    if(!file) throw std::runtime_error("cannot open observed MAME port trace: "+path);
    auto split=[](std::string line) {
        if(!line.empty() && line.back()=='\r') line.pop_back();
        std::vector<std::string> result;std::istringstream stream(line);std::string field;
        while(std::getline(stream,field,',')) result.push_back(field);
        return result;
    };
    std::string line;std::getline(file,line);auto header=split(line);
    auto column=[&](const char* name) {
        auto it=std::find(header.begin(),header.end(),name);
        if(it==header.end()) throw std::runtime_error("observed port trace column missing: "+std::string(name));
        return unsigned(it-header.begin());
    };
    const unsigned frame_col=column("frame"),control_col=column("in0"),dip_col=column("in1"),coin_col=column("in2");
    std::vector<PortState> result;
    while(std::getline(file,line)) {
        auto fields=split(line);
        if(fields.size()!=header.size()) throw std::runtime_error("malformed observed port trace row");
        auto number=[&](unsigned col,unsigned maximum) {
            size_t used=0;auto value=std::stoul(fields[col],&used,10);
            if(used!=fields[col].size() || value>maximum) throw std::runtime_error("invalid observed port value");
            return unsigned(value);
        };
        if(number(frame_col,0xffffffffu)!=result.size()) throw std::runtime_error("observed port trace is not contiguous from frame zero");
        result.push_back({uint16_t(number(control_col,65535)),uint8_t(number(dip_col,255)),uint8_t(number(coin_col,3))});
    }
    if(result.size()<required) throw std::runtime_error("observed port trace does not cover requested fields");
    return result;
}

int main(int argc,char** argv) try {
    if(argc<4) {
        std::cerr<<"usage: alpha68kn_system_sim download.bin frames output_directory [attract|gameplay] [dac-probe] [--inputs frame_states.csv] [--warm-reset-after field]\n";
        return 2;
    }
    Verilated::commandArgs(argc,argv);
    std::ifstream image(argv[1],std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(image)),{});
    if(bytes.size()!=0xa0000 || bytes[0]!='A' || bytes[5]>1)
        throw std::runtime_error("Kyros/Japan payload required; Stingray CPU/MCU not implemented");
    const unsigned requested=std::stoul(argv[2]);
    if(!requested) throw std::runtime_error("positive frame count required");
    const bool gameplay=argc<5 || std::string(argv[4])=="gameplay";
    if(argc>=5 && std::string(argv[4])!="gameplay" && std::string(argv[4])!="attract")
        throw std::runtime_error("mode must be attract or gameplay");
    bool dac_probe=false;std::string input_path;
    unsigned warm_reset_after=requested;
    for(int i=5;i<argc;i++) {
        std::string option=argv[i];
        if(option=="dac-probe") dac_probe=true;
        else if(option=="--inputs" && i+1<argc) input_path=argv[++i];
        else if(option=="--warm-reset-after" && i+1<argc) {
            warm_reset_after=std::stoul(argv[++i]);
            if(warm_reset_after>=requested) throw std::runtime_error("reset field must precede run end");
        }
        else throw std::runtime_error("unknown/missing diagnostic or input option");
    }
    const auto ports=input_path.empty() ? std::vector<PortState>() : read_port_trace(input_path,requested);
    if(warm_reset_after<requested && ports.empty())
        throw std::runtime_error("warm reset requires recorded input ports");
    const std::filesystem::path output(argv[3]);
    std::filesystem::create_directories(output);
    std::ofstream snapshot_state(output/"snapshot_state.csv");
    snapshot_state<<"frame,tick,background\n";
    std::ofstream reset_events;
    if(warm_reset_after<requested) {
        reset_events.open(output/"reset_events.csv");
        reset_events<<"frame,tick,phase,main_transactions,sound_transactions,ym_writes,dac,audio_sample,cold_reset,downloading\n";
    }
    std::ofstream events(output/"bus.csv"), summary(output/"frames.csv");
    std::ofstream audio_events(output/"audio_events.csv"), epoch_events(output/"epoch_events.csv");
    std::ofstream instruction_events(output/"instruction_events.csv");
    instruction_events<<"tick,frame,raster_x,raster_y,address,iack,rw,uds_n,lds_n,data_out,data_in_before,fc_after,pc_after,ir_after,ird_after,phase_after,cpu_phase_after\n";
    std::ofstream applied_inputs(output/"applied_inputs.csv");
    applied_inputs<<"boundary,frame,tick,controls,dips,coins_n\n";
    audio_events<<"tick,frame,kind,address,data\n";
    epoch_events<<"tick,frame,raster_x,raster_y,address,iack,rw,uds_n,lds_n,data_out,data_in\n";
    std::ofstream sound_bus,pcm_stream;
    if(dac_probe) {
        sound_bus.open(output/"sound_bus_events.csv");
        sound_bus<<"tick,frame,kind,address,data,m1_n\n";
        pcm_stream.open(output/"audio.pcm",std::ios::binary);
    }
    events<<"tick,address,transaction,iack,rw,uds_n,lds_n,data_out,data_in\n";
    summary<<"frame,main_address,sound_address,main_transactions,work_writes,strip_writes,mcu_transactions,irq1_acks,irq2_acks,unmapped,pixels,duplicates,worst_line_cycles,completed_lines,deadline_misses,row_overflows\n";
    for(const char *name: {"microrom.mem","nanorom.mem"}) {
        if(!std::filesystem::exists(name) || std::filesystem::file_size(name)==0)
            throw std::runtime_error(std::string("missing required fx68k runtime ROM: ")+name);
    }
    Valpha68kn_system top;
    Sdram device;
    top.clk=0;top.cold_reset=1;top.reset=1;top.downloading=1;top.load_wr=0;
    top.load_addr=0;top.load_data=0;top.controls=0;top.dips=0x8e;top.coins_n=3;
    // Drive every framework feature input explicitly before the first edge.
    top.pause_game=0;top.rotate180=0;top.hs_access=0;top.hs_write=0;
    top.hs_addr=0;top.hs_data_in=0;
    if(!ports.empty()) {top.controls=ports[0].controls;top.dips=ports[0].dips;top.coins_n=ports[0].coins;}
    applied_inputs<<"initial,0,0,"<<top.controls<<','<<unsigned(top.dips)<<','<<unsigned(top.coins_n)<<'\n';
    top.debug_word_addr=0;top.debug_rom_kind=0;top.debug_rom_addr=0;
    top.sdram_dq=0;top.eval();
    // Settle reset-driven SDRAM pins before interpreting device commands.
    for(unsigned i=0;i<2;i++) {top.clk=1;top.eval();top.clk=0;top.eval();}
    uint64_t ticks=0;
    uint64_t ROMchecks=0,T2checks=0,holdchecks=0;
    std::ofstream ROMsamples(output/"sound_rom_samples.csv");
    ROMsamples<<"tick,address,DI,expected,tstate,attrs\n";

    auto tick=[&]() {
top.clk=0;top.eval();device.sample(top);
// eval() has already settled this half-cycle. Re-evaluate only when the
// behavioral SDRAM changes its sole DUT input; retain every clock edge.
if(top.sdram_dq!=device.dq) {top.sdram_dq=device.dq;top.eval();}
        auto *zstate=top.rootp;
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

    };
    for(unsigned i=0;i<10000;i++) tick();
    top.cold_reset=0;
    for(unsigned i=0;!top.initialized;i++) {
        if(i==20000) throw std::runtime_error("SDRAM initialization timeout");
        tick();
    }
    for(unsigned i=0;i<bytes.size();i+=2) {
        top.load_wr=0;
        while(top.load_wait) tick();
        top.load_addr=i;top.load_data=bytes[i]|(bytes[i+1]<<8);top.load_wr=1;tick();
    }
    top.load_wr=0;top.downloading=0;
    for(unsigned i=0;top.load_busy;i++) {
        if(i==20000) throw std::runtime_error("SDRAM download drain timeout");
        tick();
    }
    for(unsigned i=0;i<4096;i++) tick();
    std::cout<<"loaded profile="<<unsigned(top.profile)<<" ticks="<<ticks
        <<" device_writes="<<device.writes<<" refreshes="<<device.refreshes<<std::endl;
    top.reset=0;
    std::vector<uint8_t> rgb(256*224*3),seen(256*224);
    unsigned frame=0,pixels=0,duplicates=0,sampled=0,extra_samples=0;
    uint32_t previous=0;
    bool capture_ok=true;
    const uint64_t started=ticks;
    std::vector<int16_t> pcm;
    pcm.reserve(uint64_t(requested)*48000/59+1000);
    uint32_t previous_sound=top.sound_transactions;
    auto inputs=[&](unsigned f) {
        if(!ports.empty()) {
            // Reproduce values observed at the same MAME frame callback,
            // rather than API set_value requests queued for the next update.
            top.controls=ports[f].controls;top.dips=ports[f].dips;top.coins_n=ports[f].coins;
            applied_inputs<<"after_frame,"<<f<<','<<ticks-started<<','<<top.controls<<','
                <<unsigned(top.dips)<<','<<unsigned(top.coins_n)<<'\n';
            applied_inputs.flush();return;
        }
        if(!gameplay) return;
        if(f==120) top.coins_n=2;
        if(f==126) top.coins_n=3;
        if(f==160) top.controls|=0x80;
        if(f==166) top.controls&=~0x80;
        if(f<200) return;
        switch((f-200)%240) {
            case 0: top.controls|=4|0x10;break;
            case 36: top.controls=(top.controls&~0x10)|0x20;break;
            case 48: top.controls&=~0x20;break;
            case 60: top.controls=(top.controls&~4)|1;break;
            case 96: top.controls=(top.controls&~1)|0x10;break;
            case 108: top.controls&=~0x10;break;
            case 120: top.controls|=8;break;
            case 180: top.controls=(top.controls&~8)|2;break;
            case 216: top.controls&=~2;break;
        }
    };
    while(frame<requested) {
        if(ticks-started>uint64_t(requested+1)*384*264*8)
            throw std::runtime_error("raster frame boundary timeout");
        // Match the oracle's input changes after the vblank-entry snapshot.
        bool boundary=top.raw_ce && top.raw_x==383 && top.raw_y==239;
        auto address=top.debug_main_addr;
        auto attrs=top.debug_main_attrs;auto dataout=top.debug_main_dout;
        auto raster_x=top.raw_x,raster_y=top.raw_y;
        auto instruction_din_before=top.debug_main_din;
        bool io_read=top.sound_io_rd;
        auto io_read_addr=top.sound_io_read_addr,io_read_data=top.sound_io_read_data;
        auto sound_address=top.debug_sound_addr;
        auto sound_attrs=top.debug_sound_attrs;
        auto sound_in=top.debug_sound_din,sound_out=top.debug_sound_dout;
        tick();
        if(top.audio_sample_ce) {
            pcm.push_back(static_cast<int16_t>(top.audio_sample));
            if(dac_probe) {pcm_stream.put(top.audio_sample&255);pcm_stream.put((top.audio_sample>>8)&255);}
        }
        if(top.sound_io_wr) audio_events<<ticks-started<<','<<frame<<",write,"
            <<unsigned(top.sound_io_addr)<<','<<unsigned(top.sound_io_data)<<'\n';
        if(top.sound_dac_wr) audio_events<<ticks-started<<','<<frame<<",dac,57348,"
            <<unsigned(top.dac)<<'\n';
        if(top.sound_transactions!=previous_sound) {
            previous_sound=top.sound_transactions;
            // Observe the same accepted writes that update board sound RAM.
            if(dac_probe && !(sound_attrs&1) && !(sound_attrs&8)
                && ((sound_address>=0xc100 && sound_address<=0xc123)
                    || (sound_address>=0xe000 && sound_address<=0xe004)))
                sound_bus<<ticks-started<<','<<frame<<",write,"<<sound_address<<','
                    <<unsigned(sound_out)<<','<<((sound_attrs>>4)&1)<<'\n';
            if(io_read) audio_events<<ticks-started<<','<<frame<<",read,"
                <<unsigned(io_read_addr)<<','<<unsigned(io_read_data)<<'\n';
        }
        // End-of-read-bus observations retain stable pre-edge address/data.
        // They are diagnostics, not an assertion of the CPU's sampling edge.
        if(dac_probe && frame>=118 && frame<=124 && !(sound_attrs&2)
            && (top.debug_sound_attrs&2) && !(sound_attrs&8)
            && ((sound_address>=0xc100 && sound_address<=0xc123) || sound_address==0xe000
                || ((sound_attrs&16) && sound_address>=0x500 && sound_address<0xc000)))
            sound_bus<<ticks-started<<','<<frame<<",read_end,"<<sound_address<<','
                <<unsigned(sound_in)<<','<<((sound_attrs>>4)&1)<<'\n';
        if(top.main_transactions!=previous) {
            previous=top.main_transactions;
            if(frame>=59 && frame<=60) {
                auto *state=top.rootp;
                uint32_t pc=(uint32_t(state->alpha68kn_system__DOT__board__DOT__maincpu__DOT__excUnit__DOT__PcH)<<16)
                    | state->alpha68kn_system__DOT__board__DOT__maincpu__DOT__excUnit__DOT__PcL;
                instruction_events<<ticks-started<<','<<frame<<','<<raster_x<<','<<raster_y<<','<<address<<','
                    <<((attrs>>3)&1)<<','<<((attrs>>2)&1)<<','<<((attrs>>1)&1)<<','<<(attrs&1)<<','
                    <<dataout<<','<<instruction_din_before<<','
                    <<unsigned(state->alpha68kn_system__DOT__board__DOT__maincpu__DOT__rFC)<<','<<pc<<','
                    <<state->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Ir<<','
                    <<state->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Ird<<','
                    <<unsigned(state->alpha68kn_system__DOT__board__DOT__phase)<<','
                    <<unsigned(state->alpha68kn_system__DOT__board__DOT__cpu_phase)<<'\n';
            }
            bool selected=(address>=0x020000 && address<0x021000)
                || (address>=0x080000 && address<0x080200)
                || (address>=0x01fc00 && address<0x01ff00);
            if(sampled++<4096 || (selected && extra_samples++<2048))
                events<<ticks-started<<','<<address<<','<<previous<<','<<((attrs>>3)&1)<<','
                    <<((attrs>>2)&1)<<','<<((attrs>>1)&1)<<','<<(attrs&1)<<','
                    <<dataout<<','<<top.debug_main_din<<'\n';
            // Complete causal stream for IRQs, backdrop writes, frame counters
            // and the message strip; no bus sample cap or injected behavior.
            if((attrs&8) || ((attrs&4)==0 && (address==0x060000 || address==0x0e0000 || (address>=0x20000 && address<=0x2000a)
                || (address>=0x40e1c && address<=0x40e3e)
                || (address>=0x40eea && address<=0x40ef0) || address==0x406c2
                || (frame>=330 && frame<=420 && address>=0x040000 && address<0x042000))))
                epoch_events<<ticks-started<<','<<frame<<','<<raster_x<<','<<raster_y<<','<<address<<','
                    <<((attrs>>3)&1)<<','<<((attrs>>2)&1)<<','<<((attrs>>1)&1)<<','<<(attrs&1)<<','
                    <<dataout<<','<<top.debug_main_din<<'\n';
        }
        if(top.video_ce && !top.video_hblank && !top.video_vblank) {
            if(top.video_y<16 || top.video_y>239)
                throw std::runtime_error("visible pixel outside native viewport");
            unsigned index=(top.video_y-16)*256+top.video_x;
            if(seen[index]++) duplicates++;
            pixels++;
            rgb[index*3]=top.video_rgb>>16;rgb[index*3+1]=top.video_rgb>>8;rgb[index*3+2]=top.video_rgb;
        }
        if(!boundary) continue;
        capture_ok &= pixels==256*224 && duplicates==0;
        summary<<frame<<','<<top.debug_main_addr<<','<<top.debug_sound_addr<<','
            <<top.main_transactions<<','<<top.work_writes<<','<<top.strip_writes<<','
            <<top.mcu_transactions<<','<<top.irq1_acks<<','<<top.irq2_acks<<','<<top.unmapped_accesses<<','
            <<pixels<<','<<duplicates<<','<<top.worst_line_cycles<<','<<top.completed_lines<<','
            <<top.deadline_misses<<','<<top.row_overflows<<'\n';
        summary.flush();
        audio_events.flush();epoch_events.flush();
        if(dac_probe) {sound_bus.flush();pcm_stream.flush();}
        if(frame<=16 || frame%30==0 || frame==119 || frame==179 || frame==1799 || frame+1==requested) {
            char name[40];std::snprintf(name,sizeof name,"frame_%06u.rgb",frame);
            std::ofstream f(output/name,std::ios::binary);
            f.write(reinterpret_cast<const char*>(rgb.data()),rgb.size());
            // Observe retained RAM directly; no model clocks, CPU state or
            // bus controls change while writing these diagnostic files.
            std::string stem(name);stem.resize(stem.size()-4);
            auto dump_ram=[&](const char* suffix,const auto& words,unsigned count) {
                std::ofstream target(output/(stem+suffix),std::ios::binary);
                for(unsigned i=0;i<count;i++) {
                    target.put((words[i]>>8)&255);target.put(words[i]&255);
                }
            };
            dump_ram(".sprites.bin",top.rootp->alpha68kn_system__DOT__board__DOT__strip_ram,4096);
            dump_ram(".work.bin",top.rootp->alpha68kn_system__DOT__board__DOT__work_ram,2048);
            snapshot_state<<frame<<','<<ticks-started<<','<<top.rootp->alpha68kn_system__DOT__background<<'\n';
            snapshot_state.flush();
            std::cout<<"frame="<<frame<<" pixels="<<pixels<<" duplicates="<<duplicates
                <<" main="<<top.main_transactions<<" strips="<<top.strip_writes
                <<" worst="<<top.worst_line_cycles<<" misses="<<top.deadline_misses<<std::endl;
        }
        std::fill(seen.begin(),seen.end(),0);pixels=0;duplicates=0;
        inputs(frame);
        if(frame==warm_reset_after) {
            auto record_reset=[&](const char* phase) {
                reset_events<<frame<<','<<ticks-started<<','<<phase<<','
                    <<top.main_transactions<<','<<top.sound_transactions<<','<<top.ym_writes<<','
                    <<unsigned(top.dac)<<','<<static_cast<int16_t>(top.audio_sample)<<','
                    <<unsigned(top.cold_reset)<<','<<unsigned(top.downloading)<<'\n';
                reset_events.flush();
            };
            record_reset("before");
            // The reference releases cabinet controls before scheduling reset.
            // Keep the loaded ROM/SDRAM and assert only the game's warm reset.
            top.controls=0;top.coins_n=3;top.reset=1;
            for(unsigned i=0;i<64;i++) tick();
            record_reset("held");
            if(top.cold_reset || top.downloading || top.main_transactions || top.sound_transactions
                || top.ym_writes || top.dac || static_cast<int16_t>(top.audio_sample)!=0)
                throw std::runtime_error("warm reset retained CPU/audio state or reloaded ROM");
            previous=top.main_transactions;previous_sound=top.sound_transactions;
            top.reset=0;
            applied_inputs<<"warm_reset,"<<frame<<','<<ticks-started<<",0,"
                <<unsigned(top.dips)<<",3\n";
        }
        // The first completed field is recorder frame 0, as in capture.lua.
        frame++;
    }
    bool ran=top.main_transactions>10 && capture_ok && !top.deadline_misses && !top.row_overflows;
    std::cout<<"frames="<<frame<<" main_transactions="<<top.main_transactions
        <<" mcu="<<top.mcu_transactions<<" strips="<<top.strip_writes
        <<" unmapped="<<top.unmapped_accesses<<" reads="<<device.reads
        <<" refreshes="<<device.refreshes<<" capture_ok="<<capture_ok<<std::endl;
    // 48 kHz mono PCM16 from the real sound-chip/mixer output, including DC.
    // No normalization or filter conceals clipping or route-gain defects.
    std::ofstream wav(output/"audio.wav",std::ios::binary);
    auto le=[&](uint32_t value,unsigned width) {for(unsigned i=0;i<width;i++) wav.put((value>>(8*i))&255);};
    const uint32_t audio_bytes=pcm.size()*2;
    wav.write("RIFF",4);le(36+audio_bytes,4);wav.write("WAVEfmt ",8);le(16,4);
    le(1,2);le(1,2);le(48000,4);le(96000,4);le(2,2);le(16,2);
    wav.write("data",4);le(audio_bytes,4);
    int minimum=32767,maximum=-32768;uint64_t changed_samples=0;
    for(unsigned i=0;i<pcm.size();i++) {
        le(static_cast<uint16_t>(pcm[i]),2);minimum=std::min(minimum,int(pcm[i]));
        maximum=std::max(maximum,int(pcm[i]));if(i && pcm[i]!=pcm[i-1]) changed_samples++;
    }
    std::ofstream audio_report(output/"audio.json");
    audio_report<<"{\"scope\":\"real CPU/chip/mixer output; audio fidelity not yet qualified\","
        <<"\"samples\":"<<pcm.size()<<",\"sample_rate\":48000,\"minimum\":"<<minimum
        <<",\"maximum\":"<<maximum<<",\"changed_samples\":"<<changed_samples
        <<",\"clipped_samples\":"<<top.audio_clipped_samples<<",\"ym_writes\":"<<top.ym_writes
        <<",\"ay1_writes\":"<<top.ay1_writes<<",\"ay2_writes\":"<<top.ay2_writes<<"}\n";
    std::ofstream ROMreport(output/"sound_rom_contract.json");
    ROMreport<<"{\"scope\":\"actualCPU candidatehardwarepath readonlychecks\",\"ROM_CEN_checks\":"
             <<ROMchecks<<",\"T2_accept_checks\":"<<T2checks<<",\"address_hold_checks\":"
             <<holdchecks<<",\"mismatch_count\":0}\n";
    if(!ROMchecks || !T2checks || !holdchecks) throw std::runtime_error("vacuousROMcontract");
    top.reset=1;tick();
    std::ofstream work(output/"work.bin",std::ios::binary),strip(output/"sprites.bin",std::ios::binary);
    for(unsigned i=0;i<4096;i++) {
        top.debug_word_addr=i;tick();uint16_t w=top.debug_work_data,s=top.debug_strip_data;
        if(i<2048) {work.put(w>>8);work.put(w&255);}strip.put(s>>8);strip.put(s&255);
    }
    top.final();
    return ran ? 0 : 1;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 3;}
