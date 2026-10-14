// ---------------------------------------------------------------------------
// narc_diag_overlay.sv -- general-purpose on-screen diagnostic overlay.
//
// NEW AND UNWIRED. Nothing in files.qip references this file and nothing in
// Arcade-NARC.sv instantiates it. It is inert until someone wires it in behind a
// `ifdef, which is deliberate: see doc/DIAG_OVERLAY.md for how.
//
// PROVENANCE
//   Adapted from the sibling Midway Wolf/Y-unit MiSTer core's rtl/diag/
//   smashtv_diag2_overlay.sv. That module's RENDERER is entirely generic -- the
//   3x5 hex glyph LUT, the per-frame toggle-detect liveness logic, the LED lane
//   geometry, the hex row banding, and the quadrant composite over live game
//   video. Its COUPLING to their core is confined to two places: the port list
//   (cpu_ce / unp_done / derailed / culprit_pc / ...) and the two always_comb
//   blocks that hardwire those names into LED lanes and hex rows.
//
//   So this version keeps the renderer and replaces the coupling with packed
//   vector ports: you pass N 32-bit values to display as hex rows and N status
//   bits to display as LEDs, and you decide at the instantiation site what they
//   mean. Their hardcoded geometry constants (32px digits, 44px row bands,
//   PX0=77, a 410x256 layout) are parameterised too, because our active area is
//   512x400, not theirs.
//
// WHAT IT IS FOR
//   Diagnosing a boot hang on REAL HARDWARE, where there is no simulator, no
//   SignalTap capture worth the fit time, and often no output at all except the
//   video signal itself. The overlay draws internal state straight onto the
//   screen, so one photograph of the cab tells you which gate is stuck.
//
//   The three display elements answer different questions:
//     colour bars  -- is the pixel clock and the RGB path alive at all?
//     LED strip    -- which boot gate is stuck? Two grading modes per lane:
//                       LEVEL    lane is green while the bit is 1
//                       ACTIVITY lane is green only if the bit was observed BOTH
//                                0 and 1 within one frame, i.e. it is TOGGLING.
//                     ACTIVITY is the important one: a request line stuck high
//                     and a request line working look identical as a level.
//     hex rows     -- what are the actual values (PC, address, opcode, counter)?
//
// COMPOSITING
//   Draws into the TOP-LEFT QUADRANT and passes the real game through
//   everywhere else, so you can read the numbers and still see what the game is
//   doing. Set SHRINK=0 to take the whole screen instead.
//
// TIMING
//   Runs on the CORE pixel domain (clk_sys + core_ce in this design), NOT on
//   CLK_VIDEO/CE_PIXEL. It sits between the core and arcade_video, so it never
//   touches the MiSTer scaler contract. Game sync/blank are passed through
//   registered by exactly one ce_pix beat, matching the RGB it emits.
//
// UNVERIFIED IN HARDWARE. Syntax/elaboration checked only; see the port report.
// ---------------------------------------------------------------------------
`default_nettype none

module narc_diag_overlay #(
    // Diagnostic layout space, in diag pixels. With SHRINK=1 this is drawn into
    // the top-left quadrant, so it should be about half the active raster.
    parameter int DIAG_W  = 256,
    parameter int DIAG_H  = 200,
    // 1 = quarter-area top-left quadrant with game passthrough (recommended),
    // 0 = diag occupies the full active area, game hidden.
    parameter bit SHRINK  = 1'b1,
    // Glyph pixel size. A hex digit cell is 4*PIXW wide and 5*PIXW tall, so a
    // 32-bit row is 8 digits = 32*PIXW wide. At the defaults: 128 x 20 px.
    parameter int PIXW    = 4,
    // How many 32-bit values to show, and how many status lanes.
    parameter int NROWS   = 4,
    parameter int NLEDS   = 10,
    // Per-frame live counter column, a moving white pixel proving frames advance.
    parameter bit LIVE_COL = 1'b1
)(
    input  wire                    clk,
    input  wire                    ce_pix,
    input  wire                    rst,

    // ---- what to display -------------------------------------------------
    // Row 0 is the TOP row. Pack with e.g. {row3, row2, row1, row0}.
    input  wire [NROWS*32-1:0]     hex_rows,
    // Lane 0 is the LEFTMOST lane.
    input  wire [NLEDS-1:0]        led_bits,
    // 0 = grade lane by LEVEL (green while the bit is 1)
    // 1 = grade lane by ACTIVITY (green only if it toggled within the frame)
    input  wire [NLEDS-1:0]        led_is_activity,
    // Status bar: green when clear, red when set. Use for a sticky "something
    // went wrong" latch (illegal opcode, watchdog, derail).
    input  wire                    status_bad,

    // ---- game video in (core domain) -------------------------------------
    input  wire [7:0]              g_r,
    input  wire [7:0]              g_g,
    input  wire [7:0]              g_b,
    input  wire                    g_hs,
    input  wire                    g_vs,
    input  wire                    g_hb,
    input  wire                    g_vb,

    // ---- composited video out --------------------------------------------
    output reg  [7:0]              vid_r,
    output reg  [7:0]              vid_g,
    output reg  [7:0]              vid_b,
    output reg                     hsync,
    output reg                     vsync,
    output reg                     hblank,
    output reg                     vblank
);

    // Active video is derived, not taken as a port: this core's video pipeline
    // carries hblank/vblank (Arcade-NARC.sv:376), not a de.
    wire g_de = ~g_hb & ~g_vb;

    // -----------------------------------------------------------------------
    // 3x5 hex glyph LUT + pixel lookup. Lifted unchanged from the sibling core.
    // -----------------------------------------------------------------------
    function automatic [14:0] glyph(input [3:0] v);
        case (v)
            4'h0: glyph = 15'b111_101_101_101_111;  4'h1: glyph = 15'b010_110_010_010_111;
            4'h2: glyph = 15'b111_001_111_100_111;  4'h3: glyph = 15'b111_001_111_001_111;
            4'h4: glyph = 15'b101_101_111_001_001;  4'h5: glyph = 15'b111_100_111_001_111;
            4'h6: glyph = 15'b111_100_111_101_111;  4'h7: glyph = 15'b111_001_001_010_010;
            4'h8: glyph = 15'b111_101_111_101_111;  4'h9: glyph = 15'b111_101_111_001_111;
            4'hA: glyph = 15'b111_101_111_101_101;  4'hB: glyph = 15'b110_101_110_101_110;
            4'hC: glyph = 15'b111_100_100_100_111;  4'hD: glyph = 15'b110_101_101_101_110;
            4'hE: glyph = 15'b111_100_111_100_111;  default: glyph = 15'b111_100_111_100_100; // F
        endcase
    endfunction

    function automatic logic fpix(input [3:0] d, input [1:0] col, input [2:0] row);
        logic [14:0] g;
        logic [2:0]  rb;
        g = glyph(d);
        case (row)
            3'd0:    rb = g[14:12];
            3'd1:    rb = g[11:9];
            3'd2:    rb = g[8:6];
            3'd3:    rb = g[5:3];
            default: rb = g[2:0];
        endcase
        fpix = (col == 2'd0) ? rb[2] : (col == 2'd1) ? rb[1] : (col == 2'd2) ? rb[0] : 1'b0;
    endfunction

    // -----------------------------------------------------------------------
    // Track the GAME raster from its own de/vblank, then map into diag space.
    // -----------------------------------------------------------------------
    reg [11:0] gx, gy;
    reg        de_q, vb_q;
    reg [23:0] frame;

    always_ff @(posedge clk) begin
        if (rst) begin
            gx <= 12'd0; gy <= 12'd0; de_q <= 1'b0; vb_q <= 1'b0; frame <= 24'd0;
        end else if (ce_pix) begin
            de_q <= g_de;
            vb_q <= g_vb;
            if (g_vb && !vb_q) begin                    // vblank rising = new frame
                gx <= 12'd0; gy <= 12'd0; frame <= frame + 24'd1;
            end else if (g_de) begin
                gx <= gx + 12'd1;                       // active pixel
            end else if (de_q && !g_de) begin
                gx <= 12'd0; gy <= gy + 12'd1;          // line end -> next row
            end
        end
    end

    // Virtual diag-layout coordinates.
    wire [11:0] hc = SHRINK ? (gx << 1) : gx;
    wire [11:0] vc = SHRINK ? (gy << 1) : gy;

    // -----------------------------------------------------------------------
    // Per-frame toggle detection for the ACTIVITY lanes.
    // A lane is alive only if the bit was seen BOTH high and low in one frame.
    // Sampled on clk (not ce_pix) so a narrow clock-enable pulse still registers.
    // -----------------------------------------------------------------------
    wire frame_tick = ce_pix && g_vb && !vb_q;

    reg [NLEDS-1:0] saw1, saw0, alive;

    always_ff @(posedge clk) begin
        if (rst) begin
            saw1 <= '0; saw0 <= '0; alive <= '0;
        end else begin
            saw1 <= saw1 |  led_bits;
            saw0 <= saw0 | ~led_bits;
            if (frame_tick) begin
                alive <= saw1 & saw0;
                saw1  <= '0;
                saw0  <= '0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Geometry. Everything derives from PIXW and the lane/row counts, so the
    // layout rescales instead of carrying the sibling's magic constants.
    //
    // The divisions below are all by ELABORATION-TIME CONSTANTS, so the fitter
    // reduces them to shifts/constant multiplies rather than inferring a divider.
    // Keep PIXW a power of two (the default is 4) and they are plain shifts.
    // -----------------------------------------------------------------------
    localparam int BAR_H     = 5 * PIXW;                 // colour bar band
    localparam int STAT_Y0   = BAR_H + PIXW;
    localparam int STAT_H    = 4 * PIXW;
    localparam int LED_Y0    = STAT_Y0 + STAT_H;
    localparam int LED_H     = 2 * PIXW;
    localparam int HEX_Y0    = LED_Y0 + LED_H + PIXW;
    localparam int ROW_PITCH = 6 * PIXW;                 // 5 glyph rows + 1 gap
    localparam int HEX_X0    = PIXW;
    localparam int HEX_W     = 32 * PIXW;                // 8 digits x 4 cols
    localparam int LEDW      = DIAG_W / NLEDS;
    localparam int HE        = DIAG_W / 8;               // colour bar width

    // Raster coordinates are unsigned 12-bit, so every constant they are
    // compared against is declared that way too. Mixing them with plain `int`
    // is what produces the signed/unsigned and width-truncation warnings that
    // this repo's build is kept clean of.
    localparam logic [11:0] C_DIAG_W    = 12'(DIAG_W);
    localparam logic [11:0] C_DIAG_H    = 12'(DIAG_H);
    localparam logic [11:0] C_PIXW      = 12'(PIXW);
    localparam logic [11:0] C_HE        = 12'(HE);
    localparam logic [11:0] C_BAR_H     = 12'(BAR_H);
    localparam logic [11:0] C_STAT_Y0   = 12'(STAT_Y0);
    localparam logic [11:0] C_STAT_Y1   = 12'(STAT_Y0 + STAT_H);
    localparam logic [11:0] C_LED_Y0    = 12'(LED_Y0);
    localparam logic [11:0] C_LED_Y1    = 12'(LED_Y0 + LED_H);
    localparam logic [11:0] C_LEDW      = 12'(LEDW);
    localparam logic [11:0] C_LEDW_M1   = 12'(LEDW - 1);
    localparam logic [11:0] C_NLEDS     = 12'(NLEDS);
    localparam logic [11:0] C_NLEDS_M1  = 12'(NLEDS - 1);
    localparam logic [11:0] C_HEX_X0    = 12'(HEX_X0);
    localparam logic [11:0] C_HEX_X1    = 12'(HEX_X0 + HEX_W);
    localparam logic [11:0] C_HEX_Y0    = 12'(HEX_Y0);
    localparam logic [11:0] C_ROW_PITCH = 12'(ROW_PITCH);
    localparam logic [11:0] C_GLYPH_H   = 12'(5 * PIXW);
    localparam logic [11:0] C_NROWS     = 12'(NROWS);

    localparam int LSEL_W = (NLEDS > 1) ? $clog2(NLEDS) : 1;
    localparam int RSEL_W = (NROWS > 1) ? $clog2(NROWS) : 1;

    wire in_diag = (hc < C_DIAG_W) && (vc < C_DIAG_H);

    // ---- colour bars ------------------------------------------------------
    reg  [7:0]  cbr, cbg, cbb;
    wire [11:0] bar_idx = hc / C_HE;
    wire [2:0]  barx    = bar_idx[2:0];
    always_comb begin
        case (barx)
            3'd0:    {cbr, cbg, cbb} = {8'hFF, 8'hFF, 8'hFF};
            3'd1:    {cbr, cbg, cbb} = {8'hFF, 8'hFF, 8'h00};
            3'd2:    {cbr, cbg, cbb} = {8'h00, 8'hFF, 8'hFF};
            3'd3:    {cbr, cbg, cbb} = {8'h00, 8'hFF, 8'h00};
            3'd4:    {cbr, cbg, cbb} = {8'hFF, 8'h00, 8'hFF};
            3'd5:    {cbr, cbg, cbb} = {8'hFF, 8'h00, 8'h00};
            3'd6:    {cbr, cbg, cbb} = {8'h00, 8'h00, 8'hFF};
            default: {cbr, cbg, cbb} = {8'h20, 8'h20, 8'h20};
        endcase
    end

    // ---- LED strip --------------------------------------------------------
    wire        in_leds  = (vc >= C_LED_Y0) && (vc < C_LED_Y1);
    wire [11:0] lane_raw = hc / C_LEDW;
    // DIAG_W is not always an exact multiple of NLEDS, so the rightmost few
    // columns can index past the last lane. Clamp rather than read out of range.
    wire [11:0] lane_idx = (lane_raw >= C_NLEDS) ? C_NLEDS_M1 : lane_raw;
    wire [LSEL_W-1:0] lane_sel = lane_idx[LSEL_W-1:0];

    wire [11:0] led_x    = hc - (lane_idx * C_LEDW);
    wire        led_body = (led_x >= 12'd1) && (led_x < C_LEDW_M1);
    wire        led_good = led_is_activity[lane_sel] ? alive[lane_sel]
                                                     : led_bits[lane_sel];

    // ---- hex rows ---------------------------------------------------------
    wire [11:0] hex_rel = vc - C_HEX_Y0;                 // valid once vc >= HEX_Y0
    wire [11:0] hex_row = hex_rel / C_ROW_PITCH;
    wire [11:0] hex_yin = hex_rel - (hex_row * C_ROW_PITCH);
    wire        in_hex  = (vc >= C_HEX_Y0) && (hex_row < C_NROWS)
                          && (hex_yin < C_GLYPH_H);

    wire [RSEL_W-1:0] row_sel = hex_row[RSEL_W-1:0];
    wire [31:0] rowval = hex_rows[{29'd0, row_sel} * 32 +: 32];

    wire        hx_in  = (hc >= C_HEX_X0) && (hc < C_HEX_X1);
    wire [11:0] hrx    = hc - C_HEX_X0;
    wire [11:0] hcell  = hrx / C_PIXW;                   // glyph-pixel column index
    wire [11:0] hdig   = hcell >> 2;                     // 4 glyph cols per digit
    wire [1:0]  hfcol  = hcell[1:0];
    wire [11:0] hfrow12 = hex_yin / C_PIXW;
    wire [2:0]  hfrow  = hfrow12[2:0];
    // Digit 0 is the most significant nibble, so select bits [31:28] downwards.
    wire [4:0]  hsh    = 5'((3'd7 - hdig[2:0]) * 3'd4);
    wire [3:0]  hnyb   = rowval[hsh +: 4];
    wire        hex_on = in_hex && hx_in && (hfcol < 2'd3) && (hfrow < 3'd5)
                         && fpix(hnyb, hfcol, hfrow);

    // ---- status bar + frame liveness column -------------------------------
    wire in_status = (vc >= C_STAT_Y0) && (vc < C_STAT_Y1);
    wire live_col  = LIVE_COL && (hc == {3'd0, frame[8:0]});

    // -----------------------------------------------------------------------
    // Composite. Game sync/blank pass through registered by one ce_pix beat so
    // they stay aligned with the RGB emitted on the same beat.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            vid_r <= 8'd0; vid_g <= 8'd0; vid_b <= 8'd0;
            hsync <= 1'b0; vsync <= 1'b0; hblank <= 1'b1; vblank <= 1'b1;
        end else if (ce_pix) begin
            hsync <= g_hs; vsync <= g_vs; hblank <= g_hb; vblank <= g_vb;
            if (!g_de) begin
                vid_r <= 8'd0;  vid_g <= 8'd0;  vid_b <= 8'd0;     // outside active video
            end else if (!in_diag) begin
                vid_r <= g_r;   vid_g <= g_g;   vid_b <= g_b;      // GAME passthrough
            end else if (vc < C_BAR_H) begin
                vid_r <= cbr;   vid_g <= cbg;   vid_b <= cbb;      // colour bars
            end else if (live_col) begin
                vid_r <= 8'hFF; vid_g <= 8'hFF; vid_b <= 8'hFF;    // frame liveness
            end else if (in_status) begin
                vid_r <= status_bad ? 8'hC0 : 8'h00;
                vid_g <= status_bad ? 8'h00 : 8'hC0;
                vid_b <= 8'h00;
            end else if (in_leds) begin
                if (led_body) begin
                    vid_r <= led_good ? 8'h00 : 8'hE0;
                    vid_g <= led_good ? 8'hE0 : 8'h00;
                    vid_b <= 8'h00;
                end else begin
                    vid_r <= 8'd0; vid_g <= 8'd0; vid_b <= 8'd0;
                end
            end else if (in_hex) begin
                vid_r <= hex_on ? 8'hFF : 8'h10;
                vid_g <= hex_on ? 8'hFF : 8'h10;
                vid_b <= hex_on ? 8'h00 : 8'h30;
            end else begin
                vid_r <= 8'h08; vid_g <= 8'h08; vid_b <= 8'h08;    // backdrop
            end
        end
    end

endmodule

`default_nettype wire
