// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_board_io.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void check(bool ok,const char* message){++checks;if(!ok)throw std::runtime_error(message);}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Vcs_board_io d;
        auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();};
        auto access=[&](unsigned a,bool w=false,unsigned data=0,unsigned strobe=15){
            d.reg_address=a;d.reg_write=w;d.reg_data=data;d.reg_strobe=strobe;d.reg_valid=1;tick();
            check(d.reg_ready&&d.reg_rsp_valid&&!d.reg_rsp_error,"board MMIO response");
            d.reg_valid=0;return d.reg_rsp_data;
        };
        d.reset=1;d.reg_valid=0;d.system_n=255;d.dips_n=255;d.p1_p2_n=d.p3_p4_n=0xffffffff;tick();d.reset=0;
        check(access(0x01200008)==0xffffffff,"idle input pins");
        d.p1_p2_n=0xa55a69c3;d.p3_p4_n=0x98765432;d.system_n=0xf3;d.dips_n=0xa5;
        check(access(0x01200000)==0xa55a69c3&&access(0x01200004)==0x98765432,"player pin placement");
        check(access(0x01200008)==0xfff3ffa5,"system/DIP byte placement");
        for(unsigned bank=0;bank<8;bank++){access(0x01280000,true,bank<<1,1);check(d.flash_bank==bank,"bank bits3:1");}
        // MAME banksw_w is one 32-bit handler fed lane-positioned data: any lane write
        // replaces the bank, and a write that omits lane 0 therefore selects bank 0
        // (verified in MAME 0.289: write_u16(01280002)/write_u8(01280001/2) -> bank 0).
        access(0x01280000,true,14,1);check(d.flash_bank==7,"bank seven");
        access(0x01280000,true,0x00020000,12);check(d.flash_bank==0,"bank high half write selects 0");
        access(0x01280000,true,14,1);access(0x01280000,true,0x0200,2);check(d.flash_bank==0,"bank byte1 write selects 0");
        access(0x01280000,true,14,1);access(0x01280000,true,0x0e,3);check(d.flash_bank==7,"bank halfword lane0 write");
        access(0x01280000,true,4,1);check(d.flash_bank==2,"bank byte0 write");
        // Unmapped/write-only words read as zero in MAME (read_u32 of 01280000/01320000 -> 0).
        check(access(0x01280000)==0&&access(0x01320000)==0,"bank/lamp write-only words read zero");
        access(0x01280000,true,0,1);
        access(0x01320000,true,0xaabbccdd);check(d.lamps==0xbbdd,"lamp lanes0/2");
        access(0x01320000,true,0x12345678,10);check(d.lamps==0xbbdd,"lamp unused lanes");
        access(0x01320000,true,0x007e0000,4);check(d.lamps==0x7edd,"independent lamp lane");
        access(0x01200000,true,3,1);check(uint32_t(d.coin_counts)==1&&uint32_t(d.coin_counts>>32)==1,"coin output rising edges");
        access(0x01200000,true,3,1);check(uint32_t(d.coin_counts)==1&&uint32_t(d.coin_counts>>32)==1,"held counter lines");
        access(0x01200000,true,0,1);access(0x01200000,true,1,1);check(uint32_t(d.coin_counts)==2&&uint32_t(d.coin_counts>>32)==1,"separate coin output counts");
        d.system_n=0xff;tick();d.system_n=0xef;tick();check(d.interrupt_events==(1u<<12),"coin1 input interrupt12");
        tick();check(!d.interrupt_events,"coin1 held produces one event");
        d.system_n=0xcf;tick();check(d.interrupt_events==(1u<<19),"coin2 interrupt19");
        d.system_n=0xff;tick();d.system_n=0xcf;tick();check(d.interrupt_events==((1u<<12)|(1u<<19)),"simultaneous coin edges");
        std::cout<<"PASS board IO: "<<checks<<" checks; real input pins, coin events/counters, bank (all-lane MAME semantics), zero write-only reads and lamp lanes\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL board IO: "<<e.what()<<"\n";return 1;}
}
