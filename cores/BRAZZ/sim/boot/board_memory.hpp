// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <vector>
#include <stdexcept>
#include <cstdint>
#include <utility>
struct Memory {
    const std::vector<uint8_t>& bios;
    const std::vector<uint8_t>& flash;
    std::vector<uint8_t> ram=std::vector<uint8_t>(0x1800000,0);
    std::array<uint8_t,0x10000> nvram{};
    std::array<uint8_t,0x34> reset_ram{};
    unsigned bank=0;
    std::vector<std::pair<uint32_t,uint8_t>> writes;
    Memory(const std::vector<uint8_t>& b,const std::vector<uint8_t>& f):bios(b),flash(f) {
        const std::array<uint32_t,6> code={0x40c0ea01,0xe906400a,0x40c02a20,0xe906400a,0xa1d03a20,0xdef4d4fa};
        for(unsigned i=0;i<code.size();++i) for(unsigned j=0;j<4;++j) reset_ram[i*4+j]=uint8_t(code[i]>>(j*8));
    }
    std::pair<unsigned,uint32_t> decode(uint32_t a) const {
        if(a<=0x1ffff) return {0,a};
        if(a>=0x02000000 && a<=0x02ffffff) return {1,a&0x7fffff};
        if(a>=0x03800000 && a<=0x03ffffff) return {2,a&0x7fffff};
        if(a>=0x04000000 && a<=0x047fffff) return {3,a&0x7fffff};
        if(a>=0x05000000 && a<=0x05ffffff) return {4,(bank<<24)|(a&0xffffff)};
        if(a>=0x01400000 && a<=0x0140ffff) return {5,a&0xffff};
        if(a>=0x01800000 && a<=0x01ffffff) return {6,a&0x7fffff};
        if(a>=0x03000000 && a<=0x0300ffff) return {7,a&0xffff};
        if(a>=0x04800000 && a<=0x04800fff) return {8,a&0xfff};
        if(a>=0x01200000 && a<=0x0120000b) return {9,a-0x01200000};
        if(a>=0x01280000 && a<=0x01280003) return {10,a-0x01280000};
        if(a>=0x01320000 && a<=0x01320003) return {11,a-0x01320000};
        if(a>=0x44414f4c && a<=0x44414f7f) return {12,a-0x44414f4c};
        return {15,a};
    }
    uint8_t read(uint32_t a) {
        auto [target,offset]=decode(a);
        switch(target) {
            case 0:return bios.at(offset);
            case 1:return ram.at(offset);
            case 2:return ram.at(0x800000+offset);
            case 3:return ram.at(0x1000000+offset);
            case 4:return offset<flash.size()?flash[offset]:0xff;
            case 5:return nvram.at(offset);
            case 12:return reset_ram.at(offset);
            default:throw std::runtime_error("unimplemented mapped device");
        }
    }
    void write(uint32_t a,uint8_t value) {
        auto [target,offset]=decode(a);
        switch(target) {
            case 0:break; // MAME ROM ignores writes.
            case 1:ram.at(offset)=value;break;
            case 2:ram.at(0x800000+offset)=value;break;
            case 3:ram.at(0x1000000+offset)=value;break;
            case 5:nvram.at(offset)=value;break;
            case 10:if(!offset)bank=(value>>1)&7;break;
            case 12:reset_ram.at(offset)=value;break;
            default:throw std::runtime_error("unimplemented mapped device");
        }
        writes.emplace_back(a,value);
    }
};
