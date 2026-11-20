// SPDX-License-Identifier: GPL-3.0-or-later
// Core-side geometry for the synthesized 512x400 MAME scanout. This does
// not establish the original PCB's analog raster or convert it to 15 kHz.
module gs_crt_video #(parameter PIXEL_UNITS=125,parameter HTOTAL=512,parameter VTOTAL=400,parameter FIXED_OUTPUT=0)(
    input wire clk, reset, enable, ce_in,
    input wire signed [4:0] hsize,
    input wire signed [8:0] hoffset,
    input wire signed [5:0] voffset,
    input wire [23:0] rgb_in,
    input wire hs_in, vs_in, hb_in, vb_in,
    output wire ce_out,
    output wire ce2_out,
    output wire [23:0] rgb_out,
    output wire hs_out, vs_out, hb_out, vb_out
);
    // A quarter-clock size step changes PIXEL_UNITS/24 clocks per pixel to
    // (PIXEL_UNITS + 6*size)/24. Even the default minimum is 101/24 > 4
    // clocks/pixel, as required by the framework video mixer.
    wire signed [4:0] size_limited = hsize < -5'sd4 ? -5'sd4 :
                                    hsize > 5'sd4 ? 5'sd4 : hsize;
    wire signed [9:0] period_signed = PIXEL_UNITS +
        10'sd6 * {{5{size_limited[4]}},size_limited};
    wire [7:0] period = period_signed[7:0];
    reg [7:0] phase = 0;
    wire [8:0] phase_next = {1'b0,phase} + 9'd24;
    wire read_tick = phase_next >= {1'b0,period};
    wire [8:0] phase_remainder = phase_next - {1'b0,period};
    wire hs_ref;
    reg hs_ref_d = 0;
    wire hs_rise = hs_ref && !hs_ref_d;
    always @(posedge clk) begin
        hs_ref_d <= hs_ref;
        if (reset || hs_rise) phase <= 0;
        else phase <= read_tick ? phase_remainder[7:0] : phase_next[7:0];
    end

    // The scan doubler must follow the adjusted read cadence. Both fractional
    // phases restart at the same native line reference for nonzero size.
    // At zero size/off, retain the continuous exact 48/125 enable stream.
    wire resized = enable && size_limited != 0;
    wire [7:0] double_period = resized && !FIXED_OUTPUT ? period : PIXEL_UNITS;
    reg [7:0] double_phase = 0;
    reg double_ce = 0;
    wire [8:0] double_next = {1'b0,double_phase} + 9'd48;
    wire double_tick = double_next >= {1'b0,double_period};
    wire [8:0] double_remainder = double_next - {1'b0,double_period};
    always @(posedge clk) begin
        double_ce <= double_tick;
        if (reset || (resized && hs_rise)) double_phase <= 0;
        else double_phase <= double_tick ? double_remainder[7:0] : double_next[7:0];
        if (reset) double_ce <= 0;
    end
    // Fixed-output presentation uses a plain, reset-independent /4 counter.
    reg [1:0] fixed_double_phase=0;
    always @(posedge clk) fixed_double_phase<=fixed_double_phase+1'b1;
    assign ce2_out = FIXED_OUTPUT ? fixed_double_phase==2'd1 : double_ce;

    // Preserve the precise source cadence at zero size rather than restarting
    // a separately rounded pixel divider on each fractional-length line.
    wire read_ce = size_limited == 0 ? ce_in : read_tick;
    reg result_ce = 0;
    always @(posedge clk) begin
        result_ce <= read_ce;
        if (reset) result_ce <= 0;
    end
    wire [23:0] adjusted_rgb;
    wire adjusted_hs,adjusted_vs,adjusted_hb,adjusted_vb;
    crt_adjust #(.HTOTAL(HTOTAL),.VTOTAL(VTOTAL),.HPOS_MODE(1)) geometry (
        .clk(clk),.pxl_cen(ce_in),.pxl2_cen(read_ce),
        .active(enable),.hsize(size_limited),.hoffset(hoffset),.voffset(voffset),
        .r_in(rgb_in[23:16]),.g_in(rgb_in[15:8]),.b_in(rgb_in[7:0]),
        .hs_in(hs_in),.vs_in(vs_in),.hb_in(hb_in),.vb_in(vb_in),
        .r_out(adjusted_rgb[23:16]),.g_out(adjusted_rgb[15:8]),.b_out(adjusted_rgb[7:0]),
        .hs_out(adjusted_hs),.vs_out(adjusted_vs),
        .hb_out(adjusted_hb),.vb_out(adjusted_vb),.hs_ref_out(hs_ref));

    // Off is an exact combinational bypass, including CE and sync/blanking.
    reg fixed_ce=0;
    reg [27:0] fixed_bypass=0,bypass_pixel=0;
    always @(posedge clk)begin
        fixed_ce<=ce_in;
        // CRT Adjust's default output is one pixel later than its input.
        // Give bypass the same pixel latency without changing the CE phase.
        if(ce_in)bypass_pixel<={rgb_in,hs_in,vs_in,hb_in,vb_in};
        fixed_bypass<=bypass_pixel;
    end
    // Fixed mode has one latency for both menu states and keeps CE during reset.
    assign ce_out = FIXED_OUTPUT ? fixed_ce : (enable ? result_ce : ce_in);
    assign rgb_out = enable ? adjusted_rgb : (FIXED_OUTPUT ? fixed_bypass[27:4] : rgb_in);
    assign hs_out = enable ? adjusted_hs : (FIXED_OUTPUT ? fixed_bypass[3] : hs_in);
    assign vs_out = enable ? adjusted_vs : (FIXED_OUTPUT ? fixed_bypass[2] : vs_in);
    assign hb_out = enable ? adjusted_hb : (FIXED_OUTPUT ? fixed_bypass[1] : hb_in);
    assign vb_out = enable ? adjusted_vb : (FIXED_OUTPUT ? fixed_bypass[0] : vb_in);
endmodule
