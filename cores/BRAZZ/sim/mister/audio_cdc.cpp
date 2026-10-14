// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer audio capture fidelity: cs_audio_interp at clk_sys 85.90908 MHz, sampled by an exact
// model of sys/audio_out.sv's clk_audio (24.576 MHz) crossing:
//     cl1 <= core_l; cl2 <= cl1; if (cl2 == cl1) cl <= cl2;
// The SPU stream is a band-limited 44.19 kHz test signal at several levels. The bench reports
// how faithfully the framework's captured value `cl` follows what the core drives (SNR of cl
// against the core output delayed by the 2-cycle crossing) and the longest interval during
// which `cl` stays frozen although the core output has changed.
#include "Vcs_audio_interp.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <deque>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    const double f_sys=85909080.0,f_aud=24576000.0;const int period=1944;
    const double min_snr=argc>1?std::atof(argv[1]):-1e9; // optional pass threshold (dB)
    const double levels[]={0.05,0.25,0.5,0.9};
    bool pass=true;
    for(double level:levels){
        Vcs_audio_interp d;d.mute=1;d.sample_valid=0;d.in_left=0;d.in_right=0;
        auto step=[&](){d.clk=0;d.eval();d.clk=1;d.eval();};
        for(int i=0;i<4;++i)step();
        d.mute=0;
        const int samples=4419; // 100 ms
        double t_aud=0;const double dt_aud=1.0/f_aud,dt_sys=1.0/f_sys;double t=0;
        uint16_t cl1=0,cl2=0,cl=0;std::deque<int16_t> hist; // core output at each clk_audio edge
        double sig=0,err=0;uint64_t frozen=0,max_frozen=0,edges=0;int16_t last_seen=0;
        for(int s=0;s<samples;++s){
            const double x=s/44192.0;
            const double v=level*32767.0*(0.6*std::sin(2*M_PI*1000*x)+0.4*std::sin(2*M_PI*6300*x));
            for(int c=0;c<period;++c){
                d.sample_valid=(c==0);d.in_left=int16_t(std::lround(v));d.in_right=int16_t(-std::lround(v));
                step();t+=dt_sys;
                while(t_aud<=t){ // clk_audio edge: framework samples the asynchronous core value
                    t_aud+=dt_aud;++edges;
                    const uint16_t core=uint16_t(d.out_left);
                    if(cl2==cl1)cl=cl2;cl2=cl1;cl1=core;
                    hist.push_back(int16_t(core));if(hist.size()>3)hist.pop_front();
                    if(s>8&&hist.size()==3){
                        const double ref=hist.front(),got=int16_t(cl);
                        sig+=ref*ref;err+=(got-ref)*(got-ref);
                        if(int16_t(cl)!=int16_t(core)&&int16_t(cl)==last_seen){if(++frozen>max_frozen)max_frozen=frozen;}else frozen=0;
                    }
                    last_seen=int16_t(cl);
                }
            }
        }
        const double snr=err>0?10*std::log10(sig/err):200.0;
        std::printf("level %.2f FS: capture SNR %.1f dB, longest stale cl %llu clk_audio cycles (%.1f us)\n",
            level,snr,(unsigned long long)max_frozen,max_frozen*1e6/f_aud);
        if(snr<min_snr)pass=false;
    }
    if(min_snr>-1e9){std::printf(pass?"PASS capture SNR >= %.1f dB at every level\n":"FAIL capture SNR below %.1f dB\n",min_snr);return pass?0:1;}
    return 0;
}
