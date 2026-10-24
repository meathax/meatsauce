/* SPDX-License-Identifier: GPL-3.0-or-later */
// 32 KiB, big-endian CPU words and an independent byte port for hiscores.
// Both ports have one registered read cycle. Writes on the byte port require
// a real CPU pause acknowledgement, not a fixed delay from the request.
module jtblkpan_workram(
    input clk,
    input [13:0] cpu_addr,
    input [15:0] cpu_data,
    input [1:0] cpu_we,
    output [15:0] cpu_q,
    input [14:0] hs_addr,
    input [7:0] hs_data,
    input hs_we, paused,
    output [7:0] hs_q
);
wire [7:0] hs_hi,hs_lo;
reg hs_odd;
always @(posedge clk) hs_odd<=hs_addr[0];
assign hs_q=hs_odd ? hs_lo : hs_hi;
jtframe_dual_ram #(.AW(14),.DW(8)) u_lo(
    .clk0(clk),.addr0(cpu_addr),.data0(cpu_data[7:0]),.we0(cpu_we[0]),.q0(cpu_q[7:0]),
    .clk1(clk),.addr1(hs_addr[14:1]),.data1(hs_data),
    .we1(hs_we && paused && hs_addr[0]),.q1(hs_lo));
jtframe_dual_ram #(.AW(14),.DW(8)) u_hi(
    .clk0(clk),.addr0(cpu_addr),.data0(cpu_data[15:8]),.we0(cpu_we[1]),.q0(cpu_q[15:8]),
    .clk1(clk),.addr1(hs_addr[14:1]),.data1(hs_data),
    .we1(hs_we && paused && !hs_addr[0]),.q1(hs_hi));
endmodule
