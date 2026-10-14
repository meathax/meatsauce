// -----------------------------------------------------------------------------
// smashtv_video.sv
//
// Video timing + frame-buffer scanout + palette for the Midway Y-Unit. Produces
// an RGB stream with sync/blank for the MiSTer scaler.
//
// Timing is Smash T.V.'s, from MAME williams/midyunit.cpp:
//   screen.set_raw(STDRES_PIXEL_CLOCK*2, 506, 90, 500, 289, 20, 276)
//   => dot clock 8 MHz, htotal 506, h visible [90,500) = 410 px,
//      vtotal 289, v visible [20,276) = 256 lines, ~54.71 Hz.
// (The real chip programs these from the TMS34010 video registers at runtime;
// this stage uses the fixed Smash T.V. numbers. Wiring the TMS video-timing
// generator in is a later refinement.)
//
// Colour path is MAME-exact (midyunit_v.cpp):
//   pen  = ((word & 0xc000) >> 8) | (word & 0x0f3f)      [6bpp pen_map]
//   pen &= 0x0fff                                         [palette_mask]
//   pal_word = paletteram[pen]                            [x RRRRR GGGGG BBBBB]
//   R = pal5bit(pal_word >> 10); G = pal5bit(>>5); B = pal5bit(>>0)
//   pal5bit(v) = (v<<3) | (v>>2)                          [5->8 bits]
//
// The frame buffer read (scan_pixel) and the palette read are each registered,
// so the sync/blank signals are delayed to match through a small pipeline.
//
// Palette RAM: 4096 entries (mask 0x0fff; the upper half aliases on write, per
// MAME). CPU writes a 16-bit word; the video side reads by pen index.
//
// Verified by sim/video_check/tb_video.sv: the colour path against a MAME
// reference, and the timing counters against the set_raw geometry.
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_video #(
  // Z-unit NARC uses a 16 MHz, 512x400 raster and an 8192-entry palette.
  // Defaults preserve the verified Smash TV Y-unit path.
  parameter bit ZUNIT_8BPP = 1'b0,
  parameter int PAL_AW  = ZUNIT_8BPP ? 13 : 12,
  parameter int HTOTAL  = ZUNIT_8BPP ? 674 : 506,
  parameter int HEBLNK  = ZUNIT_8BPP ? 122 : 90,
  parameter int HSBLNK  = ZUNIT_8BPP ? 634 : 500,
  parameter int VTOTAL  = ZUNIT_8BPP ? 433 : 289,
  parameter int VEBLNK  = ZUNIT_8BPP ? 27 : 20,
  parameter int VSBLNK  = ZUNIT_8BPP ? 427 : 276,
  // TMS34010 sync intervals begin at counter zero and end at HESYNC/VESYNC.
  // NARC's horizontal registers count two output pixels per unit, hence
  // HESYNC=0x1c is a 56-pixel pulse; vertical registers count scanlines.
  parameter int HS_START = ZUNIT_8BPP ? 0 : 6,
  parameter int HS_END   = ZUNIT_8BPP ? 56 : 34,
  parameter int VS_START = ZUNIT_8BPP ? 0 : 282,
  parameter int VS_END   = ZUNIT_8BPP ? 3 : 285,
  // CRT overscan trim: widens the BLANKING only (VRAM mapping unchanged).
  // Disabled (all 0) per user preference -- the full 410x256 is shown,
  // including the edge scratch pixels the original CRT hid.
  parameter int H_TRIM_L = 0,
  parameter int H_TRIM_R = 0,
  parameter int V_TRIM_T = 0,
  parameter int V_TRIM_B = 0
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        ce_pix,          // 8 MHz dot-clock enable
  input  wire        cfg_4bpp,        // 1 = 4bpp pen map (Trog); 0 = 6bpp (Smash TV)

  // CPU palette write (paletteram_w). offset masked to 0x0fff.
  input  wire        pal_we,
  input  wire [PAL_AW-1:0] pal_addr,
  input  wire [15:0] pal_data,

  // CPU palette read-back. The Y-Unit boot RAM-tests palette RAM (write a
  // pattern, read it back, compare); without a read port the read returns 0,
  // the self-test fails and the boot hangs. Registered read (valid next cycle,
  // within the peripheral 2-cycle ack window).
  input  wire [PAL_AW-1:0] pal_cpu_addr,
  output wire [15:0] pal_cpu_data,

  // TMS34010 DPYINT scanline register (from I/O reg file). Used to fire the
  // display interrupt at the correct scan line instead of just at vblank.
  input  wire [15:0] dpyint_line,
  input  wire [15:0] dpyctl,
  input  wire [15:0] dpytap,
  input  wire [15:0] dpyadr,
  // Live HCOUNT/VCOUNT exposed for I/O register reads (CPU polling).
  output wire [15:0] hcount_o,
  output wire [15:0] vcount_o,
  output wire        dpyint_pulse_o, // one-cycle pulse at DPYINT scan-line start

  // Frame-buffer scan port (to smashtv_vram scan port). scan_pixel is the
  // 16-bit frame-buffer word, valid one cycle after scan_idx.
  output wire [17:0] scan_idx,
  input  wire [15:0] scan_pixel,

  // Video output
  output reg  [7:0]  r,
  output reg  [7:0]  g,
  output reg  [7:0]  b,
  output reg         hsync,
  output reg         vsync,
  output reg         hblank,
  output reg         vblank,
  output wire        vblank_ae,       // UNTRIMMED vblank for the autoerase fill:
                                      // the overscan trim widens the display
                                      // vblank, and keying the cache fill on it
                                      // starts the fill early, starving the last
                                      // visible lines' erase (row-254 remnant).
  output reg         ce_pix_o         // pixel strobe aligned to r/g/b
);

  // --- Counters ------------------------------------------------------------
  logic [9:0] hc;
  logic [9:0] vc;
  always_ff @(posedge clk) begin
    if (rst) begin
      hc <= 10'd0; vc <= 10'd0;
    end else if (ce_pix) begin
      if (hc == 10'(HTOTAL-1)) begin
        hc <= 10'd0;
        vc <= (vc == 10'(VTOTAL-1)) ? 10'd0 : vc + 10'd1;
      end else begin
        hc <= hc + 10'd1;
      end
    end
  end

  // Expose live counters so the TMS34010 I/O register reads return the real
  // pixel-clock position rather than dead storage.
  assign hcount_o = {6'd0, hc};
  assign vcount_o = {6'd0, vc};
  // DPYINT pulse: one ce_pix tick at HCOUNT==0 on the programmed scan line.
  // ce_pix ensures the pulse is a single clk_sys cycle even at hc=0 which
  // holds for 3 clk_sys cycles; without ce_pix the ISR could be entered 3x.
  assign dpyint_pulse_o = ce_pix && dpyctl[15] &&
                          (hc == 10'd0) && (vc == dpyint_line[9:0]);

  // DPYINT/counter semantics keep the untrimmed window; only display blanking
  // is narrowed by the overscan trim.
  wire h_visible = (hc >= 10'(HEBLNK + H_TRIM_L)) && (hc < 10'(HSBLNK - H_TRIM_R));
  wire v_visible = (vc >= 10'(VEBLNK + V_TRIM_T)) && (vc < 10'(VSBLNK - V_TRIM_B));
  // untrimmed vertical blanking (the machine's real vblank window)
  assign vblank_ae = !((vc >= 10'(VEBLNK)) && (vc < 10'(VSBLNK)));
  wire [9:0] col = hc - HEBLNK[9:0];   // 0..409 over the untrimmed window

  // TMS34010 refresh mapping, matching MAME get_display_params() and the
  // Williams scanline callback. DPYCTL.ORG=0 complements SRFADR.
  wire [15:0] dpyadr_eff = dpyctl[10] ? dpyadr : (dpyadr ^ 16'hfffc);
  wire [8:0]  dpy_row = dpyadr_eff[12:4];
  wire [13:0] dpy_col = {3'b000, dpyadr_eff[6:2], 6'b000000} |
                         dpytap[13:0];
  wire [14:0] scan_col = {dpy_col, 1'b0} + {5'd0, col};
  assign scan_idx = {dpy_row, 9'h0} + {9'd0, scan_col[8:0]};

  // --- Palette RAM ---------------------------------------------------------
  // pen_map of the frame-buffer word -> palette index. Per MAME midyunit_v.cpp
  // video_start: 6bpp uses ((w&0xc000)>>8)|(w&0x0f3f) mask 0x0fff; 4bpp (Trog)
  // uses ((w&0xf000)>>8)|(w&0x000f) mask 0x00ff.
  function automatic [11:0] pen_map6(input [15:0] w);
    pen_map6 = {w[11:8], w[15:14], w[5:0]};
  endfunction
  function automatic [11:0] pen_map4(input [15:0] w);
    pen_map4 = {4'b0000, w[15:12], w[3:0]};
  endfunction
  function automatic [12:0] pen_map8(input [15:0] w);
    pen_map8 = w[12:0];
  endfunction
  wire [12:0] scan_pen8 = pen_map8(scan_pixel);
  wire [12:0] scan_pen6 = {1'b0, pen_map6(scan_pixel)};
  wire [12:0] scan_pen4 = {1'b0, pen_map4(scan_pixel)};
  wire [PAL_AW-1:0] scan_pen = ZUNIT_8BPP ? scan_pen8
                                  : cfg_4bpp ? scan_pen4 : scan_pen6;

  // Palette RAM as a true-dual-port block RAM. Port A handles both CPU writes
  // and CPU read-back; port B is the independent scanout read. Describing the
  // write and CPU read as separate ports makes Quartus replicate the 8Kx16 RAM
  // to obtain a third port (31 M10Ks instead of the physical 16).
  wire [15:0] pal_rd;
  wire [PAL_AW-1:0] pal_a_addr = pal_we ? pal_addr : pal_cpu_addr;
  dpram_tdp #(.AW(PAL_AW), .DW(16)) u_palette (
    .clk(clk),
    .addr_a(pal_a_addr), .din_a(pal_data), .we_a(pal_we), .q_a(pal_cpu_data),
    .addr_b(scan_pen), .din_b(16'd0), .we_b(1'b0), .q_b(pal_rd)
  );

  // pal5bit: 5 -> 8 bits.
  function automatic [7:0] pal5(input [4:0] v);
    pal5 = {v, v[4:2]};
  endfunction

  // --- Pipeline ------------------------------------------------------------
  wire hs_now = (HS_START == 0) ? (hc < 10'(HS_END))
                                : ((hc >= 10'(HS_START)) && (hc < 10'(HS_END)));
  wire vs_now = (VS_START == 0) ? (vc < 10'(VS_END))
                                : ((vc >= 10'(VS_START)) && (vc < 10'(VS_END)));
  wire hb_now = !h_visible;
  wire vb_now = !v_visible;
  wire vis_now = h_visible && v_visible && dpyctl[15];

  // Colour latency = VRAM (1 clk) + palette (1 clk) = 2 clk_sys behind hc.
  //
  // Y-unit uses 1-of-3 ce_pix, so two idle clocks sit between enables and a
  // 2-deep pipeline stepped on ce_pix matches that latency.
  //
  // Z-unit / NARC uses 2-of-3 (consecutive enables). Stepping the pipeline on
  // ce_pix alone is only 1 clk_sys apart — pal_rd is then still catching up.
  // Z therefore delays sync/blank/RGB on every clk_sys for two stages.
  logic hs_p, vs_p, hb_p, vb_p, vis_p;
  logic hs_d1, vs_d1, hb_d1, vb_d1, vis_d1;
  logic hs_d2, vs_d2, hb_d2, vb_d2, vis_d2;
  always_ff @(posedge clk) begin
    if (rst) begin
      hs_p <= 0; vs_p <= 0; hb_p <= 1'b1; vb_p <= 1'b1; vis_p <= 0;
      hs_d1 <= 0; vs_d1 <= 0; hb_d1 <= 1'b1; vb_d1 <= 1'b1; vis_d1 <= 0;
      hs_d2 <= 0; vs_d2 <= 0; hb_d2 <= 1'b1; vb_d2 <= 1'b1; vis_d2 <= 0;
      r <= 0; g <= 0; b <= 0;
      hsync <= 0; vsync <= 0; hblank <= 1; vblank <= 1; ce_pix_o <= 0;
    end else begin
      if (ZUNIT_8BPP) begin
        // Free-running 2-stage match for VRAM+palette latency.
        hs_d1 <= hs_now;  vs_d1 <= vs_now;
        hb_d1 <= hb_now;  vb_d1 <= vb_now;  vis_d1 <= vis_now;
        hs_d2 <= hs_d1;   vs_d2 <= vs_d1;
        hb_d2 <= hb_d1;   vb_d2 <= vb_d1;   vis_d2 <= vis_d1;

        if (vis_d2) begin
          r <= pal5(pal_rd[14:10]);
          g <= pal5(pal_rd[9:5]);
          b <= pal5(pal_rd[4:0]);
        end else begin
          r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end
        hsync  <= hs_d2;  vsync  <= vs_d2;
        hblank <= hb_d2;  vblank <= vb_d2;
        // Preserve the native 2-of-3 synchronous enable. NARC's wrapper marks
        // this as CE_LEVEL so adjacent enabled clocks remain two distinct
        // pixels; edge-converting this pattern collapses 512 pixels to 256.
        ce_pix_o <= ce_pix;
      end else if (ce_pix) begin
        hs_p  <= hs_now;  vs_p <= vs_now;
        hb_p  <= hb_now;  vb_p <= vb_now;  vis_p <= vis_now;

        if (vis_p) begin                             // tick 2, blank-gated
          r <= pal5(pal_rd[14:10]);
          g <= pal5(pal_rd[9:5]);
          b <= pal5(pal_rd[4:0]);
        end else begin
          r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end

        hsync  <= hs_p;  vsync  <= vs_p;
        hblank <= hb_p;  vblank <= vb_p;
        ce_pix_o <= 1'b1;
      end else begin
        ce_pix_o <= 1'b0;
      end
    end
  end

endmodule
`default_nettype wire
