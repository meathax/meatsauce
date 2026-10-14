// SPDX-License-Identifier: GPL-3.0-or-later
// Related Nintendo 5I/5J LS161 and vertical-blank LS74 network.
// CLK2 uses CK/4. ENP7 crosses CLK2 WITHOUT a junction and takes HB_n.
// ENT10 cascades 4J RCO -> 5I RCO -> 5J. Thus only active-end carry counts.
// QA..QD of both counters are retained. VB D12=V5&V6&V7, CLK11=V4.
// reset supplies a reproducible digital origin; PCB reset/power-up is unknown.
// Not connected to the production board until full timing/origin is qualified.
module n8080_vertical_counter (
    input wire clk,
    input wire reset,
    input wire ce_counter,
    input wire horizontal_active,
    input wire horizontal_carry,
    output reg [7:0] vertical,
    output reg vb
);
    wire [7:0] next_vertical=vertical+8'd1;
    always @(posedge clk) begin
        if(reset) begin vertical<=0; vb<=1; end
        else if(ce_counter && horizontal_active && horizontal_carry) begin
            vertical<=next_vertical;
            // The downstream LS74 sees the new V4 rising edge. Higher
            // bits do not change on that transition, so pre-edge D is valid.
            if(!vertical[4] && next_vertical[4]) vb<=&vertical[7:5];
        end
    end
endmodule
