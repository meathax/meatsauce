#include "Vhiscore_ram_checks.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>

int main() {
    Vhiscore_ram_checks dut;
    std::array<uint32_t,4> memory{};
    uint32_t random = 0x9e3779b9;
    unsigned checks = 0;
    auto cycle = [&](unsigned aa, unsigned ab, unsigned wa, unsigned wb,
                     uint32_t da, uint32_t db, bool verify) {
        dut.clk=0; dut.aa=aa; dut.ab=ab; dut.wa=wa; dut.wb=wb;
        dut.da=da; dut.db=db; dut.eval();
        uint32_t qa=wa ? da : memory[aa], qb=wb ? db : memory[ab];
        if (wa) memory[aa]=da;
        if (wb) memory[ab]=db; // Original procedural order gives B priority.
        dut.clk=1; dut.eval();
        if (verify && (dut.qa!=qa || dut.qb!=qb || dut.auto_qa!=qa || dut.auto_qb!=qb))
            throw std::runtime_error("registered dual-port memory contract mismatch");
        checks += verify;
    };
    for(unsigned i=0;i<4;++i) cycle(i,i,1,1,i,i,false);
    // All address pairs and read/write combinations, including simultaneous
    // same-address writes and cross-port old-data reads, with varied data.
    for(unsigned seed=0;seed<1024;++seed)
        for(unsigned aa=0;aa<4;++aa) for(unsigned ab=0;ab<4;++ab)
            for(unsigned enables=0;enables<4;++enables) {
                random ^= random<<13; random ^= random>>17; random ^= random<<5;
                uint32_t da=random & 0xffffff;
                random ^= random<<13; random ^= random>>17; random ^= random<<5;
                cycle(aa,ab,enables&1,(enables>>1)&1,da,random&0xffffff,true);
            }
    std::cout << "PASS hiscore RAM: " << checks << " registered dual-port cycles\n";
}
