// SPDX-License-Identifier: GPL-3.0-or-later
// Experimental common-clock 5 MHz Z80 and 8 MHz YM2610 enables, for the
// provisional 630/11 MHz system clock. Pixel timing is generated separately.
module spinal_sound_enable (
    input logic clk,reset,
    output wire sound_ce,ym_ce
);
    logic [6:0] sound_phase=0;
    logic [8:0] ym_phase=0;
    wire [7:0] sound_sum={1'b0,sound_phase}+8'd11;
    wire [9:0] ym_sum={1'b0,ym_phase}+10'd44;
    assign sound_ce=!reset && sound_sum>=8'd126;
    assign ym_ce=!reset && ym_sum>=10'd315;
    always_ff @(posedge clk) begin
        if(reset)begin sound_phase<=0;ym_phase<=0;end
        else begin
            sound_phase<=sound_sum>=8'd126 ? sound_sum-8'd126 : sound_sum;
            ym_phase<=ym_sum>=10'd315 ? ym_sum-10'd315 : ym_sum;
        end
    end
endmodule
