// SPDX-License-Identifier: GPL-3.0-or-later
// Common 32.220MHz crystal as fabric enables at provisional clk_sys=56MHz.
// Reuse the pinned JTFRAME fractional accumulator; never use a CE as a clock.
// The crystal/divider phase runs through game reset/pause. Consumers receive
// only a masked subset of its strobes, preserving minimum accepted spacing.
`timescale 1ns/1ns
module hangzo_audio_clocks (
    input wire clk,reset,run_enable,
    output wire ce_osc,ce_huc,ce_ym,ce_oki1,ce_oki2
);
    wire [5:0] raw_ce;
    jtframe_frac_cen #(.W(6),.WC(12)) u_crystal (
        .clk(clk),.n(12'd1611),.m(12'd2800),.cen(raw_ce),.cenb());
    reg [3:0] ym_div9;
    reg [4:0] staged;
    assign {ce_oki2,ce_oki1,ce_ym,ce_huc,ce_osc}=staged & {5{!reset && run_enable}};
    always @(posedge clk) begin
        if(reset) begin
            ym_div9<=0;
            staged<=0;
        end else begin
            staged[0]<=raw_ce[0];  //32.220MHz
            staged[1]<=raw_ce[1];  //16.110MHz RTL HuC input, internal /6 or /24
            staged[2]<=raw_ce[0] && ym_div9==8; //3.580MHz
            staged[3]<=raw_ce[5];  //1.006875MHz OKI1
            staged[4]<=raw_ce[4];  //2.013750MHz OKI2
            if(raw_ce[0]) begin
                if(ym_div9==8)ym_div9<=0;
                else ym_div9<=ym_div9+4'd1;
            end
        end
    end
endmodule
