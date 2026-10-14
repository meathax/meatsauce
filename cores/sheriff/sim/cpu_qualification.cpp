// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vn8080_cpu.h"
#include "verilated.h"
#include <array>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vn8080_cpu cpu;
    std::array<uint8_t,65536> memory{};
    // Focused architectural assertions are performed by an actual instruction
    // stream. Failures identify the first output, rather than just final HALT.
    std::vector<uint8_t> program;
    auto emit = [&](std::initializer_list<uint8_t> bytes) {
        program.insert(program.end(), bytes.begin(), bytes.end());
    };
    emit({0xf3,0x31,0x00,0xf0});                       // DI; LXI SP,f000
    emit({0x3e,0x09,0xc6,0x09,0x27,0xd3,0x00});       // DAA 9+9 =>18
    emit({0x3e,0x99,0xc6,0x01,0x27,0xd3,0x00});       // DAA 99+1 =>00,C
    emit({0x3e,0x00,0xce,0x00,0xd3,0x00});            // ADC =>01
    emit({0x3e,0x55,0xf5,0xaf,0xf1,0xd3,0x00});       // PUSH/POP PSW
    emit({0x01,0x34,0x12,0xc5,0x01,0,0,0xc1,0x78,0xd3,0});
    emit({0x79,0xd3,0});                              // BC stack =>12,34
    emit({0x3e,0x80,0xd6,0x01,0xd3,0});               // SUB =>7f
    emit({0xdb,0x01,0xd3,0});                         // IN =>a5
    emit({0xfb,0x00,0x76});                           // EI; NOP; HALT
    const size_t halt_pc = program.size();
    // Interrupt handler: record an actual RST1 entry and disable/reenable.
    // Initial JMP keeps vectors separate from diagnostic program.
    memory[0]=0xc3; memory[1]=0x00; memory[2]=0x01;
    const uint8_t handler[]={0x3e,0x77,0xd3,0x00,0xfb,0xc9};
    std::copy(std::begin(handler),std::end(handler),memory.begin()+8);
    std::copy(program.begin(),program.end(),memory.begin()+0x100);
    memory[0x100+halt_pc]=0xc3;
    memory[0x101+halt_pc]=uint8_t(0x100+halt_pc);
    memory[0x102+halt_pc]=uint8_t((0x100+halt_pc)>>8);
    const std::vector<uint8_t> expected={0x18,0x00,0x01,0x55,0x12,0x34,0x7f,0xa5,0x77};
    size_t outputs=0; bool interrupt_sent=false, ack=false, cleared=false;
    std::ofstream trace("cpu_qualification.csv");
    trace << "tick,kind,address,data,status,inte\n";
    for (uint64_t tick=0;tick<500000;tick++) {
        cpu.clk=0; cpu.reset=tick<1000; cpu.pause=0;
        if (!interrupt_sent && outputs==8 && cpu.inte && (cpu.status & 8)) {
            cpu.irq=1; interrupt_sent=true;
        }
        cpu.din=(cpu.status&1)?0xcf:(cpu.status&0x40)?0xa5:memory[cpu.address];
        cpu.eval();
        if (!cpu.reset && cpu.write_start) {
            if (cpu.status&0x10) {
                trace<<tick<<",out,"<<cpu.address<<","<<unsigned(cpu.dout)<<","<<unsigned(cpu.status)<<","<<unsigned(cpu.inte)<<"\n";
                if (outputs>=expected.size() || cpu.dout!=expected[outputs]) {
                    std::cerr<<"FAIL output "<<outputs<<" expected "<<(outputs<expected.size()?unsigned(expected[outputs]):999)<<" got "<<unsigned(cpu.dout)<<" tick "<<tick<<"\n";
                    return 1;
                }
                ++outputs;
            } else memory[cpu.address]=cpu.dout;
        }
        if (cpu.interrupt_ack) { cpu.irq=0; ack=true; }
        if (ack && !cpu.inte) cleared=true;
        cpu.clk=1; cpu.eval();
        if (outputs==expected.size() && cleared) {
            std::cout<<"PASS: DAA/carry, stack, SUB, IN/OUT, EI/HALT wake, RST1 and INTE clear; ticks="<<tick<<"\n";
            return 0;
        }
    }
    std::cerr<<"FAIL timeout outputs="<<outputs<<" address="<<std::hex<<cpu.address<<" status="<<unsigned(cpu.status)<<" ack="<<ack<<" cleared="<<cleared<<"\n";
    return 1;
}
