// Graphics deadline bench driver. Pin-level SDRAM model (MT48LC16M16 style,
// CL from the mode register), worst-case CPU/COP ROM-miss stressor, per-line
// sprite renderer cost log, frame dump. See sim/zero_contention_top.sv.
#include "Vzero_contention_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static std::vector<uint8_t> load(const std::string& name) {
    std::ifstream f("roms/regions/"+name+".bin",std::ios::binary);
    if(!f) throw std::runtime_error("missing region "+name);
    return {(std::istreambuf_iterator<char>(f)),{}};
}
struct Beat { uint64_t at; uint16_t v; };

int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    bool ideal=false, flip=false, no_reserve=false; int map=0; int stress=2; int frames=4;
    unsigned layer_enable=31; unsigned scroll[6]={0,0,0,0,0,0};
    std::string out="build/contention/out";
    for(int i=1;i<argc;++i){
        std::string a=argv[i];
        if(a=="--ideal") ideal=true;
        else if(a=="--flip") flip=true;
        else if(a=="--no-reserve") no_reserve=true;
        else if(a=="--map") map=std::atoi(argv[++i]);
        else if(a=="--stress") stress=std::atoi(argv[++i]);   // 0 none, 1 main, 2 main+cop
        else if(a=="--frames") frames=std::atoi(argv[++i]);
        else if(a=="--layers") layer_enable=std::strtoul(argv[++i],nullptr,0);
        else if(a=="--scroll") { for(int k=0;k<6;++k) scroll[k]=std::strtoul(argv[++i],nullptr,0); }
        else if(a=="--out") out=argv[++i];
    }
    auto chars=load("chars"), tiles=load("tiles"), sprites=load("sprites");
    // physical store: [bank:2][row:13][col:9] words
    std::vector<uint16_t> mem(size_t(1)<<24, 0);
    auto phys=[&](uint32_t L)->uint32_t{   // L = logical 24-bit word address {ba,a[22:1]}
        uint32_t ba=(L>>22)&3, a=L&0x3fffff, row, col;
        if(map==0){ row=a&0x1fff; col=(a>>13)&0x1ff; }
        else      { row=(a>>9)&0x1fff; col=a&0x1ff; }
        return (ba<<22)|(row<<9)|col;
    };
    auto put=[&](uint32_t L,const std::vector<uint8_t>& b){
        for(size_t i=0;i+1<b.size();i+=2) mem[phys(L+uint32_t(i/2))]=uint16_t(b[i]|(b[i+1]<<8));
    };
    put(0x080000,chars); put(0x090000,tiles); put(0x400000,sprites);

    Vzero_contention_top t;
    t.ideal=ideal; t.flip=flip; t.no_reserve=no_reserve; t.layer_enable=layer_enable;
    t.bg_x=scroll[0]; t.bg_y=scroll[1]; t.mg_x=scroll[2]; t.mg_y=scroll[3]; t.fg_x=scroll[4]; t.fg_y=scroll[5];
    t.model_dq=0; t.main_req=0; t.cop_req=0; t.oki_address=0; t.ideal_valid=0;

    // SDRAM model state
    int cl=3, bl=1; uint32_t open_row[4]; bool open_[4]={0,0,0,0};
    int64_t last_act[4]={-100,-100,-100,-100}, close_at[4]={-100,-100,-100,-100}, last_ref=-100;
    std::deque<Beat> beats; uint64_t violations=0; std::string first_violation;
    auto violate=[&](uint64_t c,const char* what){ if(!violations++){ first_violation=std::string(what)+" at "+std::to_string(c);} };
    uint64_t sd_reads=0, sd_writes=0, acts=0;

    // stressor
    uint32_t lfsr=0xace1u; auto rnd=[&]{ lfsr^=lfsr<<13; lfsr^=lfsr>>17; lfsr^=lfsr<<5; return lfsr; };
    uint64_t oki_change=0, oki_max=0, oki_windows=0, oki_late=0; bool oki_fresh=false;
    uint64_t main_done=0, cop_done=0, main_start=0, cop_start=0, main_max=0, cop_max=0, urgent_clocks=0;

    // ideal responder
    bool pending=false, prev_req=false; uint64_t due=0; uint32_t addr=0; uint8_t kind=0;
    bool spending=false, sprev=false; uint64_t sdue=0; uint32_t saddr=0;

    std::vector<uint8_t> image(320*256*3);
    const uint64_t frame=512ull*282*12, warm=100000;
    const uint64_t total=warm+uint64_t(frames)*frame;
    int frame_no=0; uint64_t overruns_after_warm_base=0, base_set=0;
    uint64_t spr_over_base=0, tile_over_base=0;
    std::ofstream lines(out+"-lines.csv"); lines<<"cycle,y,cycles,overrun\n";
    uint32_t max_measured=0; uint64_t measured_lines=0, overrun_lines=0;

    for(uint64_t c=0;c<total;++c){
        t.reset = c<60;
        // drive model DQ for this posedge
        uint16_t dq=0xdead;
        while(!beats.empty() && beats.front().at<c) beats.pop_front();
        if(!beats.empty() && beats.front().at==c) dq=beats.front().v;
        t.model_dq=dq;
        // ideal responder
        t.ideal_valid=0;
        if(ideal && !t.reset && t.rom_request && !prev_req){
            if(pending) throw std::runtime_error("overlapping ideal request");
            pending=true; due=c+3; addr=t.rom_address; kind=t.rom_kind;
        }
        prev_req=t.rom_request;
        if(ideal && pending && c==due){
            const auto& b= kind==4?chars:(kind==3?sprites:tiles);
            uint32_t f=b[addr]|(b[addr+1]<<8), s=b[addr+2]|(b[addr+3]<<8);
            t.ideal_data = kind==3 ? (f|(s<<16)) : ((f<<16)|s);
            t.ideal_valid=1; pending=false;
        }
        t.ideal_spr_valid=0;
        if(ideal && !t.reset && t.sprite_request && !sprev){
            if(spending) throw std::runtime_error("overlapping ideal sprite request");
            spending=true; sdue=c+3; saddr=t.sprite_address;
        }
        sprev=t.sprite_request;
        if(ideal && spending && (c==sdue || c==sdue+2)){
            uint32_t o=saddr+(c==sdue?0:4);
            t.ideal_spr_data=sprites[o]|(sprites[o+1]<<8)|(sprites[o+2]<<16)|(uint32_t(sprites[o+3])<<24);
            t.ideal_spr_half=(c!=sdue); t.ideal_spr_valid=t.sprite_request;
            if(c==sdue+2) spending=false;
        }
        // stressor (V30-style: hold req until valid, drop one clock, next miss)
        if(c>warm/2 && stress>=1){
            if(t.main_req && t.main_valid){ t.main_req=0; if(c>=warm+frame){ ++main_done; if(c-main_start>main_max) main_max=c-main_start; } }
            else if(!t.main_req){ t.main_address=(rnd()&0x0ffffe); t.main_req=1; main_start=c; }
        }
        if(c>warm/2 && stress>=2){
            if(t.cop_req && t.cop_valid){ t.cop_req=0; if(c>=warm+frame){ ++cop_done; if(c-cop_start>cop_max) cop_max=c-cop_start; } }
            else if(!t.cop_req){ t.cop_address=(rnd()&0x0ffffe); t.cop_req=1; cop_start=c; }
        }
        // JT6295 ROM port pattern (96 MHz, OKI 1.0227 MHz, ss=1): eight 375.5-clock
        // slots per channel; slots 1-2 present the ADPCM address and the byte on
        // rom_data at the end of slot 2 is decoded without any rom_ok check, the
        // other six present the control (phrase table) address.
        {
            uint64_t q=(c*2)/751, slot=q%8, ch=(q/8)%4;
            uint32_t want = (slot==1||slot==2) ? ((0x10000u*ch + uint32_t(q/32))&0x3ffff) : 0x0003fu;
            if(t.oki_address!=want){ t.oki_address=want; oki_change=c; oki_fresh=false; }
            if(!oki_fresh && c>oki_change && t.oki_valid_o){ oki_fresh=true; if(c>=warm+frame && c-oki_change>oki_max) oki_max=c-oki_change; }
            bool end2 = slot==2 && ((c+1)*2)/751!=q;
            if(end2 && c>=warm+frame){ ++oki_windows; if(!oki_fresh) ++oki_late; }
        }
        t.clk=0; t.eval();
        t.clk=1; t.eval();
        // decode command now on pins (registered at this edge)
        unsigned cmd=t.command, ba=t.bank, A=t.pin_address;
        int64_t ci=int64_t(c);
        switch(cmd){
        case 0b011: // ACT
            if(open_[ba]) violate(c,"ACT to open bank");
            if(ci-last_act[ba]<6) violate(c,"tRC");
            if(ci-close_at[ba]<2) violate(c,"tRP");
            if(ci-last_ref<7) violate(c,"tRFC");
            open_[ba]=true; open_row[ba]=A; last_act[ba]=ci; ++acts; break;
        case 0b101: case 0b100: { // READ / WRITE
            if(!open_[ba]) { violate(c,"RD/WR to closed bank"); break; }
            if(ci-last_act[ba]<2) violate(c,"tRCD");
            uint32_t col=A&0x1ff;
            uint32_t base=(ba<<22)|(open_row[ba]<<9);
            if(cmd==0b101){
                for(int i=0;i<bl;++i){
                    uint32_t cc=(col&~uint32_t(bl-1))|((col+i)&(bl-1));
                    beats.push_back({c+cl+1+i, mem[base|cc]});
                }
                ++sd_reads;
                if(A&0x400){ open_[ba]=false; close_at[ba]=ci+bl; }
            } else {
                uint16_t m=(A>>11)&3; uint16_t &w=mem[base|col]; uint16_t d=t.pin_write_data;
                if(!(m&1)) w=(w&0xff00)|(d&0x00ff);
                if(!(m&2)) w=(w&0x00ff)|(d&0xff00);
                ++sd_writes;
                if(A&0x400){ open_[ba]=false; close_at[ba]=ci+1+2; }
            }
            break; }
        case 0b010: // PRECHARGE
            if(A&0x400){ for(int b=0;b<4;++b){ if(open_[b]){open_[b]=false; close_at[b]=ci;} } }
            else if(open_[ba]){ open_[ba]=false; close_at[ba]=ci; }
            break;
        case 0b001: // REFRESH
            for(int b=0;b<4;++b) if(open_[b]) violate(c,"REF with open bank");
            last_ref=ci; break;
        case 0b000: // LOAD MODE
            bl=1<<(A&7); if((A&7)==7) bl=512; cl=(A>>4)&7; break;
        default: break;
        }
        if(c>=warm+frame){   // ignore the first rendered frame (pipeline/warmup)
            if(!base_set){ spr_over_base=t.spr_overruns; tile_over_base=t.tile_overruns; base_set=1; }
            if(t.video_urgent_o) ++urgent_clocks;
            if(t.line_event){
                ++measured_lines; if(t.line_overrun) ++overrun_lines;
                if(t.line_cycles>max_measured) max_measured=t.line_cycles;
                lines<<c<<','<<unsigned(t.line_y)<<','<<t.line_cycles<<','<<int(t.line_overrun)<<'\n';
            }
        }
        if(!t.reset && t.pixel_strobe && t.pixel_display){
            if(t.pixel_x>=320||t.pixel_y>=256) throw std::runtime_error("bad pixel coordinate");
            size_t i=(t.pixel_y*320+t.pixel_x)*3; image[i]=t.r; image[i+1]=t.g; image[i+2]=t.b;
        }
    }
    t.final();
    std::ofstream f(out+".ppm",std::ios::binary);
    f<<"P6\n320 256\n255\n"; f.write(reinterpret_cast<char*>(image.data()),image.size());
    const double fr=double(frames-1);
    std::printf("{\"ideal\":%d,\"map\":%d,\"stress\":%d,\"frames_measured\":%d,"
        "\"sprite_lines\":%llu,\"sprite_overrun_lines\":%llu,\"sprite_max_line_cycles\":%u,"
        "\"line_budget\":6144,\"tile_overruns\":%llu,\"sdram_reads\":%llu,\"sdram_writes\":%llu,"
        "\"cpu_fetches_per_frame\":%.0f,\"cop_fetches_per_frame\":%.0f,"
        "\"cpu_max_latency\":%llu,\"cop_max_latency\":%llu,\"urgent_clocks_per_frame\":%.0f,"
        "\"oki_max_latency\":%llu,\"oki_windows\":%llu,\"oki_late_bytes\":%llu,"
        "\"sdram_violations\":%llu,\"first_violation\":\"%s\"}\n",
        ideal,map,stress,frames-1,(unsigned long long)measured_lines,(unsigned long long)overrun_lines,max_measured,
        (unsigned long long)(t.tile_overruns-tile_over_base),(unsigned long long)sd_reads,(unsigned long long)sd_writes,
        main_done/fr, cop_done/fr,
        (unsigned long long)main_max,(unsigned long long)cop_max, urgent_clocks/fr,
        (unsigned long long)oki_max,(unsigned long long)oki_windows,(unsigned long long)oki_late,
        (unsigned long long)violations, first_violation.c_str());
    return violations?3:0;
}
