// SPDX-License-Identifier: GPL-3.0-or-later
// Treble exciter for the interpolated OKI stream (board-side enhancement, not on the PCB or in MAME).
// A ~7.6 kHz OKI holds nothing above 3.8 kHz, so the music sounds dull once interpolation images are
// removed. This regenerates harmonics of the 1.8-3.8 kHz band instead of the images (aliases):
//   h = HP1(x, 1.8 kHz); r = |h| (even harmonics); e = HP1(HP1(r, 3.8 kHz), 3.8 kHz); l = LP1(e, 12 kHz)
//   y = x + gain * l,   gain = 0 / 0.5 / 1 / 2 (level 0..3)
// One-pole filters run at the upsampler's output rate (32x OKI, ~242 kHz); coefficients come from
// scripts/gen_audio_fir.py (steel_audio_exciter.vh). One shared multiplier, 9 clocks per sample.
module steel_audio_exciter(
    input wire clk,reset,
    input wire valid,                   // new x
    input wire signed [15:0] x,
    input wire [1:0] level,
    output reg signed [15:0] y
);
`include "rtl/steel_audio_exciter.vh"
    // State is Q8 (x * 256).
    reg signed [31:0] x_prev=0,h=0,r_prev=0,e1=0,e2=0,l=0;
    reg signed [31:0] opnd=0;
    reg [17:0] coef=0;
    reg signed [50:0] prod=0;
    reg [3:0] step=0;
    wire signed [31:0] xs={{8{x[15]}},x,8'b0};
    wire signed [31:0] scaled=prod[48:17];          // Q17 coefficient
    wire signed [31:0] r=h[31] ? -h : h;
    reg signed [31:0] wet;
    always @* case(level)
        2'd1: wet=l>>>9;
        2'd2: wet=l>>>8;
        2'd3: wet=l>>>7;
        default: wet=32'sd0;
    endcase
    wire signed [31:0] mix=$signed({{16{x[15]}},x})+wet;
    always @(posedge clk)begin
        prod<=$signed(opnd)*$signed({1'b0,coef});
        if(reset)begin
            x_prev<=0;h<=0;r_prev<=0;e1<=0;e2<=0;l<=0;step<=0;y<=0;
        end else begin
            case(step)
                4'd0: if(valid)begin opnd<=h+xs-x_prev;coef<=EXC_A1;x_prev<=xs;step<=4'd1;end
                4'd2: begin h<=scaled;step<=4'd3;end
                4'd3: begin opnd<=e1+r-r_prev;coef<=EXC_A2;r_prev<=r;step<=4'd4;end
                4'd5: begin e1<=scaled;opnd<=e2+scaled-e1;coef<=EXC_A2;step<=4'd6;end
                4'd7: begin e2<=scaled;opnd<=scaled-l;coef<=EXC_B3;step<=4'd8;end
                4'd9: begin
                    l<=l+scaled;step<=4'd0;
                    y<=mix>32'sd32767 ? 16'sh7fff : mix<-32'sd32768 ? 16'sh8000 : mix[15:0];
                end
                default: step<=step+1'b1;     // 1,4,6,8: wait for the registered product
            endcase
        end
    end
endmodule
