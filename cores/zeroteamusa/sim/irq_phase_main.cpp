#include "Vzero_irq_phase_top.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc,argv);
    Vzero_irq_phase_top top;
    uint64_t last_ce=0,last_half=0,pulses=0,captures=0;
    uint64_t min_gap=UINT64_MAX,min_half_to_ce=UINT64_MAX;
    bool ce_valid=false,half_valid=false,expected=false;
    for(uint64_t cycle=0;cycle<200000;++cycle) {
        top.reset=cycle<12 || cycle==75000 || cycle==140000;
        top.pause=cycle>=6000 && cycle%337>=320;
        top.mem_rq_active=cycle>=6000 && (cycle%101<53 || cycle%347<99);
        top.irq_req=cycle%13>=6;
        top.clk=0;top.eval();
        if(top.reset) { expected=false;ce_valid=false;half_valid=false; }
        else {
            if(top.cpu_ce) {
                if(ce_valid) {
                    const auto gap=cycle-last_ce;
                    min_gap=std::min(min_gap,gap);
                    if(gap<6) throw std::runtime_error("CPU CE gap below six");
                }
                if(half_valid) {
                    const auto gap=cycle-last_half;
                    min_half_to_ce=std::min(min_half_to_ce,gap);
                    if(gap<4) throw std::runtime_error("IRQ launch to CPU CE below four");
                }
                last_ce=cycle;ce_valid=true;++pulses;
            }
            if(top.half_capture) {
                if(ce_valid && cycle-last_ce!=2)
                    throw std::runtime_error("CE_HALF is not CE+2");
                last_half=cycle;half_valid=true;expected=top.irq_req;++captures;
            }
        }
        top.clk=1;top.eval();
        if(bool(top.irq_sample)!=expected)
            throw std::runtime_error("IRQ sampler changed outside its capture/reset");
    }
    if(pulses<1000 || captures<1000 || min_gap!=6 || min_half_to_ce!=4)
        throw std::runtime_error("Insufficient phase coverage");
    std::ofstream out("sim/results/timing/irq-half-phase.json");
    out<<"{\"scope\":\"Production CE/bridge phase proof, not gameplay\","
       <<"\"cycles\":200000,\"cpu_pulses\":"<<pulses
       <<",\"half_captures\":"<<captures<<",\"minimum_ce_gap\":"<<min_gap
       <<",\"half_offset\":2,\"minimum_irq_launch_to_ce\":"<<min_half_to_ce
       <<",\"stalls_pause_reset_and_fast_irq_exercised\":true}\n";
    std::cout<<"IRQ phase PASS: minimum CE gap "<<min_gap
             <<", CE_HALF offset 2, minimum IRQ-to-CE "<<min_half_to_ce
             <<", captures "<<captures<<"\n";
    top.final();
}
