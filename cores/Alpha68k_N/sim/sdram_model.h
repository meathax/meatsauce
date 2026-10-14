#pragma once
#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

// Pin-level SDR SDRAM model: commands are sampled on the forwarded half-cycle.
// CL=2, burst=1, four banks, 512 columns. This models the external device only.
struct Sdram {
    std::vector<uint16_t> memory=std::vector<uint16_t>(1u<<24,0xaaaa);
    std::vector<uint8_t> written=std::vector<uint8_t>(0x60000,0);
    std::array<int,4> row{{-1,-1,-1,-1}};
    std::array<uint64_t,4> active{},precharged{};
    uint64_t cycle=0,writes=0,reads=0,refreshes=0,modes=0;
    uint16_t dq=0;
    struct Pending {uint64_t due;unsigned address;};
    std::vector<Pending> pending;
    template<class T> void sample(T& top) {
        ++cycle;
        for(auto it=pending.begin();it!=pending.end();) {
            if(it->due==cycle) {dq=memory.at(it->address);it=pending.erase(it);}
            else ++it;
        }
        if(!top.sdram_cke) return;
        unsigned cmd=(top.sdram_ncs<<3)|(top.sdram_nras<<2)|(top.sdram_ncas<<1)|top.sdram_nwe;
        unsigned bank=top.sdram_ba,a=top.sdram_a;
        if(cmd==3) {
            if(row[bank]!=-1 || cycle-precharged[bank]<1)
                throw std::runtime_error("SDRAM ACTIVE without precharge");
            row[bank]=a; active[bank]=cycle;
        } else if(cmd==2) {
            if(a&0x400) for(unsigned b=0;b<4;b++) {row[b]=-1;precharged[b]=cycle;}
            else {row[bank]=-1;precharged[bank]=cycle;}
        } else if(cmd==0) {
            if((a&7)!=0 || ((a>>4)&7)!=2)
                throw std::runtime_error("unexpected SDRAM burst/CAS mode: cycle="+std::to_string(cycle)+" address="+std::to_string(a));
            modes++;
        } else if(cmd==1) {
            for(auto r:row) if(r!=-1) throw std::runtime_error("refresh with active row");
            refreshes++;
        } else if(cmd==4 || cmd==5) {
            if(row[bank]<0 || cycle-active[bank]<1)
                throw std::runtime_error("SDRAM access before ACTIVE/tRCD");
            unsigned address=(bank<<22)|(unsigned(row[bank])<<9)|(a&511);
            if(cmd==4) {
                uint16_t word=memory.at(address);
                if(!top.sdram_dqml) word=(word&0xff00)|(top.sdram_din&255);
                if(!top.sdram_dqmh) word=(word&0x00ff)|(top.sdram_din&0xff00);
                memory[address]=word;
                if(address*2<written.size()) {
                    if(!top.sdram_dqml) written[address*2]++;
                    if(!top.sdram_dqmh) written[address*2+1]++;
                }
                writes++;
            } else {pending.push_back({cycle+2,address});reads++;}
            if(a&0x400) {row[bank]=-1;precharged[bank]=cycle;}
        }
    }
};
