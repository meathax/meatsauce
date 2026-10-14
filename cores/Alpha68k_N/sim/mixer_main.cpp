#include "Valpha68kn_mixer.h"
#include "verilated.h"
#include <cmath>
#include <iostream>
#include <stdexcept>

int main(int argc,char** argv) try {
    Verilated::commandArgs(argc,argv);
    Valpha68kn_mixer top;
    top.clk=0;top.reset=1;top.profile=0;top.dac=128;top.fm=0;
    top.ym_psg=0;top.ay1_psg=0;top.ay2_psg=0;
    auto tick=[&]() {top.clk=0;top.eval();top.clk=1;top.eval();};
    for(unsigned i=0;i<16;i++) tick();
    top.reset=0;
    struct Vector {unsigned profile;int fm;unsigned ym,ay1,ay2,dac;};
    const Vector vectors[]={{0,0,0,0,0,128},{0,32767,765,765,765,255},
        {0,-32768,0,0,0,0},{2,12000,120,222,333,196},
        {1,-12000,120,222,333,60},{0,0,256,127,380,128},
        {0,0,765,0,0,128}};
    unsigned pulses=0,last=0;
    for(const auto& v:vectors) {
        top.profile=v.profile;top.fm=v.fm;top.ym_psg=v.ym;top.ay1_psg=v.ay1;
        top.ay2_psg=v.ay2;top.dac=v.dac;
        // Independent floating MAME normalization/routes; no RTL Q16 constants.
        auto psg=[](unsigned sum) {return 32768.0*(sum/255.0-0.75)*0.5;};
        // YMFM's SSG table is positive, with maximum 16382 per channel.
        // Standalone AY still uses the legacy biased normalization above.
        double value=v.fm*0.30+(v.ym/255.0)*16382.0*0.30+psg(v.ay1)*0.30+
            psg(v.ay2)*(v.profile==2 ? 0.45 : 0.60)+(int(v.dac)-128)*128.0;
        int expected=std::min(32767,std::max(-32768,int(std::floor(value))));
        const auto before=top.clipped_samples;
        unsigned count=0;
        for(unsigned i=0;i<5000;i++) {
            tick();last++;
            if(!top.sample_ce) continue;
            if(last!=1000) throw std::runtime_error("audio sample cadence differs from 48 kHz");
            last=0;pulses++;count++;
            int got=int16_t(top.sample);
            if(std::abs(got-expected)>1)
                throw std::runtime_error("nominal route/width mismatch got="+std::to_string(got)+
                    " expected="+std::to_string(expected));
        }
        unsigned clips=(value>32767 || value< -32768) ? count : 0;
        if(top.clipped_samples-before!=clips) throw std::runtime_error("saturation counter mismatch");
        std::cout<<"profile="<<v.profile<<" ideal_pcm="<<expected<<" actual_pcm="<<int16_t(top.sample)
            <<" samples="<<count<<" clips="<<clips<<'\n';
    }
    top.reset=1;tick();
    if(top.sample_ce || top.sample || top.clipped_samples) throw std::runtime_error("mixer reset failed");
    std::cout<<"sample_rate=48000 samples="<<pulses<<" reset=pass scope=nominal_mixer_math_only\n";
    top.final();return 0;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
