// Isolated-sound run that records both the native-rate mix and the 48 kHz output.
#include "VZeroTeam_audio.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <vector>
#include <cstdint>
#include <stdexcept>
static std::vector<uint8_t> load(const char* path) {
    std::ifstream f(path,std::ios::binary);
    if(!f)throw std::runtime_error("Missing sound region");
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),{});
}
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    uint64_t cycles=argc>1?std::stoull(argv[1]):96000000;
    auto rom=load("roms/regions/audiocpu.bin"),oki=load("roms/regions/oki.bin");
    VZeroTeam_audio top;
    auto tick=[&](){top.clk=0;top.eval();top.clk=1;top.eval();};
    top.reset=1;top.pause=0;top.snd_cs=top.snd_wr=top.snd_rd=0;
    top.coin_input=255;top.ioctl_download=1;top.ioctl_wr=1;
    for(uint32_t a=0;a<0x10000;a+=2) {
        uint32_t source=a<0x8000?a:a+0x8000;
        top.ioctl_addr=0xa0000+a;top.ioctl_dout=rom[source]|(rom[source+1]<<8);tick();
    }
    top.ioctl_download=top.ioctl_wr=0;for(int i=0;i<60;++i)tick();top.reset=0;
    std::ofstream p49("sim/results/audio48-native.pcm",std::ios::binary),p48("sim/results/audio48-out.pcm",std::ios::binary);
    uint64_t n49=0,n48=0,sat=0;
    for(uint64_t c=0;c<cycles;++c) {
        top.coin_input=c>=24000000 && c<28800000?254:255;
        top.oki_rom_data=oki.at(top.oki_rom_addr);top.oki_rom_ok=1;
        top.clk=0;top.eval();top.clk=1;top.eval();
        if(top.audio_sample){++n49;int16_t v=top.audio_l;p49.write(reinterpret_cast<char*>(&v),2);}
        if(top.out_sample){++n48;int16_t v=top.out_l;sat+=(v==32767||v==-32768);p48.write(reinterpret_cast<char*>(&v),2);}
    }
    std::cout<<"native="<<n49<<" out48="<<n48<<" saturated="<<sat<<" l!=r:"<<(top.out_l!=top.out_r)<<"\n";
    top.final();return 0;
}
