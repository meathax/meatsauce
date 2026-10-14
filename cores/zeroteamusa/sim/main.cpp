// SPDX-License-Identifier: GPL-3.0-or-later
// Real V30 boot probe. This is not yet the integrated board acceptance run:
// unmapped devices are recorded as open bus, never presented as working COPs.
#include "Vzero_cpu_top.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

static uint16_t reg(const Vzero_cpu_top& top, int index) {
    return (top.registers[index / 2] >> ((index & 1) * 16)) & 0xffff;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string rom_path, output;
    uint64_t cycles = 3000000;
    unsigned latency = 3;
    for (int i = 1; i < argc; ++i) {
        std::string key = argv[i];
        if (i + 1 >= argc) throw std::runtime_error("Missing argument value");
        std::string value = argv[++i];
        if (key == "--rom") rom_path = value;
        else if (key == "--output") output = value;
        else if (key == "--cycles") cycles = std::stoull(value);
        else if (key == "--latency") latency = std::stoul(value);
        else throw std::runtime_error("Unknown option: " + key);
    }
    std::ifstream input(rom_path, std::ios::binary);
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(input)), {});
    if (rom.size() != 0x100000) throw std::runtime_error("Target program ROM must be exactly 1 MiB");
    std::array<uint8_t, 0x20000> ram{};
    std::set<uint32_t> fetched, unknown_reads, unknown_writes, pcs;
    uint64_t reads = 0, writes = 0, ram_writes = 0, waits = 0, ce_stalls = 0;
    bool reset_vector = false, active_read = false, active_write = false;
    uint32_t read_addr = 0, write_addr = 0;
    unsigned pending = 0;
    Vzero_cpu_top top;
    top.clk = 0; top.reset = 1; top.ready = 1; top.ce = 0;
    top.irq = 0; top.irq_vector = 0x30; top.read_data = 0xffff;
    auto byte = [&](uint32_t addr) -> uint8_t {
        if (addr >= 0x20000) return rom[addr & 0xfffff];
        if (addr < 0x400 || addr >= 0x800) return ram[addr];
        unknown_reads.insert(addr & ~1U);
        return 0xff;
    };
    for (uint64_t tick = 0; tick < cycles && !Verilated::gotFinish(); ++tick) {
        top.clk = 0;
        top.reset = tick < 60;
        top.ce = (tick % 6) == 0; // 96 MHz system / 6 = 16 MHz V30.
        top.eval();
        bool rd = top.mem_read || top.io_read;
        if (rd && (!active_read || read_addr != top.address)) {
            active_read = true; read_addr = top.address;
            pending = read_addr >= 0x20000 ? latency : 2;
            ++reads;
            if (top.code_fetch) {
                fetched.insert(read_addr);
                reset_vector |= read_addr == 0xffff0;
            }
        }
        if (!rd) active_read = false;
        // The selected donor freezes CPU CE while an external ROM transaction
        // is outstanding. READY alone does not protect its early data sample.
        // Keep the same integration contract here; BRAM has a two-cycle read.
        if (pending) { --pending; ++waits; top.ready = 0; }
        else {
            top.read_data = uint16_t(byte(read_addr)) | (uint16_t(byte(read_addr + 1)) << 8);
            top.ready = 1;
        }
        if (!top.ready && read_addr >= 0x20000 && top.ce) {
            top.ce = 0;
            ++ce_stalls;
        }
        bool wr = top.mem_write || top.io_write;
        if (wr && (!active_write || write_addr != top.address)) {
            active_write = true; write_addr = top.address; ++writes;
            if (write_addr < 0x20000 && (write_addr < 0x400 || write_addr >= 0x800)) {
                if (top.byte_enable & 1) ram[write_addr] = top.write_data & 0xff;
                if (top.byte_enable & 2) ram[write_addr + 1] = top.write_data >> 8;
                ++ram_writes;
            } else unknown_writes.insert(write_addr);
        }
        if (!wr) active_write = false;
        top.eval();
        top.clk = 1; top.eval();
        if (!top.reset) pcs.insert(((uint32_t(reg(top, 9)) << 4) + reg(top, 12)) & 0xfffff);
        Verilated::timeInc(10);
    }
    const bool passed = reset_vector && fetched.size() > 4 && ram_writes > 0 && pcs.size() > 4;
    std::ostringstream report;
    report << "{\n  \"scope\": \"real V30 reset/program/RAM seam; board devices pending\",\n"
           << "  \"passed\": " << (passed ? "true" : "false") << ",\n"
           << "  \"cycles\": " << cycles << ",\n  \"memory_latency\": " << latency
           << ",\n  \"reset_vector_fetched\": " << (reset_vector ? "true" : "false")
           << ",\n  \"unique_prefetch_addresses\": " << fetched.size()
           << ",\n  \"unique_debug_pcs\": " << pcs.size()
           << ",\n  \"reads\": " << reads << ",\n  \"writes\": " << writes
           << ",\n  \"ram_writes\": " << ram_writes << ",\n  \"wait_system_cycles\": " << waits
           << ",\n  \"external_rom_ce_stalls\": " << ce_stalls
           << ",\n  \"final_cs\": " << reg(top, 9) << ",\n  \"final_ip\": " << reg(top, 12)
           << ",\n  \"unmapped_read_addresses\": [";
    bool first = true;
    for (auto addr : unknown_reads) { if (!first) report << ','; first = false; report << addr; }
    report << "],\n  \"unmapped_write_addresses\": ["; first = true;
    for (auto addr : unknown_writes) { if (!first) report << ','; first = false; report << addr; }
    report << "]\n}\n";
    std::ofstream result(output); result << report.str();
    std::cout << report.str();
    top.final();
    return passed ? 0 : 1;
}
