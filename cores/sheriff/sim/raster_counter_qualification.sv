// SPDX-License-Identifier: GPL-3.0-or-later
module raster_counter_qualification (
    input wire clk, reset, ce_counter,
    output reg [3:0] phase,
    output wire [3:0] upper,
    output wire active, hb, carry,
    output wire [7:0] vertical,
    output wire vb
);
    always @(posedge clk) begin
        if(reset) phase<=0;
        else if(ce_counter) phase<=phase+1'b1;
    end
    n8080_horizontal_counter horizontal (
        .clk(clk),.reset(reset),.ce_counter(ce_counter),.phase_4i(phase),
        .upper_4j(upper),.h_active(active),.hb(hb),.terminal_carry(carry)
    );
    n8080_vertical_counter vertical_counter (
        .clk(clk),.reset(reset),.ce_counter(ce_counter),
        .horizontal_active(active),.horizontal_carry(carry),.vertical(vertical),.vb(vb)
    );
endmodule
