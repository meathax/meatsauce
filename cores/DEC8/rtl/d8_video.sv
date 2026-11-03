// DEC8 video for Last Mission, Gondomania and SRD: Super Real Darwin (PLAN M1).
//
// Reference model: sim/oracle/d8_render.py, pixel-exact against MAME 0.288
// on every M0 capture. "spec N" = docs/dec8_system_spec.md; dec8/v/krn line
// numbers = reference/mame/v0288/dec8.cpp, dec8_v.cpp, deckarn.cpp.
//
// Contents:
//   - raster: 384 pixels per line at a 6 MHz pixel enable (96 MHz / 16),
//     272 lines, visible 256 x 240 at lines 8-247, vblank from line 248
//     (dec8:1977-1981, "DECO video CRTC, matches PCB measurements")
//   - CPU-side RAMs, byte wide on the CPU side (the 6809/6309 is 8-bit),
//     16-bit words on the renderer side: palette {ext, RAM} 1,024 entries,
//     fix RAM and bg RAM 2 KB each (word i = bytes 2i, 2i+1, high byte
//     first, as every tile_info in dec8_v.cpp reads them), sprite RAM 2 KB
//     with its buffer (snapram MODE 1: on `i_spr_copy` the buffer becomes
//     the RAM as it stood at that clock, copy-before-write; MAME copies
//     instantly, spec 9, research item R3)
//   - LATCH = 0 (default, Lee 2026-10-02, PLAN 5.2): the renderer reads tile
//     RAM, palette, scroll and flip live while the frame is drawn (most
//     plausible PCB behaviour, unconfirmed, R5). LATCH = 1: those are
//     snapshotted at the start of line LATCH_LINE. MAME draws each frame
//     once at vblank; m1_findings lists every frame where that differs.
//   - KRN_FLIP = 0 (default, MAME, PLAN 5.4): the Karnov sprites of
//     lastmisn/gondo are not flipped with the screen (dec8.cpp never sets
//     the sprite chip's flip flag, R7); 1 applies the chip's flip path
//     (krn:79-86) whenever the screen is flipped
//   - line renderer: during line L-1 the tile passes and the sprite pass
//     build line L into three double line buffers (bg, fix, sprites);
//     scan-out mixes them by the machine's priority rule and looks the
//     colour up in the palette (DECO RM-C3 resistor weights, decrmc3)
//
// Graphics ROM port: one port, pipelined, in-order returns; 32-bit words of
// 8 pixels in the plane-byte layout of tools/gfx_layout.py (bg tiles at
// 0x000000, sprites 0x080000, fix chars 0x100000).
// ROM traffic per line: bg 17 tiles x 2 words, fix 32 tiles x 1 word,
// sprites 2 words per sprite crossing the line. One writer drains the
// returned words at one pixel per clock.

module d8_video #(
    parameter bit LATCH      = 1'b0,
    parameter int LATCH_LINE = 6,
    parameter bit KRN_FLIP   = 1'b0,
    // 1: the raster counters run from i_tim_rst (power-on) and keep sync
    // while the core is in reset (black picture); see d8_sys
    parameter bit FREE_TIMING = 1'b0,
    parameter bit PAIR_PIXELS = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_tim_rst,       // FREE_TIMING: synchronous raster reload
    output logic        o_tim_evt,       // FREE_TIMING: this pixel enable starts line 248
    input  logic        ce_pix,          // 6 MHz: exactly one clock in 16
    input  logic [3:0]  i_machine,       // machine profile, see docs/PROFILES.md

    // CPU side (decoded by the system, M2): byte address within each RAM
    input  logic [10:0] i_cpu_addr,
    input  logic [7:0]  i_cpu_din,
    input  logic        i_pal_we,        // palette RAM byte (entry = addr[9:0])
    input  logic        i_palx_we,       // palette ext byte (entry = addr[9:0])
    input  logic        i_fix_we,        // fix RAM, 2 KB
    input  logic        i_bg_we,         // bg RAM, 2 KB
    input  logic        i_row_we,
    input  logic        i_bac_mode_we,
    input  logic        i_bac_scroll_we,
    input  logic        i_bg2_we,        // cobracom: second BAC06 tile RAM, 2 KB
    input  logic        i_color_we,
    input  logic [10:0] i_color_addr,
    input  logic [7:0]  i_color_data,
    input  logic        i_spr_we,        // sprite RAM, 2 KB (srdarwin uses 512 bytes)
    input  logic        i_spr_copy,      // sprite buffer copy (spec 9)
    input  logic        i_scr_we,        // m_scroll[i_scr_sel] = din (MAME's 4 scroll bytes)
    input  logic [1:0]  i_scr_sel,
    input  logic        i_flip_we,       // flip = din[0]
    input  logic        i_user_flip,
    output logic [7:0]  o_pal_dout,
    output logic [7:0]  o_palx_dout,
    output logic [7:0]  o_fix_dout,
    output logic [7:0]  o_bg_dout,
    output logic [7:0]  o_row_dout,
    output logic [7:0]  o_bac_scroll_dout,
    output logic [7:0]  o_bg2_dout,
    output logic [7:0]  o_spr_dout,

    // graphics ROM port (byte address, tools/gfx_layout.py)
    output logic        o_rom_req,
    output logic [21:0] o_rom_addr,
    input  logic        i_rom_gnt,
    input  logic        i_rom_rv,
    input  logic [31:0] i_rom_data,

    // video
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_de,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_vbl,           // one clk at the start of line 248 (NMI, MCU INT0)
    output logic [8:0]  o_vcnt,          // current line (M2: MAME's vblank = lines 248-271, 0-7)
    output logic        o_mvbl,          // MAME's vblank (lines 248-271, 0-7), registered (M4 timing)
    output logic        o_nmi_vbl,       // the same, NMI input (leads o_mvbl by NMI_LEAD pixels on gb)
    output logic        o_busy,          // a snapshot engine is running
    output logic        o_hold,          // a CPU write is held by a snapshot engine

    // gate counters / debug
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [7:0]  o_dbg_err,
    output logic [9:0]  o_dbg_pen        // palette index of the output pixel
);

  localparam logic [21:0] BG_BASE  = 22'h000000;
  localparam logic [21:0] SPR_BASE = 22'h080000;
  localparam logic [21:0] FIX_BASE = 22'h100000;
  localparam int H_ACT = 256, H_TOTAL = 384, V_TOTAL = 272;
  localparam int V_VIS0 = 8, V_VIS1 = 247, V_VBL = 248;
  localparam int NMI_LEAD = 2;
  // sync positions are not in the driver; placed inside the blanking
  localparam int HS_START = 304, HS_END = 336;
  localparam int VS_START = 256;

  wire sh = i_machine == 4'd3;
  wire gb = i_machine == 4'd5 || i_machine == 4'd6;
  wire ga = i_machine == 4'd4;
  wire lm = i_machine == 4'd0 || sh || i_machine == 4'd7;
  wire go_m = i_machine == 4'd1;
  wire sr = i_machine == 4'd2;
  // Cobra-Command (dec8_v.cpp screen_update_cobracom): BAC06 #0 (tiles2,
  // opaque, palette 128) under BAC06 #1 (tiles1, pen 0 transparent, palette
  // 192), MXC06 sprites (palette 64; colour bit 2 clear = behind BAC06 #1),
  // 2bpp fix layer (palette 0) on top. Flip = BAC06 #0 control 0 bit 7.
  wire cb = i_machine == 4'd9;
  // Psycho-Nics Oscar (dec8_v.cpp L287-329): one BAC06 (normal 'tiles'
  // layout, colour bit 3 = group 1 whose pens 8-15 are over the sprites),
  // MXC06 sprites, fix chars; flip from the BAC06 control register
  wire os = i_machine == 4'd8;
  wire mxc = cb || os;                    // MXC06 sprite list

  // ================================================================ timing
  logic [8:0] hcnt /* verilator public_flat_rd */;
  logic [8:0] vcnt /* verilator public_flat_rd */;
  // power-on phase as MAME: the screen starts at the first vblank line
  wire tim_rst = FREE_TIMING ? i_tim_rst : !rst_n;
  assign o_tim_evt = ce_pix && hcnt == 9'(H_TOTAL - 1) && vcnt == 9'(V_VBL - 1);
  always_ff @(posedge clk) begin
    if (tim_rst) begin
      hcnt <= '0;
      vcnt <= 9'(V_VBL);
      o_mvbl <= 1'b1;
    end else if (ce_pix) begin
      if (hcnt == 9'(H_TOTAL - 1)) begin
        hcnt <= '0;
        vcnt <= (vcnt == 9'(V_TOTAL - 1)) ? 9'd0 : vcnt + 9'd1;
        // the same as (new vcnt >= 248 || new vcnt < 8), one register
        if (vcnt == 9'(V_VBL - 1)) o_mvbl <= 1'b1;
        else if (vcnt == 9'(V_VIS0 - 1)) o_mvbl <= 1'b0;
      end else hcnt <= hcnt + 9'd1;
    end
  end
  // vblank as seen by the NMI input. MAME's HD6309 takes the vblank NMI at
  // the instruction boundary that ends up to one CPU cycle (two pixels)
  // before the line-248 edge (measured on meikyuh/ghostb: boundary-T = -1
  // taken, -2 not taken), while the DSW0/IN vblank status bit flips at the
  // edge itself. Here the Ghostbusters family's NMI request leads the status
  // bit by NMI_LEAD pixels; the clear stays on the common edge.
  always_ff @(posedge clk) begin
    if (tim_rst) o_nmi_vbl <= 1'b1;
    else if (ce_pix) begin
      if (hcnt == 9'(H_TOTAL - 1 - ((gb || go_m) ? NMI_LEAD : 0)) && vcnt == 9'(V_VBL - 1)) o_nmi_vbl <= 1'b1;
      else if (hcnt == 9'(H_TOTAL - 1) && vcnt == 9'(V_VIS0 - 1)) o_nmi_vbl <= 1'b0;
    end
  end
  wire last_px    = ce_pix && hcnt == 9'(H_TOTAL - 1);
  wire vbl_start  = last_px && vcnt == 9'(V_VBL - 1);
  wire latch_now  = last_px && vcnt == 9'(LATCH_LINE - 1);
  wire line_start = ce_pix && hcnt == 9'd0;
  always_ff @(posedge clk) o_vbl <= rst_n && vbl_start;
  assign o_vcnt = vcnt;

  // ================================================================ registers
  logic [7:0] sc [0:3];          // MAME m_scroll[0..3]: x MSB, x LSB, y MSB, y LSB
  logic       flip_r;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) sc[i] <= '0;
      flip_r <= 1'b0;
    end else begin
      if (i_scr_we) sc[i_scr_sel] <= i_cpu_din;
      if (i_flip_we) flip_r <= i_cpu_din[0];
    end
  end
  // scroll = (m_scroll[0] << 8) + m_scroll[1] (v:336-337, 435, 512-513); the
  // tilemaps are 512 wide (and 512 or 256 high), so only 9 bits matter
  wire [8:0] sx_live = {sc[0][0], 8'd0} + {1'b0, sc[1]};
  wire [8:0] sy_live = {sc[2][0], 8'd0} + {1'b0, sc[3]};

  logic [8:0] v_sx, v_sy;
  logic       v_flip, v_user_flip;
  wire        bac0_flip;                 // BAC06 #0 control 0 bit 7 (get_flip_state)
  wire        flip_src = (cb || os) ? bac0_flip : flip_r;
  generate
    if (LATCH) begin : g_latch_regs
      always_ff @(posedge clk) if (latch_now) begin
        v_sx <= sx_live; v_sy <= sy_live; v_flip <= flip_src ^ i_user_flip; v_user_flip <= i_user_flip;
      end
    end else begin : g_live_regs
      always_comb begin
        v_sx = sx_live; v_sy = sy_live; v_flip = flip_src ^ i_user_flip; v_user_flip = i_user_flip;
      end
    end
  endgenerate

  // ================================================================ RAMs
  // CPU byte to 16-bit word: even byte = high lane (tile_info reads
  // ram[2i] << 8 | ram[2i+1]); palette word = {ext, RAM}
  localparam int TMODE = LATCH ? 1 : 0;
  wire [1:0]  be_tile = i_cpu_addr[0] ? 2'b01 : 2'b10;
  wire [15:0] din16   = {i_cpu_din, i_cpu_din};
  logic [9:0] pal_va, fix_va, bg_va, spr_va;
  logic [15:0] pal_q, fix_q, bg_q, spr_q;
  logic [15:0] pal_cq, fix_cq, bg_cq, spr_cq;
  logic [3:0] busy_v, hold_v;
  logic [7:0] err_v [0:3];
  wire color_load = gb && i_color_we;
  wire bac_ram_cs, bac_rom_cs;
  wire [13:1] bac_ram_addr;
  wire [17:1] bac_rom_addr;
  logic [31:0] bac_rom_data;
  logic bac_issued, bac_return_valid;
  wire [7:0] bac_pixel;
  logic [15:0] row_cq, row_q;
  logic bac_tile_r, bac_row_r, bac_unmapped_r;
  always_ff @(posedge clk) begin
    bac_tile_r <= bac_ram_addr[13];
    bac_row_r <= !bac_ram_addr[13] && bac_ram_addr[10];
    bac_unmapped_r <= |bac_ram_addr[12:11];
  end
  d8_dpram #(.AW(9), .DW(16)) u_rows (
      .clk, .addr_a(i_cpu_addr[9:1]), .d_a(din16), .we_a(gb && i_row_we), .be_a(be_tile),
      .q_a(row_cq), .addr_b(bac_ram_addr[9:1]), .q_b(row_q));
  wire [15:0] bac_ram_data = bac_tile_r ? (bac_unmapped_r ? 16'd0 : bg_q)
                                                     : (bac_row_r && gb) ? row_q : 16'd0;
  wire [8:0] bac_render = vcnt >= 9'd270 ? vcnt-9'd270 : vcnt+9'd2;
  // BAC06 #0: Ghostbusters' playfield, or Cobra-Command's lower playfield
  // (registers 3800-3807 / 3810-381f: CPU address bit 9 clear). BAC06 #1:
  // Cobra-Command's upper playfield (3a00-3a07 / 3a10-3a1f: bit 9 set).
  wire bac0_on = gb || cb || os;
  wire bac0_sel = gb || os || (cb && !i_cpu_addr[9]);
  wire bac1_sel = cb && i_cpu_addr[9];
  d8_bac06 #(.REVERSED_TILE_LAYOUT(1)) u_bac06 (
      .clk, .rst_n(rst_n && bac0_on), .i_ce12(ce_pix || ph == 4'd7), .i_ce6(ce_pix),
      .i_mode_we(bac0_sel && i_bac_mode_we), .i_scroll_we(bac0_sel && i_bac_scroll_we),
      .i_reg_addr(i_cpu_addr[3:0]), .i_data(i_cpu_din), .o_scroll_data(o_bac_scroll_dout),
      .o_flip(bac0_flip), .i_flip(v_flip), .i_rev(gb),
      .i_vdump(vcnt), .i_vrender(bac_render), .i_hdump(hcnt),
      .i_lhbl(hcnt < 9'd256), .i_lvbl(vcnt >= 9'd8 && vcnt < 9'd248),
      .i_hs(hcnt >= 9'd304 && hcnt < 9'd336), .i_vs(vcnt >= 9'd262 && vcnt < 9'd265),
      .i_vload(vcnt == 9'd7), .i_hinit(hcnt == 9'd255),
      .o_ram_cs(bac_ram_cs), .o_ram_addr(bac_ram_addr), .i_ram_data(bac_ram_data), .i_ram_ok(1'b1),
      .o_rom_cs(bac_rom_cs), .o_rom_addr(bac_rom_addr), .i_rom_data(bac_rom_data),
      .i_rom_ok(bac_return_valid), .o_pixel(bac_pixel), .i_status_addr(8'd0), .o_status_data());

  // Cobra-Command BAC06 #1 and its tile RAM (1000-17ff). No row/column
  // scroll RAM on this board (cobra_map), so the RAM path is tile-only.
  wire bac1_ram_cs, bac1_rom_cs;
  wire [13:1] bac1_ram_addr;
  wire [17:1] bac1_rom_addr;
  logic [31:0] bac1_rom_data;
  logic bac1_issued, bac1_return_valid;
  wire [7:0] bac1_pixel;
  logic [15:0] bg2_cq, bg2_q;
  logic bac1_tile_r, bac1_unmapped_r;
  always_ff @(posedge clk) begin
    bac1_tile_r <= bac1_ram_addr[13];
    bac1_unmapped_r <= |bac1_ram_addr[12:11];
  end
  d8_dpram #(.AW(10), .DW(16)) u_bg2 (
      .clk, .addr_a(i_cpu_addr[10:1]), .d_a(din16), .we_a(cb && i_bg2_we), .be_a(be_tile),
      .q_a(bg2_cq), .addr_b(bac1_ram_addr[10:1]), .q_b(bg2_q));
  wire [15:0] bac1_ram_data = (bac1_tile_r && !bac1_unmapped_r) ? bg2_q : 16'd0;
  d8_bac06 #(.REVERSED_TILE_LAYOUT(0)) u_bac06b (
      .clk, .rst_n(rst_n && cb), .i_ce12(ce_pix || ph == 4'd7), .i_ce6(ce_pix),
      .i_mode_we(bac1_sel && i_bac_mode_we), .i_scroll_we(bac1_sel && i_bac_scroll_we),
      .i_reg_addr(i_cpu_addr[3:0]), .i_data(i_cpu_din), .o_scroll_data(),
      .o_flip(), .i_flip(v_flip), .i_rev(1'b0),
      .i_vdump(vcnt), .i_vrender(bac_render), .i_hdump(hcnt),
      .i_lhbl(hcnt < 9'd256), .i_lvbl(vcnt >= 9'd8 && vcnt < 9'd248),
      .i_hs(hcnt >= 9'd304 && hcnt < 9'd336), .i_vs(vcnt >= 9'd262 && vcnt < 9'd265),
      .i_vload(vcnt == 9'd7), .i_hinit(hcnt == 9'd255),
      .o_ram_cs(bac1_ram_cs), .o_ram_addr(bac1_ram_addr), .i_ram_data(bac1_ram_data), .i_ram_ok(1'b1),
      .o_rom_cs(bac1_rom_cs), .o_rom_addr(bac1_rom_addr), .i_rom_data(bac1_rom_data),
      .i_rom_ok(bac1_return_valid), .o_pixel(bac1_pixel), .i_status_addr(8'd0), .o_status_data());

  d8_snapram #(.AW(10), .MODE(TMODE)) u_pal (
      .clk, .rst_n, .i_cpu_addr(color_load ? i_color_addr[9:0] : i_cpu_addr[9:0]),
      .i_cpu_din(color_load ? {i_color_data,i_color_data} : din16),
      .i_cpu_be(color_load ? (i_color_addr[10] ? 2'b10 : 2'b01) : (i_palx_we ? 2'b10 : 2'b01)),
      .i_cpu_we(color_load || i_pal_we || i_palx_we),
      .o_cpu_dout(pal_cq), .i_snap(latch_now), .o_busy(busy_v[0]), .o_hold(hold_v[0]), .o_err(err_v[0]),
      .i_vid_addr(pal_va), .o_vid_q(pal_q));
  d8_snapram #(.AW(10), .MODE(TMODE)) u_fix (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:1]), .i_cpu_din(din16), .i_cpu_be(be_tile), .i_cpu_we(i_fix_we),
      .o_cpu_dout(fix_cq), .i_snap(latch_now), .o_busy(busy_v[1]), .o_hold(hold_v[1]), .o_err(err_v[1]),
      .i_vid_addr(fix_va), .o_vid_q(fix_q));
  d8_snapram #(.AW(10), .MODE(TMODE)) u_bg (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:1]), .i_cpu_din(din16), .i_cpu_be(be_tile), .i_cpu_we(i_bg_we),
      .o_cpu_dout(bg_cq), .i_snap(latch_now), .o_busy(busy_v[2]), .o_hold(hold_v[2]), .o_err(err_v[2]),
      .i_vid_addr(bg_va), .o_vid_q(bg_q));
  d8_snapram #(.AW(10), .MODE(1)) u_spr (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:1]), .i_cpu_din(din16), .i_cpu_be(be_tile), .i_cpu_we(i_spr_we),
      .o_cpu_dout(spr_cq), .i_snap(i_spr_copy), .o_busy(busy_v[3]), .o_hold(hold_v[3]), .o_err(err_v[3]),
      .i_vid_addr(spr_va), .o_vid_q(spr_q));
  assign o_busy = |busy_v;
  assign o_hold = |hold_v;
  always_comb begin
    o_dbg_err = '0;
    for (int i = 0; i < 4; i++) o_dbg_err = o_dbg_err | err_v[i];
  end
  // CPU reads: the lane of the address presented one clock earlier
  logic lane_r;
  always_ff @(posedge clk) lane_r <= i_cpu_addr[0];
  assign o_pal_dout  = pal_cq[7:0];
  assign o_palx_dout = pal_cq[15:8];
  assign o_fix_dout  = lane_r ? fix_cq[7:0] : fix_cq[15:8];
  assign o_bg_dout   = lane_r ? bg_cq[7:0] : bg_cq[15:8];
  assign o_spr_dout  = lane_r ? spr_cq[7:0] : spr_cq[15:8];
  assign o_row_dout = lane_r ? row_cq[7:0] : row_cq[15:8];
  assign o_bg2_dout = lane_r ? bg2_cq[7:0] : bg2_cq[15:8];

  // ================================================================ renderer
  wire [8:0] next_line = (vcnt == 9'(V_TOTAL - 1)) ? 9'd0 : vcnt + 9'd1;
  wire       want_line = line_start && next_line >= 9'(V_VIS0) && next_line <= 9'(V_VIS1);

  logic        busy, pend;
  logic [8:0]  pend_line;
  logic [7:0]  r_line;          // display line of the pass (8-247)
  logic        r_flip, r_user_flip;
  logic [8:0]  r_sx, r_sy;
  logic [15:0] cyc, maxcyc, overruns;
  wire         go = !busy && (want_line || pend);
  wire [8:0]   go_line = want_line ? next_line : pend_line;

  // ---- tile issuer: layer 0 bg (17 tiles x 2 words), layer 1 fix (32 x 1)
  localparam logic [1:0] T_IDLE = 2'd0, T_ADDR = 2'd1, T_WAIT = 2'd2, T_ISS = 2'd3;
  logic [1:0]  t_st;
  logic        t_layer;
  logic [5:0]  t_k;
  logic        t_j;
  logic        t_done;
  logic [15:0] t_w;              // tile RAM word
  logic        t_lane;           // srdarwin fix: byte lane of the tile

  // bg logical line: (line + sy) unflipped, (sy + 255 - line) flipped (tilemap.cpp,
  // spec 3); srdarwin has no y scroll and is 256 high
  wire [8:0]   r_syb   = sr ? 9'd0 : r_sy;
  wire [8:0]   bg_ly0  = r_flip ? (r_syb + 9'd255 - {1'b0, r_line}) : ({1'b0, r_line} + r_syb);
  wire [8:0]   bg_ly   = sr ? {1'b0, bg_ly0[7:0]} : bg_ly0;
  wire [7:0]   fx_ly   = r_flip ? 8'd255 - r_line : r_line;
  wire [4:0]   bg_row  = sr ? {1'b0, bg_ly[7:4]} : bg_ly[8:4];
  wire [4:0]   bg_col  = r_sx[8:4] + t_k[4:0];
  wire [4:0]   fx_row  = fx_ly[7:3];
  wire [4:0]   fx_col  = t_k[4:0];
  // bg tile RAM word: lastmisn_scan_rows (v:359-363), gondo/srdarwin row-major
  wire [9:0]   bg_idx  = lm ? {bg_row[4], bg_col[4], bg_row[3:0], bg_col[3:0]}
                      : sr ? {1'b0, bg_row[3:0], bg_col} : {bg_row, bg_col};
  wire [9:0]   fx_tile = {fx_row, fx_col};
  assign bg_va  = bac0_on ? bac_ram_addr[10:1] : bg_idx;
  assign fix_va = sr ? {1'b0, fx_tile[9:1]} : fx_tile;

  // tile word decode
  wire [11:0]  bg_code = sr ? {2'd0, t_w[9:0]} : t_w[11:0];
  wire [3:0]   bg_attr = sr ? {2'd0, t_w[13:12]} : t_w[15:12];
  wire [7:0]   sr_ch   = t_lane ? t_w[7:0] : t_w[15:8];
  wire [9:0]   fx_code = sr ? {2'd0, sr_ch} : t_w[9:0];             // chars wrap at 1,024
  // cobracom: get_cobracom_fix_tile_info colour = (tile & 0xe000) >> 13
  wire [3:0]   fx_attr = sr ? 4'd0 : gb ? {2'd0,t_w[11:10]} : (lm || os) ? {2'd0, t_w[15:14]} :
                         cb ? {1'b0, t_w[15:13]} : {1'b0, t_w[14:12]};
  // ROM word addresses (gfx_layout.py): K tiles pixels 0-7 at +16, SRD tiles at +0
  wire [3:0]   bg_y    = bg_ly[3:0];
  wire         bg_half = sr ? t_j : !t_j;
  wire [21:0]  bg_addr = BG_BASE + {3'd0, bg_code, bg_half, bg_y, 2'b00};
  wire [21:0]  fx_addr = FIX_BASE + {7'd0, fx_code, fx_ly[2:0], 2'b00};
  // screen x of the word's first pixel; logical x = col*16 + j*8 (bg), col*8 (fix)
  wire [8:0]   bg_lx   = {bg_col, t_j, 3'd0};
  wire [8:0]   bg_x0   = r_flip ? (9'd255 + r_sx - bg_lx) : (bg_lx - r_sx);
  wire [7:0]   fx_x0   = r_flip ? 8'd255 - {fx_col, 3'd0} : {fx_col, 3'd0};
  wire [5:0]   t_last  = t_layer ? 6'd31 : 6'd16;
  wire         t_req   = t_st == T_ISS;

  // ---- sprite walker
  // Karnov (krn:31-125): 256 entries of 4 words, drawn in list order,
  // later entries over earlier (lastmisn) or last-to-first with the first
  // opaque pixel winning (gondo): in both the visible sprite pixel is the
  // one of the highest-numbered entry, so the walker runs 0 to 255 and the
  // line buffer keeps the last opaque write (with its behind flag).
  // srdarwin (v:159-205): 128 entries of 4 bytes, drawn 127 down to 0, first
  // opaque pixel wins: again the highest-numbered entry, walked 0 to 127.
  localparam logic [2:0] W_A0 = 3'd0, W_D0 = 3'd1, W_D1 = 3'd2, W_D2 = 3'd3, W_D3 = 3'd4,
                         W_POS = 3'd5, W_HIT = 3'd6, W_IDLE = 3'd7;
  logic [2:0]  w_st;
  logic [7:0]  w_e;
  logic        w_done;
  logic [15:0] w0, w1, w2;
  logic [10:0] w_ys, w_xs, w_ys2;  // signed screen positions (registered in W_POS)
  logic        w_fx, w_fy, w_two;
  logic [11:0] w_c0, w_c1;
  logic [3:0]  w_col;
  logic        w_bh;
  wire  [7:0]  w_last = sr ? 8'd127 : 8'd255;

  // Karnov position math on words 0-3 (w0..w2 registered, word 3 = spr_q in W_D3)
  wire         k_extra = w0[11];
  wire  [8:0]  k_yt    = w0[8:0] + 9'd16 + (k_extra ? 9'd16 : 9'd0);   // (y [+16] + 16) & 0x1ff
  wire  [8:0]  k_xt    = w2[8:0] + 9'd16;
  wire  [10:0] k_ys0   = 11'd256 - {2'd0, k_yt};
  wire  [10:0] k_xs0   = 11'd256 - {2'd0, k_xt};
  wire         k_fl    = (KRN_FLIP && (r_flip ^ r_user_flip)) ^ r_user_flip;
  wire  [10:0] k_ys    = k_fl ? (11'd240 - k_ys0 - (k_extra ? 11'd16 : 11'd0)) : k_ys0;
  wire  [10:0] k_xs    = k_fl ? (11'd240 - k_xs0) : k_xs0;
  wire         k_fx    = w1[2] ^ k_fl;
  wire         k_fy    = w1[1] ^ k_fl;
  wire  [11:0] k_spr   = k_extra ? {spr_q[11:1], 1'b0} : spr_q[11:0];
  wire  [11:0] k_c0    = (k_extra && k_fy) ? (k_spr | 12'd1) : k_spr;
  wire  [11:0] k_c1    = (k_extra && k_fy) ? k_spr : (k_spr | 12'd1);
  // srdarwin on bytes b0 = w0[15:8], b1 = w0[7:0], b2 = w1[15:8], b3 = w1[7:0]
  // (w1 = spr_q in W_D1)
  wire  [7:0]  s_b0    = w0[15:8];
  wire  [7:0]  s_b1    = w0[7:0];
  wire  [10:0] s_code  = {s_b1[7:5], spr_q[7:0]};
  wire  [10:0] s_sx0   = 11'd241 - {3'd0, spr_q[15:8]};
  wire  [10:0] s_sy    = r_flip ? (11'd240 - {3'd0, s_b0}) : {3'd0, s_b0};
  wire  [10:0] s_sx    = r_flip ? (11'd240 - s_sx0) : s_sx0;
  wire  [10:0] s_sy2   = r_flip ? (s_sy - 11'd16) : (s_sy + 11'd16);
  wire         s_skip  = s_code == 11'd0 || s_b0 == 8'hF8;

  // MXC06 (decmxc06.cpp draw_sprites, Cobra-Command): 256 entries of 4
  // words, w0 = {en, flipy, flipx, hsize[1:0], wsize[1:0], y[8:0]},
  // w1 = code, w2 = {colour[3:0], flash, x[8:0]}. An enabled parent of
  // width 2^wsize consumes the following (2^wsize - 1) entries as its
  // columns; every column reads its own code word and keeps the parent's
  // position, colour and flips. Column x of a parent at (sx, sy), height h:
  // 16-pixel pieces at sx -/+ 16x, sy -/+ 16y (flip: +), piece y code =
  // (code & ~(h-1)) + ... (parent flipy). Here a column is one hit test of
  // its whole h*16 rows: top row ytop, piece index k from the top, and the
  // piece code is base | k, or base | (h-1-k) when the effective y flip
  // (parent flipy ^ screen flip) is set, which also reverses the rows.
  // Drawn in list order, last opaque write wins: MAME draws the list
  // backwards with prio_transpen marking each pixel (priority 31).
  logic [2:0]  mx_left;                  // columns still owned by the current parent
  logic        mx_child;                 // the entry being walked is a column
  logic [1:0]  mx_hs;                    // log2 height
  logic        mx_fx, mx_afy, mx_bh, mx_draw;
  logic [3:0]  mx_col;
  logic [10:0] mx_ytop, mx_xcur;
  logic        frame_odd;                // MAME screen frame_number() & 1 (sprite flash)
  wire  [10:0] mx_sy0  = {{2{w0[8]}}, w0[8:0]};          // signed 9-bit y of the parent
  wire  [10:0] mx_sx0  = {{2{spr_q[8]}}, spr_q[8:0]};    // signed 9-bit x (word 2 on spr_q in W_D2)
  wire  [7:0]  mx_h16  = 8'd16 << w0[12:11];
  wire  [10:0] mx_hm16 = {3'd0, mx_h16 - 8'd16};                  // 16 * (h - 1)
  wire  [2:0]  mx_hmask = (3'd1 << mx_hs) - 3'd1;
  wire  [10:0] mx_d    = {3'd0, r_line} - mx_ytop;
  wire  [2:0]  mx_k    = mx_d[6:4];
  wire         mx_hit  = mx_draw && mx_d[10:7] == 4'd0 && (mx_k & ~mx_hmask) == 3'd0;
  wire  [11:0] mx_code = w_c0 | {9'd0, (mx_afy ? ~mx_k : mx_k) & mx_hmask};
  wire  [3:0]  mx_row  = mx_afy ? 4'd15 - mx_d[3:0] : mx_d[3:0];

  // hit test on the registered positions (W_HIT)
  wire  [10:0] h_d0    = {3'd0, r_line} - w_ys;
  wire  [10:0] h_d1    = {3'd0, r_line} - w_ys2;
  // Karnov: part 1 is rows 16-31 of the same position; srdarwin: its own position
  wire         h_p0    = h_d0[10:4] == 7'd0;
  wire         h_p1    = w_two && (sr ? (h_d1[10:4] == 7'd0) : (h_d0[10:5] == 6'd0 && h_d0[4]));
  wire  [3:0]  h_r     = h_p0 ? h_d0[3:0] : (sr ? h_d1[3:0] : h_d0[3:0]);
  wire  [3:0]  h_row   = w_fy ? 4'd15 - h_r : h_r;
  wire  [11:0] h_code  = h_p0 ? w_c0 : w_c1;
  wire         h_any   = mxc ? mx_hit : (h_p0 || h_p1);

  // ---- hit queue: {x[10:0], fx, code[11:0], row[3:0], colour[3:0], behind}
  logic        h_push, h_pop, h_empty, h_full;
  logic [32:0] h_d, h_q;
  /* verilator lint_off PINCONNECTEMPTY */
  d8_fifo #(.W(33), .DEPTH(16)) u_hits (
      .clk, .clr(!rst_n), .push(h_push), .d(h_d), .pop(h_pop), .q(h_q),
      .empty(h_empty), .full(h_full), .count());

  // ---- request tags: {layer[1:0], x0[10:0], dir, wide, fmt[1:0], attr[4:0]}
  logic        m_push, m_pop, m_empty, m_full;
  logic [21:0] m_d, m_q;
  d8_fifo #(.W(22), .DEPTH(8)) u_tags (
      .clk, .clr(!rst_n), .push(m_push), .d(m_d), .pop(m_pop), .q(m_q),
      .empty(m_empty), .full(m_full), .count());

  // ---- returned words
  logic        d_pop, d_empty;
  logic [31:0] d_q;
  d8_fifo #(.W(32), .DEPTH(8)) u_ret (
      .clk, .clr(!rst_n), .push(i_rom_rv), .d(i_rom_data), .pop(d_pop), .q(d_q),
      .empty(d_empty), .full(), .count());
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- sprite line buffer clear (the pass's half, before any sprite pixel)
  logic [8:0]  clr_i;
  wire         clr_done = clr_i[8];

  // ---- sprite fetcher: two words (pixels 0-7, 8-15) per hit
  logic        f_j;
  wire  [10:0] f_x     = h_q[32:22];
  wire         f_fx    = h_q[21];
  wire  [11:0] f_code  = h_q[20:9];
  wire  [3:0]  f_row   = h_q[8:5];
  wire  [4:0]  f_attr  = h_q[4:0];               // {colour, behind}
  // both sprite layouts keep pixels 0-7 at +16 (gfx_layout.py)
  wire  [21:0] f_addr  = SPR_BASE + {3'd0, (sr ? {1'b0, f_code[10:0]} : f_code), !f_j, f_row, 2'b00};
  wire  [10:0] f_x0    = f_x + (f_fx ? (f_j ? 11'd7 : 11'd15) : (f_j ? 11'd8 : 11'd0));
  wire         f_req   = t_done && clr_done && !h_empty && busy;

  localparam logic [1:0] FMT_K4 = 2'd0, FMT_P3 = 2'd1, FMT_SRT = 2'd2, FMT_SRC = 2'd3;
  wire  [1:0]  bg_fmt  = sr ? FMT_SRT : FMT_K4;
  wire  [1:0]  fx_fmt  = sr ? FMT_SRC : FMT_P3;
  wire  [1:0]  sp_fmt  = sr ? FMT_P3 : FMT_K4;

  // BAC06 fetches take the port when the line engine does not want it.
  // Cobra-Command BAC06 #0 (tiles2) has data for codes 0-1023 only; MAME
  // decodes codes 1024-4095 to pen 0, so those words return zero without
  // an SDRAM read (bac0_zero). Its words live at BG2_BASE; BAC06 #1 reads
  // tiles1 at BG_BASE. A BAC06 #1 return is tagged layer 0, which is the
  // legacy bg layer that Cobra-Command does not use.
  localparam logic [21:0] BG2_BASE = 22'h120000;
  wire bac0_zero  = cb && bac_rom_addr[17:16] != 2'd0;
  wire want_bac0  = bac0_on && bac_rom_cs && !bac_issued && !bac0_zero;
  wire want_bac1  = cb && bac1_rom_cs && !bac1_issued;
  wire choose_bac = want_bac0 && !t_req && !f_req;
  wire choose_bac1 = want_bac1 && !want_bac0 && !t_req && !f_req;
  wire any_accept = o_rom_req && i_rom_gnt;
  assign o_rom_req  = (t_req || f_req || choose_bac || choose_bac1) && !m_full;
  assign o_rom_addr = choose_bac ? (cb ? (BG2_BASE | {5'd0, bac_rom_addr[15:1], 2'b00}) : {3'd0,bac_rom_addr,2'b00}) :
                      choose_bac1 ? {3'd0,bac1_rom_addr,2'b00} :
                      t_req ? (t_layer ? fx_addr : bg_addr) : f_addr;
  wire   accept     = any_accept && !choose_bac && !choose_bac1;
  assign m_push     = any_accept;
  assign m_d        = choose_bac ? {2'd3,20'd0} : choose_bac1 ? {2'd0,20'd0} :
                      t_req ? (t_layer ? {2'd1, 3'd0, fx_x0, r_flip, 1'b0, fx_fmt, fx_attr, 1'b0}
                                       : {2'd0, 2'd0, bg_x0, r_flip, 1'b1, bg_fmt, bg_attr, 1'b0})
                            : {2'd2, f_x0, f_fx, 1'b0, sp_fmt, f_attr};
  assign h_pop      = accept && !t_req && f_j;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy <= 1'b0;
      pend <= 1'b0;
      t_st <= T_IDLE;
      t_done <= 1'b1;
      w_st <= W_IDLE;
      w_done <= 1'b1;
      f_j <= 1'b0;
      clr_i <= 9'h100;
      cyc <= '0;
      maxcyc <= '0;
      overruns <= '0;
    end else begin
      // ---- line start / overrun bookkeeping
      if (want_line && busy) begin
        overruns <= overruns + 16'd1;
        pend <= 1'b1;
        pend_line <= next_line;
      end else if (go) pend <= 1'b0;

      if (go) begin
        busy <= 1'b1;
        r_line <= go_line[7:0];
        r_flip <= v_flip;
        r_user_flip <= v_user_flip;
        r_sx <= v_sx;
        r_sy <= v_sy;
        t_st <= T_ADDR;
        t_layer <= bac0_on;                       // BAC06 playfields: fix layer only
        t_k <= '0;
        t_j <= 1'b0;
        t_done <= 1'b0;
        w_st <= W_A0;
        w_e <= '0;
        mx_left <= 3'd0;
        w_done <= 1'b0;
        f_j <= 1'b0;
        clr_i <= '0;
        cyc <= '0;
      end else if (busy) begin
        cyc <= cyc + 16'd1;
        if (t_done && w_done && h_empty && m_empty && d_empty && clr_done) begin
          busy <= 1'b0;
          if (cyc > maxcyc) maxcyc <= cyc;
        end
      end

      if (!go && !clr_done) clr_i <= clr_i + (PAIR_PIXELS ? 9'd2 : 9'd1);

      // ---- tile issuer: tile RAM read, then 2 (bg) or 1 (fix) requests
      case (t_st)
        T_ADDR: begin
          t_lane <= fx_tile[0];
          t_st <= T_WAIT;
        end
        T_WAIT: begin
          t_w <= t_layer ? fix_q : bg_q;
          t_st <= T_ISS;
        end
        T_ISS: if (accept) begin
          if (!t_layer && !t_j) t_j <= 1'b1;
          else begin
            t_j <= 1'b0;
            if (t_k == t_last) begin
              t_k <= '0;
              if (t_layer) begin
                t_st <= T_IDLE;
                t_done <= 1'b1;
              end else begin
                t_layer <= 1'b1;
                t_st <= T_ADDR;
              end
            end else begin
              t_k <= t_k + 6'd1;
              t_st <= T_ADDR;
            end
          end
        end
        default: ;
      endcase

      // ---- sprite walker: each state presents the next word address; the
      // word arrives on spr_q in the following state
      if (!go) begin
        case (w_st)
          W_A0: w_st <= W_D0;
          W_D0: if (mxc) begin                      // MXC06: spr_q = word 0
            mx_child <= mx_left != 3'd0;
            if (mx_left != 3'd0) begin              // a column of the current parent
              mx_left <= mx_left - 3'd1;
              w_st <= W_D1;
            end else if (!spr_q[15]) begin          // parent not enabled: next entry
              if (w_e == w_last) w_st <= W_IDLE;
              else begin
                w_e <= w_e + 8'd1;
                w_st <= W_A0;
              end
            end else begin
              w0 <= spr_q;
              w_st <= W_D1;
            end
          end else begin                            // spr_q = word 0
            w0 <= spr_q;
            if (!sr && !spr_q[15]) begin            // Karnov: not enabled (krn:40)
              if (w_e == w_last) w_st <= W_IDLE;
              else begin
                w_e <= w_e + 8'd1;
                w_st <= W_A0;
              end
            end else w_st <= W_D1;
          end
          W_D1: begin                               // spr_q = word 1
            w1 <= spr_q;
            if (mxc) w_st <= mx_child ? W_D3 : W_D2; // MXC06: code word; a parent also needs word 2
            else if (sr) begin
              if (s_skip) begin                     // code 0 or y 0xf8 (v:172-177)
                if (w_e == w_last) w_st <= W_IDLE;
                else begin
                  w_e <= w_e + 8'd1;
                  w_st <= W_A0;
                end
              end else begin
                w_ys <= s_sy;
                w_ys2 <= s_sy2;
                w_xs <= s_sx;
                w_fx <= s_b1[2] ^ r_flip;
                w_fy <= r_flip;
                w_two <= s_b1[4];
                w_c0 <= {1'b0, s_code};
                w_c1 <= {1'b0, s_code + 11'd1};     // code + 1 wraps at 2,048 elements
                w_col <= {1'b0, s_b1[3], s_b1[1:0]};
                w_bh <= {s_b1[3], s_b1[1:0]} == 3'd0;  // colour 0 behind priority 2
                w_st <= W_HIT;
              end
            end else if (!spr_q[0]) begin           // Karnov: word 1 bit 0 clear (krn:58)
              if (w_e == w_last) w_st <= W_IDLE;
              else begin
                w_e <= w_e + 8'd1;
                w_st <= W_A0;
              end
            end else w_st <= W_D2;
          end
          W_D2: begin                               // spr_q = word 2
            w2 <= spr_q;
            if (mxc) begin                          // MXC06 parent: w0 = word 0, spr_q = word 2
              mx_left  <= (3'd1 << w0[10:9]) - 3'd1;
              mx_hs    <= w0[12:11];
              mx_fx    <= w0[13] ^ r_flip;
              mx_afy   <= w0[14] ^ r_flip;
              // cobracom: 4 colours (colour % 4) and cobracom_colpri_cb (bit 2
              // clear = behind BAC06 #1); oscar: 16 colours, no priority callback
              mx_col   <= cb ? {2'd0, spr_q[13:12]} : spr_q[15:12];
              mx_bh    <= cb && !spr_q[14];
              mx_draw  <= !spr_q[11] || frame_odd;  // flash: drawn on odd frames only
              mx_ytop  <= r_flip ? mx_sy0 : (11'd240 - mx_sy0 - mx_hm16);
              mx_xcur  <= r_flip ? mx_sx0 : (11'd240 - mx_sx0);
            end
            w_st <= W_D3;
          end
          W_D3: if (mxc) begin                      // MXC06 column: w1 = its code word
            w_xs  <= mx_xcur;
            mx_xcur <= r_flip ? mx_xcur + 11'd16 : mx_xcur - 11'd16;
            w_fx  <= mx_fx;
            w_c0  <= w1[11:0] & ~{9'd0, mx_hmask};  // code & ~(h-1), mod 4096 elements
            w_col <= mx_col;
            w_bh  <= mx_bh;
            w_st  <= W_HIT;
          end else begin                            // spr_q = word 3: positions
            w_ys <= k_ys;
            w_ys2 <= k_ys;
            w_xs <= k_xs;
            w_fx <= k_fx;
            w_fy <= k_fy;
            w_two <= k_extra;
            w_c0 <= k_c0;
            w_c1 <= k_c1;
            w_col <= spr_q[15:12];
            w_bh <= go_m && spr_q[15];              // gondo_colpri_cb: colour bit 3 (v:462-467)
            w_st <= W_HIT;
          end
          W_HIT: if (!h_any || !h_full) begin
            if (w_e == w_last) w_st <= W_IDLE;
            else begin
              w_e <= w_e + 8'd1;
              w_st <= W_A0;
            end
          end
          default: ;
        endcase
        if (w_st == W_IDLE) w_done <= 1'b1;
      end

      // ---- fetcher word counter
      if (accept && !t_req) f_j <= !f_j;
    end
  end

  // word address on the sprite buffer port for the walker's next read
  always_comb begin
    case (w_st)
      W_A0:   spr_va = sr ? {2'd0, w_e[6:0], 1'b0} : {w_e, 2'd0};
      W_D0:   spr_va = sr ? {2'd0, w_e[6:0], 1'b1} : {w_e, 2'd1};
      W_D1:   spr_va = {w_e, 2'd2};
      W_D2:   spr_va = {w_e, 2'd3};
      default: spr_va = {w_e, 2'd0};
    endcase
  end
  // Karnov entry e = words 4e..4e+3; srdarwin entry e = bytes 4e..4e+3 =
  // words 2e ({b0, b1}) and 2e+1 ({b2, b3})
  assign h_push = !go && w_st == W_HIT && h_any && !h_full && busy;
  assign h_d    = mxc ? {w_xs, w_fx, mx_code, mx_row, w_col, w_bh}
                     : {w_xs, w_fx, h_code, h_row, w_col, w_bh};

  // ---- writer: one pixel per clock from the returned words
  logic [2:0]  wb;
  wire  [1:0]  w_lay  = m_q[21:20];
  wire  [10:0] w_x0   = m_q[19:9];
  wire         w_dir  = m_q[8];
  wire         w_wide = m_q[7];
  wire  [1:0]  w_fmt  = m_q[6:5];
  wire  [4:0]  w_at   = m_q[4:0];
  // pixel decode (gfx_layout.decode_word)
  function automatic [3:0] decode_pixel(input [31:0] data_word,input [2:0] index,input [1:0] fmt);
    logic [7:0] a, c;
    logic [1:0] xx;
    xx = index[1:0];
    a = index[2] ? data_word[15:8] : data_word[31:24];
    c = index[2] ? data_word[7:0]  : data_word[23:16];
    case (fmt)
      FMT_K4:  decode_pixel = {data_word[3'd7 - index], data_word[5'd15 - {2'd0, index}], data_word[5'd23 - {2'd0, index}], data_word[5'd31 - {2'd0, index}]};
      FMT_P3:  decode_pixel = {1'b0, data_word[5'd15 - {2'd0, index}], data_word[5'd23 - {2'd0, index}], data_word[5'd31 - {2'd0, index}]};
      FMT_SRT: decode_pixel = {a[3'd7 - {1'b0, xx}], a[3'd3 - {1'b0, xx}], c[3'd7 - {1'b0, xx}], c[3'd3 - {1'b0, xx}]};
      default: begin                                // FMT_SRC: pixels 0-3 lane 0, 4-7 lane 1
        a = index[2] ? data_word[23:16] : data_word[31:24];
        decode_pixel = {2'd0, a[3'd7 - {1'b0, xx}], a[3'd3 - {1'b0, xx}]};
      end
    endcase
  endfunction
  wire [3:0] pix=decode_pixel(d_q,wb,w_fmt);
  wire [2:0] wb2=wb+3'd1;
  wire [3:0] pix2=decode_pixel(d_q,wb2,w_fmt);
  wire         is_sp  = w_lay == 2'd2;
  wire  [10:0] wx_s   = w_dir ? w_x0 - {8'd0, wb} : w_x0 + {8'd0, wb};
  wire  [8:0]  wx_t0  = w_dir ? w_x0[8:0] - {6'd0, wb} : w_x0[8:0] + {6'd0, wb};
  wire  [8:0]  wx_t   = w_wide ? wx_t0 : {1'b0, wx_t0[7:0]};
  wire         wvis   = is_sp ? (wx_s[10:8] == 3'd0 && pix != 4'd0) : !wx_t[8];
  wire [10:0] wx_s2=w_dir?w_x0-{8'd0,wb2}:w_x0+{8'd0,wb2};
  wire [8:0] wx_t02=w_dir?w_x0[8:0]-{6'd0,wb2}:w_x0[8:0]+{6'd0,wb2};
  wire [8:0] wx_t2=w_wide?wx_t02:{1'b0,wx_t02[7:0]};
  wire wvis2=is_sp?(wx_s2[10:8]==0&&pix2!=0):!wx_t2[8];
  wire         wact   = !d_empty && !m_empty;
  always_ff @(posedge clk) begin
    if (!rst_n || !bac0_on) begin
      bac_issued <= 1'b0;
      bac_return_valid <= 1'b0;
      bac_rom_data <= '0;
    end else begin
      if (!bac_rom_cs) begin
        bac_issued <= 1'b0;
        bac_return_valid <= 1'b0;
      end
      if (any_accept && choose_bac) bac_issued <= 1'b1;
      if (wact && w_lay == 2'd3 && wb == 3'd0) begin
        bac_rom_data <= d_q;
        bac_return_valid <= 1'b1;
      end
      if (bac_rom_cs && bac0_zero && !bac_issued) begin   // blank tiles2 codes 1024-4095
        bac_issued <= 1'b1;
        bac_rom_data <= '0;
        bac_return_valid <= 1'b1;
      end
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n || !cb) begin
      bac1_issued <= 1'b0;
      bac1_return_valid <= 1'b0;
      bac1_rom_data <= '0;
    end else begin
      if (!bac1_rom_cs) begin
        bac1_issued <= 1'b0;
        bac1_return_valid <= 1'b0;
      end
      if (any_accept && choose_bac1) bac1_issued <= 1'b1;
      if (wact && w_lay == 2'd0 && wb == 3'd0) begin
        bac1_rom_data <= d_q;
        bac1_return_valid <= 1'b1;
      end
    end
  end
  // frame parity for MXC06 flash. MAME's screen frame_number counts vblank
  // ends (screen.cpp vblank_end) and the frame is drawn at vblank start, so
  // lines 8-247 see the count after the end of the vblank before them; the
  // raster powers up at line 248. The renderer builds line L during line
  // L-1, so the parity flips on entering line 7.
  always_ff @(posedge clk) begin
    if (tim_rst) frame_odd <= 1'b0;
    else if (last_px && vcnt == 9'(V_VIS0 - 2)) frame_odd <= !frame_odd;
  end
  wire  [7:0]  wx     = is_sp ? wx_s[7:0] : wx_t[7:0];
  wire  [8:0]  lb_wa  = {r_line[0], wx};
  wire [7:0] wx2=is_sp?wx_s2[7:0]:wx_t2[7:0];
  wire [8:0] lb_wa2={r_line[0],wx2};
  wire         wr_en  = wact && wvis;
  wire wr_en2=wact&&wvis2;
  assign d_pop = wact && wb == (PAIR_PIXELS?3'd6:3'd7);
  assign m_pop = d_pop;
  always_ff @(posedge clk) begin
    if (!rst_n) wb <= '0;
    else if (wact) wb <= wb + (PAIR_PIXELS?3'd2:3'd1);
  end

  assign o_dbg_overruns = overruns;
  assign o_dbg_maxcyc   = maxcyc;

  // ---- line buffers: port A written by the writer, port B read by scan-out
  // bg {attr, pen}, fix {attr, pen}, sprites {behind, colour, pen}
  wire  [8:0]  lb_ra = {vcnt[0], hcnt[7:0]};
  logic [15:0] lbq_bg, lbq_fx, lbq_sp;
  wire [15:0] lbq_bg_single,lbq_fx_single,lbq_sp_single;
  wire [15:0] lbq_bg_pair,lbq_fx_pair,lbq_sp_pair;
  assign lbq_bg=PAIR_PIXELS?lbq_bg_pair:lbq_bg_single;
  assign lbq_fx=PAIR_PIXELS?lbq_fx_pair:lbq_fx_single;
  assign lbq_sp=PAIR_PIXELS?lbq_sp_pair:lbq_sp_single;
  /* verilator lint_off PINCONNECTEMPTY */
  d8_dpram #(.AW(9), .DW(16)) u_lb_bg (
      .clk, .addr_a(lb_wa), .d_a({8'd0, w_at[4:1], pix}), .we_a(!PAIR_PIXELS && wr_en && w_lay == 2'd0 && !cb), .be_a(2'b11),
      .q_a(), .addr_b(lb_ra), .q_b(lbq_bg_single));
  d8_dpram #(.AW(9), .DW(16)) u_lb_fx (
      .clk, .addr_a(lb_wa), .d_a({8'd0, w_at[4:1], pix}), .we_a(!PAIR_PIXELS && wr_en && w_lay == 2'd1), .be_a(2'b11),
      .q_a(), .addr_b(lb_ra), .q_b(lbq_fx_single));
  d8_dpram #(.AW(9), .DW(16)) u_lb_sp (
      .clk, .addr_a(clr_done ? lb_wa : {r_line[0], clr_i[7:0]}),
      .d_a(clr_done ? {7'd0, w_at[0], w_at[4:1], pix} : 16'd0),
      .we_a(!PAIR_PIXELS && (clr_done ? (wr_en && is_sp) : busy)), .be_a(2'b11),
      .q_a(), .addr_b(lb_ra), .q_b(lbq_sp_single));
  generate if(PAIR_PIXELS)begin:gen_pair_pixels
    d8_linebuf_pair bg_pair(.clk,.addr0(lb_wa),.addr1(lb_wa2),
      .data0({8'd0,w_at[4:1],pix}),.data1({8'd0,w_at[4:1],pix2}),
      .we0(wr_en&&w_lay==0&&!cb),.we1(wr_en2&&w_lay==0&&!cb),.read_addr(lb_ra),.read_data(lbq_bg_pair));
    d8_linebuf_pair fx_pair(.clk,.addr0(lb_wa),.addr1(lb_wa2),
      .data0({8'd0,w_at[4:1],pix}),.data1({8'd0,w_at[4:1],pix2}),
      .we0(wr_en&&w_lay==1),.we1(wr_en2&&w_lay==1),.read_addr(lb_ra),.read_data(lbq_fx_pair));
    d8_linebuf_pair sp_pair(.clk,
      .addr0(clr_done?lb_wa:{r_line[0],clr_i[7:0]}),
      .addr1(clr_done?lb_wa2:{r_line[0],(clr_i[7:0]+8'd1)}),
      .data0(clr_done?{7'd0,w_at[0],w_at[4:1],pix}:16'd0),
      .data1(clr_done?{7'd0,w_at[0],w_at[4:1],pix2}:16'd0),
      .we0(clr_done?(wr_en&&is_sp):busy),.we1(clr_done?(wr_en2&&is_sp):busy),
      .read_addr(lb_ra),.read_data(lbq_sp_pair));
  end else begin:gen_single_pixel
    assign lbq_bg_pair=16'd0;
    assign lbq_fx_pair=16'd0;
    assign lbq_sp_pair=16'd0;
  end endgenerate
  /* verilator lint_on PINCONNECTEMPTY */

  // ================================================================ mixer
  // lastmisn (v:334-345): bg opaque, sprites over it, fix (pen 0
  // transparent) on top. gondo (v:517-524): bg pens 8-15 are layer 0
  // (priority 2); a sprite with colour bit 3 is behind them. srdarwin
  // (v:412-460): bg group 3 all pens and groups 1-2 pens 8-15 are layer 0;
  // a colour 0 sprite is behind them. Palette index (spec 6): fix col*8+pen
  // (srdarwin 128+pen), sprites 256+colour*16+pen (srdarwin 64+colour*8+pen),
  // bg 768+colour*16+pen (srdarwin group*16+pen).
  logic [9:0] mx;
  always_comb begin
    logic [3:0] bgp, bga, fxp, fxa, spp, spa;
    logic       spb, l0;
    bgp = (gb || os) ? bac_pixel[3:0] : lbq_bg[3:0];
    bga = (gb || os) ? bac_pixel[7:4] : lbq_bg[7:4];
    fxp = lbq_fx[3:0]; fxa = lbq_fx[7:4];
    spp = lbq_sp[3:0]; spa = lbq_sp[7:4]; spb = lbq_sp[8];
    l0 = sr ? (bga[1:0] == 2'd3 || (bga[1:0] != 2'd0 && bgp[3])) : (go_m && bgp[3]);
    // cobracom: fix col*4+pen; sprites 64+col*16+pen unless behind an
    // opaque BAC06 #1 pixel; BAC06 #1 192+col*16+pen (pen 0 transparent);
    // BAC06 #0 128+col*16+pen (opaque). Gfx colours wrap at 4 (colour % 4).
    if (cb) begin
      if (fxp[1:0] != 2'd0)
        mx = {5'd0, fxa[2:0], fxp[1:0]};
      else if (spp != 4'd0 && !(spb && bac1_pixel[3:0] != 4'd0))
        mx = {4'b0001, spa[1:0], spp};
      else if (bac1_pixel[3:0] != 4'd0)
        mx = {4'b0011, bac1_pixel[5:4], bac1_pixel[3:0]};
      else
        mx = {4'b0010, bac_pixel[5:4], bac_pixel[3:0]};
    end
    else if (fxp != 4'd0)
      mx = sr ? {8'b00100000, fxp[1:0]} : os ? {5'b01000, fxa[1:0], fxp[2:0]} : {4'd0, fxa[2:0], fxp[2:0]};
    // Shackled category 1 (colour bit 3), pens 4..15, is drawn after sprites.
    // Garyo draws category 1 after sprites without Shackled's pen split.
    // Oscar (dec8_v.cpp L296-329): group 1 (colour bit 3) pens 8-15 over
    // the sprites; fix 256+col*8, sprites col*16, bg 384+(col&7)*16.
    else if (spp != 4'd0 && !(spb && l0) && !(sh && bga[3] && |bgp[3:2]) && !(ga && bga[3]) &&
             !(os && bga[3] && bgp[3]))
      mx = sr ? {4'b0001, spa[2:0], spp[2:0]} : os ? {2'b00, spa, spp} : {2'b01, spa, spp};
    else
      mx = sr ? {4'b0000, bga[1:0], bgp} : gb ? {2'b10,bga,bgp} : os ? {3'b011, bga[2:0], bgp} : {2'b11, bga, bgp};
  end

  // ================================================================ scan-out
  // Phase within the pixel (16 clocks): 0 line buffers addressed by the
  // counters, 1 mixer result registered, 2 palette addressed, 3 entry
  // registered; the colour is registered at the next pixel enable (one
  // pixel of pipeline delay on every output).
  logic [3:0]  ph;
  logic [9:0]  ma;
  logic [15:0] col;
  always_ff @(posedge clk) begin
    if (ce_pix) ph <= 4'd0;
    else if (ph != 4'd15) ph <= ph + 4'd1;
  end
  assign pal_va = ma;
  always_ff @(posedge clk) begin
    if (ph == 4'd1) ma <= mx;
    if (ph == 4'd3) col <= pal_q;
  end
  // DECO RM-C3 (decrmc3.cpp:214-224): R = bits 0-3, G = 4-7, B = ext 0-3,
  // each bit weighted 0x0e, 0x1f, 0x43, 0x8f
  function automatic [7:0] wt(input [3:0] v);
    wt = (v[0] ? 8'h0e : 8'h00) + (v[1] ? 8'h1f : 8'h00) + (v[2] ? 8'h43 : 8'h00) + (v[3] ? 8'h8f : 8'h00);
  endfunction

  // FREE_TIMING: sync and blanking run from the raster whatever the core
  // reset; the picture is black while the core is held in reset
  wire out_rst = FREE_TIMING ? tim_rst : !rst_n;
  always_ff @(posedge clk) begin
    if (out_rst) begin
      o_de <= 1'b0;
      o_hblank <= 1'b1;
      o_vblank <= 1'b1;
      o_hs <= 1'b0;
      o_vs <= 1'b0;
    end else if (ce_pix) begin
      o_de     <= hcnt < 9'(H_ACT) && vcnt >= 9'(V_VIS0) && vcnt <= 9'(V_VIS1);
      o_hblank <= hcnt >= 9'(H_ACT);
      o_vblank <= vcnt < 9'(V_VIS0) || vcnt > 9'(V_VIS1);
      o_hs     <= hcnt >= 9'(HS_START) && hcnt < 9'(HS_END);
      o_vs     <= vcnt >= 9'(VS_START) && vcnt < 9'(VS_START + 3);
      o_r <= (rst_n || !FREE_TIMING) ? wt(col[3:0])  : 8'd0;
      o_g <= (rst_n || !FREE_TIMING) ? wt(col[7:4])  : 8'd0;
      o_b <= (rst_n || !FREE_TIMING) ? wt(col[11:8]) : 8'd0;
      o_dbg_pen <= ma;
    end
  end

endmodule
