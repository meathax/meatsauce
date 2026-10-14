#include "Vhiscore_timer_checks.h"
#include <cstdint>
#include <cstdio>
#include <stdexcept>

int main() {
    Vhiscore_timer_checks dut;
    unsigned checks=0;
    auto check = [&](uint32_t timer) {
        dut.timer=timer; dut.eval();
        if(dut.result!=timer-uint32_t(1)) throw std::runtime_error("32-bit timer decrement mismatch");
        ++checks;
    };
    // Every two-byte pattern at every byte alignment, with zero/one prefixes
    // to exercise each borrow boundary independently, including total wrap.
    for(unsigned byte=0;byte<4;++byte) for(uint32_t value=0;value<65536;++value) {
        uint32_t timer=value<<(byte*8);
        check(timer); check(timer|0x01010101); check(timer|0x80808080);
    }
    uint32_t random=0x9e3779b9;
    for(unsigned i=0;i<1048576;++i) {
        random^=random<<13; random^=random>>17; random^=random<<5;
        check(random);
    }
    std::printf("PASS hiscore decrement: %u 32-bit comparisons including every byte borrow\n",checks);
}
