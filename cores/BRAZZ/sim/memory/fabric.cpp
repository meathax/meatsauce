// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_memory_fabric.h"
#include "verilated.h"
#include "sdram_model.hpp"
#include "ddr_model.hpp"
#include "../boot/board_memory.hpp"
#include <iostream>
#include <random>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Vcs_memory_fabric d;SdramModel sdram;DdrModel ddr;
        std::vector<uint8_t> bios(0x20000,0),cart(0x3000000,0);Memory expected(bios,cart);
        uint64_t transactions=0,backups=0;
        auto clock=[&](){
            ddr.step(d);d.sdram_data_in=sdram.tick(d.sdram_cke,d.sdram_cs_n,
                d.sdram_ras_n,d.sdram_cas_n,d.sdram_we_n,d.sdram_ba,d.sdram_address,
                d.sdram_dqm,d.sdram_data_out,d.sdram_data_oe);d.eval();
        };
        d.req_valid=0;d.load_valid=0;d.backup_valid=0;d.gpu_burst_valid=0;d.reset=1;clock();clock();d.reset=0;
        // The board stays in reset until NVRAM and the power-up SDRAM clear finish.
        for(unsigned n=0;n<400000&&!d.memory_initialized;n++)clock();
        ddr.check(d.memory_initialized,"fabric power-up clear/self-test timeout");
        ddr.check(d.sdram_test_done&&d.sdram_test_errors==0,"SDRAM self-test must pass on the ideal model");
        auto address=[&](unsigned target,uint32_t offset){
            const uint32_t base[13]={0,0x02000000,0x03800000,0x04000000,0x05000000,0x01400000,0,0,0,0,0,0,0x44414f4c};
            if(target==4){expected.bank=offset>>24;offset&=0xffffff;}
            return base[target]+offset;
        };
        auto request=[&](unsigned target,uint32_t offset,bool write,uint32_t value,unsigned mask,bool error=false){
            d.req_target=target;d.req_offset=offset;d.req_data=value;d.req_strobe=mask;d.req_write=write;d.req_valid=1;
            uint64_t start=ddr.cycles;bool accepted=false,done=false;
            while(ddr.cycles-start<20000){
                d.eval();bool accept=d.req_valid&&d.req_ready;clock();
                if(accept){accepted=true;d.req_valid=0;}
                if(d.rsp_valid){
                    ddr.check(accepted&&bool(d.rsp_error)==error,"fabric owner/error mismatch");
                    if(!error){
                        if(write){
                            if(target!=0&&target!=4)for(unsigned b=0;b<4;b++)if(mask&(1u<<b))expected.write(address(target,offset)+b,value>>(8*b));
                        }else{
                            uint32_t want=0;
                            for(unsigned b=0;b<4;b++)want|=uint32_t(expected.read(address(target,offset)+b))<<(8*b);
                            ddr.check(d.rsp_data==want,"fabric read differs from MAME board map");
                        }
                    }
                    done=true;break;
                }
                if(accepted)ddr.check(!d.req_ready,"fabric accepted a second owner");
            }
            ddr.check(done,"fabric request timeout");++transactions;clock();ddr.check(!d.rsp_valid,"fabric duplicate reply");
        };
        auto load=[&](unsigned target,uint32_t offset,uint64_t value){
            d.load_target=target;d.load_offset=offset;d.load_data=value;d.load_be=255;d.load_valid=1;
            bool accepted=false,done=false;
            for(unsigned n=0;n<2000;n++){
                d.eval();bool accept=d.load_valid&&d.load_ready;clock();if(accept){accepted=true;d.load_valid=0;}
                if(d.load_done){ddr.check(accepted&&!d.load_error,"fabric loader ownership/error");done=true;break;}
            }
            ddr.check(done,"fabric loader timeout");
            auto& image=target==0?bios:cart;for(unsigned b=0;b<8;b++)image[offset+b]=value>>(8*b);
            clock();
        };
        load(0,0,0x1111222233334444ull);load(4,0,0xaaaabbbbccccddddull);
        load(0,0x1fff8,0x123456789abcdef0ull);load(4,0x2fffff8,0x0fedcba987654321ull);
        for(unsigned target:{0u,4u}){request(target,0,false,0,15);request(target,4,false,0,15);}
        request(0,0x1fffc,false,0,15);request(4,0x2fffffc,false,0,15);
        for(unsigned target:{1u,2u,3u,5u,12u}){
            uint32_t offset=target==12?0x30:target==5?0xfffc:0x7ffffc;
            for(unsigned mask=0;mask<16;mask++){
                request(target,offset,true,0x76543210u^(mask*0x11111111u),mask);
                request(target,offset,false,0,15);
            }
            request(target,0,false,0,15);
        }
        std::mt19937 random(0x4d454d46);
        for(unsigned n=0;n<3000;n++){
            unsigned target=1+random()%3;uint32_t offset=random()&0x7ffffc;
            request(target,offset,true,random(),1+random()%15);request(target,offset,false,0,15);
            if(n%47==0){request(0,0,false,0,15);request(12,0,false,0,15);}
        }
        // GPU 32-byte line bursts: random byte strobes, both SDRAM regions, read back through
        // bursts and the word path, and bursts contending with word requests on the same cycle.
        uint64_t bursts=0;
        auto burst_line_address=[&](bool region,uint32_t line){return (region?0x04000000u:0x03800000u)+(line<<5);};
        auto burst=[&](bool region,uint32_t line,bool write,const uint32_t* data,uint32_t strobes,
                       bool with_word=false,unsigned word_target=0,uint32_t word_offset=0,uint32_t word_value=0){
            d.gpu_burst_region=region;d.gpu_burst_line=line;d.gpu_burst_write=write;d.gpu_burst_wstrobe=strobes;
            for(unsigned w=0;w<8;w++)d.gpu_burst_wdata[w]=data[w];
            d.gpu_burst_valid=1;
            if(with_word){d.req_target=word_target;d.req_offset=word_offset;d.req_data=word_value;d.req_strobe=15;d.req_write=1;d.req_valid=1;}
            bool b_accepted=false,b_done=false,w_accepted=!with_word,w_done=!with_word;
            for(unsigned n=0;n<40000&&!(b_done&&w_done);n++){
                d.eval();bool b_acc=d.gpu_burst_valid&&d.gpu_burst_ready,w_acc=d.req_valid&&d.req_ready;clock();
                if(b_acc){b_accepted=true;d.gpu_burst_valid=0;}
                if(w_acc){w_accepted=true;d.req_valid=0;}
                if(d.gpu_burst_done){
                    ddr.check(b_accepted&&!b_done,"burst done without ownership");b_done=true;
                    for(unsigned w=0;w<8;w++){
                        const uint32_t a=burst_line_address(region,line)+w*4;
                        if(write){for(unsigned b=0;b<4;b++)if((strobes>>(4*w+b))&1)expected.write(a+b,data[w]>>(8*b));}
                        else{uint32_t want=0;for(unsigned b=0;b<4;b++)want|=uint32_t(expected.read(a+b))<<(8*b);
                            ddr.check(uint32_t(d.gpu_burst_rdata[w])==want,"burst read differs from board memory");}
                    }
                }
                if(with_word&&d.rsp_valid){
                    ddr.check(w_accepted&&!w_done&&!d.rsp_error,"word reply during burst");w_done=true;
                    for(unsigned b=0;b<4;b++)expected.write(address(word_target,word_offset)+b,word_value>>(8*b));
                }
            }
            ddr.check(b_done&&w_done,"burst/word contention timeout");++bursts;clock();
        };
        for(unsigned n=0;n<1200;n++){
            const bool region=random()&1;const uint32_t line=(random()&0x3ffff);uint32_t data[8];
            for(auto& w:data)w=random();
            uint32_t strobes=random();if(n%5==0)strobes=0xffffffffu;if(n%11==0)strobes=0;
            burst(region,line,true,data,strobes);
            burst(region,line,false,data,0);
            request(region?3:2,(line<<5)+(random()&28),false,0,15);
            if(n%3==0){
                // Contention: a word write elsewhere in the same region on the same cycle as a burst.
                const uint32_t other=(line^0x155)&0x3ffff;
                burst(region,line,true,data,random(),true,region?3:2,(other<<5)+(random()&28),random());
                burst(region,other,false,data,0);burst(region,line,false,data,0);
            }
        }
        // A word read already presented to the SDRAM controller (row activation in flight, not yet
        // accepted) when a burst arrives with burst priority, same bank, different row. The burst
        // must not preempt it: the donor would issue the burst column into the word's row
        // (GPU line-burst build: burst word 0 returned work-RAM data, hardware black screen).
        for(unsigned n=0;n<600;n++){
            const bool region=random()&1;const uint32_t line=random()&0x3ffff;const unsigned lead=1+n%5;
            const uint32_t word_offset=((line<<5)^(0x2000u<<(random()%8)))&0x7ffffcu;
            uint32_t data[8];for(auto& w:data)w=random()|1u;
            burst(region,line,true,data,0xffffffffu);request(1,word_offset,true,random(),15);
            request(1,random()&0x7ffffc,false,0,15); // a completed word request gives the burst priority
            d.req_target=1;d.req_offset=word_offset;d.req_strobe=15;d.req_write=0;d.req_valid=1;d.gpu_burst_valid=0;
            bool w_accepted=false,w_done=false,b_accepted=false,b_done=false;
            for(unsigned c=0;c<40000&&!(b_done&&w_done);c++){
                if(c==lead){d.gpu_burst_region=region;d.gpu_burst_line=line;d.gpu_burst_write=0;d.gpu_burst_wstrobe=0;d.gpu_burst_valid=1;}
                d.eval();bool b_acc=d.gpu_burst_valid&&d.gpu_burst_ready,w_acc=d.req_valid&&d.req_ready;clock();
                if(b_acc){b_accepted=true;d.gpu_burst_valid=0;}
                if(w_acc){w_accepted=true;d.req_valid=0;}
                if(d.gpu_burst_done){
                    ddr.check(b_accepted&&!b_done,"burst done without ownership");b_done=true;
                    for(unsigned w=0;w<8;w++){const uint32_t a=burst_line_address(region,line)+w*4;uint32_t want=0;
                        for(unsigned b=0;b<4;b++)want|=uint32_t(expected.read(a+b))<<(8*b);
                        ddr.check(uint32_t(d.gpu_burst_rdata[w])==want,"burst after a presented word read returned the wrong row");}
                }
                if(d.rsp_valid){
                    ddr.check(w_accepted&&!w_done&&!d.rsp_error,"presented word read reply");w_done=true;uint32_t want=0;
                    for(unsigned b=0;b<4;b++)want|=uint32_t(expected.read(address(1,word_offset)+b))<<(8*b);
                    ddr.check(d.rsp_data==want,"word read overlapped by a burst differs from board memory");
                }
            }
            ddr.check(b_done&&w_done,"presented word/burst timeout");++bursts;clock();
        }
        // Backup uses the same NVRAM port.
        for(unsigned i:{0u,1u,16383u}){
            d.backup_address=i;d.backup_data=0xdead0000u+i;d.backup_strobe=15;d.backup_write=1;d.backup_valid=1;
            d.eval();ddr.check(d.backup_ready,"backup unavailable without board NVRAM request");clock();
            ddr.check(d.backup_rsp_valid,"backup response missing");d.backup_valid=0;++backups;
            for(unsigned b=0;b<4;b++)expected.write(0x01400000+i*4+b,d.backup_data>>(8*b));
            clock();request(5,i*4,false,0,15);
        }
        // Simultaneous board and backup NVRAM writes: board wins, backup holds.
        d.req_target=5;d.req_offset=0;d.req_data=0xabcddcba;d.req_strobe=15;d.req_write=1;d.req_valid=1;
        d.backup_address=1;d.backup_data=0x12344321;d.backup_strobe=15;d.backup_write=1;d.backup_valid=0;
        d.eval();ddr.check(d.req_ready,"board token not accepted");clock();d.req_valid=0;d.backup_valid=1;
        d.eval();ddr.check(!d.backup_ready,"stored board token lost NVRAM port priority");clock();
        d.eval();ddr.check(d.backup_ready,"backup not released after NVRAM port transfer");
        ddr.check(d.rsp_valid && !d.rsp_error && d.rsp_data==0xdead0000u,
                  "owned board OLD_DATA reply before backup transfer");
        clock();
        ddr.check(!d.rsp_valid && d.backup_rsp_valid && d.backup_rsp_data==0xdead0001u,
                  "distinct consumed board / backup OLD_DATA replies");d.backup_valid=0;
        for(unsigned b=0;b<4;b++){expected.write(0x01400000+b,0xabcddcbau>>(8*b));expected.write(0x01400004+b,0x12344321u>>(8*b));}
        clock();request(5,0,false,0,15);request(5,4,false,0,15);
        // Transport reset preserves NVRAM; reinitialize the SDRAM model too.
        d.reset=1;clock();clock();d.reset=0;
        request(5,0,false,0,15);request(5,4,false,0,15);request(5,0xfffc,false,0,15);
        // Check unmapped requests and local region bounds.
        request(15,0,false,0,15,true);request(5,0x10000,false,0,15,true);request(12,0x34,false,0,15,true);
        for(unsigned n=0;n<1500;n++)clock();
        std::cout<<"PASS physical memory fabric: "<<transactions<<" board-map transactions, "<<backups
            <<" backup operations, "<<sdram.reads<<" SDRAM reads, "<<sdram.writes<<" SDRAM writes, "
            <<sdram.refreshes<<" refreshes, "<<ddr.reads<<" DDR bursts, "<<bursts<<" GPU line bursts (strobed writes, reads, word contention); local reset seed and NVRAM masks/priority pass\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL physical memory fabric: "<<e.what()<<"\n";return 1;}
}
