// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vvm80a_phase.h"
#include "verilated.h"
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    std::filesystem::path out=argc>1?argv[1]:"phase-evidence";
    std::filesystem::create_directories(out);
    std::ofstream result(out/"aperture.csv");
    result<<"phase_mode,irq_offset_from_final_phi2,first_lda_sync,irq_tick,return_pc,following_cycle_sync,ana_opcode_sync,final_tstate,final_mcycle,final_phase\n";
    unsigned errors=0;
    for(unsigned mode=0;mode<2;mode++) for(int offset:std::vector<int>{-26,-14,-2,-1,0,1,2,5,12,13,24,25,26}) {
        Vvm80a_phase cpu;
        cpu.level_mode=mode;cpu.irq=0;
        std::array<uint8_t,65536> memory{};
        memory[0]=0xc3;memory[1]=0;memory[2]=1;
        const uint8_t program[]={0xf3,0x31,0x00,0xf0,0x21,0x00,0x20,0x36,0x01,0xfb,0x00,
            0x3a,0x00,0x20,0xa7,0xc2,0x0b,0x01,0x76};
        std::copy(std::begin(program),std::end(program),memory.begin()+0x100);
        memory[8]=0x76;
        uint64_t anchor=0,irq_tick=0,following_sync=0,ana_sync=0;
        bool previous_sync=false,sent=false;
        unsigned final_tstate=0,final_mcycle=0,final_phase=0;
        std::ofstream wave(out/(std::string(mode?"levels":"pulses")+"_"+std::to_string(offset)+".csv"));
        wave<<"tick,phase,tstate,mcycle,sync,dbin,wr_n,address,status,irq,intr,inta,mstart\n";
        bool done=false;
        for(uint64_t tick=0;tick<10000;tick++) {
            cpu.clk=0;cpu.reset=tick<1000;
            if(anchor&&tick==anchor+299+offset){cpu.irq=1;sent=true;irq_tick=tick;}
            cpu.din=(cpu.status&1)?0xcf:memory[cpu.address];
            cpu.eval();
            if(!cpu.reset&&cpu.sync&&!previous_sync&&(cpu.dout&0x20)) {
                if(cpu.address==0x10b&&!anchor)anchor=tick;
                if(cpu.address==0x10e&&!following_sync)following_sync=tick;
                if(cpu.address==0x10e&&!(cpu.dout&1)&&!ana_sync)ana_sync=tick;
            }
            previous_sync=cpu.sync;
            if(anchor&&tick==anchor+299){final_tstate=cpu.tstate;final_mcycle=cpu.mcycle;final_phase=cpu.phase_debug;}
            if(anchor&&tick>=anchor+260&&tick<=anchor+450)
                wave<<tick<<','<<unsigned(cpu.phase_debug)<<','<<unsigned(cpu.tstate)<<','<<unsigned(cpu.mcycle)<<','
                    <<unsigned(cpu.sync)<<','<<unsigned(cpu.dbin)<<','<<unsigned(cpu.wr_n)<<','<<cpu.address<<','
                    <<unsigned(cpu.status)<<','<<unsigned(cpu.irq)<<','<<unsigned(cpu.intr_debug)<<','
                    <<unsigned(cpu.inta_debug)<<','<<unsigned(cpu.mstart_debug)<<'\n';
            if(!cpu.reset&&cpu.write_start) {
                memory[cpu.address]=cpu.dout;
                if(cpu.address==0xeffe&&sent) {
                    unsigned pc=(unsigned(memory[0xefff])<<8)|memory[0xeffe];
                    result<<(mode?"levels":"pulses")<<','<<offset<<','<<anchor<<','<<irq_tick<<','<<pc<<','
                        <<following_sync<<','<<ana_sync<<','<<final_tstate<<','<<final_mcycle<<','<<final_phase<<'\n';
                    std::cout<<(mode?"levels":"pulses")<<" IRQ offset="<<offset<<" return="<<std::hex<<pc<<std::dec
                        <<" LDA SYNC="<<anchor<<" ANA SYNC="<<ana_sync<<'\n';
                    if((pc!=0x10b&&pc!=0x10e&&pc!=0x10f)||following_sync-anchor!=325)errors++;
                    done=true;break;
                }
            }
            if(cpu.interrupt_ack)cpu.irq=0;
            cpu.clk=1;cpu.eval();
        }
        if(!done){std::cerr<<"FAIL timeout mode="<<mode<<" offset="<<offset<<'\n';errors++;}
    }
    std::cout<<"Interrupt aperture diagnostic complete; invalid/timeout cases="<<errors<<'\n';
    return errors?1:0;
}
