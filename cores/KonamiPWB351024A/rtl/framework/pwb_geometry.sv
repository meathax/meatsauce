// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from the pinned Simple156 osman_geometry quarter-cycle read cadence.
// Use game-aligned blanking directly; never infer blanking from delayed counters.
module pwb_geometry (
    input wire clk,reset,ce_in,active,
    input wire signed [4:0] hsize,hposition,vposition,
    input wire [7:0] red_in,green_in,blue_in,
    input wire hs_in,vs_in,hblank_in,vblank_in,
    output wire ce_out,hs_out,vs_out,hblank_out,vblank_out,
    output wire [7:0] red_out,green_out,blue_out
);
    wire signed [4:0] size=hsize>5'sd6 ? 5'sd6 : hsize < -5'sd10 ? -5'sd10 : hsize;
    wire [8:0] read_period=9'd32+{{4{size[4]}},size};
    reg [7:0] phase=0;
    reg old_hs=0;
    wire [8:0] next_phase={1'b0,phase}+9'd4;
    wire tick=next_phase>=read_period;
    wire read_ce=active?tick:ce_in;
    wire hs_ref;
    // The linebuffer emits the completed previous source line. SPY changes
    // VBlank before HSync, so retain that previous line's blanking until the
    // same pixel-enabled HSync edge used by the buffer's bank exchange.
    reg line_hs=0,completed_vblank=1;
    always @(posedge clk) begin
        if(reset) begin line_hs<=0;completed_vblank<=1;end
        else if(ce_in) begin
            line_hs<=hs_in;
            if(hs_in&&!line_hs) completed_vblank<=vblank_in;
        end
    end
    always @(posedge clk) begin
        old_hs<=hs_ref;
        if(reset||(hs_ref&&!old_hs)) phase<=0;
        else phase<=tick?8'(next_phase-read_period):next_phase[7:0];
    end
    wire [7:0] cr,cg,cb;
    wire chs,cvs,chb,cvb;
    crt_adjust #(.VTOTAL(264),.HTOTAL(384),.HPOS_MODE(1)) u_adjust(
        .clk(clk),.pxl_cen(ce_in),.pxl2_cen(read_ce),.active(active),
        .hsize(size),.hoffset({{3{hposition[4]}},hposition,1'b0}),
        .voffset({vposition[4],vposition}),
        .r_in(red_in),.g_in(green_in),.b_in(blue_in),.hs_in(hs_in),.vs_in(vs_in),
        .hb_in(hblank_in),.vb_in(completed_vblank),.r_out(cr),.g_out(cg),.b_out(cb),
        .hs_out(chs),.vs_out(cvs),.hb_out(chb),.vb_out(cvb),.hs_ref_out(hs_ref));
    assign ce_out=read_ce;
    assign {red_out,green_out,blue_out}=active?{cr,cg,cb}:{red_in,green_in,blue_in};
    assign {hs_out,vs_out,hblank_out,vblank_out}=active?{chs,cvs,chb,cvb}:{hs_in,vs_in,hblank_in,vblank_in};
endmodule
