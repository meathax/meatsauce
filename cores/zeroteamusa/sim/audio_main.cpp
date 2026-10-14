#include "VZeroTeam_audio.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <vector>
#include <map>
#include <stdexcept>
#include <cstdint>

static std::vector<uint8_t> load(const char* path) {
    std::ifstream f(path,std::ios::binary);
    if(!f)throw std::runtime_error("Missing sound region");
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),{});
}
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    uint64_t cycles=argc>1?std::stoull(argv[1]):96000000;
    auto rom=load("roms/regions/audiocpu.bin"),oki=load("roms/regions/oki.bin");
    if(rom.size()!=0x20000 || oki.size()!=0x100000)throw std::runtime_error("Wrong sound region size");
    VZeroTeam_audio top;
    uint64_t reset_enabled_clocks=0;
    auto tick=[&](){top.clk=0;top.eval();if(top.reset&&top.debug_cen)++reset_enabled_clocks;top.clk=1;top.eval();};
    top.reset=1;top.pause=0;top.snd_cs=top.snd_wr=top.snd_rd=0;
    top.coin_input=255;top.ioctl_download=1;top.ioctl_wr=1;
    // MAME raw-ROM reconstruction: fixed first half, ROM_CONTINUE at 0x10000.
    for(uint32_t a=0;a<0x10000;a+=2) {
        uint32_t source=a<0x8000?a:a+0x8000;
        top.ioctl_addr=0xa0000+a;top.ioctl_dout=rom[source]|(rom[source+1]<<8);tick();
    }
    top.ioctl_download=top.ioctl_wr=0;for(int i=0;i<60;++i)tick();top.reset=0;
    uint64_t fetches=0,writes=0,iacks=0,ymwrites=0,okiwrites=0,coinreads=0,samples=0,nonzero=0,cen=0;
    uint64_t idle_nonzero_samples=0;
    bool pf=false,pw=false,pi=false,pr=false;
    std::map<uint16_t,uint64_t> regs;
    std::ofstream trace("sim/results/audio-reg-trace.csv");trace<<"cycle,address,data\n";
    std::ofstream pcm("sim/results/audio-isolated.pcm",std::ios::binary);
    uint64_t traced=0;
    for(uint64_t c=0;c<cycles;++c) {
        top.coin_input=c>=24000000 && c<28800000?254:255;
        top.oki_rom_data=oki.at(top.oki_rom_addr);top.oki_rom_ok=1;
        top.clk=0;top.eval();
        if(top.debug_fetch&&!pf)++fetches;
        if(top.debug_iack&&!pi)++iacks;
        if(top.debug_read&&!pr&&top.debug_address==0x4013)++coinreads;
        if(top.debug_write&&!pw) {
            ++writes;
            if(top.debug_address>=0x4000) {
                ++regs[top.debug_address];
                if(traced++<2000)trace<<c<<","<<top.debug_address<<","<<int(top.debug_data)<<"\n";
            }
            ymwrites+=top.debug_address==0x4009;okiwrites+=top.debug_address==0x6000;
        }
        cen+=top.debug_cen;
        pf=top.debug_fetch;pw=top.debug_write;pi=top.debug_iack;pr=top.debug_read;
        top.clk=1;top.eval();
        if(top.audio_sample) {
            ++samples;nonzero+=top.audio_l!=0;
            if(c<24000000)idle_nonzero_samples+=top.audio_l!=0;
            uint8_t b[2]={uint8_t(top.audio_l),uint8_t(top.audio_l>>8)};
            pcm.write(reinterpret_cast<char*>(b),2);
        }
    }
    std::ofstream r("sim/results/audio-isolated.json");
    r<<"{\n\"cycles\":"<<cycles<<",\"z80_enables\":"<<cen<<",\"fetches\":"<<fetches
     <<",\"writes\":"<<writes<<",\"interrupt_acknowledgements\":"<<iacks
     <<",\"fm_data_writes\":"<<ymwrites<<",\"oki_writes\":"<<okiwrites
     <<",\"coin_reads\":"<<coinreads<<",\"samples\":"<<samples<<",\"nonzero_samples\":"<<nonzero
     <<",\"last_address\":"<<top.debug_address<<",\"register_writes\":{";
    bool first=true;for(auto[a,n]:regs){if(!first)r<<",";first=false;r<<"\""<<a<<"\":"<<n;}r<<"},\"reset_enabled_clocks\":"<<reset_enabled_clocks<<",\"idle_nonzero_samples\":"<<idle_nonzero_samples<<"}\n";
    std::cout<<"Z80 fetches="<<fetches<<" IRQ="<<iacks<<" FMwrites="<<ymwrites<<" coins="<<coinreads<<" samples="<<samples<<" nonzero="<<nonzero<<"\n";
    top.final();return fetches>100&&ymwrites>100&&coinreads>0&&reset_enabled_clocks>=6&&idle_nonzero_samples==0?0:1;
}
