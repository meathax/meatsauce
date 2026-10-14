// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vse3208_execute.h"
#include "verilated.h"
#include "../obj_dir/cpu_reference/se3208_reference.hpp"
#include <array>
#include <cstdio>
#include <memory>
#include <string>
#include <unordered_set>

double sc_time_stamp() { return 0; }
static uint32_t random_state = 0x3208cafe;
static uint32_t random32() { random_state ^= random_state << 13; random_state ^= random_state >> 17; return random_state ^= random_state << 5; }
int main(int argc, char** argv) {
    Verilated::commandArgs(argc,argv);
    const std::unordered_set<std::string> families = {
        "ADC","ADCI","ADD","ADDI","AND","ANDI","ASL","ASR","CLR","CMP","CMPI",
        "EXTB","EXTS","LDI","LERI","LSR","MOV","MULS","NEG","OR","ORI","SBC","SBCI",
        "SET","SUB","SUBI","TST","TSTI","XOR","XORI"
    };
    const std::array<uint32_t,16> edges = {0,1,0xffffffff,0x80000000,0x7fffffff,0x80000001,0xfffffffe,2,31,32,0xffff,0x10000,0xaaaa5555,0x5555aaaa,0x80,0xff};
    auto reference = std::make_unique<se3208_device>();
    Vse3208_execute dut;
    unsigned tests=0, encodings=0;
    for (unsigned opcode=0;opcode<65536;++opcode) {
        const std::string name=reference->operation_name(uint16_t(opcode));
        if (!families.count(name)) continue;
        if ((name=="EXTB" || name=="EXTS") && (opcode&8)) continue;
        ++encodings;
        for (unsigned trial=0;trial<32;++trial) {
            std::array<uint32_t,8> before;
            for(unsigned i=0;i<8;++i) {
                before[i] = trial<16 ? edges[(trial+i)&15] : random32();
                reference->m_R[i] = dut.registers[i] = before[i];
            }
            reference->m_PC=0x100; reference->m_SP=0x2000;
            reference->m_SR=dut.sr=random32(); reference->m_ER=dut.er=random32();
            reference->m_IRQ=0; reference->m_NMI=0;
            reference->m_program.write_word(0x100,uint16_t(opcode));
            dut.opcode=opcode; dut.eval(); reference->step();
            bool mismatch=!dut.supported || dut.next_sr!=reference->m_SR || dut.next_er!=reference->m_ER;
            for(unsigned i=0;i<8;++i) {
                const uint32_t actual=(dut.register_write && dut.register_index==i) ? dut.register_data : before[i];
                mismatch |= actual!=reference->m_R[i];
            }
            if(mismatch) {
                std::fprintf(stderr,"FAIL %s opcode=%04x trial=%u SR RTL=%08x MAME=%08x ER RTL=%08x MAME=%08x dst=%u data=%08x\n",name.c_str(),opcode,trial,dut.next_sr,reference->m_SR,dut.next_er,reference->m_ER,dut.register_index,dut.register_data);
                for(unsigned i=0;i<8;++i) std::fprintf(stderr,"R%u before=%08x MAME=%08x\n",i,before[i],reference->m_R[i]);
                return 1;
            }
            ++tests;
        }
    }
    std::printf("PASS SE3208 register execution: %u cases across %u encodings / %zu families; flags, extension chains, shifts and multiply match MAME\n",tests,encodings,families.size());
    return 0;
}
