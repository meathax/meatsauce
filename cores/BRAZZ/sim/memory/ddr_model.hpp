// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <deque>
#include <stdexcept>
#include <vector>
// Avalon timing model for the reserved MiSTer ROM window. Memory reads use
// actual accepted bursts, with waitrequest and independently delayed beats.
struct DdrModel {
    std::vector<uint8_t> bytes=std::vector<uint8_t>(0x7020000,0); // up to 7 cartridge banks + BIOS
    struct Beat {uint64_t cycle;uint64_t data;};
    std::deque<Beat> pending;
    uint64_t cycles=0,reads=0,writes=0,beats=0,busy_cycles=0;
    uint32_t random=0x43534444;
    struct Command {bool read,write;uint32_t address;unsigned burst,be;uint64_t data;};
    bool stalled=false;Command held{};
    uint32_t next(){random^=random<<13;random^=random>>17;random^=random<<5;return random;}
    void check(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
    uint64_t word(uint32_t address){
        check(address>=0x6000000,"DDR address below reserved window");
        uint32_t offset=(address-0x6000000)*8;
        check(uint64_t(offset)+8<=bytes.size(),"DDR address above reserved window");
        uint64_t value=0;for(unsigned b=0;b<8;b++)value|=uint64_t(bytes[offset+b])<<(8*b);
        return value;
    }
    template<class V> static auto resetting(const V& d,int)->decltype(bool(d.memory_reset)){return d.memory_reset;}
    template<class V> static bool resetting(const V& d,long){return d.reset;}
    Command current{};bool current_accepted=false;
    template<class V> void prepare(V& d){
        ++cycles;d.clk=0;
        d.DDRAM_BUSY=(next()%4)==0;busy_cycles+=d.DDRAM_BUSY;
        d.DDRAM_DOUT_READY=!pending.empty()&&pending.front().cycle==cycles;
        if(d.DDRAM_DOUT_READY)d.DDRAM_DOUT=pending.front().data;
        d.eval();
        Command command{bool(d.DDRAM_RD),bool(d.DDRAM_WE),d.DDRAM_ADDR,d.DDRAM_BURSTCNT,d.DDRAM_BE,d.DDRAM_DIN};
        check(!(command.read&&command.write),"DDR simultaneous read/write");
        if(resetting(d,0))stalled=false;
        if(stalled){
            check(command.read==held.read&&command.write==held.write&&command.address==held.address&&command.burst==held.burst&&command.be==held.be&&command.data==held.data,"DDR command changed under waitrequest");
        }
        bool accepted=(command.read||command.write)&&!d.DDRAM_BUSY;
        stalled=(command.read||command.write)&&d.DDRAM_BUSY;held=command;
        current=command;current_accepted=accepted;
    }
    template<class V> void finish(V& d,bool falling_edge=true){
        const auto& command=current;bool accepted=current_accepted;
        d.clk=1;d.eval();
        if(d.DDRAM_DOUT_READY){pending.pop_front();++beats;}
        if(accepted&&command.read){
            check(pending.empty()&&command.burst==8&&command.be==255,"DDR invalid/overlapping line read");
            uint64_t due=cycles+20+next()%51;
            for(unsigned i=0;i<8;i++){pending.push_back({due,word(command.address+i)});due+=1+next()%4;}
            ++reads;
        }
        if(accepted&&command.write){
            check(command.burst==1,"DDR loader write must be one beat");word(command.address);
            uint32_t offset=(command.address-0x6000000)*8;
            for(unsigned b=0;b<8;b++)if(command.be&(1u<<b))bytes[offset+b]=command.data>>(8*b);
            ++writes;
        }
        if(falling_edge){d.clk=0;d.eval();}
    }
    template<class V> void step(V& d){prepare(d);finish(d);}
};
