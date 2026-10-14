#include "Vopl_gain_checks.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <iostream>
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    Vopl_gain_checks dut;
    uint64_t checks=0;
    // Normal slot, each rhythm slot, and the empty/default slot selector.
    for(unsigned slot : {0u,1u,2u,4u,8u,16u,32u,64u})
    for(unsigned rhythm=0;rhythm<2;rhythm++)
    for(unsigned volume=0;volume<256;volume++)
    for(int sample=-4096;sample<4096;sample++) {
        dut.slot=slot; dut.rhy_en=rhythm; dut.volume=volume;
        dut.sample=sample & 8191; dut.clk=0; dut.eval();
        int scaled=sample*((rhythm && (slot & 63))?2:1)*int(slot?volume:16);
        // Arithmetic right shift with floor rounding for negative products.
        int expected=scaled>=0?scaled/16:-((-scaled+15)/16);
        expected=std::clamp(expected,-8192,8191);
        int actual=dut.gain; if(actual & 8192) actual-=16384;
        if(actual!=expected) {
            std::cerr<<"gain mismatch slot="<<slot<<" rhythm="<<rhythm
                <<" volume="<<volume<<" sample="<<sample
                <<" actual="<<actual<<" expected="<<expected<<"\n";
            return 1;
        }
        ++checks;
    }
    std::cout<<"OPL gain/clamp PASS comparisons="<<checks<<"\n";
}
