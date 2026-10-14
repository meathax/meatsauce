// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module ssv_srmp7_bank (
    input  logic clk,
    input  logic cold_rst,
    input  logic write,
    input  logic data,
    output logic bank
);
always_ff @(posedge clk) begin
    if (cold_rst)
        bank <= 1'b0;
    else if (write)
        bank <= data;
end
endmodule
