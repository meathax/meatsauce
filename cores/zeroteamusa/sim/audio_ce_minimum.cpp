// Production sound oscillator spacing proof, not audio/gameplay acceptance.
#include "VZeroTeam_audio.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    VZeroTeam_audio top;
    top.ioctl_download=top.ioctl_wr=top.snd_cs=top.snd_wr=top.snd_rd=0;
    top.coin_input=255;top.oki_rom_ok=1;top.oki_rom_data=0;
    uint64_t previous=0,pulses=0,minimum=UINT64_MAX,maximum=0;
    for(uint64_t cycle=0;cycle<200000;++cycle) {
        top.reset=cycle<2000 || cycle==75000 || cycle==140000;
        top.pause=cycle>=6000 && cycle%337>=310;
        top.clk=0;top.eval();
        if(top.debug_cen) {
            if(pulses) {
                const auto gap=cycle-previous;
                if(gap<26)throw std::runtime_error("Sound CPU CE gap below 26");
                minimum=std::min(minimum,gap);maximum=std::max(maximum,gap);
            }
            previous=cycle;++pulses;
        }
        top.clk=1;top.eval();
    }
    if(pulses<1000 || minimum!=26)throw std::runtime_error("Insufficient sound CE coverage");
    std::ofstream out("sim/results/timing/audio-ce-minimum.json");
    out<<"{\"scope\":\"Production oscillator spacing, not sound/gameplay acceptance\","
       <<"\"cycles\":200000,\"pulses\":"<<pulses<<",\"minimum_gap\":"<<minimum
       <<",\"maximum_gap\":"<<maximum<<",\"pause_and_reset_exercised\":true}\n";
    std::cout<<"Sound CE PASS: minimum "<<minimum<<", maximum "<<maximum
             <<", pulses "<<pulses<<"\n";
    top.final();
}
