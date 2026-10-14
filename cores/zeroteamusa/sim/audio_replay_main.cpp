// Replay observed main-bus writes and physical coins through production sound RTL.
// The host supplies ROM bytes and records outputs; all sound CPU/chip state is RTL.
#include "VZeroTeam_audio.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <vector>

struct Event { uint64_t cycle; std::string kind; uint32_t address,data,mask; };
static std::vector<uint8_t> load(const char* path) {
    std::ifstream f(path,std::ios::binary);
    if(!f)throw std::runtime_error("Missing staged sound ROM");
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),{});
}
static int replay_main(int argc,char**argv) {
    if(argc!=4)throw std::runtime_error("Expected observed stimulus CSV, output directory and cycle limit");
    Verilated::commandArgs(argc,argv);
    std::ifstream f(argv[1]);if(!f)throw std::runtime_error("Missing sound stimulus");
    std::string line;std::getline(f,line);
    if(!line.empty()&&line.back()=='\r')line.pop_back();
    if(line!="cycle,kind,address,data,mask")throw std::runtime_error("Bad sound stimulus header");
    std::vector<Event> events;
    while(std::getline(f,line)) {
        std::replace(line.begin(),line.end(),',',' ');std::istringstream row(line);Event e{};
        if(!(row>>e.cycle>>e.kind>>e.address>>e.data>>e.mask))throw std::runtime_error("Bad sound stimulus row");
        if(e.kind!="write"&&e.kind!="coin")throw std::runtime_error("Unknown stimulus kind");
        events.push_back(e);
    }
    if(events.empty())throw std::runtime_error("Empty sound stimulus");
    std::stable_sort(events.begin(),events.end(),[](const Event&a,const Event&b){return a.cycle<b.cycle;});
    const uint64_t limit=std::stoull(argv[3]);
    if(limit<=events.back().cycle)
        throw std::runtime_error("Cycle limit ends before the full stimulus: last event at "
            +std::to_string(events.back().cycle)+", requested limit "+std::to_string(limit)
            +". Choose a longer limit before running the model.");
    const std::filesystem::path out(argv[2]);std::filesystem::create_directories(out);
    auto rom=load("roms/regions/audiocpu.bin"),oki=load("roms/regions/oki.bin");
    if(rom.size()!=0x20000||oki.size()!=0x100000)throw std::runtime_error("Wrong sound region size");
    VZeroTeam_audio top;
    uint64_t reset_enables=0;
    auto tick=[&](){top.clk=0;top.eval();if(top.reset&&top.debug_cen)++reset_enables;top.clk=1;top.eval();};
    top.reset=1;top.pause=0;top.coin_input=255;
    top.snd_cs=top.snd_wr=top.snd_rd=0;top.snd_addr=top.snd_wdata=0;
    top.oki_rom_ok=0;top.oki_rom_data=255;top.ioctl_download=top.ioctl_wr=1;
    for(uint32_t a=0;a<0x10000;a+=2) {
        uint32_t source=a<0x8000?a:a+0x8000;
        top.ioctl_addr=0xa0000+a;top.ioctl_dout=rom[source]|(rom[source+1]<<8);tick();
    }
    top.ioctl_download=top.ioctl_wr=0;for(unsigned i=0;i<60;++i)tick();top.reset=0;
    uint64_t fetches=0,iacks=0,fm_data=0,oki_writes=0,samples=0,nonzero=0;
    uint64_t first_nonzero=UINT64_MAX,main_writes=0,coin_events=0,bank_writes=0,stereo_diffs=0,serialized_writes=0;
    int minimum=32767,maximum=-32768;size_t next=0;bool pf=false,pi=false,pw=false;
    uint8_t fm_register=0;
    std::map<unsigned,uint64_t> fm_keys;
    std::ofstream trace(out/"sound-events.csv");trace<<"cycle,address,data\n";
    std::ofstream pcm(out/"audio.pcm",std::ios::binary);
    for(uint64_t c=0;c<limit;++c) {
        top.snd_cs=top.snd_wr=0;
        bool written=false;
        while(next<events.size()&&events[next].cycle<=c) {
            const auto&e=events[next];
            if(e.kind=="coin") {top.coin_input=e.data;++coin_events;++next;continue;}
            if(!(e.mask&255)){++next;continue;}
            if(e.address<0x700||e.address>=0x720)throw std::runtime_error("Observed sound address outside implemented latch window");
            if(written){++serialized_writes;break;}
            // main_top encodes cpu_addr[4:2], matching MAME offset >> 1.
            top.snd_cs=top.snd_wr=1;top.snd_addr=(e.address-0x700)/4;top.snd_wdata=e.data;
            ++main_writes;++next;written=true;
        }
        top.oki_rom_data=oki.at(top.oki_rom_addr);top.oki_rom_ok=1;
        top.clk=0;top.eval();
        if(top.debug_fetch&&!pf)++fetches;
        if(top.debug_iack&&!pi)++iacks;
        if(top.debug_write&&!pw) {
            const auto a=top.debug_address;const auto d=top.debug_data;
            if(a>=0x4000)trace<<c<<","<<a<<","<<int(d)<<"\n";
            if(a==0x4008)fm_register=d;
            if(a==0x4009){++fm_data;if(fm_register>=0xb0&&fm_register<=0xb8&&(d&32))++fm_keys[fm_register];}
            oki_writes+=a==0x6000;bank_writes+=a==0x4007;
        }
        pf=top.debug_fetch;pi=top.debug_iack;pw=top.debug_write;
        top.clk=1;top.eval();
        if(top.audio_sample) {
            ++samples;const int16_t sample=top.audio_l;
            if(sample){++nonzero;if(first_nonzero==UINT64_MAX)first_nonzero=c;}
            stereo_diffs+=top.audio_l!=top.audio_r;
            minimum=std::min(minimum,int(sample));maximum=std::max(maximum,int(sample));
            uint8_t b[2]={uint8_t(sample),uint8_t(sample>>8)};pcm.write(reinterpret_cast<char*>(b),2);
        }
        if(c&&c%104000000==0)
            std::cout<<"Sound replay cycle="<<c<<" mainWrites="<<main_writes<<" FM="<<fm_data<<" OKI="<<oki_writes<<" samples="<<samples<<" nonzero="<<nonzero<<std::endl;
    }
    std::ofstream report(out/"result.json");
    report<<"{\"scope\":\"Observed-command production sound replay, not live CPU gameplay proof\",\"cycles\":"<<limit
      <<",\"events\":"<<events.size()<<",\"events_consumed\":"<<next<<",\"main_writes\":"<<main_writes
      <<",\"coin_events\":"<<coin_events<<",\"serialized_same_cycle_writes\":"<<serialized_writes
      <<",\"reset_enabled_clocks\":"<<reset_enables<<",\"fetches\":"<<fetches<<",\"interrupt_acknowledgements\":"<<iacks
      <<",\"fm_data_writes\":"<<fm_data<<",\"oki_writes\":"<<oki_writes<<",\"bank_writes\":"<<bank_writes
      <<",\"samples\":"<<samples<<",\"nonzero_samples\":"<<nonzero<<",\"first_nonzero_cycle\":"<<first_nonzero
      <<",\"minimum\":"<<minimum<<",\"maximum\":"<<maximum<<",\"mono_differences\":"<<stereo_diffs<<",\"fm_key_ons\":{";
    bool first=true;for(auto [reg,count]:fm_keys){if(!first)report<<",";first=false;report<<"\""<<reg<<"\":"<<count;}
    report<<"}}\n";
    std::cout<<"Completed sound replay events="<<next<<"/"<<events.size()<<" FM="<<fm_data<<" OKI="<<oki_writes<<" nonzero="<<nonzero<<std::endl;
    top.final();return reset_enables>=6&&next==events.size()&&fetches>100&&fm_data>100&&stereo_diffs==0?0:1;
}

int main(int argc,char**argv) {
    try { return replay_main(argc,argv); }
    catch(const std::exception& e) { std::cerr<<e.what()<<std::endl;return 1; }
}
