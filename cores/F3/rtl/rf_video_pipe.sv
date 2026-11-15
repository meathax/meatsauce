// Taito F3 game video pipeline

module rf_video_pipe #(parameter SEPARATE_MEMORY_INIT=0)
(
    input  logic        solid_hud,
    input  logic        saturn_sky,
    input  logic        short_sprite_lag,
    input  logic        clk,
    input  logic        reset,
    input  logic        clk_ram,
    input wire memory_init,

    // raster position from rayforce_video
    input  logic  [2:0] div,
    input  logic  [8:0] hcnt,
    input  logic  [8:0] vcnt,
    input  logic        hblank,
    input  logic        vblank,
    input  logic        rate_60,       // 257-line frame (see rayforce_video)

    // video control registers 0x660000-1F
    input  logic [7:0][15:0] ctrl0,
    input  logic [7:0][15:0] ctrl1,
    // Flipscreen DEFAULT only. The live value comes from the sprite command
    // word via the sprite engine (`flip_eff` below) -- MAME takes
    // m_flipscreen from exactly that bit, and it must follow the game: Ray
    // Force sets it permanently, Elevator Action Returns does not, and this
    // core used to wire it to a constant 1, which rendered that game upside
    // down. The port is what the layers use until the first prepass has run.
    input  logic        flip,

    // which F3 visarea this game uses -- the sprite cull needs it, or the
    // lines outside Ray Force's 224-line window are dropped
    input  logic  [1:0] vis_mode,

    // f3_config_table "extend": 1 = four 64x32 playfields (Ray Force,
    // Elevator Action Returns, both Bubble Bobble games), 0 = eight 32x32
    // (Puzzle Bobble, Darius Gaiden, Cleopatra Fortune, Grid Seeker,
    // Space Invaders '95, Gekirindan). Changes playfield addressing.
    input  logic        extend,

    // video RAM read ports (B side of the CPU's BRAMs)
    output logic [14:0] line_addr,
    input  logic [15:0] line_q,
    output logic [13:0] pf_addr,
    input  logic [15:0] pf_q,
    output logic [13:0] pal_addr,
    input  logic [15:0] pal_q,
    output logic [11:0] text_addr,
    input  logic [15:0] text_q,
    output logic [11:0] char_addr,
    input  logic [15:0] char_q,
    output logic [14:0] pivot_addr,
    input  logic [15:0] pivot_q,

    // SDRAM channels for the two tile planes
    output logic [26:1] ch1_addr,
    input  logic [63:0] ch1_dout,
    output logic        ch1_req,
    input  logic        ch1_ready,
    output logic [26:1] ch2_addr,
    input  logic [63:0] ch2_dout,
    output logic        ch2_req,
    input  logic        ch2_ready,

    // sprite RAM read port (B side of the CPU's sprite BRAM), for the walker
    output logic [14:0] spr_addr,
    input  logic [15:0] spr_q,

    // sprite gfx SDRAM channels: two fetch buses (A, B) x two planes (lo,
    // hi). Only ch4 is free on the real controller, so all four share it
    // through rf_spr_ch_share at Rayforce.sv (and in the bench's pipe_top).
    output logic [26:1] spr_a_lo_addr,
    input  logic [63:0] spr_a_lo_dout,
    output logic        spr_a_lo_req,
    input  logic        spr_a_lo_ready,
    output logic [26:1] spr_a_hi_addr,
    input  logic [63:0] spr_a_hi_dout,
    output logic        spr_a_hi_req,
    input  logic        spr_a_hi_ready,
    output logic [26:1] spr_b_lo_addr,
    input  logic [63:0] spr_b_lo_dout,
    output logic        spr_b_lo_req,
    input  logic        spr_b_lo_ready,
    output logic [26:1] spr_b_hi_addr,
    input  logic [63:0] spr_b_hi_dout,
    output logic        spr_b_hi_req,
    input  logic        spr_b_hi_ready,

    output logic [23:0] rgb,           // blanked outside the visible area

    // ---- the sprite framebuffer's DDR3 port, out to rf_ddr_arb ----------
    output logic  [7:0] ddr_burstcnt,
    output logic [28:0] ddr_addr,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    output logic        ddr_we,
    output logic        ddr_rd,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,
    // ---- the output flip (rf_out_flip): the raw output upside down ------
    input  logic        out_flip,

                                       //  lines the mixer started before the
                                       //  sprite draw had finished them}
                                       //  prepass, rows dropped at the cap}

    // 12-bit palette entries, per game -- see rf_video_mix.sv
    input  logic        pal12,
    // SDRAM map profile bases (see cfg_map in Rayforce.sv). Two profiles:
    // the 18.5 MB map every earlier game uses, and a 36 MB map whose
    // sprites region is 13 MB, which is what the sets that did not fit need.
    input  logic [26:1] tile_base_lo,
    input  logic [26:1] tile_base_hi,
    input  logic [26:1] sgfx_base_lo,
    input  logic [26:1] sgfx_base_hi
);

    localparam int H_START = 46;

    // ---- raster-driven sequencing ----------------------------------------
    // hcnt holds each value for eight clocks (div 0..7); div picks the clock.
    wire        h0        = (hcnt == 9'd0);
    // The frame is 262 lines native or 257 with the 60 Hz option (the same
    // pair of constants as rayforce_video); either way the last two raster
    // lines are the wrap where line 0 is decoded, then mixed.
    wire  [8:0] v_last    = rate_60 ? 9'd256 : 9'd261;     // V_TOTAL - 1
    wire  [8:0] v_last1   = v_last - 9'd1;                 // V_TOTAL - 2
    wire  [8:0] l_mix     = (vcnt == v_last)  ? 9'd0 : vcnt + 9'd1;
    wire  [8:0] l_bld     = (vcnt == v_last1) ? 9'd0 :
                            (vcnt == v_last)  ? 9'd1 : vcnt + 9'd2;
    wire        do_mix    = (l_mix <= 9'd255);
    wire        do_bld    = (l_bld <= 9'd255);

    logic frame_start, mix_start, dec_start;
    logic [7:0] bld_y;
    logic       mix_bank;
    logic [7:0] mix_y;                  // the line the mixer is composing
    // The output line buffer is THREE banks of 320 (960 of the 1024 words
    // its three M10K hold) as of the analog flip: the flip's writer reads a
    // finished line back out over the two rasters after it, so the bank has
    // to survive two lines, not one. mix_b3 is the bank the mixer composes
    // into this raster (line mod 3), beam_b3 the one it composed last raster
    // -- the line the beam shows now. Counted, not divided: +1 a line, 0 at
    // line 0.
    logic [1:0] mix_b3, beam_b3;
    function automatic logic [9:0] lb_base(input logic [1:0] b);
        lb_base = (b == 2'd0) ? 10'd0 : (b == 2'd1) ? 10'd320 : 10'd640;
    endfunction

    always_ff @(posedge clk) begin
        frame_start <= 1'b0;
        mix_start   <= 1'b0;
        dec_start   <= 1'b0;
        if (!reset && h0) begin
            case (div)
                3'd0: frame_start <= (vcnt == v_last1);
                3'd1: begin
                          beam_b3 <= mix_b3;
                          mix_b3  <= (l_mix == 9'd0) ? 2'd0 : (mix_b3 == 2'd2) ? 2'd0 : mix_b3 + 2'd1;
                          if (do_mix) begin
                              mix_start <= 1'b1;
                              mix_bank  <= l_mix[0];
                              mix_y     <= l_mix[7:0];
                          end
                      end
                // (the sprite draw is not started per line: it runs ahead
                // of the mixer on its own, see rf_video_spr)
                3'd4: if (do_bld) begin
                          dec_start <= 1'b1;
                          bld_y     <= l_bld[7:0];
                      end
                default: ;
            endcase
        end
    end

    // ---- line decoder ----------------------------------------------------
    logic line_busy;
    logic [3:0][8:0]  colscroll, x_scale, y_scale, clip_l, clip_r;
    logic [3:0][19:0] rowscroll;
    logic [3:0]       pf_mosaic, sp_bsel, pf_alt;
    logic [4:0]       x_sample;
    logic [3:0][3:0]  blend;
    logic [7:0]       fx_6400, pivot_control;
    logic [15:0]      bg_palette, pivot_enable, pivot_mix;
    logic             pivot_bsel, pivot_mosaic, sp_mosaic;
    logic [3:0][15:0] sp_mix, pf_pal_add, pf_mix;

    // "extend" (1024x512 playfields) comes from MAME's per-game config
    // table, not from control word 15, and so it comes from the MRA's game
    // config byte here rather than from anything the game writes.
    rf_video_line line (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .line_start(dec_start),
        .y(flip_eff ? (8'd255 - bld_y) : bld_y),
        .extend(extend), .busy(line_busy),
        .lr_addr(line_addr), .lr_q(line_q),
        .clip_l(clip_l), .clip_r(clip_r), .blend(blend), .x_sample(x_sample),
        .fx_6400(fx_6400), .bg_palette(bg_palette),
        .pivot_control(pivot_control), .pivot_bsel(pivot_bsel),
        .pivot_enable(pivot_enable), .pivot_mix(pivot_mix), .pivot_mosaic(pivot_mosaic),
        .sp_mix(sp_mix), .sp_bsel(sp_bsel), .sp_mosaic(sp_mosaic),
        .pf_colscroll(colscroll), .pf_alt_tilemap(pf_alt),
        .pf_x_scale(x_scale), .pf_y_scale(y_scale), .pf_pal_add(pf_pal_add),
        .pf_rowscroll(rowscroll), .pf_mix(pf_mix), .pf_mosaic(pf_mosaic)
    );

    // the builder starts the clock after the decoder finishes
    logic line_busy_d, pf_go, pf_busy;
    always_ff @(posedge clk) begin
        line_busy_d <= line_busy;
        pf_go       <= line_busy_d & ~line_busy;
    end

    // ---- playfields + tile fetch -----------------------------------------
    logic [15:0] gfx_code; logic [3:0] gfx_row;
    logic gfx_req, gfx_valid, gfx_busy;
    logic [95:0] gfx_pix;
    logic pf_rd_start, pf_rd_step;
    logic [3:0][15:0] pf_rd_q;
    logic [3:0] pf_used;

    rf_video_pf pf (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .ctrl0(ctrl0), .flip(flip_eff), .vis_mode(vis_mode),
        .line_start(pf_go), .screen_y(bld_y),
        .extend(extend), .alt_tilemap(pf_alt),
        .colscroll(colscroll), .x_scale(x_scale), .y_scale(y_scale),
        .rowscroll(rowscroll), .mosaic_en(pf_mosaic), .x_sample(x_sample),
        .busy(pf_busy),
        .pf_addr(pf_addr), .pf_q(pf_q),
        .gfx_code(gfx_code), .gfx_row(gfx_row), .gfx_req(gfx_req),
        .gfx_pix(gfx_pix), .gfx_valid(gfx_valid), .gfx_busy(gfx_busy),
        .rd_start(pf_rd_start), .rd_step(pf_rd_step), .rd_q(pf_rd_q), .rd_used(pf_used)
    );

    rf_gfx_bus #(.SEPARATE_INIT(SEPARATE_MEMORY_INIT)) gfx (
        .clk_cpu(clk), .reset(reset),.init(memory_init),
        .code(gfx_code), .row(gfx_row), .req(gfx_req),
        .pix(gfx_pix), .valid(gfx_valid), .busy(gfx_busy),
        .clk_ram(clk_ram),
        .ch_lo_addr(ch1_addr), .ch_lo_dout(ch1_dout), .ch_lo_req(ch1_req), .ch_lo_ready(ch1_ready),
        .ch_hi_addr(ch2_addr), .ch_hi_dout(ch2_dout), .ch_hi_req(ch2_req), .ch_hi_ready(ch2_ready),
        .base_lo(tile_base_lo), .base_hi(tile_base_hi)
    );

    // ---- pivot / text layer ------------------------------------------------
    // Same start as the playfield builder (after the decoder), same line;
    // read by the mixer at smp_x out of the bank it is composing.
    logic        pv_busy, pv_opaque, pv_used;
    logic [15:0] pv_color;

    rf_video_pivot pivot (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .ctrl1(ctrl1), .flip(flip_eff), .vis_mode(vis_mode),
        .line_start(pf_go), .screen_y(bld_y),
        .pivot_control(pivot_control), .mosaic_en(pivot_mosaic), .x_sample(x_sample),
        .busy(pv_busy),
        .text_addr(text_addr), .text_q(text_q),
        .char_addr(char_addr), .char_q(char_q),
        .pivot_addr(pivot_addr), .pivot_q(pivot_q),
        .rd_bank(mix_bank), .rd_x(smp_x),
        .rd_color(pv_color), .rd_opaque(pv_opaque), .rd_used(pv_used)
    );

    // ---- sprite engine ---------------------------------------------------
    // Prepass once per frame (frame_start swaps its double-banked buckets and
    // walks sprite RAM); the draw runs ahead of the mixer into its own ring
    // of line buffers, held back only by the mixer's line (mix_y); the mixer
    // samples it at smp_x for the line it is composing.
    logic        spr_prepass_busy, spr_line_busy;
    logic  [8:0] spr_lines_done;
    logic        spr_flipscreen;
    // the game's own bit once the prepass has read it; the port until then
    wire         flip_eff = spr_flipscreen;
    /* verilator lint_off UNUSED */
    /* verilator lint_on UNUSED */
    // peak-hold accumulators for the two sprite rows (see frame_end below)
    // ...held from the WARM frame on. The first frames after a reset have no
    // sprite buckets built yet, so the mixer legitimately starts lines the
    // draw has not reached and the late counter would latch a permanent FAIL
    // out of the boot (the bench shows exactly 254 such lines in its priming
    // frame). Eight frames is well past the first real prepass.
    wire  [15:0] sp_color;              // from the framebuffer, a frame later
    logic  [3:0] sp_used;
    wire   [8:0] smp_x;
    // sprite engine <-> framebuffer
    wire         spr_par, spr_fb_req, spr_fb_busy;
    wire   [7:0] spr_fb_line;
    wire   [8:0] spr_fb_addr;
    wire  [15:0] spr_fb_q;

    rf_video_spr #(.SEPARATE_MEMORY_INIT(SEPARATE_MEMORY_INIT)) sprites (
        .clk(clk), .reset(reset), .clk_ram(clk_ram),.memory_init(memory_init), .vis_mode(vis_mode),

        .frame_start(frame_start), .prepass_busy(spr_prepass_busy),
        .short_lag(short_sprite_lag),
        .line_busy(spr_line_busy), .lines_done(spr_lines_done),
        .o_flipscreen(spr_flipscreen),

        .spr_addr(spr_addr), .spr_q(spr_q),
        .ch_a_lo_addr(spr_a_lo_addr), .ch_a_lo_dout(spr_a_lo_dout), .ch_a_lo_req(spr_a_lo_req), .ch_a_lo_ready(spr_a_lo_ready),
        .ch_a_hi_addr(spr_a_hi_addr), .ch_a_hi_dout(spr_a_hi_dout), .ch_a_hi_req(spr_a_hi_req), .ch_a_hi_ready(spr_a_hi_ready),
        .ch_b_lo_addr(spr_b_lo_addr), .ch_b_lo_dout(spr_b_lo_dout), .ch_b_lo_req(spr_b_lo_req), .ch_b_lo_ready(spr_b_lo_ready),
        .ch_b_hi_addr(spr_b_hi_addr), .ch_b_hi_dout(spr_b_hi_dout), .ch_b_hi_req(spr_b_hi_req), .ch_b_hi_ready(spr_b_hi_ready),
        .rd_line(mix_y), .rd_used(sp_used),
        .o_par(spr_par),
        .fb_req(spr_fb_req), .fb_line(spr_fb_line), .fb_busy(spr_fb_busy), .fb_used(),
        .fb_addr(spr_fb_addr), .fb_q(spr_fb_q),
        .gfx_base_lo(sgfx_base_lo), .gfx_base_hi(sgfx_base_hi)
    );

    // The sprite framebuffer: the draw's finished lines go out to DDR3 and
    // the mixer reads LAST frame's back. This is what takes the per-line
    // deadline off the draw entirely -- see rf_spr_fb.sv for the measurements
    // that forced it.
    // the pipe's DDR3 port, shared below between spr_fb (F) and the flip (V)
    logic  [7:0] f_burstcnt, v_burstcnt;
    logic [28:0] f_addr, v_addr;
    logic [63:0] f_din, v_din, f_dout, v_dout;
    logic  [7:0] f_be, v_be;
    logic        f_we, f_rd, f_busy, f_dout_ready;
    logic        v_we, v_rd, v_busy, v_dout_ready;
    rf_spr_fb spr_fb (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .par(spr_par),
        .wr_req(spr_fb_req), .wr_line(spr_fb_line), .wr_busy(spr_fb_busy),
        .lb_addr(spr_fb_addr), .lb_q(spr_fb_q),
        .rd_line(mix_y), .rd_x(smp_x), .rd_color(sp_color),

        .ddr_burstcnt(f_burstcnt), .ddr_addr(f_addr), .ddr_din(f_din),
        .ddr_be(f_be), .ddr_we(f_we), .ddr_rd(f_rd),
        .ddr_busy(f_busy), .ddr_dout(f_dout), .ddr_dout_ready(f_dout_ready)
    );

    // The pipe's DDR3 port is shared between the sprite framebuffer and the
    // output flip. Both read, so the returning beats have to be told apart
    // -- see rf_ddr_tag_mux.
    rf_ddr_tag_mux ddr_mux (

        .clk(clk), .reset(reset),
        // inert unless the flip is actually on -- see the module header
        .enable(out_flip),
        .f_burstcnt(f_burstcnt), .f_addr(f_addr), .f_din(f_din), .f_be(f_be),
        .f_we(f_we), .f_rd(f_rd), .f_busy(f_busy), .f_dout(f_dout), .f_dout_ready(f_dout_ready),
        .v_burstcnt(v_burstcnt), .v_addr(v_addr), .v_din(v_din), .v_be(v_be),
        .v_we(v_we), .v_rd(v_rd), .v_busy(v_busy), .v_dout(v_dout), .v_dout_ready(v_dout_ready),
        .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr), .ddr_din(ddr_din),
        .ddr_be(ddr_be), .ddr_we(ddr_we), .ddr_rd(ddr_rd),
        .ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready)
    );

    // The output flip: last frame's raster, upside down, for the analog
    // output (see rf_out_flip.sv). It reads the line buffer the beam is not
    // using and fills the display buffer the beam reads instead.
    logic  [9:0] flip_lb_addr;
    logic        flip_db_we;
    logic  [8:0] flip_db_waddr;
    logic [47:0] flip_db_wdata;
    // (rf_out_flip itself is instantiated with the line buffers below,
    // which it reads and writes)

    // ---- mixer -----------------------------------------------------------
    logic mix_busy, out_valid;
    logic [8:0] out_x;
    logic [23:0] out_rgb;
    wire         x_req;
    wire   [8:0] x_req_x;

    rf_video_mix mix (
        .solid_hud(solid_hud),
        .saturn_sky(saturn_sky),
        .clk(clk), .reset(reset),
        .line_start(mix_start), .busy(mix_busy),
        .clip_l(clip_l), .clip_r(clip_r), .blend(blend), .bg_palette(bg_palette),
        .pivot_mix(pivot_mix), .pivot_bsel(pivot_bsel),
        .sp_mix(sp_mix), .sp_bsel(sp_bsel),
        .pf_pal_add(pf_pal_add), .pf_mix(pf_mix),
        .pf_rd_start(pf_rd_start), .pf_rd_step(pf_rd_step), .pf_q(pf_rd_q), .pf_used(pf_used),
        .x_req(x_req), .x_req_x(x_req_x), .smp_x(smp_x),
        .sp_color(sp_color), .sp_used(sp_used),
        .pv_color(pv_color), .pv_opaque(pv_opaque), .pv_used(pv_used),
        .pal_addr(pal_addr), .pal_q(pal_q), .pal12(pal12),
        .out_valid(out_valid), .out_x(out_x), .out_rgb(out_rgb)

    );

    wire  [8:0] xn = hcnt + 9'd1 - H_START[8:0];
    wire [23:0] lb_q;

    // While the output flip is on, the beam reads the display buffer below
    // and this buffer's read port belongs to the flip's writer, which reads
    // line T back out of the bank the beam would have read, over rasters T
    // and T+1 (three banks: see mix_b3).
    rf_bram #(.WIDTH(24), .AW(10)) u_lbuf (
        .clk(clk),
        // Three banks only while the flip needs a line to survive two
        // rasters. With the flip off this is the original two-bank buffer,
        // addressed exactly as it was before rf_out_flip existed -- the
        // 2026-09-11 bisect says every build without this machinery renders
        // Darius Gaiden's Zone A palette correctly.
        .waddr(out_flip ? (lb_base(mix_b3) + 10'(out_x)) : {mix_bank, out_x}),
        .wdata(out_rgb), .wren(out_valid),
        .raddr(out_flip ? flip_lb_addr : {vcnt[0], xn}), .q(lb_q)
    );

    // The flip's display buffer: three banks of 160 two-pixel words (480 of
    // the 512 the three M10K hold), written by rf_out_flip two lines ahead,
    // read by the beam a word per two pixels from the bank it names.
    wire [47:0] db_q;
    logic [8:0] flip_db_rbase;
    rf_bram #(.WIDTH(48), .AW(9)) u_dbuf (
        .clk(clk),
        .waddr(flip_db_waddr), .wdata(flip_db_wdata), .wren(flip_db_we),
        .raddr(flip_db_rbase + 9'(xn[8:1])), .q(db_q)
    );

    rf_out_flip out_flipper (
        .clk(clk), .reset(reset), .enable(out_flip),
        .h0(h0), .div(div), .vcnt(vcnt), .vis_mode(vis_mode),
        .lb_base(lb_base(beam_b3)), .lb_addr(flip_lb_addr), .lb_q(lb_q),
        .db_we(flip_db_we), .db_waddr(flip_db_waddr), .db_wdata(flip_db_wdata),
        .db_rbase(flip_db_rbase),
        .ddr_burstcnt(v_burstcnt), .ddr_addr(v_addr), .ddr_din(v_din),
        .ddr_be(v_be), .ddr_we(v_we), .ddr_rd(v_rd),
        .ddr_busy(v_busy), .ddr_dout(v_dout), .ddr_dout_ready(v_dout_ready)

    );

    logic [23:0] rgb_q;
    always_ff @(posedge clk)
        if (div == 3'd7) rgb_q <= !out_flip ? lb_q : (xn[0] ? db_q[47:24] : db_q[23:0]);

    assign rgb = (hblank | vblank) ? 24'd0 : rgb_q;

endmodule
