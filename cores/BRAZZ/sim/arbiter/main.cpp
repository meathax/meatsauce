// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_bus_arbiter.h"
#include "verilated.h"
#include <array>
#include <cstdio>
#include <stdexcept>
static vluint64_t ticks=0;
double sc_time_stamp(){return double(ticks);}
static uint32_t rng=0xA8B17E;
static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;return rng^=rng<<5;}
static void edge(Vcs_bus_arbiter& d){d.clk=0;d.eval();++ticks;d.clk=1;d.eval();++ticks;}
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);Vcs_bus_arbiter d;
    try{
        d.reset=1;d.client_valid=0;d.req_ready=0;d.rsp_valid=0;edge(d);d.reset=0;
        d.client_valid=2;d.client_address=uint64_t(0x200)<<32;d.client_data=uint64_t(0x1234)<<32;d.client_strobe=0xf0;d.client_write=2;edge(d);
        d.client_valid=3;d.client_address|=0x100;d.client_data|=0x5678;d.client_strobe=0xff;d.client_write=3;
        for(unsigned i=0;i<8;++i){d.clk=0;d.eval();if(!d.req_valid || d.req_client!=1 || d.req_address!=0x200 || d.req_data!=0x1234 || d.client_ready)throw std::runtime_error("stalled grant changed");edge(d);}
        d.req_ready=1;edge(d);d.rsp_valid=1;d.rsp_data=0xabcd;d.rsp_error=1;d.clk=0;d.eval();
        if(d.client_rsp_valid!=2 || d.client_rsp_data!=0xabcd || !d.client_rsp_error)throw std::runtime_error("response owner/error mismatch");edge(d);d.rsp_valid=0;
        d.reset=1;edge(d);d.reset=0;
        std::array<unsigned,2> issued{},completed{};
        bool pending=false;unsigned delay=0,owner=0,transactions=0;uint32_t reply=0;bool error=false;int previous=-1;
        for(unsigned timeout=0;timeout<10000 && (completed[0]<64 || completed[1]<64);++timeout){
            d.client_valid=(issued[0]<64?1:0)|(issued[1]<64?2:0);
            d.client_address=(uint64_t(0x2000+issued[1]*4)<<32)|(0x1000+issued[0]*4);
            d.client_data=(uint64_t(0xbb000000|issued[1])<<32)|(0xaa000000|issued[0]);
            d.client_strobe=0xff;d.client_write=3;d.req_ready=!pending && ((random32()&3)!=0);
            d.rsp_valid=pending && !delay;d.rsp_data=reply;d.rsp_error=error;d.clk=0;d.eval();
            const bool accept=d.req_valid && d.req_ready,response=d.rsp_valid;
            const unsigned accepted_owner=d.req_client;const uint32_t address=d.req_address,data=d.req_data;
            if(response){if(d.client_rsp_valid!=(1u<<owner) || d.client_rsp_data!=reply || bool(d.client_rsp_error)!=error)throw std::runtime_error("delayed response delivered to wrong client");++completed[owner];}
            if(accept){
                if(pending || d.client_ready!=(1u<<accepted_owner))throw std::runtime_error("multiple accepted owners");
                if((issued[0]<64 && issued[1]<64) && previous==int(accepted_owner))throw std::runtime_error("round-robin starvation");
                const uint32_t expected_address=(accepted_owner?0x2000:0x1000)+issued[accepted_owner]*4;
                const uint32_t expected_data=(accepted_owner?0xbb000000:0xaa000000)|issued[accepted_owner];
                if(address!=expected_address || data!=expected_data || d.req_strobe!=15 || !d.req_write)throw std::runtime_error("request payload corrupted");
            }
            edge(d);if(pending && delay)--delay;if(response)pending=false;
            if(accept){pending=true;owner=accepted_owner;reply=address^data;error=(transactions%7)==0;delay=1+random32()%9;previous=owner;++issued[owner];++transactions;}
        }
        if(completed[0]!=64 || completed[1]!=64)throw std::runtime_error("arbiter timeout");
        std::printf("PASS board-bus arbiter: stalled grant retention, 128 contended requests, fair ownership and delayed/error responses\n");return 0;
    }catch(const std::exception& e){std::fprintf(stderr,"FAIL arbiter: %s\n",e.what());return 1;}
}
