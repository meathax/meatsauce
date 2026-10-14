// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_ddr_rom_backend.h"
#include "verilated.h"
#include "ddr_model.hpp"
#include <iostream>
#include <random>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Vcs_ddr_rom_backend d;DdrModel memory;
        std::vector<uint8_t> expected(0x3020000,0);
        uint64_t transactions=0,loads=0,max_latency=0;
        d.req_valid=0;d.load_valid=0;d.reset=1;memory.step(d);memory.step(d);d.reset=0;
        auto load=[&](unsigned target,uint32_t offset,uint64_t data,unsigned mask,bool error=false){
            d.load_target=target;d.load_offset=offset;d.load_data=data;d.load_be=mask;d.load_valid=1;
            uint64_t start=memory.cycles;bool accepted=false,done=false;
            while(memory.cycles-start<2000){
                d.eval();bool accept=d.load_valid&&d.load_ready;memory.step(d);
                if(accept){accepted=true;d.load_valid=0;}
                if(d.load_done){memory.check(accepted&&bool(d.load_error)==error,"DDR loader completion/error");done=true;break;}
            }
            memory.check(done,"DDR loader timeout");++loads;
            if(!error){uint32_t at=(target==0?0x3000000:0)+offset;
                for(unsigned b=0;b<8;b++){if(mask&(1u<<b))expected[at+b]=data>>(8*b);
                    memory.check(memory.bytes[at+b]==expected[at+b],"DDR physical loader address/mask");}}
            memory.step(d);memory.check(!d.load_done,"DDR duplicate loader reply");
        };
        auto read=[&](unsigned target,uint32_t offset,bool error=false,bool write=false){
            d.req_target=target;d.req_offset=offset;d.req_write=write;d.req_valid=1;
            uint64_t start=memory.cycles;bool accepted=false,done=false;
            while(memory.cycles-start<2000){
                d.eval();bool accept=d.req_valid&&d.req_ready;memory.step(d);
                if(accept){accepted=true;d.req_valid=0;}
                if(d.rsp_valid){
                    memory.check(accepted&&bool(d.rsp_error)==error,"DDR ROM response ownership/error");
                    uint32_t want=write?0:0xffffffff;
                    if(!error&&!write&&(target==0?offset<0x20000:offset<0x3000000)){
                        want=0;uint32_t at=(target==0?0x3000000:0)+offset;
                        for(unsigned b=0;b<4;b++)want|=uint32_t(expected[at+b])<<(8*b);
                    }
                    memory.check(d.rsp_data==want,"DDR ROM read mismatch");done=true;break;
                }
            }
            memory.check(done,"DDR ROM request timeout");++transactions;
            if(memory.cycles-start>max_latency)max_latency=memory.cycles-start;
            memory.step(d);memory.check(!d.rsp_valid,"DDR duplicate ROM reply");
        };
        for(unsigned target:{0u,4u})for(uint32_t offset:{0u,8u,56u,64u,0x1000u,0x1fff8u}){
            load(target,offset,0x87654321fedcba98ull^offset,255);
        }
        for(uint32_t offset:{0xfffff8u,0x1000000u,0x2000000u,0x2fffff8u})load(4,offset,0x12345678aabbccddull^offset,255);
        for(unsigned target:{0u,4u})for(uint32_t offset:{0u,4u,8u,12u,56u,60u,64u,68u,0x1000u,0x1004u,0x1fff8u,0x1fffcu})read(target,offset);
        for(uint32_t offset:{0xfffff8u,0xfffffcu,0x1000000u,0x1000004u,0x2000000u,0x2000004u,0x2fffff8u,0x2fffffcu})read(4,offset);
        for(unsigned mask=0;mask<256;mask++){
            load(4,0x345678,0x0102030405060708ull*mask,mask);read(4,0x345678);read(4,0x34567c);
        }
        uint64_t before=memory.reads;
        for(unsigned i=0;i<16;i++)read(4,0x876500+i*4);
        memory.check(memory.reads==before+1,"DDR 64-byte line cache failed");
        before=memory.writes;read(4,0);
        memory.check(memory.writes==before,"DDR ROM read wrote memory");
        read(15,0,true);read(0,0x20000,true);read(4,2,true);read(4,0x3000000);
        read(4,0,false,true);memory.check(memory.writes==before,"DDR CPU ROM write not ignored");read(4,0);
        load(1,0,0,255,true);load(4,1,0,255,true);load(0,0x20000,0,255,true);
        std::mt19937 random(0x44445233);
        for(unsigned i=0;i<2000;i++)read(4,(random()%0x3000000)&~3u);
        // Cancel an accepted burst, then prove a new owner cannot consume old beats.
        before=memory.reads;d.req_target=4;d.req_offset=0x8000;d.req_write=0;d.req_valid=1;
        for(unsigned n=0;n<2000&&memory.reads==before;n++){d.eval();bool accept=d.req_valid&&d.req_ready;memory.step(d);if(accept)d.req_valid=0;}
        memory.check(memory.reads==before+1,"DDR reset test did not accept a read");
        d.reset=1;memory.step(d);memory.step(d);d.reset=0;read(0,0);
        memory.check(memory.pending.empty(),"DDR reset left undrained beats");
        std::cout<<"PASS DDR ROM backend: "<<transactions<<" reads/ignored writes/errors, "<<loads<<" masked loader operations, "
            <<memory.reads<<" eight-beat bursts, "<<memory.writes<<" physical writes, "<<memory.busy_cycles<<" busy cycles, max request "
            <<max_latency<<" clocks; cache invalidation and reset drain pass\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL DDR ROM backend: "<<e.what()<<"\n";return 1;}
}
