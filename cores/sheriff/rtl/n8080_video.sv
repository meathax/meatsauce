// SPDX-License-Identifier: GPL-3.0-or-later
// Sheriff native RGB -> optional CRT geometry -> standard MiSTer arcade video.
// Credited rmonic79 GPL-3.0 adaptation aligns source-bank VBlank; sys/ is unchanged.
module n8080_video (
    input wire clk, reset, ce_native,
    input wire [2:0] rgb,
    input wire hblank,vblank,hsync,vsync,
    input wire [2:0] effects,
    input wire forced_scandoubler, crt_enabled,
    input wire [3:0] hsize_setting,hpos_setting,vpos_setting,
    inout wire [21:0] gamma_bus,
    output wire clk_video,ce_video,
    output wire [7:0] red,green,blue,
    output wire hs,vs,de,
    output wire [1:0] scanlines
);
    function automatic signed [8:0] adjustment(input [3:0] setting);
        begin
            adjustment=setting<=4 ? $signed({5'b0,setting}) :
                       setting<=8 ? 9'sd4-$signed({5'b0,setting}) : 9'sd0;
        end
    endfunction
    wire signed [4:0] size=5'(adjustment(hsize_setting));
    wire signed [8:0] position=adjustment(hpos_setting)<<<2;
    wire signed [5:0] vertical=6'(adjustment(vpos_setting));
    // Neutral settings preserve the exact native path and need no line buffer.
    wire geometry_active=crt_enabled&&((size!=0)||(position!=0)||(vertical!=0));
    wire [7:0] period=8'd40+{{3{size[4]}},size};
    reg [7:0] phase=0;
    reg read_ce=0,previous_hs=0;
    wire hs_reference;
    wire hs_edge=ce_native&&hs_reference&&!previous_hs;
    // Quarter-pixel rate accumulator. Reset on the same CE-qualified HSync
    // reference used by both halves of the donor's line buffer.
    always @(posedge clk) begin
        if(ce_native)previous_hs<=hs_reference;
        read_ce<=0;
        if(reset||hs_edge)phase<=0;
        else if(phase>=period-8'd4)begin phase<=phase+8'd4-period;read_ce<=1;end
        else phase<=phase+8'd4;
    end
    wire [7:0] crt_r,crt_g,crt_b;
    wire crt_hs,crt_vs,crt_hb,crt_vb;
    n8080_crt_adjust #(.HTOTAL(320),.VTOTAL(256),.HPOS_MODE(0)) geometry (
        .clk(clk),.pxl_cen(ce_native),.pxl2_cen(read_ce),.active(geometry_active),
        .hsize(size),.hoffset(position),.voffset(vertical),
        .r_in({8{rgb[0]}}),.g_in({8{rgb[1]}}),.b_in({8{rgb[2]}}),
        .hs_in(hsync),.vs_in(vsync),.hb_in(hblank),.vb_in(vblank),
        .r_out(crt_r),.g_out(crt_g),.b_out(crt_b),
        .hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),.hs_ref_out(hs_reference)
    );
    // Geometry can change the number of input samples inside native blanking;
    // reserve the complete 320-pixel line for the standard scaler's buffers.
    // Same capture convention as arcade_video, with an explicit freeze input
    // and a scoped-RGB adaptation of the template mixer; sys/ remains pristine.
    assign clk_video=clk;
    wire ce_source=geometry_active?read_ce:ce_native;
    wire hs_fixed,vs_fixed;
    sync_fix sync_h(clk,crt_hs,hs_fixed);
    sync_fix sync_v(clk,crt_vs,vs_fixed);
    reg old_ce=0,ce_capture=0,hs_capture=0,vs_capture=0,hb_capture=1,vb_capture=1;
    reg [23:0] rgb_capture=0;
    always @(posedge clk) begin
        old_ce<=ce_source;ce_capture<=0;
        if(!old_ce&&ce_source)begin
            ce_capture<=1;hs_capture<=hs_fixed;
            if(!hs_capture&&hs_fixed)vs_capture<=vs_fixed;
            rgb_capture<={crt_r,crt_g,crt_b};hb_capture<=crt_hb;
            if(hb_capture&&!crt_hb)vb_capture<=crt_vb;
        end
    end
    wire [2:0] sl=effects?effects-3'd1:3'd0;
    assign scanlines=sl[1:0];
    wire [21:0] configured_gamma;
    wire gamma_enabled;
    n8080_gamma_guard gamma_configuration (
        .clk(clk),.enable_requested(gamma_bus[19]),.write_entry(gamma_bus[18]),
        .write_address(gamma_bus[17:8]),.enable_validated(gamma_enabled)
    );
    assign configured_gamma[20:0]={gamma_bus[20],gamma_enabled,gamma_bus[18:0]};
    assign gamma_bus[21]=configured_gamma[21];
    n8080_video_mixer #(.LINE_LENGTH(324),.HALF_DEPTH(0),.GAMMA(1)) standard_video (
        .CLK_VIDEO(clk),.ce_pix(ce_capture),.CE_PIXEL(ce_video),
        .R(rgb_capture[23:16]),.G(rgb_capture[15:8]),.B(rgb_capture[7:0]),
        .HBlank(hb_capture),.VBlank(vb_capture),.HSync(hs_capture),.VSync(vs_capture),
        .VGA_R(red),.VGA_G(green),.VGA_B(blue),.VGA_HS(hs),.VGA_VS(vs),.VGA_DE(de),
        .scandoubler((effects!=0)||forced_scandoubler),.hq2x(effects==1),
        .HDMI_FREEZE(1'b0),.freeze_sync(),.gamma_bus(configured_gamma)
    );
endmodule
