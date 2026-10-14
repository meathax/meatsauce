#include "Vtiming_audio_phase.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <verilated.h>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtiming_audio_phase dut;
    uint64_t min_setup = UINT64_MAX, min_hold = UINT64_MAX, min_half = UINT64_MAX;
    uint64_t last_data = 0, last_rise = 0, last_edge = 0, rising_edges = 0;
    bool old_sclk = false, old_data = false, old_lrclk = false;
    uint64_t quiet_until = 200;
    for (uint64_t cycle = 0; cycle < 60000; ++cycle) {
        dut.sample_rate = cycle < 20000 ? 0 : cycle < 40000 ? 1 : ((cycle / 503) & 1);
        dut.reset = cycle < 16 || (cycle >= 48000 && cycle < 48016);
        if (dut.reset) quiet_until = cycle + 200;
        dut.left_chan = uint16_t(cycle * 17);
        dut.right_chan = uint16_t(~(cycle * 31));
        dut.clk = 0; dut.eval();
        dut.clk = 1; dut.eval();
        bool edge = dut.sclk != old_sclk;
        bool rise = edge && dut.sclk;
        bool changed = dut.sdata != old_data || dut.lrclk != old_lrclk;
        if (cycle > quiet_until) {
            if (edge && last_edge > quiet_until) min_half = std::min(min_half, cycle - last_edge);
            if (rise) {
                ++rising_edges;
                if (last_data > quiet_until) min_setup = std::min(min_setup, cycle - last_data);
            }
            if (changed && last_rise > quiet_until) min_hold = std::min(min_hold, cycle - last_rise);
        }
        if (changed) last_data = cycle;
        if (rise) last_rise = cycle;
        if (edge) last_edge = cycle;
        old_sclk = dut.sclk; old_data = dut.sdata; old_lrclk = dut.lrclk;
    }
    dut.final();
    if (rising_edges < 1000 || min_setup < 3 || min_hold < 3 || min_half < 4) {
        throw std::runtime_error("Production I2S phase/spacing proof failed");
    }
    std::printf("I2S_PHASE_PASS cycles=60000 rising_edges=%llu minimum_setup_cycles=%llu minimum_hold_cycles=%llu minimum_half_period_cycles=%llu\n",
        (unsigned long long)rising_edges, (unsigned long long)min_setup,
        (unsigned long long)min_hold, (unsigned long long)min_half);
}
