// SPDX-License-Identifier: GPL-3.0-or-later
// Simulation-only wrapper so one Verilator model checks both the address map
// and the CPU transport-cache policy that share cs_address_decode.sv.
module cs_decode_policy_bench (
    input logic [31:0] address,
    input logic [2:0] flash_bank,
    output logic [3:0] target,
    output logic [31:0] offset,
    input logic write, flash_read_override,
    output logic cacheable
);
    cs_address_decode map (.address, .flash_bank, .target, .offset);
    cs_cache_policy policy (.address, .write, .flash_read_override, .cacheable);
endmodule
