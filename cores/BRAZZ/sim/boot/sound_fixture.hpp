// SPDX-License-Identifier: GPL-3.0-or-later
// Test BIOS only: all board state is established by real reset/fetch/execute.
#pragma once
#include <vector>
#include <cstdint>
void sound_fixture_reference_reset();
void sound_fixture_reference_render(int32_t*,int32_t*);
inline std::vector<uint8_t> sound_fixture_bios(){
    std::vector<uint8_t> bios(131072,0);
    auto word=[&](unsigned address,uint32_t value){for(unsigned i=0;i<4;++i)bios.at(address+i)=uint8_t(value>>(i*8));};
    word(0,0x100);word(8,0x800); // reset PC, IRQ vector 2
    unsigned pc=0x100;
    auto emit=[&](uint16_t opcode){bios.at(pc++)=uint8_t(opcode);bios.at(pc++)=uint8_t(opcode>>8);};
    auto ldi=[&](unsigned reg,uint32_t value){
        emit(uint16_t(0x4000|((value>>18)&0x3fff)));
        emit(uint16_t(0x4000|((value>>4)&0x3fff)));
        emit(uint16_t(0xe800|(reg<<8)|(value&15)));
    };
    auto write=[&](uint32_t address,uint32_t value){ldi(1,address);ldi(0,value);emit(0x3020);};
    auto write16=[&](uint32_t address,uint32_t value){ldi(1,address);ldi(0,value);emit(0x2820);};
    auto save_r0=[&](uint32_t address){ldi(1,address);emit(0x3020);};
    auto read=[&](uint32_t address){ldi(1,address);emit(0x1020);};
    // Exercise real CP0 and cache hits in the same reset-driven sound/IRQ BIOS.
    ldi(0,0x800);emit(0xfc67);emit(0xfc6e);save_r0(0x0200070c);
    read(0x01200008);save_r0(0x02000710);
    read(0x01200008);save_r0(0x02000714); // bench changes DIP pins between reads
    // Main-RAM mirrors must share cache tags and see writes through either view.
    write(0x02000718,0x12345678);read(0x02800718);save_r0(0x0200071c);
    write(0x02000718,0xcafebeef);read(0x02800718);save_r0(0x02000720);
    write(0x02800718,0x5a5aa5a5);read(0x02000718);save_r0(0x02000724);
    ldi(1,0x021ff000);emit(0xa1ca); // LEATOSP 0(R1)
    write(0x02000700,0);write(0x02000704,0);write(0x02000708,0);
    write(0x04000000,0x7f7f7f7f);write(0x04000004,0x7f7f7f7f);
    for(unsigned c:{0u,31u}){
        uint32_t base=0x04800000+c*32;
        write(base,0);write(base+4,0x107f0000);write(base+8,(0x2000u<<16)|0x100u);
        write(base+12,(c==0?0x7f000000:0x20000000));
        write(base+16,(c==0?0x40000001:0x60000001));
        write(base+20,0);write(base+24,0);write(base+28,0);
    }
    write(0x04800600,0x00001f1d); // RS disabled, max31, clock29
    write(0x04800480,0);write(0x04800500,0xffffffff);
    write(0x01800c08,4); // enable sound IRQ2 only
    write16(0x04800404,0x8000);write16(0x04800404,0x801f);
    emit(0xe0ad); // SET SR.ENI
    write(0x04800600,0x80001f1d); // atomic CHNNUM/CTRL, start sound
    emit(0xdeff); // idle at the same instruction; IRQ drives progress
    if(pc>=0x800)throw std::runtime_error("test BIOS overlaps IRQ handler");
    pc=0x800;
    emit(0x9107); // preserve R0-R2 and ER; SR/PC already stacked by IRQ
    read(0x01800c0c);save_r0(0x02000704);
    read(0x04800500);save_r0(0x02000708);
    ldi(1,0x04800500);emit(0x3020); // W1C exactly observed sound pending
    write(0x01800c04,2); // SoC INTVEC acknowledge
    read(0x02000700);emit(0xea01);emit(0xc400);emit(0x3020); // ++IRQ counter
    emit(0x9907);emit(0x9e00); // restore GPR/ER, then SR/PC
    return bios;
}
