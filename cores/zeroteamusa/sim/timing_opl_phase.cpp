#include "Vtiming_opl_phase.h"
#include "sine_table.h"
#include <array>
#include <cstdio>
#include <stdexcept>

int main() {
    Vtiming_opl_phase dut;
    std::array<unsigned,3> shift{};
    unsigned last_ce=0,last_op=0,min_ce=1000000,min_op=1000000,captures=0;
    unsigned last_slot=0,min_slot_to_observed_gain=1000000;
    for(unsigned tick=1;tick<=240000;++tick) {
        dut.clk=0; dut.pause=(tick%4096)>=3800;
        dut.reset=(tick%8192)>=8080; dut.din=(tick*73)^tick;
        dut.operator_data=(tick*17)&8191; dut.rhythm=(tick/31)&1;
        dut.eval();
        bool ce=dut.ce_z80, op=dut.cenop;
        unsigned old_lookup=dut.lookup,old_shift=dut.shifted;
        unsigned expected=sine_table[shift[2]];
        int held=(dut.held_operator&4096) ? int(dut.held_operator)-8192 : int(dut.held_operator);
        int gained=(dut.rhythm && (dut.slot&63)) ? held*2 : held;
        if(ce) {if(last_ce) min_ce=std::min(min_ce,tick-last_ce);last_ce=tick;}
        if(op) {
            // The free-running gain register was sampled one clock before
            // this enabled consumer event, after the slot had settled.
            if(last_slot) min_slot_to_observed_gain=std::min(min_slot_to_observed_gain,tick-1-last_slot);
            last_slot=tick;
            if(last_op) min_op=std::min(min_op,tick-last_op);
            last_op=tick;
            shift[2]=shift[1];shift[1]=shift[0];shift[0]=dut.din;
            ++captures;
        }
        dut.clk=1;dut.eval();
        if(dut.gain_result!=(unsigned(gained)&16383))
            throw std::runtime_error("gain register changed its unity-gain semantics");
        if(op) {
            if(captures>3 && (dut.lookup!=expected || dut.shifted!=shift[2]))
                throw std::runtime_error("enabled shift/ROM capture mismatch");
        } else if(dut.lookup!=old_lookup || dut.shifted!=old_shift)
            throw std::runtime_error("shift/ROM changed between enables");
    }
    if(min_ce<26 || min_op<107 || min_slot_to_observed_gain<106 || captures<2000)
        throw std::runtime_error("FM enable cadence violated");
    std::printf("PASS OPL phase: 240000 clocks, %u captures, min Z80 CE=%u, min operator CE=%u\n",
                captures,min_ce,min_op);
    std::printf("PASS OPL gain observation: slot settled for >=%u clocks before observed gain capture\n",
                min_slot_to_observed_gain);
}
