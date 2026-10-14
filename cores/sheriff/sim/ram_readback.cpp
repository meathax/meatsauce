// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vn8080_ram_readback.h"
#include "verilated.h"
#include <cstdio>

struct Case { unsigned reset, clr, hread, phi1, phi3, rd, flags, captured, ready; };
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vn8080_ram_readback m;
    // Explicit manufacturer-function cases: flag feedback, clear dominance,
    // no synthetic clock on clear release, and LS74 Qbar asynchronous rules.
    const Case cases[] = {
        {1,0,1,1,0,0x00,0,0x00,1},
        {0,0,1,1,0,0x11,0,0x00,1},
        {0,1,1,1,0,0x11,0,0x00,0},
        {0,1,0,1,0,0x11,0,0x00,0},
        {0,1,1,1,0,0x11,1,0x11,0},
        {0,1,1,1,0,0x22,1,0x11,0},
        {0,1,0,1,0,0x22,3,0x22,0},
        {0,1,0,0,1,0x22,3,0x22,0},
        {0,1,0,1,0,0x22,3,0x22,0},
        {0,1,0,1,1,0x22,3,0x22,1},
        {0,1,0,0,1,0x22,3,0x22,1},
        {0,1,1,0,1,0x33,3,0x22,1},
        {0,1,0,0,1,0x33,3,0x33,1},
        {0,0,0,0,1,0x33,0,0x00,1},
        {0,0,0,0,1,0x33,0,0x00,1},
        {0,0,1,0,1,0x44,0,0x00,1},
        {0,1,1,0,1,0x44,0,0x00,0},
        {0,1,0,0,1,0x44,0,0x00,0},
        {0,1,1,0,1,0x44,1,0x44,0},
        {0,1,0,0,1,0x55,3,0x55,0},
        {0,1,0,1,0,0x55,3,0x55,0},
        {0,1,0,1,1,0x55,3,0x55,1},
    };
    unsigned checked = 0;
    for (const auto &c : cases) {
        m.reset = c.reset; m.ramstb_n = c.clr; m.hread_n = c.hread;
        m.phi1_ttl = c.phi1; m.phi3_ttl = c.phi3; m.rd = c.rd;
        m.clk = 0; m.eval(); m.clk = 1; m.eval();
        unsigned flags = (m.rdy_in << 1) | m.first_capture;
        if (flags != c.flags || m.captured_data != c.captured || m.ready != c.ready) {
            std::fprintf(stderr, "FAIL case=%u flags=%u/%u data=%u/%u READY=%u/%u\n",
                checked, flags, c.flags, m.captured_data, c.captured, m.ready, c.ready);
            return 1;
        }
        ++checked;
    }
    std::printf("PASS cases=%u capture_feedback=1 clear_release_no_edge=1 READY_Qbar=1\n", checked);
    m.final();
    return 0;
}
