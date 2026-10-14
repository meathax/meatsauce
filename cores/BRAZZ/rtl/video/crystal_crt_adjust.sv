// BrezzaSoft Crystal System MiSTer core -- CRT Adjust glue.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
// Modified for Arcade-CrystalSystem_MiSTer (2026-10-08): the per-H-Size window tables below were computed for a
// fixed HSync at pixel 361 (their CRTC) and a 320/360 width. This core places HSync from its own CRTC model
// (crysking: pixel 344), so the window is measured from the native stream every frame (active width W and
// HSync-to-active distance A) and hc/lo/hi are computed with the same formulas that generate the original
// tables (verified identical for A=94,W=320 and A=68,W=360): C = A + W/2, f = 100 - hsize,
// hc = round(C*f/100) - C, lo = ceil(34*f/100) - A, hi = floor(455*f/100) - (A + W + 3). The fixed SYNC_LAG = 64 is
// replaced by a measured lag (A - 14) so the late HSync stays in the blanking. `wide` is unused.
//
// OSD CRT Adjust for the native 15-kHz picture, ported from the owner's Namco NB-1 core (nb1_crt_adjust.sv, M17,
// hardware-confirmed), itself the NA-1/NA-2 M26 integration, around the UNMODIFIED upstream
// rtl/vendor/crt_adjust.sv (MiSTer-CRT-Adjust, rmonic79). Same OSD controls, status bits, encodings, ranges and
// defaults as NB-1 / NA-1 / NA-2:
//   [96]      CRT Adjust Off / On (0 = Off = default = TRUE bypass: the native stream, zero latency)
//   [116:112] H-Size OSD index -> -12..+10, one step = 1 % (index 0 = 0, 1..10 = +1..+10,
//             11..22 = -12..-1, 23..31 unreachable = 0); + = WIDER
//   [104:101] H-Position signed -8..+7, one step = 6 pixels (+ moves the picture left, as NA/NB)
//   [108:105] V-Shift    signed -8..+7, one step = 1 line (clamped to -3..+7, below)
//
// Engine as NB-1 (HPOS_CONTENTSHIFT, H-Size about the picture centre, content offset clamped to the blanking,
// syncs fed SYNC_LAG pixels late so the module never sees a negative offset, HSync-to-HSync line window with the
// blank of the line being written / read). Only the geometry is Crystal's:
//   native line 455 pixels at clk_sys/12 (7.159 MHz), active 0..319, HSync 361..394 (34 px); 262 lines, active
//   0..239, VSync 244..246 (CRTC reset defaults = what crysking programs).
//   HSync-to-HSync window: active 94..413, centre 254; in read ticks with f = 1 - hsize / 100:
//     hc = round(254 f) - 254, lo = ceil(34 f) - 94, hi = floor(455 f) - 417.
//   lo >= -63, so SYNC_LAG = 64.
//   360-pixel mode (Top Blade V programs HDISP 360, HSWBP 0x2121: HSync 387..420, same 455 x 262 raster):
//   window active 68..427, centre 248: hc = round(248 f) - 248, lo = ceil(34 f) - 68, hi = floor(455 f) - 431;
//   selected by `wide` (HDISP > 320), sampled per frame.
//   V-Shift: the content is one line late through the buffer (lines 1..240) and VSync starts at line 244, so a
//   negative shift is clamped at -3 (VSync never lands on a picture line).
// The controls are sampled once per frame (frame_event, inside vertical blanking); the adjust is gated off while
// the scandoubler is active; the adjusted stream also reaches HDMI while On (core-side insertion).
module crystal_crt_adjust #(
    parameter integer SYS_HZ = 85_909_080,
    parameter integer PIX_DIV = 12,
    parameter integer HTOTAL = 455,
    parameter integer VTOTAL = 262
) (
    input  wire        clk_sys,
    input  wire        ce_pix,
    input  wire        frame_event,     // one pulse per frame, inside vertical blanking
    // OSD
    input  wire        osd_on,          // status[96]
    input  wire [4:0]  osd_hsize,       // status[116:112]
    input  wire [3:0]  osd_hpos,        // status[104:101]
    input  wire [3:0]  osd_vshift,      // status[108:105]
    input  wire        sd_off,          // scandoubler off (Fx None and not forced)
    input  wire        vb_next,         // the vertical blank of the NEXT native line (see above)
    input  wire        wide,            // 360-pixel picture (HDISP > 320): the second geometry table
    // native stream
    input  wire [23:0] rgb_in,
    input  wire        hblank_in,
    input  wire        vblank_in,
    input  wire        hsync_in,
    input  wire        vsync_in,
    // to arcade_video
    output wire        ce_out,
    output wire [23:0] rgb_out,
    output wire        hblank_out,
    output wire        vblank_out,
    output wire        hsync_out,
    output wire        vsync_out,
    // state (bench / overlay)
    output wire        active,
    output reg  signed [4:0] hsize_s = 5'sd0,
    output reg  signed [3:0] hpos_s  = 4'sd0,
    output reg  signed [3:0] vsh_s   = 4'sd0
);
    reg crt_on = 1'b0;
    always @(posedge clk_sys) if (frame_event) begin
        crt_on  <= osd_on;
        hsize_s <= (osd_hsize <= 5'd10) ? $signed(osd_hsize)
                 : (osd_hsize <= 5'd22) ? $signed(osd_hsize - 5'd23)
                 : 5'sd0;
        hpos_s  <= $signed(osd_hpos);
        vsh_s   <= $signed(osd_vshift);
    end
    assign active = crt_on && sd_off;

    // Native window measurement (pixels on ce_pix): W = active pixels per line, A = HTOTAL minus the HSync start
    // counted from the first active pixel. Latched per frame.
    reg [9:0] px_cnt = 10'd0, w_line = 10'd320, hs_pos = 10'd361, w_q = 10'd320, a_q = 10'd94;
    reg hb_d = 1'b1, hs_d = 1'b0;
    always @(posedge clk_sys) if (ce_pix) begin
        hb_d <= hblank_in; hs_d <= hsync_in;
        px_cnt <= (hb_d && !hblank_in) ? 10'd1 : px_cnt + 10'd1;
        if (!hb_d && hblank_in && !vblank_in) w_line <= px_cnt;
        if (hsync_in && !hs_d && !vblank_in) hs_pos <= px_cnt;
    end
    always @(posedge clk_sys) if (frame_event) begin w_q <= w_line; a_q <= 10'(HTOTAL) - hs_pos; end
    // hc/lo/hi pipeline (constant between frame events): x/100 = (x * 83887) >> 23, exact for x <= 60000.
    reg signed [8:0] hc, lo, hi;
    reg [6:0]  f_q = 7'd100;
    reg [9:0]  c_q = 10'd254;
    reg [16:0] cf_q = 17'd0, sf_q = 17'd0, tf_q = 17'd0;
    always @(posedge clk_sys) begin
        f_q  <= 7'(8'sd100 - 8'(hsize_s));
        c_q  <= a_q + {1'b0, w_q[9:1]};
        cf_q <= 17'(c_q * f_q + 17'd50);
        sf_q <= 17'(7'd34 * f_q + 17'd99);
        tf_q <= 17'(9'(HTOTAL) * f_q);
        hc   <= 9'(((34'(cf_q) * 34'd83887) >> 23)) - 9'(c_q);
        lo   <= 9'(((34'(sf_q) * 34'd83887) >> 23)) - 9'(a_q);
        hi   <= 9'(((34'(tf_q) * 34'd83887) >> 23)) - 9'(a_q + w_q + 10'd3);
    end
    reg signed [8:0] hoff_q = 9'sd0;
    wire signed [9:0] hoff_raw = $signed({hc[8], hc}) - ($signed({{6{hpos_s[3]}}, hpos_s}) * 10'sd6);
    always @(posedge clk_sys)
        hoff_q <= (hoff_raw < $signed({lo[8], lo})) ? lo : (hoff_raw > $signed({hi[8], hi})) ? hi : hoff_raw[8:0];
    // Sync lag (pixels): the late HSync must land in the blanking just before the next picture, and the
    // offset (hoff + lag) must stay non-negative: lag = A - 14 gives hoff + lag >= ceil(34f) - 14 > 0.
    localparam integer SYNC_LAG = 128; // shift-register depth (max lag)
    reg [7:0] lag_q = 8'd80;
    always @(posedge clk_sys) lag_q <= (a_q > 10'd141) ? 8'd127 : (a_q < 10'd30 ? 8'd16 : 8'(a_q - 10'd14));
    wire signed [8:0] hoffset = active ? (hoff_q + $signed({1'b0, lag_q})) : 9'sd0;
    wire signed [3:0] vsh_c   = (vsh_s < -4'sd3) ? -4'sd3 : vsh_s;
    wire signed [5:0] voffset = active ? $signed({{2{vsh_c[3]}}, vsh_c}) : 6'sd0;

    localparam integer PIXEL_HZ = SYS_HZ / PIX_DIV;
    localparam integer STEP     = (PIXEL_HZ + 50) / 100;
    wire hs_ref;
    reg  hs_ref_d = 1'b0;
    always @(posedge clk_sys) hs_ref_d <= hs_ref;
    wire hs_ref_rise = hs_ref && !hs_ref_d;
    // registered: hsize_s changes only at a frame event, so one clock late is exact
    reg  signed [31:0] read_inc = PIXEL_HZ;
    always @(posedge clk_sys) read_inc <= PIXEL_HZ - (hsize_s * STEP);
    reg  [26:0] phase = 27'd0;
    wire [27:0] phase_sum = {1'b0, phase} + read_inc[26:0];
    wire rd_tick = (phase_sum >= SYS_HZ);
    always @(posedge clk_sys) begin
        if (hs_ref_rise)  phase <= 27'd0;
        else if (rd_tick) phase <= phase_sum - SYS_HZ;
        else              phase <= phase_sum[26:0];
    end
    reg use_nco = 1'b0;
    always @(posedge clk_sys) use_nco <= active && (hsize_s != 5'sd0);
    wire rd_ce = use_nco ? rd_tick : ce_pix;

    // vertical blank of the line being written in the module's HSync-to-HSync window: after the native
    // HSync (pixel 361) that window holds the NEXT line; sampled by the module at the HSync rise
    wire vb_wr = vb_next;
    // HSync / VSync, SYNC_LAG pixels late (native pixel CE)
    reg [SYNC_LAG-1:0] hs_dl = '0, vs_dl = '0;
    always @(posedge clk_sys) if (ce_pix) begin
        hs_dl <= {hs_dl[SYNC_LAG-2:0], hsync_in};
        vs_dl <= {vs_dl[SYNC_LAG-2:0], vsync_in};
    end
    wire hs_lag = hs_dl[lag_q - 8'd1];
    wire vs_lag = vs_dl[lag_q - 8'd1];
    // ... and of the line being read (the module's vb_line / vb_active pair, same edge)
    reg hs_in_d = 1'b0, vb_l1 = 1'b0, vb_rd = 1'b0;
    always @(posedge clk_sys) if (ce_pix) begin
        hs_in_d <= hs_lag;
        if (hs_lag && !hs_in_d) begin vb_l1 <= vb_wr; vb_rd <= vb_l1; end
    end
    wire [23:0] a_rgb;
    wire a_hs, a_vs, a_hb, a_vb;
    crt_adjust #(.VTOTAL(VTOTAL), .HTOTAL(HTOTAL), .HPOS_MODE(1)) crt_adjust (
        .clk(clk_sys), .pxl_cen(ce_pix), .pxl2_cen(rd_ce),
        .active(active),
        .hsize(hsize_s), .hoffset(hoffset), .voffset(voffset),
        .r_in(rgb_in[23:16]), .g_in(rgb_in[15:8]), .b_in(rgb_in[7:0]),
        .hs_in(hs_lag), .vs_in(vs_lag), .hb_in(hblank_in), .vb_in(vb_wr),
        .r_out(a_rgb[23:16]), .g_out(a_rgb[15:8]), .b_out(a_rgb[7:0]),
        .hs_out(a_hs), .vs_out(a_vs), .hb_out(a_hb), .vb_out(a_vb),
        .hs_ref_out(hs_ref));

    // TRUE bypass when Off: the native stream, zero added latency (the M16 picture)
    assign ce_out     = active ? rd_ce : ce_pix;
    assign rgb_out    = active ? a_rgb : rgb_in;
    assign hblank_out = active ? a_hb  : hblank_in;
    assign vblank_out = active ? vb_rd : vblank_in;
    assign hsync_out  = active ? a_hs  : hsync_in;
    assign vsync_out  = active ? a_vs  : vsync_in;
endmodule
