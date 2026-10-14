#include "Vaddress_decode_checks.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    Vaddress_decode_checks dut;
    uint64_t checks=0;
    for(unsigned enable=0;enable<2;enable++)
    for(unsigned dx=0;dx<2;dx++)
    for(unsigned bank=0;bank<2;bank++)
    for(unsigned dxbank=0;dxbank<16;dxbank++)
    for(unsigned addr=0;addr<(1u<<20);addr++) {
        dut.A=addr; dut.DBEN=enable; dut.board_dx=dx;
        dut.rom_bank=bank; dut.dx_prg_bank=dxbank; dut.eval();
        if(dut.mismatch) {
            std::cerr<<"decode mismatch addr="<<std::hex<<addr
                <<" DBEN="<<enable<<" DX="<<dx<<" bank="<<bank
                <<" DXbank="<<dxbank<<"\n";
            return 1;
        }
        ++checks;
    }
    std::cout<<"Address decoder equivalence PASS comparisons="<<checks<<"\n";
}
