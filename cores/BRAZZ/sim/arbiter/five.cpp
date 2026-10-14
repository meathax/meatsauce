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
        std::array<unsigned,5> sent{},received{};
        bool pending=false;unsigned owner=0,packet=0,delay=0,total=0;
        unsigned last=4;
        for(unsigned cycle=0;cycle<10000&&total<320;cycle++){
            d.client_valid=0;
            for(unsigned i=0;i<5;i++){
                if(sent[i]<64)d.client_valid|=1<<i;
                d.client_address[i]=0x02000000+i*0x1000+sent[i]*4;
                d.client_data[i]=i*0x10000+sent[i];
            }
            d.client_strobe=0xfffff;d.client_write=31;
            d.req_ready=!pending&&cycle%5!=0;
            d.rsp_valid=pending&&delay==0;
            d.rsp_data=owner*0x10000+packet;d.rsp_error=packet%7==0;d.eval();
            bool accept=d.req_valid&&d.req_ready,reply=d.rsp_valid;
            unsigned selected=d.req_client;
            if(d.req_grant!=(d.req_valid?(1u<<selected):0u))
                throw std::runtime_error("one-hot request grant");
            if(accept){
                if(pending||selected>=5)throw std::runtime_error("request ownership");
                if(selected!=(last+1)%5)throw std::runtime_error("five-way round robin");
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
        for(unsigned i=0;i<5;i++)if(sent[i]!=64||received[i]!=64)throw std::runtime_error("missing client transactions");
        unsigned sparse_cases=0;
        for(unsigned start=0;start<5;start++)for(unsigned mask=1;mask<32;mask++){
            d.reset=1;d.client_valid=0;d.rsp_valid=0;clock();d.reset=0;
            unsigned predecessor=(start+4)%5;
            d.client_valid=1u<<predecessor;d.req_ready=1;d.eval();
            if(!d.req_valid||d.req_client!=predecessor)throw std::runtime_error("pointer setup");
            clock();d.client_valid=0;d.rsp_valid=1;d.eval();clock();d.rsp_valid=0;
            unsigned expected=5;
            for(unsigned i=0;i<5;i++){unsigned c=(start+i)%5;if(mask&(1u<<c)){expected=c;break;}}
            for(unsigned i=0;i<5;i++){d.client_address[i]=0x05000000+i*0x100;d.client_data[i]=0xfeed0000+i;}
            d.client_valid=mask;d.req_ready=0;d.eval();
            if(!d.req_valid||d.req_client!=expected||d.req_grant!=(1u<<expected))throw std::runtime_error("sparse round robin/grant");
            clock();d.client_valid=31; // Earlier contenders cannot steal a stalled grant.
            for(unsigned stall=0;stall<3;stall++){
                d.eval();if(d.req_client!=expected||d.req_grant!=(1u<<expected)||d.req_address!=0x05000000+expected*0x100||d.req_data!=0xfeed0000+expected||d.client_ready)
                    throw std::runtime_error("locked grant payload");
                clock();
            }
            d.req_ready=1;d.eval();
            if(d.client_ready!=(1u<<expected))throw std::runtime_error("locked grant ready");
            clock();d.client_valid=0;d.rsp_valid=1;d.rsp_data=0x12340000+expected;d.rsp_error=1;d.eval();
            if(d.client_rsp_valid!=(1u<<expected)||d.client_rsp_data!=0x12340000+expected||!d.client_rsp_error)
                throw std::runtime_error("sparse response ownership");
            clock();d.rsp_valid=0;++sparse_cases;
        }
        std::cout<<"PASS arbiter5: 320 contended requests, 64/client; "<<sparse_cases<<" sparse pointer/mask cases with locked grants and delayed/error replies\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL arbiter5: "<<e.what()<<"\n";return 1;}
}
