// Core-side CRT boundary; sys/ remains pinned. GPL-3.0-or-later.
module alpha68kn_crt (
    input wire clk,ce_in,hs_in,vs_in,de_in,vb_in,active,direct_video,
    input wire [23:0] rgb_in,
    input wire [2:0] hsize,vsize,
    input wire [4:0] hpos,vpos,
    output wire ce_out,hs_out,vs_out,de_out,
    output wire [23:0] rgb_out
);
    wire signed [4:0] hstep=hsize<=2 ? $signed({2'd0,hsize}) : hsize==3 ? -5'sd2 : hsize==4 ? -5'sd1 : 5'sd0;
    wire signed [5:0] vstep=vsize<=3 ? $signed({3'd0,vsize}) : vsize<=6 ? $signed({3'd0,vsize})-6'sd7 : 6'sd0;
    wire [23:0] vrgb;
    wire vce,vhs,vvs,vde,vvb;
    // 12 lines support +/-3 retimed lines with native 6 MHz pixel cadence.
    // Keep this stage bypassed on direct video to preserve fixed HSync cadence.
    crt_vsize #(.RING_LINES(12),.LINE_PX(384)) vertical (
        .clk(clk),.pxl_cen(ce_in),.active(active && !direct_video),.tube_mode(1'b0),.vsize(-vstep),
        .r_in(rgb_in[23:16]),.g_in(rgb_in[15:8]),.b_in(rgb_in[7:0]),
        .hs_in(hs_in),.vs_in(vs_in),.de_in(de_in),.vb_in(vb_in),
        .r_out(vrgb[23:16]),.g_out(vrgb[15:8]),.b_out(vrgb[7:0]),
        .hs_out(vhs),.vs_out(vvs),.de_out(vde),.vb_out(vvb),.ce_out(vce)
    );
    wire hs_ref;
    reg hs_ref_d=0;
    reg [7:0] rd_acc=0;
    // Whole master cycles give uniformly spaced output pixels; rephase every
    // line on the SAME HSync reference used by the donor's buffer engine.
    wire [7:0] rd_period=8'd32 + {{3{hstep[4]}},hstep}*8'd4;
    wire rd_tick=rd_acc+8'd4>=rd_period;
    always @(posedge clk) begin
        hs_ref_d<=hs_ref;
        if(hs_ref && !hs_ref_d) rd_acc<=0;
        else if(rd_tick) rd_acc<=rd_acc+8'd4-rd_period;
        else rd_acc<=rd_acc+8'd4;
    end
    wire rd_ce=active ? rd_tick : vce;
    wire [23:0] adjusted;
    wire ahs,avs,ahb,avb;
    crt_adjust #(.VTOTAL(264),.HTOTAL(384),.HPOS_MODE(0)) horizontal (
        .clk(clk),.pxl_cen(vce),.pxl2_cen(rd_ce),.active(active),.hsize(hstep),
        .hoffset({{4{hpos[4]}},hpos}),.voffset({vpos[4],vpos}),
        .r_in(vrgb[23:16]),.g_in(vrgb[15:8]),.b_in(vrgb[7:0]),
        .hs_in(vhs),.vs_in(vvs),.hb_in(!vde),.vb_in(vvb),
        .r_out(adjusted[23:16]),.g_out(adjusted[15:8]),.b_out(adjusted[7:0]),
        .hs_out(ahs),.vs_out(avs),.hb_out(ahb),.vb_out(avb),.hs_ref_out(hs_ref)
    );
    // The donor already gates its active window with true vertical blank.
    assign ce_out=active ? rd_ce : ce_in;
    assign rgb_out=active ? adjusted : rgb_in;
    assign hs_out=active ? ahs : hs_in;
    assign vs_out=active ? avs : vs_in;
    // The line-buffer pass flag can remain high for two read pulses after
    // its line reset when enlarged content reaches the sync boundary. Keep
    // that pipeline tail in blanking, including the accumulator rephase.
    assign de_out=active ? !(ahb || avb || hs_ref || ahs) : de_in;
endmodule
