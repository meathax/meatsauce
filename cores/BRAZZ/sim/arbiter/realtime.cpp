// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_bus_arbiter.h"
#include "verilated.h"
#include <array>
#include <cstdio>
#include <stdexcept>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);Vcs_bus_arbiter d;
    std::array<unsigned,5> sent{},received{};bool pending=false,locked=false;
    unsigned owner=0,remaining=0,locked_owner=0;uint64_t last_sound=0,max_sound_gap=0;
    d.reset=1;d.clk=0;d.eval();d.clk=1;d.eval();d.reset=0;
    try{for(uint64_t clock=0;clock<60000;++clock){
        d.clk=0;d.client_valid=31;
        for(unsigned i=0;i<5;++i){d.client_address[i]=0x03800000+i*0x1000+sent[i]*4;d.client_data[i]=sent[i];}
        d.client_write=7;d.client_strobe=0xfffff;d.req_ready=(clock%13)!=0;
        d.rsp_valid=pending&&!remaining;d.rsp_data=owner*0x10000+received[owner];d.rsp_error=0;d.eval();
        if(d.client_rsp_valid){
            if(!pending||d.client_rsp_valid!=(1u<<owner))throw std::runtime_error("reply ownership");
            ++received[owner];pending=false;
        }
        if(d.req_valid){
            unsigned id=d.req_client;
            if(locked&&id!=locked_owner)throw std::runtime_error("stalled grant moved");
            if(d.req_address!=0x03800000+id*0x1000+sent[id]*4)throw std::runtime_error("selected payload");
            if(d.req_ready){
                if(pending)throw std::runtime_error("overlapping owned requests");
                owner=id;pending=true;remaining=220;++sent[id];locked=false;
                if(id==3){max_sound_gap=std::max(max_sound_gap,clock-last_sound);last_sound=clock;}
            }else{locked=true;locked_owner=id;}
        }
        if(clock-last_sound>=1944)throw std::runtime_error("sound request starved beyond sample period under continuous display traffic");
        d.clk=1;d.eval();if(pending&&remaining)--remaining;
    }
    for(unsigned i=0;i<5;++i)if(!received[i])throw std::runtime_error("background client starved");
    std::printf("PASS realtime arbiter: 220-cycle nonpreemptible memory, persistent five-client demand; max sound grant gap=%llu; replies=%u/%u/%u/%u/%u\n",(unsigned long long)max_sound_gap,received[0],received[1],received[2],received[3],received[4]);return 0;
    }catch(const std::exception&e){std::fprintf(stderr,"FAIL realtime arbiter: %s; sent=%u/%u/%u/%u/%u\n",e.what(),sent[0],sent[1],sent[2],sent[3],sent[4]);return 1;}
}
