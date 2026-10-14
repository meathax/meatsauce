// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic MAME-profile serial ADC. The pinned driver uses 56 device
// clocks at a FIXME 1.5 MHz; cycles is descriptor-selected for later evidence.
`timescale 1ns/1ps
module ssv_upd7001 (
    input logic clk, input logic rst, input logic [7:0] analog,
    input logic [7:0] cycles,
    input logic control_we, input logic cs_in, sck_in,
    output logic eoc_so
);
logic cs, sck, oe, converting, eoc_active;
logic [7:0] shift, count;
always_ff @(posedge clk) begin
    if (rst) begin cs<=1; sck<=0; oe<=0; converting<=0; eoc_active<=0; shift<=0; count<=0; end
    else begin
        if (converting) begin
            if (count == 1) begin shift<=analog; converting<=0; eoc_active<=1; end
            else count<=count-1'd1;
        end
        if (control_we) begin
            if (!cs_in && cs) begin eoc_active<=0; oe<=1; end
            if (cs_in && !cs) begin converting<=1; count<=cycles; oe<=0; end
            if (!cs_in && !sck_in && sck) shift <= {shift[6:0],1'b0};
            cs<=cs_in; sck<=sck_in;
        end
    end
end
assign eoc_so = !eoc_active && (!oe || shift[7]);
endmodule
