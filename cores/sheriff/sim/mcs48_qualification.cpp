// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vn8080_mcs48.h"
#include "verilated.h"
#include <array>
#include <fstream>
#include <iostream>
#include <vector>
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);Vn8080_mcs48 b;
    auto step=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};
    b.reset=1;b.pause=0;b.sound1=0;b.sound2=0;
    std::array<uint8_t,1024> code{};
    code[0]=0x04;code[1]=0x10; // JMP main; IRQ vector at 3
    code[3]=0x23;code[4]=0x80;code[5]=0x3a;code[6]=0x93;
    const uint8_t main[]={0x23,0,0x3a,0xb8,0x3f,0x23,0x55,0xa0,0x27,0xf0,0x39,0x05,0x04,0x20};
    std::copy(std::begin(main),std::end(main),code.begin()+0x10);
    code[0x20]=0x04;code[0x21]=0x20;
    for(unsigned a=0;a<1024;a++){b.load_wr=1;b.load_addr=a;b.load_data=code[a];step();}
    b.load_wr=0;for(int i=0;i<100;i++)step();b.reset=0;
    bool ram_ok=false, output_ok=false, irq_ok=false;
    std::ofstream log("mcs48_qualification.csv");log<<"tick,address,p1,p2,irq_n,ram_write,ram_address,ram_data\n";
    for(unsigned t=0;t<200000;t++) {
        if(b.ram_write && (b.ram_address&63)==63 && b.ram_dout==0x55)ram_ok=true;
        if(b.p1_out==0x55 && b.p2_out==0) {output_ok=true;b.sound1=2;}
        step();
        if(t%100==0)log<<t<<","<<b.program_address<<","<<unsigned(b.p1_out)<<","<<unsigned(b.p2_out)<<","<<unsigned(b.irq_n)<<","<<unsigned(b.ram_write)<<","<<unsigned(b.ram_address)<<","<<unsigned(b.ram_dout)<<"\n";
        if(output_ok && b.p2_out==0x80) {
            irq_ok=true;b.sound1=0;
            // Observe the return instruction, not merely the ISR's port write.
            bool returned=false;
            for(unsigned i=0;i<10000;i++) {step();returned|=b.program_address==0x20;}
            if(!returned){std::cerr<<"FAIL RETR did not resume main loop\n";return 1;}
            break;
        }
    }
    if(!ram_ok||!output_ok||!irq_ok){std::cerr<<"FAIL synthetic RAM="<<ram_ok<<" ports="<<output_ok<<" IRQ="<<irq_ok<<" pc="<<b.program_address<<" p1="<<unsigned(b.p1_out)<<" p2="<<unsigned(b.p2_out)<<"\n";return 1;}
    std::cout<<"PASS synthetic: external program fetch, 64-byte RAM, ports and persistent IRQ/RETR\n";
    if(argc>1) {
        std::ifstream f(argv[1],std::ios::binary);std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)),{});
        if(rom.size()!=1024)return 2;
        b.reset=1;b.sound1=0;b.sound2=0;
        for(unsigned a=0;a<1024;a++){b.load_wr=1;b.load_addr=a;b.load_data=rom[a];step();}
        b.load_wr=0;for(int t=0;t<100;t++)step();b.reset=0;
        unsigned edges=0;unsigned previous=b.dac_bit;bool visited=false;
        for(unsigned t=0;t<3000000;t++) {
            if(t==100000)b.sound1=2;
            if(t==200000)b.sound1=0;
            if(t==1000000)b.sound1=8;
            if(t==1100000)b.sound1=0;
            if(t==2000000)b.sound2=16;
            if(t==2100000)b.sound2=0;
            step();visited|=b.program_address>16;
            if(b.dac_bit!=previous){++edges;previous=b.dac_bit;}
        }
        std::cout<<"Real Sheriff ROM: program progression="<<visited<<" DAC edges="<<edges<<" final address="<<b.program_address<<"\n";
        if(!visited||!edges)return 1;
    }
    return 0;
}
