// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-lane bridge between the standard Hiscore module and System 16B work RAM.
module dfjail_hiscore_ramtap(
    input  [13:1] cpu_addr,
    input  [15:0] cpu_data,
    input  [1:0]  cpu_we,
    input  [15:0] cpu_q,
    input         pause_cpu,
    input  [13:0] hiscore_address,
    input  [7:0]  hiscore_data,
    input         hiscore_read,
    input         hiscore_write,
    output [13:1] ram_address,
    output [15:0] ram_data,
    output [1:0]  ram_we,
    output [7:0]  hiscore_q
);

wire hiscore_grant = pause_cpu && (hiscore_read || hiscore_write);
wire hiscore_write_grant = pause_cpu && hiscore_write;

assign ram_address = hiscore_grant ? hiscore_address[13:1] : cpu_addr;
assign ram_data    = hiscore_write_grant ? {hiscore_data, hiscore_data} : cpu_data;
// Selecting a score read address must never carry the CPU write strobes.
assign ram_we = hiscore_grant ? (hiscore_write ? (hiscore_address[0] ? 2'b01 : 2'b10) : 2'b00) : cpu_we;

// System 16B is a big-endian 68000: even byte addresses use D15:8.
assign hiscore_q   = hiscore_address[0] ? cpu_q[7:0] : cpu_q[15:8];

endmodule
