//============================================================================
// boomrang video (MAME liberate_v.cpp screen_update_boomrang)
//
// Layer order: BG LAYER1 -> sprites pri8 -> BG LAYER0 -> sprites pri0 -> FG
//
// This is a hardware pipeline, not a per-pixel software renderer. Every memory
// is a synchronous-read BRAM and each pixel gets an 8-clock fetch window (48 MHz
// / 6 MHz dot clock), sequenced by hvgen's `dot` phase.
//
// GFX ROMs are split so that one pixel never needs more than one read from any
// single block:
//   gfx1 -> 3 x 16K plane BRAMs (MAME RGN_FRAC(1,3) planes at 0/0x4000/0x8000).
//           Port A serves the FG, port B the sprite engine.
//   gfx2 -> 3 x 8K bank BRAMs, which is exactly how MAME's tiles1/tiles2
//           layouts carve the region up:
//             bank A 0x0000 : tiles1 plane2 (bits 3:0) + plane1 (bits 7:4)
//             bank B 0x2000 : tiles2 plane2 (bits 3:0) + plane1 (bits 7:4)
//             bank C 0x4000 : plane0, tiles1 in bits 3:0, tiles2 in bits 7:4
//           so a BG pixel costs 2 useful reads, and one byte covers 4 pixels.
//
// Sprites are evaluated and drawn into a ping-pong line buffer across the whole
// preceding scanline (384 dots x 8 = 3072 clocks), one pixel per clock.
//============================================================================

import yellowcab_rom_map::*;

module video (
  input             clk_sys,
  input             reset,

  input      [15:0] cpu_ab,
  input       [7:0] cpu_dout,
  input             rw,
  input             color_cs,
  input             video_cs,
  input             sprite_cs,

  input       [7:0] io_ram0,
  input       [7:0] io_ram1,
  input       [7:0] io_ram2,
  input       [7:0] io_ram3,
  input       [7:0] io_ram4,
  input       [7:0] io_ram5,
  input       [7:0] io_ram6,

  input             ioctl_download,
  input      [26:0] ioctl_addr,
  input       [7:0] ioctl_dout,
  input             ioctl_wr,

  // user1 (BG tilemap ROM) is shared with the main CPU's bank view
  input      [13:0] user1_cpu_addr,
  output      [7:0] user1_cpu_q,

  output            hb,
  output            vb,
  output            hs,
  output            vs,
  output            ce_pix,
  output      [3:0] red,
  output      [3:0] green,
  output      [3:0] blue,

  input             prom_wr,
  input       [4:0] prom_addr,
  input       [7:0] prom_data,

  output      [7:0] color_dout,
  output      [7:0] video_dout,
  output      [7:0] sprite_dout
);

wire [8:0] h, v;
wire [2:0] dot;

hvgen u_hv(
  .clk_sys ( clk_sys ),
  .reset   ( reset   ),
  .hb      ( hb      ),
  .vb      ( vb      ),
  .hs      ( hs      ),
  .vs      ( vs      ),
  .hcount  ( h       ),
  .vcount  ( v       ),
  .dot     ( dot     ),
  .ce_pix  ( ce_pix  )
);

//--------------------------------------------------------------------------
// ioctl decode
//--------------------------------------------------------------------------
reg ioctl_wr_d;
always @(posedge clk_sys) ioctl_wr_d <= ioctl_wr;
wire ioctl_stb = ioctl_download && ioctl_wr && !ioctl_wr_d;

wire in_gfx1  = (ioctl_addr >= GFX1_BASE)  && (ioctl_addr < GFX1_BASE  + GFX1_SIZE);
wire in_gfx2  = (ioctl_addr >= GFX2_BASE)  && (ioctl_addr < GFX2_BASE  + GFX2_SIZE);
wire in_user1 = (ioctl_addr >= USER1_BASE) && (ioctl_addr < USER1_BASE + USER1_SIZE);

wire [26:0] gfx1_off = ioctl_addr - GFX1_BASE[26:0];   // 0..0xBFFF
wire [26:0] gfx2_off = ioctl_addr - GFX2_BASE[26:0];   // 0..0x7FFF (0x6000 used)
wire [26:0] usr1_off = ioctl_addr - USER1_BASE[26:0];  // 0..0x3FFF

wire [1:0]  gfx1_plane = gfx1_off[15:14];   // 3 x 16K
wire [13:0] gfx1_a     = gfx1_off[13:0];
wire [1:0]  gfx2_bank  = gfx2_off[14:13];   // 3 x 8K
wire [12:0] gfx2_a     = gfx2_off[12:0];

//--------------------------------------------------------------------------
// Scroll / control
//--------------------------------------------------------------------------
wire [7:0] scrollx    = io_ram0;
wire [7:0] scrolly    = io_ram1;
wire       bg_disable = io_ram6[2];
wire [1:0] bg_color   = io_ram6[5:4];
wire       flip       = io_ram6[0];

// Screen flip is modelled the way MAME's flip_screen_set does for tilemaps:
// mirror the scan coordinate. Sprites are NOT flipped here -- MAME's
// boomrang_draw_sprites applies flip to sx/sy itself.
wire [7:0] fx = flip ? (8'd255 - h[7:0]) : h[7:0];
wire [7:0] fy = flip ? (8'd255 - v[7:0]) : v[7:0];

//--------------------------------------------------------------------------
// FG: 8x8x3 planar, fix_scan = (row & 0x1f) + ((31 - (col & 0x1f)) << 5)
//--------------------------------------------------------------------------
wire [4:0] fg_col = fx[7:3];
wire [4:0] fg_row = fy[7:3];
wire [9:0] fg_idx = { (5'd31 - fg_col), fg_row };

wire [7:0] fg_lo, fg_hi;     // videoram / colorram, valid from dot 1
reg  [7:0] fg_p0, fg_p1, fg_p2;

// MAME get_fix_tile_info: tile = videoram + (colorram << 8), gfx(0) has 2048
// elements so only colorram[2:0] survives; color = (colorram & 0x70) >> 4, but
// the 32-byte PROM is 4 banks of 8 pens, so only 2 bits can address anything.
wire [10:0] fg_code = { fg_hi[2:0], fg_lo };
wire  [1:0] fg_pal  = fg_hi[5:4];
wire  [2:0] fg_py   = flip ? (3'd7 - fy[2:0]) : fy[2:0];
wire  [2:0] fg_px   = flip ? (3'd7 - fx[2:0]) : fx[2:0];
wire [13:0] fg_gaddr = { fg_code, fg_py };    // code*8 + py

// MAME drawgfx: bit = 0x80 >> (bitnum & 7), i.e. MSB first
wire [2:0] fg_bit = 3'd7 - fg_px;
wire [2:0] fg_pix = { fg_p2[fg_bit], fg_p1[fg_bit], fg_p0[fg_bit] };
wire [5:0] fg_pen = (fg_pix == 3'd0) ? 6'd32 : {1'b0, fg_pal, fg_pix};

//--------------------------------------------------------------------------
// BG: 16x16 from gfx2 via the user1 page table
//--------------------------------------------------------------------------
// MAME boomrang: set_scrollx(0, -io_ram[0]), set_scrolly(0, io_ram[1]).
//
// Sign derivation from tilemap.cpp, because getting this backwards makes the
// background scroll against the sprites:
//   draw_instance(..., xpos, ypos) writes the tilemap origin at
//     dest.pix(y1, xpos)                       => screen = map + xpos
//   xpos comes from effective_rowscroll(), which returns
//     m_dx - m_rowscroll[i]  (m_dx = 0)        => xpos = -scroll_value
//   therefore                                     map = screen + scroll_value
// Substituting the two calls above:
//   map_x = screen_x + (-io_ram[0]) = screen_x - io_ram[0]
//   map_y = screen_y + ( io_ram[1]) = screen_y + io_ram[1]
wire [8:0] bmap_x = {1'b0, fx} - {1'b0, scrollx};
wire [8:0] bmap_y = {1'b0, fy} + {1'b0, scrolly};
wire [4:0] bg_col = bmap_x[8:4];
wire [4:0] bg_row = bmap_y[8:4];
wire [3:0] bg_lx  = bmap_x[3:0];
wire [3:0] bg_ly  = bmap_y[3:0];

// back_scan: (row & 0xf) + ((15 - (col & 0xf)) << 4) + ((row & 0x10) << 5)
//                                                    + ((col & 0x10) << 4)
wire [9:0] bg_tidx = {6'd0, bg_row[3:0]}
                   + {2'd0, (4'd15 - bg_col[3:0]), 4'd0}
                   + {bg_row[4], 9'd0}
                   + {1'b0, bg_col[4], 8'd0};

// get_back_tile_info page select from io_ram[2..5]
wire [7:0] bg_page = bg_tidx[8] ? (bg_tidx[9] ? io_ram5 : io_ram4)
                                : (bg_tidx[9] ? io_ram3 : io_ram2);
wire [13:0] u1_addr = { bg_page[5:0], bg_tidx[7:0] };  // user1 is 16K

wire [7:0] bg_tile;          // valid from dot 1
wire       bg_bank3 = bg_tile[7];
wire [6:0] bg_code  = bg_tile[6:0];

// byte = code*64 + ly*4 + (3 - lx[3:2])   (xoffset 24..27,16..19,8..11,0..3)
wire [12:0] bg_gaddr = { bg_code, bg_ly, (2'd3 - bg_lx[3:2]) };

reg [7:0] bg_a, bg_b, bg_c;
wire [7:0] bg_hi_byte = bg_bank3 ? bg_b : bg_a;
// "bit offset 4" lands in verilog bits 3:0, "bit offset 0" in bits 7:4
wire [2:0] bg_bit_h = 3'd3 - {1'b0, bg_lx[1:0]};
wire [2:0] bg_bit_l = 3'd7 - {1'b0, bg_lx[1:0]};
wire [2:0] bg_pix = { bg_hi_byte[bg_bit_h],
                      bg_hi_byte[bg_bit_l],
                      bg_bank3 ? bg_c[bg_bit_l] : bg_c[bg_bit_h] };

wire [5:0] bg_pen_val = {1'b0, bg_color, bg_pix};

// MAME set_transmask(0, fgmask=0x0001, bgmask=0x007e); tilemap.cpp:574-583 --
// a SET mask bit marks the pen TRANSPARENT for that layer. So LAYER1 (the
// bottom pass) is opaque on pens 0 and 7, LAYER0 (the top pass) on pens 1..7.
// Pen 7 is drawn by both, which is what puts it above the pri-8 sprites.
wire bg_l1_hit = !bg_disable && ((bg_pix == 3'd0) || (bg_pix == 3'd7));
wire bg_l0_hit = !bg_disable && (bg_pix != 3'd0);

//--------------------------------------------------------------------------
// CPU-visible VRAM (port A = CPU, port B = video)
//--------------------------------------------------------------------------
bram_tdp #(.DW(8), .AW(10)) u_colorram (
  .clk(clk_sys),
  .a_addr(cpu_ab[9:0]), .a_din(cpu_dout), .a_we(color_cs && !rw), .a_dout(color_dout),
  .b_addr(fg_idx),      .b_din(8'd0),     .b_we(1'b0),            .b_dout(fg_hi)
);

bram_tdp #(.DW(8), .AW(10)) u_videoram (
  .clk(clk_sys),
  .a_addr(cpu_ab[9:0]), .a_din(cpu_dout), .a_we(video_cs && !rw), .a_dout(video_dout),
  .b_addr(fg_idx),      .b_din(8'd0),     .b_we(1'b0),            .b_dout(fg_lo)
);

//--------------------------------------------------------------------------
// Sprite RAM: 512 entries x 4 bytes, held as 4 byte-lanes so the sprite engine
// can read a whole entry in one clock while the CPU still writes single bytes.
//--------------------------------------------------------------------------
wire [8:0] sp_slot_rd;
wire [7:0] spr_q [0:3];
wire [7:0] spr_cpu_q [0:3];

genvar gi;
generate
  for (gi = 0; gi < 4; gi = gi + 1) begin : g_spr
    bram_tdp #(.DW(8), .AW(9)) u_spr (
      .clk(clk_sys),
      .a_addr(cpu_ab[10:2]), .a_din(cpu_dout),
      .a_we(sprite_cs && !rw && (cpu_ab[1:0] == gi[1:0])), .a_dout(spr_cpu_q[gi]),
      .b_addr(sp_slot_rd),   .b_din(8'd0), .b_we(1'b0), .b_dout(spr_q[gi])
    );
  end
endgenerate

assign sprite_dout = spr_cpu_q[cpu_ab[1:0]];

//--------------------------------------------------------------------------
// GFX ROMs
//--------------------------------------------------------------------------
wire [13:0] sp_gaddr;
wire [7:0]  fg_pq [0:2];
wire [7:0]  sp_pq [0:2];

generate
  for (gi = 0; gi < 3; gi = gi + 1) begin : g_gfx1
    bram_tdp #(.DW(8), .AW(14)) u_g1 (
      .clk(clk_sys),
      // Port A: FG fetch, plus the ioctl download (CPUs are held during load)
      .a_addr(ioctl_download ? gfx1_a : fg_gaddr),
      .a_din(ioctl_dout),
      .a_we(ioctl_stb && in_gfx1 && (gfx1_plane == gi[1:0])),
      .a_dout(fg_pq[gi]),
      // Port B: sprite engine
      .b_addr(sp_gaddr), .b_din(8'd0), .b_we(1'b0), .b_dout(sp_pq[gi])
    );
  end
endgenerate

wire [7:0] gfx2_q [0:2];
generate
  for (gi = 0; gi < 3; gi = gi + 1) begin : g_gfx2
    bram_sdp #(.DW(8), .AW(13)) u_g2 (
      .clk(clk_sys),
      .wr_addr(gfx2_a), .wr_din(ioctl_dout),
      .wr_en(ioctl_stb && in_gfx2 && (gfx2_bank == gi[1:0])),
      .rd_addr(bg_gaddr), .rd_dout(gfx2_q[gi])
    );
  end
endgenerate

// user1: main CPU bank view on port A, BG tile lookup on port B
bram_tdp #(.DW(8), .AW(14)) u_user1 (
  .clk(clk_sys),
  .a_addr(ioctl_download ? usr1_off[13:0] : user1_cpu_addr),
  .a_din(ioctl_dout), .a_we(ioctl_stb && in_user1), .a_dout(user1_cpu_q),
  .b_addr(u1_addr),   .b_din(8'd0), .b_we(1'b0),    .b_dout(bg_tile)
);

//--------------------------------------------------------------------------
// Per-pixel fetch pipeline
//   dot 0 : addresses presented (fg_idx, u1_addr) -- combinational
//   dot 1 : fg_lo/fg_hi/bg_tile valid -> gfx addresses presented
//   dot 2 : (address settle)
//   dot 3 : plane bytes valid -> latch
//   dot 6 : composite latched, ce_pix asserted for dot 7
//--------------------------------------------------------------------------
always @(posedge clk_sys) begin
  if (dot == 3'd3) begin
    fg_p0 <= fg_pq[0];
    fg_p1 <= fg_pq[1];
    fg_p2 <= fg_pq[2];
    bg_a  <= gfx2_q[0];
    bg_b  <= gfx2_q[1];
    bg_c  <= gfx2_q[2];
  end
end

//--------------------------------------------------------------------------
// Sprite engine
//--------------------------------------------------------------------------
localparam [2:0] SP_CLEAR = 3'd0,
                 SP_SCAN0 = 3'd1,
                 SP_SCAN1 = 3'd2,
                 SP_FETCH = 3'd3,
                 SP_DRAW  = 3'd4,
                 SP_DONE  = 3'd5;

reg [2:0] sp_st;
reg [9:0] sp_slot;
reg [8:0] sp_clr;
reg [4:0] sp_px;
reg [2:0] sp_fetch_cnt;
reg       sp_second;      // drawing the second tile of a 16x32 sprite
reg       wr_bank;
reg [7:0] render_y;

reg [8:0] sp_code0, sp_code1;
reg [8:0] sp_code_cur;
reg [7:0] sp_sx;
reg [7:0] sp_sy0, sp_sy1;
reg [3:0] sp_ly;
reg       sp_fy, sp_multi, sp_pri, sp_color;

reg [7:0] sp_left [0:2];
reg [7:0] sp_right[0:2];

// line buffers: {bank, x}
reg [8:0] lb_waddr;
reg [5:0] lb_wdata;
reg       lb_we_hi, lb_we_lo;

wire [5:0] sp_hi_pen, sp_lo_pen;

// Read the bank that was just filled -- it is written only during the previous
// line, so during this line's active display it is stable. Indexed by raw h:
// MAME's sprite code already produced screen coordinates.
bram_tdp #(.DW(6), .AW(9)) u_lb_hi (
  .clk(clk_sys),
  .a_addr(lb_waddr), .a_din(lb_wdata), .a_we(lb_we_hi), .a_dout(),
  .b_addr({wr_bank, h[7:0]}), .b_din(6'd0), .b_we(1'b0), .b_dout(sp_hi_pen)
);

bram_tdp #(.DW(6), .AW(9)) u_lb_lo (
  .clk(clk_sys),
  .a_addr(lb_waddr), .a_din(lb_wdata), .a_we(lb_we_lo), .a_dout(),
  .b_addr({wr_bank, h[7:0]}), .b_din(6'd0), .b_we(1'b0), .b_dout(sp_lo_pen)
);

// Sprite entry currently under evaluation
wire [7:0] s0 = spr_q[0];
wire [7:0] s1 = spr_q[1];
wire [7:0] s2 = spr_q[2];
wire [7:0] s3 = spr_q[3];

assign sp_slot_rd = sp_slot[8:0];
assign sp_gaddr   = { sp_code_cur, 5'd0 } + { 9'd0, (sp_fetch_cnt == 3'd0) ? 5'd16 : 5'd0 }
                  + { 10'd0, sp_ly };

// MAME boomrang_draw_sprites, in source order
wire       e_active = (s0[0] == 1'b1);
wire       e_multi  = s0[4];
wire       e_fy     = s0[1];
wire [8:0] e_code   = { s0[7:5], s1 };          // code %= 512 in MAME
wire [7:0] e_sy_pre = e_multi ? (s2 + 8'd16) : s2;
wire [7:0] e_sy_n   = 8'd240 - e_sy_pre;
wire [7:0] e_sx_n   = 8'd240 - s3;
// code/code2 swap uses the PRE-flip fy
wire [8:0] e_code_a = (e_fy && e_multi) ? (e_code + 9'd1) : e_code;
wire [8:0] e_code_b = (e_fy && e_multi) ? e_code          : (e_code + 9'd1);
wire [7:0] e_sy     = flip ? (8'd240 - e_sy_n) : e_sy_n;
wire [7:0] e_sx     = flip ? (8'd240 - e_sx_n) : e_sx_n;
wire [7:0] e_sy2    = flip ? (e_sy - 8'd16)    : (e_sy + 8'd16);
wire       e_fy_f   = flip ? ~e_fy : e_fy;

// 9-bit so a sprite near the bottom is clipped, not wrapped (MAME clips)
wire [8:0] dy0 = {1'b0, render_y} - {1'b0, e_sy};
wire [8:0] dy1 = {1'b0, render_y} - {1'b0, e_sy2};
wire       hit0 = (dy0 < 9'd16);
wire       hit1 = e_multi && (dy1 < 9'd16);

wire [8:0] draw_x = {1'b0, sp_sx} + {5'd0, sp_px[3:0]};
wire [2:0] sp_bit = 3'd7 - sp_px[2:0];
wire [2:0] sp_pix = sp_px[3]
   ? { sp_right[2][sp_bit], sp_right[1][sp_bit], sp_right[0][sp_bit] }
   : { sp_left [2][sp_bit], sp_left [1][sp_bit], sp_left [0][sp_bit] };

always @(posedge clk_sys) begin
  lb_we_hi <= 1'b0;
  lb_we_lo <= 1'b0;

  if (reset) begin
    sp_st    <= SP_DONE;
    wr_bank  <= 1'b0;
    sp_slot  <= 10'd0;
    sp_clr   <= 9'd0;
  end else if (h == 9'd0 && dot == 3'd0) begin
    // Start of a line: flip banks and build the buffer for the NEXT line.
    wr_bank   <= ~wr_bank;
    render_y  <= v[7:0] + 8'd1;
    sp_st     <= SP_CLEAR;
    sp_clr    <= 9'd0;
    sp_slot   <= 10'd0;
    sp_second <= 1'b0;
  end else begin
    case (sp_st)
      SP_CLEAR: begin
        lb_waddr <= { ~wr_bank, sp_clr[7:0] };
        lb_wdata <= 6'd32;
        lb_we_hi <= 1'b1;
        lb_we_lo <= 1'b1;
        if (sp_clr == 9'd255) sp_st <= SP_SCAN0;
        sp_clr <= sp_clr + 9'd1;
      end

      // Address presented in SCAN0, entry valid in SCAN1 (BRAM latency 1)
      SP_SCAN0: sp_st <= SP_SCAN1;

      SP_SCAN1: begin
        if (e_active && (hit0 || hit1)) begin
          sp_multi <= e_multi;
          sp_pri   <= s0[3];
          sp_color <= s0[2];
          sp_fy    <= e_fy_f;
          sp_sx    <= e_sx;
          sp_sy0   <= e_sy;
          sp_sy1   <= e_sy2;
          sp_code0 <= e_code_a;
          sp_code1 <= e_code_b;
          if (hit0) begin
            sp_code_cur <= e_code_a;
            sp_ly       <= e_fy_f ? (4'd15 - dy0[3:0]) : dy0[3:0];
            sp_second   <= 1'b0;
          end else begin
            sp_code_cur <= e_code_b;
            sp_ly       <= e_fy_f ? (4'd15 - dy1[3:0]) : dy1[3:0];
            sp_second   <= 1'b1;
          end
          sp_fetch_cnt <= 3'd0;
          sp_st        <= SP_FETCH;
        end else begin
          if (sp_slot == 10'd511) sp_st <= SP_DONE;
          else begin
            sp_slot <= sp_slot + 10'd1;
            sp_st   <= SP_SCAN0;
          end
        end
      end

      // 0: left-half address out. 1: right-half address out, left data in.
      // 2: right data in.
      SP_FETCH: begin
        if (sp_fetch_cnt == 3'd1) begin
          sp_left[0] <= sp_pq[0];
          sp_left[1] <= sp_pq[1];
          sp_left[2] <= sp_pq[2];
        end
        if (sp_fetch_cnt == 3'd2) begin
          sp_right[0] <= sp_pq[0];
          sp_right[1] <= sp_pq[1];
          sp_right[2] <= sp_pq[2];
          sp_px       <= 5'd0;
          sp_st       <= SP_DRAW;
        end
        sp_fetch_cnt <= sp_fetch_cnt + 3'd1;
      end

      SP_DRAW: begin
        if (sp_pix != 3'd0 && !draw_x[8]) begin   // pen 0 transparent, clip at 255
          lb_waddr <= { ~wr_bank, draw_x[7:0] };
          lb_wdata <= { 2'b0, sp_color, sp_pix };
          lb_we_hi <= sp_pri;
          lb_we_lo <= ~sp_pri;
        end
        if (sp_px == 5'd15) begin
          // second tile of a 16x32 sprite?
          if (!sp_second && sp_multi && ({1'b0, render_y} - {1'b0, sp_sy1}) < 9'd16) begin
            sp_code_cur  <= sp_code1;
            sp_ly        <= sp_fy ? (4'd15 - (render_y - sp_sy1)) : (render_y - sp_sy1);
            sp_second    <= 1'b1;
            sp_fetch_cnt <= 3'd0;
            sp_st        <= SP_FETCH;
          end else if (sp_slot == 10'd511) begin
            sp_st <= SP_DONE;
          end else begin
            sp_slot <= sp_slot + 10'd1;
            sp_st   <= SP_SCAN0;
          end
        end
        sp_px <= sp_px + 5'd1;
      end

      default: ; // SP_DONE - idle until the next line
    endcase
  end
end

//--------------------------------------------------------------------------
// Composite (MAME screen_update_boomrang order)
//--------------------------------------------------------------------------
reg [5:0] pen;
always @* begin
  if (bg_disable)         pen = 6'd32;
  else if (bg_l1_hit)     pen = bg_pen_val;
  else                    pen = 6'd32;

  if (sp_hi_pen != 6'd32) pen = sp_hi_pen;
  if (bg_l0_hit)          pen = bg_pen_val;
  if (sp_lo_pen != 6'd32) pen = sp_lo_pen;
  if (fg_pen   != 6'd32)  pen = fg_pen;
end

reg [5:0] pen_r;
always @(posedge clk_sys)
  if (dot == 3'd6) pen_r <= pen;

palette u_pal(
  .clk(clk_sys),
  .prom_wr(prom_wr),
  .prom_addr(prom_addr),
  .prom_data(prom_data),
  .pen(pen_r),
  .red(red), .green(green), .blue(blue)
);

endmodule
