// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vvr0_dma.h"
#include "verilated.h"
#include "../obj_dir/dma_reference/vr0_reference.hpp"
#include <cstdio>
#include <stdexcept>
#include <array>

static vluint64_t ticks=0;
double sc_time_stamp(){return double(ticks);}
static uint32_t rng=0xD0A03208;
static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;return rng^=rng<<5;}
struct Test {
    Vvr0_dma dut;
    ByteBus memory;
    bool pending=false, inject_error=false;
    unsigned delay=0,events=0,requests=0;
    uint32_t reply=0;
    void tick(){
        dut.clk=0;dut.req_ready=!pending && ((random32()&3)!=0);
        dut.rsp_valid=pending && !delay;dut.rsp_data=reply;dut.rsp_error=inject_error;dut.eval();++ticks;
        const bool accept=dut.req_valid && dut.req_ready,response=dut.rsp_valid;
        const uint32_t address=dut.req_address,data=dut.req_data;const unsigned lanes=dut.req_strobe;const bool write=dut.req_write;
        dut.clk=1;dut.eval();++ticks;
        if(dut.reset){pending=false;return;}
        if(pending && delay)--delay;if(response)pending=false;
        if(accept){
            if(pending || (address&3) || !lanes)throw std::runtime_error("DMA bus protocol");
            ++requests;pending=true;delay=1+random32()%7;
            if(write && !inject_error)for(unsigned lane=0;lane<4;++lane)if(lanes&(1<<lane))memory.write_byte(address+lane,uint8_t(data>>(lane*8)));
            reply=memory.read_dword(address);
        }
        events |= dut.completion;
    }
    void reset(){dut.reg_valid=0;dut.reset=1;tick();dut.reset=0;events=0;inject_error=false;}
    uint32_t access(unsigned address,bool write=false,uint32_t data=0,unsigned strobe=15,bool error=false){
        dut.reg_address=address;dut.reg_data=data;dut.reg_strobe=strobe;dut.reg_write=write;dut.reg_valid=1;tick();
        if(!dut.reg_ready || !dut.reg_rsp_valid || bool(dut.reg_rsp_error)!=error)throw std::runtime_error("DMA register response");
        dut.reg_valid=0;return dut.reg_rsp_data;
    }
    void descriptor(unsigned channel,uint32_t src,uint32_t dst,uint32_t count){access(channel*16+4,true,src);access(channel*16+8,true,dst);access(channel*16+12,true,count);}
    void finish(){
        for(unsigned timeout=0;timeout<20000;++timeout){tick();if(dut.fault)throw std::runtime_error("DMA transfer fault");if(!dut.busy && !pending)return;}
        throw std::runtime_error("DMA deadline timeout");
    }
};
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);Test t;unsigned cases=0;
    try {
        for(unsigned width=0;width<4;++width)for(unsigned srcmode=0;srcmode<4;++srcmode)for(unsigned dstmode=0;dstmode<4;++dstmode)
        for(unsigned size: {0u,1u,3u,17u})for(unsigned alignment=0;alignment<4;++alignment){
            t.reset();t.memory=ByteBus{};
            for(unsigned address=0;address<0x1000;++address)t.memory.write_byte(address,uint8_t(random32()));
            t.memory.trace_writes=true;ByteBus expected=t.memory;
            const unsigned channel=cases&1,control=0x400|width|(srcmode<<4)|(dstmode<<2);
            const uint32_t src=0x180+alignment,dst=0x880+((alignment+1)&3);
            vr0_reference reference;reference.m_host_space=&expected;
            reference.m_dma[channel].src=src;reference.m_dma[channel].dst=dst;reference.m_dma[channel].size=size;
            reference.dmac_w<0>(0,channel==0?control:0);reference.dmac_w<1>(0,channel==1?control:0);
            t.descriptor(channel,src,dst,size);t.access(channel*16,true,control);t.finish();
            if(t.memory.writes!=expected.writes || t.events!=(1u<<channel) || t.access(channel*16)!=reference.m_dma[channel].ctrl || t.access(channel*16+12)!=0 || t.access(channel*16+4)!=src || t.access(channel*16+8)!=dst)
                throw std::runtime_error("DMA mismatch with extracted MAME transfer");
            ++cases;
        }
        // Program and queue channel 1 while channel 0 is actively transferring.
        t.reset();t.memory=ByteBus{};for(unsigned a=0;a<0x1000;++a)t.memory.write_byte(a,uint8_t(random32()));t.memory.trace_writes=true;
        ByteBus expected=t.memory;vr0_reference reference;reference.m_host_space=&expected;
        reference.m_dma[0].src=0x100;reference.m_dma[0].dst=0x400;reference.m_dma[0].size=32;
        reference.m_dma[1].src=0x200;reference.m_dma[1].dst=0x600;reference.m_dma[1].size=17;
        reference.dmac_w<0>(0,0x402);reference.dmac_w<1>(0,0x401);
        t.descriptor(0,0x100,0x400,32);t.access(0,true,0x402);
        t.descriptor(1,0x200,0x600,17);t.access(16,true,0x401);t.finish();
        if(t.events!=3 || t.memory.writes!=expected.writes)throw std::runtime_error("dual-channel queued DMA mismatch");
        // Partial register writes and explicit rejection of unsupported repeats.
        t.reset();t.access(4,true,0x11223344);t.access(4,true,0xaabbccdd,5);
        if(t.access(4)!=0x11bb33dd)throw std::runtime_error("DMA byte enables");
        // DMATCx is a 24-bit register (MAME master).
        t.reset();t.access(12,true,0xffffffff);if(t.access(12)!=0x00ffffff)throw std::runtime_error("DMA count is 24 bits");
        t.reset();t.access(4,true,0x11223344);t.access(4,true,0xaabbccdd,5);
        t.access(0,true,0x440,15,true);if(t.dut.busy)throw std::runtime_error("repeat mode silently executed");
        t.reset();t.descriptor(0,0x100,0x400,3);t.inject_error=true;t.access(0,true,0x402);
        for(unsigned i=0;i<100 && !t.dut.fault;++i)t.tick();
        if(!t.dut.fault || t.dut.fault_address!=0x100 || t.events)throw std::runtime_error("DMA bus error not visible");
        std::printf("PASS VRender0 DMA: %u extracted-MAME transfer cases; widths/counts/hold/directions/unaligned lanes, queued channels, register byte enables, latency/backpressure and explicit unsupported/bus errors; %u requests\n",cases,t.requests);
        return 0;
    }catch(const std::exception& error){std::fprintf(stderr,"FAIL VRender0 DMA: %s case=%u clock=%llu\n",error.what(),cases,(unsigned long long)(ticks/2));return 1;}
}
