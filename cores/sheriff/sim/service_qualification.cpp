// SPDX-License-Identifier: GPL-2.0-or-later
// Component fixture: original short program, not a replacement game ROM.
#include "Vn8080_board.h"
#include "verilated.h"
#include <array>
#include <iostream>

static bool qualify(unsigned offset, unsigned borrowed) {
    Vn8080_board b;
    auto step=[&]() { b.clk=0;b.eval();b.clk=1;b.eval(); };
    b.reset=1;b.pause=0;b.debug_req=0;b.debug_freeze=0;
    b.debug_wr=0;b.load_wr=1;b.input0=0;b.input1=0;b.input2=0;b.input3=0xfc;
    // DI; LXI SP,7ffe; LDA 4000; OUT 4; HLT.
    const std::array<unsigned,10> program={0xf3,0x31,0xfe,0x7f,0x3a,0,0x40,0xd3,4,0x76};
    for(unsigned a=0;a<0x4800;a++) {
        b.load_addr=a;b.load_data=a<program.size()?program[a]:0;step();
    }
    b.load_wr=0;for(unsigned i=0;i<1000;i++)step();
    b.reset=0;b.pause=1;b.debug_req=1;b.debug_wr=1;
    b.debug_addr=0;b.debug_dout=5;step();
    b.debug_addr=0x3fff;b.debug_dout=borrowed;step();
    b.debug_wr=0;b.debug_req=0;b.pause=0;
    bool found=false;
    for(unsigned i=0;i<10000;i++) {
        b.clk=0;b.eval();
        if(b.cpu_dbin && b.cpu_address==0x4000){found=true;break;}
        step();
    }
    if(!found){std::cerr<<"FAIL pending LDA read not found\n";return false;}
    for(unsigned i=0;i<offset;i++)step();
    b.clk=0;b.eval();
    if(!b.cpu_dbin || b.cpu_address!=0x4000){std::cerr<<"FAIL fixture left RAM read\n";return false;}
    const unsigned address=b.cpu_address, data=b.cpu_dout, dbin=b.cpu_dbin;
    b.pause=1;b.debug_req=1;b.debug_addr=0x3fff;
    for(unsigned i=0;i<32;i++) {
        step();
        if(b.cpu_address!=address || b.cpu_dout!=data || b.cpu_dbin!=dbin){
            std::cerr<<"FAIL CPU bus changed during service\n";return false;
        }
    }
    if(b.debug_data!=borrowed){std::cerr<<"FAIL service did not borrow requested byte\n";return false;}
    // Actual hiscore requester may lower pause and request on the same edge.
    b.pause=0;b.debug_req=0;
    for(unsigned i=0;i<2;i++) {
        step();
        if(b.cpu_address!=address || b.cpu_dout!=data || b.cpu_dbin!=dbin){
            std::cerr<<"FAIL CPU resumed before RAM port refill\n";return false;
        }
    }
    for(unsigned i=0;i<10000;i++) {
        b.clk=0;b.eval();
        if(b.cpu_write && (b.cpu_status&0x10)) {
            if((b.cpu_address&7)!=4 || b.cpu_dout!=5) {
                std::cerr<<"FAIL LDA/OUT after service offset="<<offset
                         <<" borrowed="<<borrowed<<" data="<<unsigned(b.cpu_dout)<<'\n';
                return false;
            }
            return true;
        }
        step();
    }
    std::cerr<<"FAIL post-service OUT timeout\n";return false;
}
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    for(unsigned byte:{0U,0x9aU,0xffU})
        for(unsigned offset=0;offset<25;offset++)
            if(!qualify(offset,byte))return 1;
    std::cout<<"PASS: 75 mid-read RAM-service cases, paused bus stable, simultaneous release protected, LDA/OUT byte exact\n";
}
