// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_audio_interp.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void ck(bool b,const char*s){++checks;if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Vcs_audio_interp d;d.mute=0;d.sample_valid=0;d.in_left=0;d.in_right=0;
        auto step=[&](){d.clk=0;d.eval();d.clk=1;d.eval();};
        const int samples[]={0,10000,-10000,20000,20000,-32768,32767,0,1000};
        for(unsigned s=0;s<9;++s){
            for(unsigned c=0;c<1944;++c){
                d.sample_valid=(c==0);d.in_left=samples[s];d.in_right=-samples[s]/2;step();
                // Held for the whole period: sys/audio_out.sv only accepts values that are
                // stable across two clk_audio samples.
                ck(int16_t(d.out_left)==samples[s]&&int16_t(d.out_right)==-samples[s]/2,"sample held for the whole period");
                d.in_left=12345;d.in_right=-12345; // ignored without sample_valid
            }
        }
        d.mute=1;step();ck(int16_t(d.out_left)==0&&int16_t(d.out_right)==0,"mute");
        std::cout<<"PASS audio interpolator: "<<checks<<" checks; each sample held stable for its 1944-clock period, mute\n";
        return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}
}
