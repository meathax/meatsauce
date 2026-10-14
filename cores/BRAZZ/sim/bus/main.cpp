// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_bus_ram.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <stdexcept>

static vluint64_t simulation_time = 0;
double sc_time_stamp() { return double(simulation_time); }

struct Bench {
    Vcs_bus_ram dut;
    unsigned clocks = 0, transactions = 0;
    void tick() {
        dut.clk = 0; dut.eval(); ++simulation_time;
        dut.clk = 1; dut.eval(); ++simulation_time;
        dut.clk = 0; dut.eval(); ++clocks;
    }
    void reset() { dut.req_valid = 0; dut.reset = 1; tick(); dut.reset = 0; tick(); }
    uint32_t access(uint32_t addr, bool write, uint32_t value, unsigned mask, bool expect_error = false) {
        dut.req_addr = addr; dut.req_write = write; dut.req_data = value;
        dut.req_strb = mask; dut.req_valid = 1; dut.eval();
        bool accepted = false;
        unsigned start = clocks;
        for (unsigned watchdog = 0; watchdog < 32; ++watchdog) {
            bool handshake = dut.req_valid && dut.req_ready;
            tick();
            if (handshake) { accepted = true; dut.req_valid = 0; }
            if (dut.rsp_valid) {
                if (!accepted || bool(dut.rsp_error) != expect_error)
                    throw std::runtime_error("bad response/acceptance/error ordering");
                if (clocks - start < 4) throw std::runtime_error("backend latency was bypassed");
                uint32_t result = dut.rsp_data;
                tick();
                if (dut.rsp_valid || !dut.req_ready) throw std::runtime_error("duplicate response or stuck busy");
                ++transactions; return result;
            }
            if (accepted && dut.req_ready) throw std::runtime_error("accepted request lost before response");
        }
        throw std::runtime_error("transaction timeout");
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Bench b; b.reset();
        constexpr uint32_t base = 0x02000000;
        for (unsigned i = 0; i < 16; ++i) b.access(base + i*4, true, 0x10203040u + i, 15);
        for (unsigned i = 0; i < 16; ++i)
            if (b.access(base + i*4, false, 0, 0) != 0x10203040u + i) throw std::runtime_error("word storage mismatch");
        b.access(base, true, 0xaabbccdd, 5);
        if (b.access(base, false, 0, 0) != 0x10bb30dd) throw std::runtime_error("byte lanes mismatch");
        b.access(base + 1, true, 0, 15, true);
        b.access(base + 64, false, 0, 0, true);
        b.access(base - 4, false, 0, 0, true);
        b.reset();
        if (b.access(base, false, 0, 0) != 0x10bb30dd) throw std::runtime_error("reset damaged persistent RAM");
        b.dut.req_valid = 1; b.dut.req_addr = base; b.dut.req_data = 0;
        b.dut.req_write = 1; b.dut.req_strb = 15; b.tick(); b.reset();
        for (unsigned i = 0; i < 6; ++i) { b.tick(); if (b.dut.rsp_valid) throw std::runtime_error("ghost response after reset"); }
        if (b.access(base, false, 0, 0) != 0x10bb30dd) throw std::runtime_error("cancelled write committed");
        std::printf("PASS bus: %u transactions, byte lanes/range faults/reset/latency; %u clocks\n", b.transactions, b.clocks);
        return 0;
    } catch (const std::exception& e) { std::fprintf(stderr, "FAIL bus: %s\n", e.what()); return 1; }
}
