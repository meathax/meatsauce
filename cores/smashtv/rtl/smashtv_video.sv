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
  input  wire [11:0] pal_addr,
  input  wire [15:0] pal_data,

  // CPU palette read-back. The Y-Unit boot RAM-tests palette RAM (write a
  // pattern, read it back, compare); without a read port the read returns 0,
  // the self-test fails and the boot hangs. Registered read (valid next cycle,
  // within the peripheral 2-cycle ack window).
  input  wire [11:0] pal_cpu_addr,
  output reg  [15:0] pal_cpu_data,

  // TMS34010 DPYINT scanline register (from I/O reg file). Used to fire the
  // display interrupt at the correct scan line instead of just at vblank.
  input  wire [15:0] dpyint_line,
  input  wire [15:0] dpystrt,        // DPYSTRT: per-frame display start (vertical scroll)
  input  wire [15:0] dpyctl,         // DPYCTL: DUDATE = bits[9:2]; origin bit 0x400
  // Live HCOUNT/VCOUNT exposed for I/O register reads (CPU polling).
  output wire [15:0] hcount_o,
  output wire [15:0] vcount_o,
  output wire        dpyint_pulse_o, // one-cycle pulse at DPYINT scan-line start

  // Frame-buffer scan port (to smashtv_vram scan port). scan_pixel is the
  // 16-bit frame-buffer word, valid one cycle after scan_idx.
  output wire [17:0] scan_idx,
  output wire [8:0]  rowaddr_o,       // scrolled VRAM row being scanned (for autoerase)
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

  // --- Timing constants (Smash T.V. set_raw) -------------------------------
  localparam int HTOTAL = 506;
  localparam int HEBLNK = 90;    // first visible column
  localparam int HSBLNK = 500;   // first blanked column after visible
  localparam int VTOTAL = 289;
  localparam int VEBLNK = 20;    // first visible line
  localparam int VSBLNK = 276;   // first blanked line after visible
  // Sync pulses: place a nominal sync inside blanking (exact front/back porch
  // split isn't specified by set_raw; the scaler only needs consistent edges).
  localparam int HS_START = 512 % HTOTAL; // near end of line
  localparam int HS_END   = 540 % HTOTAL;
  localparam int VS_START = 282;
  localparam int VS_END   = 285;

  // --- Counters ------------------------------------------------------------
  logic [9:0] hc;
  logic [9:0] vc;
  always_ff @(posedge clk) begin
    if (rst) begin
      hc <= 10'd0; vc <= 10'd0;
    end else if (ce_pix) begin
      if (hc == HTOTAL-1) begin
        hc <= 10'd0;
        vc <= (vc == VTOTAL-1) ? 10'd0 : vc + 10'd1;
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
  assign dpyint_pulse_o = ce_pix && (hc == 10'd0) && (vc == dpyint_line[9:0]);

  // DPYINT/counter semantics keep the untrimmed window; only display blanking
  // is narrowed by the overscan trim.
  wire h_visible = (hc >= HEBLNK + H_TRIM_L) && (hc < HSBLNK - H_TRIM_R);
  wire v_visible = (vc >= VEBLNK + V_TRIM_T) && (vc < VSBLNK - V_TRIM_B);
  // untrimmed vertical blanking (the machine's real vblank window)
  assign vblank_ae = !((vc >= VEBLNK) && (vc < VSBLNK));
  wire [9:0] col = hc - HEBLNK[9:0];   // 0..409 over the untrimmed window
  wire [8:0] row = vc[8:0] - VEBLNK[8:0]; // 0..255 over the untrimmed window

  // -------------------------------------------------------------------------
  // DPYADR walker -- MAME tms34010.cpp scanline_update. At vblank DPYADR is
  // loaded with DPYSTRT; each visible line DPYADR -= DUDATE (DPYCTL[9:2]); the
  // scanned VRAM row = (DPYADR ^ 0xFFFC) >> 4 (XOR when DPYCTL.origin bit 0x400
  // is clear, as on Smash TV / Total Carnage). This makes the display SCROLL
  // when the game rewrites DPYSTRT (Total Carnage boss / Pleasure-Dome sections
  // via `move a0,@DPYSTRT`). Smash TV holds DPYSTRT=0xFFFC, DUDATE=0x10, for
  // which rowaddr == row exactly, so this is a no-op there (verified equivalent).
  wire [15:0] dudate     = dpyctl & 16'h03fc;
  wire        line_start = ce_pix && (hc == 10'd0);
  reg  [15:0] dpyadr_acc = 16'hFFFC;
  always @(posedge clk) begin
    if (rst) dpyadr_acc <= 16'hFFFC;
    else if (line_start) begin
      if (vc[9:0] <= VEBLNK[9:0])       dpyadr_acc <= dpystrt;             // vblank + line 0: load DPYSTRT
      else if (vc[9:0] < VSBLNK[9:0])   dpyadr_acc <= dpyadr_acc - dudate; // visible lines: DUDATE walk
    end
  end
  wire [15:0] dpyadr_x = dpyctl[10] ? dpyadr_acc : (dpyadr_acc ^ 16'hFFFC);
  wire [8:0]  rowaddr  = dpyadr_x[12:4];   // (DPYADR^0xFFFC) >> 4, VRAM row (mod 512)
  assign rowaddr_o = rowaddr;

  // Frame-buffer index: rowaddr*512 + col.
`ifdef SMASHTV_DEBUG_AE
  // DIAGNOSTIC: display the AUTOERASE SOURCE lines directly at the top of the
  // screen, bypassing the autoerase copy. Rows 0-11 -> VRAM line 510, rows
  // 12-23 -> VRAM line 511. If these bands show the grey floor colour, the
  // source (510/511) IS populated -> the cache-fill/erase path drops it; if
  // they are black, the game's writes to 510/511 never landed (CPU/blit path).
  // Bands in the MIDDLE of the screen (clear of overscan trim + HUD): rows
  // 108-119 -> line 510, rows 120-131 -> line 511.
  wire       dbg_band   = (row >= 9'd108) && (row < 9'd132);
  wire [8:0] dbg_srcrow = (row < 9'd120) ? 9'd510 : 9'd511;
  assign scan_idx = dbg_band ? ({dbg_srcrow, 9'h0} + col[8:0])
                             : ({rowaddr, 9'h0} + col[8:0]);
`else
  assign scan_idx = {rowaddr, 9'h0} + col[8:0];
`endif

  // --- Palette RAM ---------------------------------------------------------
  // pen_map of the frame-buffer word -> palette index. Per MAME midyunit_v.cpp
  // video_start: 6bpp uses ((w&0xc000)>>8)|(w&0x0f3f) mask 0x0fff; 4bpp (Trog)
  // uses ((w&0xf000)>>8)|(w&0x000f) mask 0x00ff.
  function automatic [11:0] pen_map6(input [15:0] w);
    pen_map6 = (((w & 16'hc000) >> 8) | (w & 16'h0f3f)) & 12'h0fff;
  endfunction
  function automatic [11:0] pen_map4(input [15:0] w);
    pen_map4 = (((w & 16'hf000) >> 8) | (w & 16'h000f)) & 12'h00ff;
  endfunction
  wire [11:0] scan_pen = cfg_4bpp ? pen_map4(scan_pixel) : pen_map6(scan_pixel);

  // Palette RAM as a clean simple-dual-port block RAM: a write-only port and a
  // read-only port, each in its own always block with no reset on the output
  // register (M10K output registers have no async clear). Keeping the read out of
  // the big output pipeline is what lets Quartus infer it -- inline, gated by
  // ce_pix and mixed with reset logic, it became a 4096:1 mux + 65 K registers.
  (* ramstyle = "M10K" *) logic [15:0] paletteram [0:4095];
  logic [15:0] pal_rd;
  always_ff @(posedge clk) if (pal_we) paletteram[pal_addr] <= pal_data;           // write port
  always_ff @(posedge clk) if (ce_pix) pal_rd <= paletteram[scan_pen];             // scan read port
  always_ff @(posedge clk) pal_cpu_data <= paletteram[pal_cpu_addr];               // CPU read-back port

  // pal5bit: 5 -> 8 bits.
  function automatic [7:0] pal5(input [4:0] v);
    pal5 = {v, v[4:2]};
  endfunction

  // --- Pipeline ------------------------------------------------------------
  wire hs_now = (hc >= HS_START) && (hc < HS_END);
  wire vs_now = (vc >= VS_START) && (vc < VS_END);
  wire hb_now = !h_visible;
  wire vb_now = !v_visible;
  wire vis_now = h_visible && v_visible;

  // Colour latency from the counters to the RGB output is two ce_pix ticks:
  //   scan_pixel settles within the tick (VRAM 1-clk read << ce_pix period),
  //   so pal_rd is one tick behind the counters and r one more -> 2 ticks.
  // A 1-deep control register plus the output register puts sync/blank at the
  // same 2 ticks, so every output leaves aligned.
  logic hs_p, vs_p, hb_p, vb_p, vis_p;

  always_ff @(posedge clk) begin
    if (rst) begin
      hs_p <= 0; vs_p <= 0; hb_p <= 1'b1; vb_p <= 1'b1; vis_p <= 0;
      r <= 0; g <= 0; b <= 0;
      hsync <= 0; vsync <= 0; hblank <= 1; vblank <= 1; ce_pix_o <= 0;
    end else if (ce_pix) begin
      hs_p  <= hs_now;  vs_p <= vs_now;
      hb_p  <= hb_now;  vb_p <= vb_now;  vis_p <= vis_now;

      if (vis_p) begin                               // tick 2, blank-gated
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

endmodule
`default_nettype wire
