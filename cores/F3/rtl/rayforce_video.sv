//============================================================================
//  Ray Force -- F3 raster timing
//
//  Timing is the real machine's, from MAME taito_f3.cpp:
//      set_raw(26.686 MHz / 4, 432, 46, 320+46, 262, 24, 232+24)
//      pixel clock 6.6715 MHz = clk_sys / 8 (clk_sys = 53.372 MHz)
//      => 58.94 Hz, which the OSD reporting that number is part of the test.
//
//  The F3 renders 232 scanlines; each game then crops itself with line RAM
//  and a visarea. gunlock/rayforce use f3_224a: set_visarea(46, 365, 31, 254)
//  -- 320x224 starting at line 31, NOT line 24. Line RAM is indexed by the
//  raw raster line (MAME's scanline_draw walks screen_y 0..255 and indexes
//  line ram with it), so vcnt IS the line-RAM index and the visible window
//  is a crop of it. Getting this offset wrong shifts every per-line effect
//  by seven lines, which is the kind of bug that looks like bad line RAM
//  decoding for a week.
//
//  vbl_rise is the main CPU's vblank interrupt: MAME schedules it at
//  visarea.max_y + 1, so line 255.
//
//============================================================================

module rayforce_video
(
    input  logic        clk,          // 53.372 MHz
    input  logic        reset,

    // Refresh Rate OSD option. Native is 262 lines = 58.94 Hz (MAME: 58.97);
    // 60Hz trims the vertical blank to 257 lines = 60.08 Hz, H rate
    // unchanged, so the game runs 1.9% fast in exchange for a picture every
    // 60 Hz display holds without judder. rf_video_pipe carries the same
    // two constants for its lookahead wrap.
    input  logic  [1:0] vis_mode,     // which F3 visarea (see below)
    input  logic        rate_60,

    output logic        vbl_rise,     // one pulse at the vblank interrupt line

    // raster position, for the game renderer
    output logic  [2:0] div_o,
    output logic  [8:0] hcnt_o,
    output logic  [8:0] vcnt_o,

    output logic        ce_pix,       // clk / 8
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,        // active high, straight into arcade_video
    output logic        vsync
);

    // ---- counters --------------------------------------------------------
    // vcnt IS the line-RAM index; the visible window is a crop of the
    // 262-line raster, so vsync has to live in what is left.
    //
    // The crop is the ONE thing that differs between the four Taito F3
    // machine configurations in MAME, and every F3 game uses one of them
    // (taito_f3.cpp: the base f3 set_raw is 432x262 for all of them, and
    // f3_224a/b/c only override set_visarea):
    //
    //   vis_mode 0  f3_224a  lines 31..254   224 visible   <- Ray Force
    //   vis_mode 1  f3_224b  lines 32..255   224 visible
    //   vis_mode 2  f3_224c  lines 24..247   224 visible
    //   vis_mode 3  f3       lines 24..255   232 visible   <- Elevator
    //                                                         Action Returns
    //
    // 0 is the default so a core with no game-config ROM behaves as before.
    localparam int H_TOTAL = 432, H_START = 46, H_END = 366;   // 320 visible
    localparam int V_TOTAL = 262;
    localparam int HS_BEG  = 388, HS_WID  = 32;
    localparam int VS_BEG  = 258, VS_WID  = 3;

    wire [8:0] v_start = (vis_mode == 2'd0) ? 9'd31 :
                         (vis_mode == 2'd1) ? 9'd32 : 9'd24;
    wire [8:0] v_end   = (vis_mode == 2'd3) ? 9'd256 : (v_start + 9'd224);

    wire [8:0] v_total = rate_60 ? 9'd257 : V_TOTAL[8:0];
    wire [8:0] vs_beg  = rate_60 ? 9'd1   : VS_BEG[8:0];   // 258 wraps to 1

    logic [2:0] div;
    logic [8:0] hcnt;
    logic [8:0] vcnt;

    always_ff @(posedge clk) begin
        div    <= div + 3'd1;
        ce_pix <= (div == 3'd7);
        if (reset) begin
            div <= '0; hcnt <= '0; vcnt <= '0;
        end else if (div == 3'd7) begin
            if (hcnt == H_TOTAL - 1) begin
                hcnt <= '0;
                if (vcnt == v_total - 9'd1) begin
                    vcnt  <= '0;
                end else vcnt <= vcnt + 9'd1;
            end else hcnt <= hcnt + 9'd1;
        end
    end

    assign div_o  = div;
    assign hcnt_o = hcnt;
    assign vcnt_o = vcnt;

    // The vblank interrupt fires as the raster leaves the visible area.
    wire line_end = (div == 3'd7) && (hcnt == H_TOTAL - 1);
    always_ff @(posedge clk) vbl_rise <= !reset && line_end && (vcnt == v_end - 9'd1);

    assign hblank = (hcnt < H_START) || (hcnt >= H_END);
    assign vblank = (vcnt < v_start) || (vcnt >= v_end);
    assign hsync  = (hcnt >= HS_BEG) && (hcnt < HS_BEG + HS_WID);
    assign vsync  = (vcnt >= vs_beg) && (vcnt < vs_beg + VS_WID[8:0]);

endmodule
