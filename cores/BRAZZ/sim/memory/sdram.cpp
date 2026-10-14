// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_sdram_backend.h"
#include "verilated.h"
#include "sdram_model.hpp"
#include <algorithm>
#include <iostream>
#include <random>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Vcs_sdram_backend d;SdramModel memory;
        std::vector<uint32_t> expected(0x1800000/4,0);
        uint64_t clocks=0,transactions=0,max_latency=0;
        auto clock=[&](){
            d.clk=1;d.eval();d.clk=0;d.eval();
            d.sdram_data_in=memory.tick(d.sdram_cke,d.sdram_cs_n,d.sdram_ras_n,
                d.sdram_cas_n,d.sdram_we_n,d.sdram_ba,d.sdram_address,
                d.sdram_dqm,d.sdram_data_out,d.sdram_data_oe);d.eval();++clocks;
        };
        d.reset=1;d.req_valid=0;clock();clock();d.reset=0;
        auto request=[&](unsigned target,uint32_t offset,bool write,uint32_t value,unsigned strobe,bool error=false){
            d.req_target=target;d.req_offset=offset;d.req_write=write;
            d.req_data=value;d.req_strobe=strobe;d.req_valid=1;
            uint64_t start=clocks;bool accepted=false,answered=false;
            while(clocks-start<20000){
                d.eval();bool accept=d.req_valid&&d.req_ready;
                clock();if(accept){accepted=true;d.req_valid=0;}
                if(d.rsp_valid){
                    memory.check(accepted,"SDRAM response without accepted request");
                    memory.check(bool(d.rsp_error)==error,"SDRAM unexpected error status");
                    if(!error&&!write)memory.check(d.rsp_data==expected[((target-1)*0x800000+offset)/4],"SDRAM word read mismatch");
                    if(!error&&write){
                        auto& word=expected[((target-1)*0x800000+offset)/4];
                        for(unsigned b=0;b<4;b++)if(strobe&(1u<<b))word=(word&~(0xffu<<(8*b)))|(value&(0xffu<<(8*b)));
                    }
                    answered=true;break;
                }
                if(accepted)memory.check(!d.req_ready,"SDRAM accepts second owned request");
            }
            memory.check(answered,"SDRAM request timeout");
            max_latency=std::max(max_latency,clocks-start);++transactions;
            clock();memory.check(!d.rsp_valid,"SDRAM duplicate reply");
        };
        for(unsigned target=1;target<=3;target++){
            for(uint32_t offset:{0u,4u,0x3fcu,0x400u,0x800u,0xc00u,0x1000u,0x123454u,0x7ffffcu}){
                request(target,offset,true,0xf00d0000u^(target<<16)^offset,15);
                request(target,offset,false,0,15);
                for(unsigned mask=0;mask<16;mask++){
                    request(target,offset,true,0x87654321u^(mask*0x01010101u),mask);
                    request(target,offset,false,0,15);
                }
            }
        }
        // Each region retains its own coherent line across interleaved clients.
        uint64_t before=memory.reads;
        for(unsigned word=0;word<8;word++)for(unsigned target=1;target<=3;target++)
            request(target,0x2000+word*4,false,0,15);
        memory.check(memory.reads-before==24,"sequential/interleaved cache lines refilled unexpectedly");
        before=memory.reads;
        request(3,0x200c,true,0xabcdef01,5);request(3,0x200c,false,0,15);
        memory.check(memory.reads==before,"coherent write caused unnecessary read fill");
        memory.check(d.initialized,"SDRAM readiness not asserted after real MRS/guard");
        // Real first-draw failure: GPU framebuffer blending and scanout share VRAM,
        // but distinct lines must coexist instead of refilling on every turn.
        before=memory.reads;
        for(unsigned repeat=0;repeat<4;repeat++)for(unsigned word=0;word<8;word++){
            request(3,0x400080+word*4,false,0,15);
            request(3,0x1000+word*4,false,0,15);
        }
        memory.check(memory.reads-before==16,"GPU/scanout interleave thrashes VRAM read lines");
        before=memory.reads;
        request(3,0x400088,true,0xaabbccdd,10);request(3,0x1004,true,0x11223344,3);
        request(3,0x400088,false,0,15);request(3,0x1004,false,0,15);
        memory.check(memory.reads==before,"coherence failed across both VRAM read lines");
        std::mt19937 random(0x43535953);
        for(unsigned i=0;i<5000;i++){
            unsigned target=1+random()%3;uint32_t offset=(random()&0x7ffffc);
            request(target,offset,true,random(),1+random()%15);
            request(target,offset,false,0,15);
            if(i%41==0)for(unsigned n=0;n<800;n++)clock();
        }
        request(0,0,false,0,15,true);request(4,0,true,0,15,true);
        request(1,0x800000,false,0,15,true);request(2,2,false,0,15,true);
        for(unsigned n=0;n<2000;n++)clock();
        memory.check(memory.configured&&memory.refreshes>20,"SDRAM initialization/refresh not exercised");
        std::cout<<"PASS SDRAM physical backend: "<<transactions<<" mapped/masked/error transactions, "
            <<memory.reads<<" BL2 reads, "<<memory.writes<<" BL2 writes, "<<memory.refreshes
            <<" refreshes, max refresh gap "<<memory.max_refresh_gap<<" clocks, max request latency "
            <<max_latency<<", "<<clocks<<" clocks; no pin timing violations\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL SDRAM physical backend: "<<e.what()<<"\n";return 1;}
}
