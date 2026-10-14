// SPDX-License-Identifier: GPL-3.0-or-later
// MAME uPD4701-compatible SSV profile. Eagle Shot's pin arrangement is marked
// uncertain in the pinned driver; this preserves that behavioral assumption.
`timescale 1ns/1ps
module ssv_upd4701 (
    input logic clk, input logic rst,
    input logic [11:0] coord_x, coord_y,
    input logic control_we, input logic [7:0] control,
    output logic [7:0] data
);
logic cs=1'b1, ul, xy;
logic [11:0] start_x, start_y, latch_x, latch_y;
always_ff @(posedge clk) begin
    if (rst) begin cs<=1; ul<=0; xy<=0; start_x<=0; start_y<=0; latch_x<=0; latch_y<=0; end
    else if (control_we) begin
        if (cs && control[6]) begin
            latch_x <= coord_x - start_x;
            latch_y <= coord_y - start_y;
        end
        cs <= !control[6]; ul <= control[5]; xy <= control[4];
        if (control[3]) start_x <= coord_x;
        if (control[2]) start_y <= coord_y;
    end
end
always_comb begin
    if (cs) data = 8'hff;
    else if (xy) data = ul ? {4'd0,latch_y[11:8]} : latch_y[7:0];
    else data = ul ? {4'd0,latch_x[11:8]} : latch_x[7:0];
end
endmodule
