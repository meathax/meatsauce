// SPDX-License-Identifier: GPL-2.0-or-later
// Synthetic documented 8080 instructions, not game ROM data.
// Timing reference: MAME 0.289 i8085.cpp lut_cycles_8080 and conditional
// call/return helpers; explicit ISA classes below include taken-cycle costs.
#include "Vn8080_cpu.h"
#include "verilated.h"
#include <array>
#include <fstream>
#include <iostream>
#include <vector>

static bool documented(unsigned op) {
    for (unsigned undefined : {0x08,0x10,0x18,0x20,0x28,0x30,0x38,0xcb,0xd9,0xdd,0xed,0xfd})
        if (op==undefined) return false;
    return op!=0x76; // HALT/wakeup is covered by cpu_qualification, not this cadence test.
}
static bool taken(unsigned op, unsigned mode) {
    const bool flags[8]={bool(mode),!mode,!mode,bool(mode),bool(mode),!mode,!mode,bool(mode)};
    return flags[(op>>3)&7];
}
static unsigned expected(unsigned op,unsigned mode) {
    if (op<0x40) {
        if ((op&0xcf)==1) return 10; // LXI
        if ((op&0xcf)==3 || (op&0xcf)==0x0b) return 5; // INX/DCX
        if ((op&0xcf)==9) return 10; // DAD
        if ((op&0xc7)==4 || (op&0xc7)==5) return ((op>>3)&7)==6?10:5;
        if ((op&0xc7)==6) return ((op>>3)&7)==6?10:7;
        if (op==2 || op==0x12 || op==0x0a || op==0x1a) return 7;
        if (op==0x22 || op==0x2a) return 16;
        if (op==0x32 || op==0x3a) return 13;
        return 4;
    }
    if (op<0x80) return (((op>>3)&7)==6 || (op&7)==6)?7:5;
    if (op<0xc0) return (op&7)==6?7:4;
    if ((op&0xc7)==0xc0) return taken(op,mode)?11:5;
    if ((op&0xcf)==0xc1) return 10;
    if ((op&0xc7)==0xc2 || op==0xc3) return 10;
    if ((op&0xc7)==0xc4) return taken(op,mode)?17:11;
    if ((op&0xcf)==0xc5) return 11;
    if ((op&0xc7)==0xc6) return 7;
    if ((op&0xc7)==0xc7) return 11;
    if (op==0xc9 || op==0xd3 || op==0xdb) return 10;
    if (op==0xcd) return 17;
    if (op==0xe3) return 18;
    if (op==0xe9 || op==0xf9) return 5;
    return 4;
}

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    std::ofstream report("cpu_timing.csv");
    report<<"opcode,flag_mode,expected_t_states,actual_master_clocks,next_pc,pass\n";
    unsigned cases=0,failures=0;
    for (unsigned op=0;op<256;op++) if (documented(op)) for(unsigned mode=0;mode<2;mode++) {
        Vn8080_cpu cpu;
        std::array<uint8_t,65536> memory{};
        memory[0]=0xc3;memory[1]=0x00;memory[2]=0x01;
        const std::vector<uint8_t> setup={0xf3,0x31,0x00,0xf0,
            0x01,0x00,0x05,0x11,0x00,0x05,0x21,0x00,0x05,
            0x3e,uint8_t(mode?0x80:0),0xa7,uint8_t(mode?0x37:0x00),0xc3,0x00,0x02};
        std::copy(setup.begin(),setup.end(),memory.begin()+0x100);
        memory[0x200]=op;memory[0x201]=0x00;memory[0x202]=0x05;
        memory[0xf000]=0x00;memory[0xf001]=0x05;
        uint64_t first=0,last=0;unsigned next=0;
        for(uint64_t tick=0;tick<30000;tick++) {
            cpu.clk=0;cpu.reset=tick<1000;cpu.pause=0;cpu.irq=0;
            cpu.din=(cpu.status&0x40)?0xa5:memory[cpu.address];cpu.eval();
            if (!cpu.reset && cpu.read_start && (cpu.status&0x20)) {
                if(first) {last=tick;next=cpu.address;break;}
                if(cpu.address==0x200) first=tick;
            }
            if (!cpu.reset && cpu.write_start && !(cpu.status&0x10)) memory[cpu.address]=cpu.dout;
            cpu.clk=1;cpu.eval();
        }
        const unsigned wanted=expected(op,mode);
        const bool pass=first && last && last-first==wanted*25;
        report<<op<<','<<mode<<','<<wanted<<','<<(last?last-first:0)<<','<<next<<','<<pass<<'\n';
        cases++;
        if(!pass) {failures++;std::cerr<<"FAIL opcode="<<std::hex<<op<<std::dec<<" flags="<<mode
            <<" expected="<<wanted*25<<" clocks observed="<<(last?last-first:0)<<'\n';}
        cpu.final();
    }
    std::cout<<"Documented 8080 cadence cases="<<cases<<" failures="<<failures
        <<"; HALT and undocumented opcodes excluded\n";
    return failures?1:0;
}
