// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vvr0_control.h"
#include "verilated.h"
#include <cstdio>
#include <stdexcept>
#include <cstdint>

static vluint64_t ticks=0;
double sc_time_stamp(){return double(ticks);}
struct Test {
    Vvr0_control dut;
    unsigned checks=0;
    void tick(){dut.clk=0;dut.eval();++ticks;dut.clk=1;dut.eval();++ticks;}
    void require(bool condition,const char* message){++checks;if(!condition)throw std::runtime_error(message);}
    void reset(){dut.req_valid=0;dut.interrupt_events=0;dut.reset=1;tick();dut.reset=0;tick();}
    uint32_t access(uint32_t address,bool write=false,uint32_t data=0,uint8_t strobe=15,bool error=false){
        dut.req_address=address;dut.req_write=write;dut.req_data=data;dut.req_strobe=strobe;dut.req_valid=1;
        dut.clk=0;dut.eval();require(dut.req_ready,"MMIO request refused");tick();
        require(dut.rsp_valid,"MMIO response missing");require(bool(dut.rsp_error)==error,"MMIO error policy");
        const uint32_t result=dut.rsp_data;dut.req_valid=0;return result;
    }
    void event(uint32_t mask){dut.interrupt_events=mask;tick();dut.interrupt_events=0;}
};
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);Test t;
    try {
        t.reset();t.require(!t.dut.irq && t.dut.timer_active==0,"reset outputs");
        t.require(t.access(0)==0xa00 && t.access(4)==0x41,"chip identity");
        t.access(0x4000,true,4);t.access(0x4004,true,0x3420);
        t.require(t.dut.pll_control==4 && t.dut.pll_program==0x3420,"PLL configuration capture");
        t.access(0x4004,true,0xaabbccdd,2);t.require(t.dut.pll_program==0xcc20,"PLL byte enable");
        t.require(t.access(0x4000)==0 && t.access(0x4004)==0 && t.access(0x10)==0 && t.access(0x14)==0,
                  "MAME unmapped/nop platform and watchdog reads return zero");
        t.access(0x10,true,0x12345678);t.require(t.access(0x10)==0,"watchdog write/readback is nop");
        // UART0/1 (MAME vr0uart): reset UCON=1, UBDR=1, empty receive FIFO; TX holds USTAT bits 5/6 for one
        // frame (768*(UBDR+1) clocks per bit) then raises interrupt 15 (UART0) / 18 (UART1).
        t.require(t.access(0x1000)==1&&t.access(0x1010)==1&&t.access(0x100c)==0&&t.access(0x1020)==1,"UART reset registers");
        t.access(0x0c08,true,(1u<<15)|(1u<<18));t.access(0x1010,true,0);t.access(0x1000,true,0x103);
        t.access(0x1008,true,0x41);t.require((t.access(0x1004)&0x60)==0x60,"UART TX busy");
        for(int i=0;i<11*768+4;i++)t.tick();
        t.require((t.access(0x1004)&0x60)==0&&(t.access(0x0c0c)&(1u<<15)),"UART TX complete interrupt");
        t.access(0x0c04,true,15);t.access(0x0c08,true,0);
        t.require(t.access(0xc00)==0,"native MAME interrupt-map hole read");
        t.access(0xc00,true,0x1800,3);t.access(0xc00,true,0x2000,3);
        t.require(t.access(0xc00)==0 && !t.dut.irq && !t.dut.interrupt_enable && !t.dut.interrupt_status,
                  "interrupt-map hole write changed live controller");
        t.event(1u<<24);t.require(!t.dut.irq,"disabled event latched");
        t.access(0xc08,true,0xffffffff);t.access(0xc04,true,0x500,2);
        for(unsigned bit=0;bit<32;++bit){
            t.event(1u<<bit);t.require(t.dut.irq && t.dut.irq_vector==(0xa0|bit),"IRQ source/vector");
            t.require(t.access(0xc0c)==(1u<<bit),"IRQ status read");
            t.access(0xc04,true,bit,1);t.require(!t.dut.irq,"IRQ software acknowledge");
        }
        t.event((1u<<31)|(1u<<17));t.require(t.dut.irq_vector==(0xa0|17),"IRQ lowest-number priority");
        t.access(0xc04,true,17,1);t.require(t.dut.irq_vector==0xbf,"IRQ priority after acknowledge");
        t.access(0xc0c,true,0xffffffff);t.require(t.dut.irq,"INTST write unexpectedly acknowledged");
        t.access(0xc08,true,0);t.require(!t.dut.irq,"disable did not clear pending status");
        t.access(0xc08,true,0xffffffff);t.event(1u<<7);
        t.dut.interrupt_events=1u<<7;t.access(0xc04,true,7,1);t.dut.interrupt_events=0;
        t.require(t.dut.irq,"simultaneous IRQ event lost during acknowledge");
        t.access(0xc04,true,7,1);t.require(!t.dut.irq,"new event could not be acknowledged");
        const unsigned sources[]={0,1,9,10};
        for(unsigned timer=0;timer<4;++timer)for(unsigned pd: {0u,1u,3u,255u}) {
            t.reset();t.access(0xc08,true,1u<<sources[timer]);
            t.access(0x1404+timer*8,true,2);
            t.access(0x1400+timer*8,true,(pd<<8)|1);
            const unsigned period=2*(pd+1)*3;
            t.require(!t.dut.irq,"timer fired on start");
            for(unsigned i=1;i<period;++i){t.tick();t.require(!t.dut.irq,"timer fired early");}
            t.tick();t.require(t.dut.irq,"timer missed deadline");
            t.require(!(t.dut.timer_active&(1<<timer)),"one-shot timer stayed active");
            t.require((t.access(0x1400+timer*8)&1)==0,"one-shot enable did not clear");
            t.require(t.access(0x1404+timer*8)==0x00000002,"timer reload readback (upper half unmapped zero)");
        }
        // Periodic reload uses the new divider/count only at the next expiry;
        // changing parameters must not restart the current scheduled period.
        t.reset();t.access(0xc08,true,1);t.access(0x1404,true,4);t.access(0x1400,true,3);
        t.tick();t.tick();t.access(0x1404,true,1);t.access(0x1400,true,0x103);
        for(unsigned i=0;i<5;++i){t.tick();t.require(!t.dut.irq,"running timer rescheduled early");}
        t.tick();t.require(t.dut.irq && t.dut.timer_active==1,"periodic first expiry");
        t.access(0xc04,true,0,1);
        for(unsigned i=0;i<6;++i){t.tick();t.require(!t.dut.irq,"periodic reload early");}
        t.tick();t.require(t.dut.irq,"periodic reload missed");
        t.access(0x1400,true,0);t.access(0xc04,true,0,1);
        for(unsigned i=0;i<32;++i)t.tick();t.require(!t.dut.irq,"stopped timer fired");
        // Maximum divisor/count fits the full 26-bit period without overflow.
        t.reset();t.access(0xc08,true,1);t.access(0x1404,true,0xffff);t.access(0x1400,true,0xff01);
        for(unsigned i=0;i<2048;++i)t.tick();t.require(!t.dut.irq && t.dut.timer_active==1,"maximum timer overflow");
        // MAME oracle (scripts/mame/control_probe.lua): 16-bit timer count behind umask32 0xffff,
        // byte-lane combine, upper-half writes ignored, full 32-bit control readback.
        t.reset();
        t.access(0x1404,true,0xffffffff);t.require(t.access(0x1404)==0x0000ffff,"timer count w32 readback");
        t.access(0x1404,true,0);t.access(0x1404,true,0x1200,2);t.require(t.access(0x1404)==0x1200,"timer count byte lane 1");
        t.access(0x1404,true,0x55550000,12);t.require(t.access(0x1404)==0x1200,"timer count upper-half write ignored");
        t.access(0x1404,true,0xabcd1234);t.require(t.access(0x1404)==0x00001234,"timer count w32 low half only");
        t.access(0x1400,true,0xdeadbeee);t.require(t.access(0x1400)==0xdeadbeee,"timer control full 32-bit readback");
        t.access(0x1400,true,0xff00);
        // INTVEC w32 0xfffffe1f acknowledges source 31 and selects vector group 6; INTEN lane combine.
        t.access(0xc08,true,0x11223344);t.access(0xc08,true,0xaa0000,4);
        t.require(t.access(0xc08)==0x11aa3344,"INTEN byte lane 2");
        t.access(0xc08,true,0xffffffff);t.event(1u<<31);
        t.access(0xc04,true,0xfffffe1f);
        t.require(!t.dut.irq && t.access(0xc04)==0x600,"INTVEC w32 acknowledge and vector group");
        t.event(1u<<3);t.require(t.dut.irq_vector==(0xc0|3),"vector group applied to next source");
        t.access(0xc04,true,0x0705,3);t.require(t.dut.irq && t.access(0xc04)==0x700,"INTVEC halfword combine");
        t.access(0xc04,true,3,1);t.require(!t.dut.irq,"ack after vector change");
        std::printf("PASS VRender0 control: %u checks; 32 IRQ sources/priority/ack, byte lanes, four timer deadlines/reload/stop, platform configuration and unknown-device errors\n",t.checks);
        return 0;
    }catch(const std::exception& error){std::fprintf(stderr,"FAIL VRender0 control: %s at clock=%llu\n",error.what(),(unsigned long long)(ticks/2));return 1;}
}
