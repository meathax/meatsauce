// SPDX-License-Identifier: GPL-3.0-or-later
// Proven donor RAM ports. Outputs are consumed on read cycles; a write cycle
// may also refresh its output. Sort swaps write distinct addresses, with both
// read enables off, so the donor's no_rw_check excludes no observable collision.
module gaiapolis_bram_tdp #(parameter integer DW=32,AW=8)(
    input logic clk,we_a,re_a,we_b,re_b,
    input logic [AW-1:0] addr_a,addr_b,
    input logic [DW-1:0] data_a,data_b,
    output logic [DW-1:0] q_a,q_b
);
    jtframe_dual_ram_cen #(.DW(DW),.AW(AW)) u_ram(
        .clk0(clk),.cen0(we_a || re_a),.we0(we_a),.addr0(addr_a),.data0(data_a),.q0(q_a),
        .clk1(clk),.cen1(we_b || re_b),.we1(we_b),.addr1(addr_b),.data1(data_b),.q1(q_b));
endmodule
