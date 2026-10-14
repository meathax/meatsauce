// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "sdram_model.hpp"
#include <algorithm>
#include <array>
#include <cstdlib>
#include <cmath>
#include <deque>
#include <fstream>
#include <sstream>
#include <string>
struct SdramReturnBeat {double at;uint16_t data;};
struct SdramPinProfile {
    std::string name;double clock_delta,chip_access,input_pad,board;
    static SdramPinProfile selected(){
        const char* file=std::getenv("CS_SDRAM_TIMING_PROFILE");
        const char* name=std::getenv("CS_SDRAM_TIMING_PROFILE_NAME");
        if(!file||!name)throw std::runtime_error("timed boot requires explicit fitted pin profile and name");
        std::ifstream input(file);if(!input)throw std::runtime_error("missing fitted pin profile");
        std::string line;SdramPinProfile selected{};unsigned count=0,matches=0;
        while(std::getline(input,line)){
            if(line.empty()||line[0]=='#')continue;
            std::istringstream row(line);SdramPinProfile p;
            if(!(row>>p.name>>p.clock_delta>>p.chip_access>>p.input_pad>>p.board)||
                p.clock_delta<=-5.82||p.clock_delta>=5.82||p.chip_access<2.7||p.chip_access>6.5||p.input_pad<0||p.board<0||p.board>1)
                throw std::runtime_error("invalid fitted pin profile");
            ++count;if(p.name==name){selected=p;++matches;}
        }
        if(count!=8||matches!=1)throw std::runtime_error("fitted profile must contain eight unique selected corner endpoints");
        return selected;
    }
};
// The same chronological pin model serves the backend qualification and full
// board cold boot. RAM is changed only by real pin commands; DQ returns include
// chip access, declared board flight and fitted pad-to-capture delay.
// HasCapturePort enables the historical prototype input-clock experiment only.
template<bool HasCapturePort=false> struct TimedSdramPort {
    SdramModel& memory;SdramPinProfile profile;bool registered_io;double capture_phase=-2.4;
    static constexpr double period=11.64021164021164;
    struct Pins{bool cke=0,cs_n=1,ras_n=1,cas_n=1,we_n=1;unsigned ba=0,address=0,dqm=3;uint16_t data_out=0;bool oe=0;};
    Pins previous_pins;
    uint64_t cycles=0;uint16_t dq=0xdead;std::deque<SdramReturnBeat> returns;
    TimedSdramPort(SdramModel& m,SdramPinProfile p,bool registered):memory(m),profile(p),registered_io(registered){}
    template<class V> void advance(V& d,double now){
        while(!returns.empty()&&returns.front().at<=now){dq=returns.front().data;returns.pop_front();}
        d.sdram_data_in=dq;
    }
    template<class V> void prepare(V& d){advance(d,cycles*period);d.eval();}
    template<class V> void finish(V& d){
        double now=cycles*period,phase=(registered_io?0:period/2)+profile.clock_delta;
        if(phase<0)phase+=period;
        Pins current{bool(d.sdram_cke),bool(d.sdram_cs_n),bool(d.sdram_ras_n),bool(d.sdram_cas_n),bool(d.sdram_we_n),
            unsigned(d.sdram_ba),unsigned(d.sdram_address),unsigned(d.sdram_dqm),uint16_t(d.sdram_data_out),bool(d.sdram_data_oe)};
        // Single-clock design: pins launch on the master-clock rising edge; the SDRAM edge that
        // samples them sits clock_delta+shift (>= the pin arrival) after that edge, so it may
        // fall in the next core cycle. DQ is registered only at core edges (prepare()), so the
        // chronological DQ queue must not advance to a future SDRAM-edge time.
        const Pins used=current;
        auto event=[&](double at,unsigned kind){
            if(!(HasCapturePort&&kind==2))advance(d,at);
            if(kind==1)d.clk=0;
            else if(kind==2){
                bool read=used.cke&&!used.cs_n&&used.ras_n&&!used.cas_n&&used.we_n;
                unsigned bank=used.ba,column=used.address;
                memory.tick(used.cke,used.cs_n,used.ras_n,used.cas_n,used.we_n,
                    bank,column,used.dqm,used.data_out,used.oe);
                if(read){double access=profile.chip_access+profile.input_pad+profile.board;
                    returns.push_back({at+period+access,memory.words[memory.index(bank,column)]});
                    returns.push_back({at+2*period+access,memory.words[memory.index(bank,(column&~1u)|((column+1)&1u))]});}
            }else if constexpr(HasCapturePort)d.sdram_capture_clk=(kind==3);
            d.eval();
        };
        struct Event{double at;unsigned kind;};
        if constexpr(HasCapturePort){
            // Single-clock capture: DQ is registered on the core clock. capture_phase is
            // the PLL phase shift of the forwarded SDRAM_CLK (it moves the SDRAM edge, not
            // a capture register), so the SDRAM edge sits at clock_delta+shift (mod period).
            double shifted=profile.clock_delta+capture_phase;
            if(shifted<period/2){event(now+shifted,2);event(now+period/2,1);}
            else{event(now+period/2,1);event(now+shifted,2);}
        }else{
            if(phase<period/2){event(now+phase,2);event(now+period/2,1);}
            else{event(now+period/2,1);event(now+phase,2);}
        }
        previous_pins=current;
        ++cycles;
    }
};
