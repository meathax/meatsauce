#include "Vraiden2_ce_gen.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

// ZeroTeam.sdc gives every V30 CE-to-CE path a five-clock window. Check the
// production generator never emits closer pulses at either OSD speed, that the
// unstalled period is exact (6 = 16 MHz, 5 = 19.2 MHz turbo), and that cycles
// deferred by a stall are caught up (16 MHz must then show the 5-clock gap).
struct Result { uint64_t pulses, minimum, maximum, nominal; };

static Result run(Vraiden2_ce_gen& top, uint8_t clk_sel, uint64_t nominal) {
    top.clk_sel=clk_sel; top.ls245_en=0; top.cpu_rd=0; top.rd_lat=0;
    uint64_t previous=0, pulses=0, minimum=UINT64_MAX, maximum=0, early=0;
    for (uint64_t cycle=0; cycle<200000; ++cycle) {
        top.reset=cycle<12 || cycle==75000 || cycle==140000;
        top.pause=cycle>=6000 && cycle%337>=320;
        top.mem_rq_active=cycle>=6000 && (cycle%101<53 || cycle%347<99);
        top.clk=0; top.eval(); top.clk=1; top.eval();
        if (!top.ce) continue;
        if (pulses) {
            const auto gap=cycle-previous;
            if (gap<5) throw std::runtime_error("CE spacing below five fabric clocks");
            if (cycle<6000) {
                if (gap!=nominal) throw std::runtime_error("Unstalled CE period is not the selected clock");
                ++early;
            }
            minimum=std::min(minimum,gap); maximum=std::max(maximum,gap);
        }
        previous=cycle; ++pulses;
    }
    if (pulses<1000 || early<500 || minimum!=5) throw std::runtime_error("Insufficient CE coverage");
    return {pulses,minimum,maximum,nominal};
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vraiden2_ce_gen top;
    const Result normal=run(top,0,6), turbo=run(top,4,5);
    std::ofstream out("sim/results/timing/v30-ce-minimum.json");
    auto json=[](const Result& r){
        return "{\"pulses\":"+std::to_string(r.pulses)+",\"minimum_gap\":"+std::to_string(r.minimum)
              +",\"maximum_gap\":"+std::to_string(r.maximum)+",\"nominal_gap\":"+std::to_string(r.nominal)+"}";
    };
    out<<"{\"cycles\":200000,\"clk_sel_0\":"<<json(normal)<<",\"clk_sel_4\":"<<json(turbo)
       <<",\"stall_pause_and_reset_exercised\":true}\n";
    std::cout<<"Target V30 CE: 16 MHz nominal 6, minimum "<<normal.minimum<<", maximum "<<normal.maximum
             <<"; 19.2 MHz nominal 5, minimum "<<turbo.minimum<<", maximum "<<turbo.maximum<<"\n";
    top.final();
}
