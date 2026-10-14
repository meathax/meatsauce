// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vn8080_video_register.h"
#include <verilated.h>
#include <cstdint>
#include <cstdlib>
#include <iostream>

static void check(Vn8080_video_register& model, unsigned expected, const char* stage) {
    if (model.q != expected || model.qa != (expected & 1) || model.qh != (expected >> 7)) {
        std::cerr << stage << ": expected " << expected << ", actual " << unsigned(model.q) << '\n';
        std::exit(1);
    }
}

// Independent pin-by-pin interpretation of the TI table, rather than vector
// shift expressions shared with the RTL. Pin A is index 0; pin H is index 7.
static unsigned table(unsigned previous, unsigned mode, unsigned right,
                      unsigned left, unsigned parallel, bool ce, bool clear_n) {
    if (!clear_n) return 0;
    if (!ce || mode == 0) return previous;
    if (mode == 3) return parallel;
    unsigned result = 0;
    for (unsigned pin = 0; pin < 8; ++pin) {
        const unsigned value = mode == 1 ? (pin == 0 ? right : ((previous >> (pin - 1)) & 1))
                                         : (pin == 7 ? left : ((previous >> (pin + 1)) & 1));
        result |= value << pin;
    }
    return result;
}

static void edge(Vn8080_video_register& model) {
    model.clk = 0; model.eval();
    model.clk = 1; model.eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vn8080_video_register model;
    model.clk = 0; model.clear_n = 0; model.ce_clock = 0;
    model.s0 = 0; model.s1 = 0; model.serial_right = 0; model.serial_left = 0;
    model.parallel_data = 0; model.eval(); edge(model);
    unsigned cases = 0;
    const unsigned patterns[] = {0,255,0x96,0x81};
    for (unsigned previous = 0; previous < 256; ++previous)
    for (unsigned mode = 0; mode < 4; ++mode)
    for (unsigned right = 0; right < 2; ++right)
    for (unsigned left = 0; left < 2; ++left)
    for (unsigned ce = 0; ce < 2; ++ce)
    for (unsigned clear_n = 0; clear_n < 2; ++clear_n)
    for (unsigned parallel : patterns) {
        model.clear_n = 1; model.ce_clock = 1; model.s0 = 1; model.s1 = 1;
        model.parallel_data = previous; model.eval(); edge(model);
        check(model, previous, "load initial state");
        // Change controls while the chip clock is high, as TI specifies.
        model.ce_clock = ce; model.s0 = mode & 1; model.s1 = mode >> 1;
        model.serial_right = right; model.serial_left = left;
        model.parallel_data = parallel; model.clear_n = clear_n; model.eval();
        check(model, clear_n ? previous : 0, "no clock / overriding clear");
        model.clk = 0; model.eval();
        check(model, clear_n ? previous : 0, "falling edge holds");
        model.clk = 1; model.eval();
        check(model, table(previous,mode,right,left,parallel,ce,clear_n), "rising edge");
        ++cases;
    }
    // Physical bus order on the related I/O schematic: A=RD7 ... H=RD0.
    // The two selected end outputs must emit the eight bits in opposite order.
    for (unsigned flip = 0; flip < 2; ++flip) {
        model.clear_n = 1; model.ce_clock = 1; model.s0 = 1; model.s1 = 1;
        model.parallel_data = 0x69; model.eval(); edge(model); // reversal of RD=0x96
        model.s0 = !flip; model.s1 = flip; model.serial_right = 0; model.serial_left = 0;
        model.eval();
        for (unsigned bit = 0; bit < 8; ++bit) {
            const unsigned actual = flip ? model.qa : model.qh;
            const unsigned expected = (0x96 >> (flip ? 7-bit : bit)) & 1;
            if (actual != expected) return 2;
            edge(model);
        }
    }
    model.final();
    std::cout << "SN74198 functional cases=" << cases
              << " pin-order streams=2 overriding-clear/CE/edge checks=PASS\n";
}
