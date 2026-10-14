// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vn8080_memory_phases.h"
#include "verilated.h"
#include <cstdio>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vn8080_memory_phases m;
    auto tick = [&]() { m.clk = 0; m.eval(); m.clk = 1; m.eval(); };
    m.reset = 1; m.ce_xtal = 0; tick();
    m.reset = 0;
    unsigned edges = 0, samples = 0;
    // Closed-form QA rising-edge count; QB history uses the count *before*
    // each shift. This oracle does not repeat the RTL decade/divider registers.
    for (unsigned master = 0; master < 16000; ++master) {
        m.ce_xtal = master % 5 == 0 || master % 5 == 3;
        if (m.ce_xtal) ++edges;
        unsigned rises = (edges + 1) / 2;
        unsigned count = ((rises + 1) / 2) & 15;
        unsigned history = 0;
        for (unsigned delay = 0; delay < 8; ++delay) {
            if (rises > delay) {
                unsigned older_rise = rises - delay;
                unsigned pre_count = older_rise / 2;
                history |= ((pre_count >> 1) & 1) << delay;
            }
        }
        tick();
        bool ok = m.phase_4i == count && m.delay_4a == history
            && m.raw_cas_n == !(history & 2)
            && m.raw_ras_n == !!((history & 2) && (history & 8))
            && m.comadr_n == !(history & 64)
            && m.hread_n == !(count & 4);
        if (!ok) {
            std::fprintf(stderr, "FAIL master=%u edges=%u count=%u/%u history=%u/%u\n",
                master, edges, m.phase_4i, count, m.delay_4a, history);
            return 1;
        }
        ++samples;
    }
    std::printf("PASS master_samples=%u crystal_edges=%u includes_CE_holds=1\n", samples, edges);
    m.final();
    return 0;
}
