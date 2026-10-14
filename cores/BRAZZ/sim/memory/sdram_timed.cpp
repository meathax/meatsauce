// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_sdram_backend.h"
#include "verilated.h"
#include "sdram_timed_port.hpp"
#include <deque>
#include <iomanip>
#include <fstream>
#include <sstream>
#include <string>
#include <cstdlib>
#include <algorithm>
#include <unordered_map>
#include <iostream>
#include <stdexcept>

double sc_time_stamp(){return 0;}
// CL2 data starts after T1+tAC, and must be available by T2. The functional
// model's T2 edge update is insufficient to qualify the FPGA sampling window.
// These points combine the saved fit's per-corner clock and input-pad delays
// with allowed ISSI L chip returns and provisional 0..0.5 ns board flights.
struct Profile {std::string name;double clock_delta,chip_access,input_pad,board;};
static const Profile profiles[]={
    {"slow_hot_latest",4.646,6.5,2.445,1.0},
    {"slow_cold_latest",4.180,6.5,2.513,1.0},
    {"fast_hot_latest",2.743,6.5,1.505,1.0},
    {"fast_cold_latest",2.371,6.5,1.482,1.0},
    {"slow_hot_earliest",2.105,2.7,1.865,0.0},
    {"slow_cold_earliest",1.687,2.7,1.871,0.0},
    {"fast_hot_earliest",1.621,2.7,0.727,0.0},
    {"fast_cold_earliest",1.271,2.7,0.621,0.0}
};
static uint16_t pattern(uint32_t i){return uint16_t(0xa137u+i*0x11u+(i>>5)*0x101u);}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    std::vector<Profile> active(std::begin(profiles),std::end(profiles));
    if(const char* file=std::getenv("CS_SDRAM_TIMING_PROFILE")){
        std::ifstream input(file);if(!input){std::cerr<<"missing timing profile "<<file<<"\n";return 2;}
        active.clear();std::string line;
        while(std::getline(input,line)){
            if(line.empty()||line[0]=='#')continue;
            std::istringstream row(line);Profile p;
            if(!(row>>p.name>>p.clock_delta>>p.chip_access>>p.input_pad>>p.board) ||
               p.clock_delta<=-5.82 || p.clock_delta>=5.82 || p.chip_access<2.7 || p.chip_access>6.5 ||
               p.input_pad<0 || p.board<0 || p.board>1){std::cerr<<"invalid timing profile row\n";return 2;}
            active.push_back(p);
        }
        if(active.size()!=8){std::cerr<<"expected eight timing profiles\n";return 2;}
        std::cout<<"timing_profile_file="<<file<<"\n";
    }
    unsigned failures=0;
    for(const auto& profile:active){
        uint64_t clocks=0,transactions=0;
        try{
            Vcs_sdram_backend d;SdramModel memory;
            for(uint32_t i=0;i<memory.words.size();++i)memory.words[i]=pattern(i);
            constexpr bool registered_io=
#ifdef CS_SDRAM_REGISTERED_IO
                true;
#else
                false;
#endif
            TimedSdramPort<true> pins(memory,{profile.name,profile.clock_delta,profile.chip_access,profile.input_pad,profile.board},registered_io);
            #ifdef CS_SDRAM_LATE_CAPTURE
            const char* phase_text=std::getenv("CS_SDRAM_CAPTURE_PHASE_NS");
            if(!phase_text)throw std::runtime_error("missing fitted capture phase");
            pins.capture_phase=std::stod(phase_text);
#endif
            auto clock=[&](){pins.prepare(d);d.clk=1;d.eval();pins.finish(d);++clocks;};
            d.reset=1;d.req_valid=0;clock();clock();d.reset=0;
            while(!d.initialized&&clocks<20000)clock();
            memory.check(d.initialized,"physical SDRAM initialization timeout");
            uint64_t max_response=0;
            std::unordered_map<uint32_t,uint32_t> shadow;
            auto original=[&](uint32_t index){return uint32_t(pattern(index))|(uint32_t(pattern(index+1))<<16);};
            auto request=[&](unsigned target,uint32_t offset,bool write,uint32_t value,unsigned mask){
                uint32_t index=((target-1)*0x800000u+offset)/2;
                uint32_t expected=shadow.count(index)?shadow.at(index):original(index);
                if(write){
                    for(unsigned lane=0;lane<4;++lane)if(mask&(1u<<lane))
                        expected=(expected&~(255u<<(lane*8)))|(value&(255u<<(lane*8)));
                    shadow[index]=expected;
                }
                d.req_target=target;d.req_offset=offset;d.req_write=write;
                d.req_data=value;d.req_strobe=mask;d.req_valid=1;
                uint64_t start=clocks;bool accepted=false,answered=false;
                while(clocks-start<20000){
                    d.eval();bool accept=d.req_valid&&d.req_ready;
                    clock();if(accept){accepted=true;d.req_valid=0;}
                    if(d.rsp_valid){
                        memory.check(accepted&&!d.rsp_error,"delayed request ownership/error");
                        if(!write&&d.rsp_data!=expected){
                            std::cerr<<"profile="<<profile.name<<" target="<<target<<" offset="<<offset
                                <<" actual=0x"<<std::hex<<d.rsp_data<<" expected=0x"<<expected<<std::dec<<"\n";
                            throw std::runtime_error("delayed SDRAM halfword assembly mismatch");
                        }
                        answered=true;++transactions;max_response=std::max(max_response,clocks-start);break;
                    }
                }
                memory.check(answered,"delayed SDRAM request timeout");clock();
                if(write){
                    uint32_t stored=uint32_t(memory.words[index])|(uint32_t(memory.words[index+1])<<16);
                    memory.check(stored==expected,"actual masked pin write differs from cache/shadow");
                }
            };
            for(unsigned target=1;target<=3;++target)
                for(uint32_t offset:{0u,4u,0x3fcu,0x400u,0x1000u,0x7ffffcu})request(target,offset,false,0,15);
            // Both physical halfwords, every lane mask, bank/row boundaries;
            // inspect chip storage so cache hits cannot hide a pin-write defect.
            for(unsigned target=1;target<=3;++target)
                for(uint32_t offset:{0x3ffcu,0x4000u})for(unsigned mask=0;mask<16;++mask){
                    request(target,offset,true,0x87654321u^(mask*0x01010101u),mask);
                    request(target,offset,false,0,15);
                }
            std::cout<<"PASS profile="<<profile.name<<" transactions="<<transactions<<" clocks="<<clocks<<" max_response_clocks="<<max_response<<"\n";
        }catch(const std::exception& e){
            ++failures;
            std::cerr<<"FAIL profile="<<profile.name<<" clocks="<<clocks<<" reason="<<e.what()<<"\n";
        }
    }
    std::cout<<"delayed_return_profiles="<<active.size()<<" failed="<<failures
        <<"; provisional saved-fit pin-window qualification, not full board signoff\n";
    return failures?1:0;
}
