// SPDX-License-Identifier: GPL-3.0-or-later
// Simple dual-port RAM with one write address and a registered read port.
module gaiapolis_bram #(parameter integer DW=48,AW=9)(
    input logic clk,we,re,
    input logic [AW-1:0] write_addr,read_addr,
    input logic [DW-1:0] write_data,
    output logic [DW-1:0] read_data
);
    (* ramstyle = "M10K" *) logic [DW-1:0] memory [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if(we) memory[write_addr]<=write_data;
        if(re) read_data<=memory[read_addr];
    end
endmodule
