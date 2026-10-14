// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_bus_arbiter.h"
#include "verilated.h"
#include <array>
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Vcs_bus_arbiter d;
        auto clock=[&](){d.clk=1;d.eval();d.clk=0;d.eval();};
        d.reset=1;d.client_valid=0;d.req_ready=0;d.rsp_valid=0;clock();d.reset=0;
        std::array<unsigned,3> sent{},received{};
        bool pending=false;unsigned owner=0,packet=0,delay=0,total=0;
        unsigned last=2;
        for(unsigned cycle=0;cycle<10000&&total<192;cycle++){
            d.client_valid=0;
            for(unsigned i=0;i<3;i++){
                if(sent[i]<64)d.client_valid|=1<<i;
                d.client_address[i]=0x02000000+i*0x1000+sent[i]*4;
                d.client_data[i]=i*0x10000+sent[i];
            }
            d.client_strobe=0xfff;d.client_write=7;
            d.req_ready=!pending&&cycle%4!=0;
            d.rsp_valid=pending&&delay==0;
            d.rsp_data=owner*0x10000+packet;d.rsp_error=packet%7==0;d.eval();
            bool accept=d.req_valid&&d.req_ready,reply=d.rsp_valid;
            unsigned selected=d.req_client;
            if(accept){
                if(pending||selected>=3)throw std::runtime_error("request ownership");
                if(selected!=(last+1)%3)throw std::runtime_error("three-way round robin");
                if(d.client_ready!=(1u<<selected)||d.req_address!=d.client_address[selected]||d.req_data!=d.client_data[selected]||d.req_strobe!=15)
                    throw std::runtime_error("request data/ready routing");
            }
            if(reply){
                if(d.client_rsp_valid!=(1u<<owner)||d.client_rsp_data!=owner*0x10000+packet||d.client_rsp_error!=(packet%7==0))
                    throw std::runtime_error("response ownership/data/error");
                ++received[owner];++total;
            }else if(d.client_rsp_valid)throw std::runtime_error("early response");
            clock();
            if(pending){if(delay)--delay;else pending=false;}
            if(accept){owner=selected;packet=sent[owner]++;pending=true;delay=1+cycle%5;last=owner;}
        }
        for(unsigned i=0;i<3;i++)if(sent[i]!=64||received[i]!=64)throw std::runtime_error("missing client transactions");
        std::cout<<"PASS arbiter3: 192 contended requests, 64/client; delayed replies, stalls, fair ownership and error routing\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL arbiter3: "<<e.what()<<"\n";return 1;}
}
