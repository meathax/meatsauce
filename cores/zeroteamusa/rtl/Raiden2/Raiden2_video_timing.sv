// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Umberto Parisi's Seibu timing generator.
// MAME 0.289 raiden2.cpp:1173: 8 MHz, 512x282, active 320x256.
// MAME does not provide sync placement; both pulses fit wholly in blanking.
module Raiden2_video_timing (
    input wire clk,reset,mode_60hz,
    output reg ce_pix,
    output reg [9:0] hpos,vpos,
    output wire [9:0] active_x,
    output wire [8:0] active_y,
    output wire hblank,vblank,hsync,vsync,de,
    output wire [9:0] h_vis_start,
    output wire [8:0] v_vis_start
);
    // Legacy mode input is ignored: changing the raster changes game speed.
    reg [3:0] divider;
    always @(posedge clk) begin
        if(reset) begin divider<=0;ce_pix<=0;hpos<=0;vpos<=0;end
        else begin
            ce_pix<=divider==11;
            divider<=divider==11 ? 4'd0 : divider+4'd1;
            if(ce_pix) begin
                if(hpos==511) begin
                    hpos<=0;vpos<=vpos==281 ? 10'd0 : vpos+10'd1;
                end else hpos<=hpos+10'd1;
            end
        end
    end
    assign hblank=hpos>=320;
    assign vblank=vpos>=256;
    assign de=!hblank && !vblank;
    assign hsync=hpos>=360 && hpos<398;
    assign vsync=vpos>=260 && vpos<263;
    assign h_vis_start=0;
    assign v_vis_start=0;
    assign active_x=de ? hpos : 10'd0;
    assign active_y=de ? vpos[8:0] : 9'd0;
endmodule
