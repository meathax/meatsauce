module bwing_video (
  input             clk_sys,
  input             reset,
  input      [15:0] cpu_ab,
  input       [7:0] cpu_dout,
  input             cpu_rw,
  input             cpu_stb,
  input       [7:0] mapmask,
  output reg  [7:0] cpu_dout_mux,
  input             ioctl_download,
  input      [26:0] ioctl_addr,
  input       [7:0] ioctl_dout,
  input             ioctl_stb,
  input      [26:0] char_base,
  input      [26:0] sprite_base,
  output reg  [3:0] red,
  output reg  [3:0] green,
  output reg  [3:0] blue,
  output            hs,
  output            vs,
  output            hb,
  output            vb,
  output            ce_pix
);

wire [8:0] h, v;
wire [2:0] dot;
hvgen #(
  .V_TOTAL_P(9'd272), .V_SYNC_S_P(9'd260), .V_SYNC_E_P(9'd264)
) u_hv (
  .clk_sys(clk_sys), .reset(reset), .hb(hb), .vb(vb), .hs(hs), .vs(vs),
  .hcount(h), .vcount(v), .dot(dot), .ce_pix(ce_pix)
);

wire cocktail = mapmask[5];
// MAME flips tilemaps around the visible-area centre.  Both extents are 256
// here (x=0..255 and y extent 8+247+1), so the flipped source origin is 255.
wire [9:0] visible_flip_x = 10'd255 - {1'b0, h};
wire [9:0] visible_flip_y = 10'd255 - {1'b0, v};
wire [7:0] sx8 = cocktail ? visible_flip_x[7:0] : h[7:0];
wire [7:0] sy8 = cocktail ? v[7:0] : visible_flip_y[7:0];

reg [7:0] sreg [0:7];
reg [7:0] palatch;
always @(posedge clk_sys) begin
  if (reset) begin
    palatch <= 8'd0;
    for (int i = 0; i < 8; i++) sreg[i] <= 8'd0;
  end else if (cpu_stb && !cpu_rw && cpu_ab >= 16'h1b00 && cpu_ab <= 16'h1b07) begin
    sreg[cpu_ab[2:0]] <= cpu_dout;
    if (cpu_ab[2:0] == 3'd6) palatch <= cpu_dout;
  end
end

// Character/tile/sprite RAM
wire [9:0] char_idx = {sx8[7:3], sy8[7:3]};
wire [7:0] char_code, char_cpu_q;
bram_tdp #(.DW(8), .AW(10)) u_char_vram (
  .clk(clk_sys),
  .a_addr(cpu_ab[9:0]), .a_din(cpu_dout),
  .a_we(cpu_stb && !cpu_rw && cpu_ab >= 16'h1000 && cpu_ab < 16'h1400), .a_dout(char_cpu_q),
  .b_addr(char_idx), .b_din(8'd0), .b_we(1'b0), .b_dout(char_code)
);

wire [9:0] bg_scroll_x = {sreg[1][7:6], sreg[2]} + (cocktail ? 10'd1016 : 10'd8);
wire [9:0] bg_scroll_y = {sreg[1][5:4], sreg[3]};
wire [9:0] fg_scroll_x = {sreg[1][3:2], sreg[4]} + (cocktail ? 10'd1016 : 10'd8);
wire [9:0] fg_scroll_y = {sreg[1][1:0], sreg[5]};
wire [9:0] layer_x = cocktail ? visible_flip_x : {1'b0, h};
wire [9:0] layer_y = cocktail ? {1'b0, v} : visible_flip_y;
wire [9:0] bg_x = layer_x + bg_scroll_x;
wire [9:0] bg_y = layer_y + bg_scroll_y;
wire [9:0] fg_x = layer_x + fg_scroll_x;
wire [9:0] fg_y = layer_y + fg_scroll_y;
wire [11:0] bg_tidx = {bg_x[9:8], bg_y[9:8], bg_x[7:4], bg_y[7:4]};
wire [11:0] fg_tidx = {fg_x[9:8], fg_y[9:8], fg_x[7:4], fg_y[7:4]};
wire [7:0] fg_tile, bg_tile, fg_cpu_q, bg_cpu_q;

bram_tdp #(.DW(8), .AW(12)) u_fg_map (
  .clk(clk_sys), .a_addr(cpu_ab[11:0]), .a_din(cpu_dout),
  .a_we(cpu_stb && !cpu_rw && mapmask[7:6] == 2'd0 && cpu_ab >= 16'h2000 && cpu_ab < 16'h3000),
  .a_dout(fg_cpu_q), .b_addr(fg_tidx), .b_din(8'd0), .b_we(1'b0), .b_dout(fg_tile)
);
bram_tdp #(.DW(8), .AW(12)) u_bg_map (
  .clk(clk_sys), .a_addr(cpu_ab[11:0]), .a_din(cpu_dout),
  .a_we(cpu_stb && !cpu_rw && mapmask[7:6] == 2'd0 && cpu_ab >= 16'h3000 && cpu_ab < 16'h4000),
  .a_dout(bg_cpu_q), .b_addr(bg_tidx), .b_din(8'd0), .b_we(1'b0), .b_dout(bg_tile)
);

// Dynamic tile graphics: raw $6000 RAM is three 8K plane blocks. Within each
// block the foreground occupies the first 4K and background the second 4K.
wire [14:0] gfx_cpu_off = {mapmask[7:6] - 2'd1, 13'd0} + {2'b00, cpu_ab[12:0]};
wire [1:0] gfx_cpu_plane = gfx_cpu_off[14:13];
wire [12:0] fg_gaddr = {1'b0, fg_tile[6:0], 5'd0}
                         + {8'd0, fg_x[3] ? 5'd16 : 5'd0}
                         + {9'd0, fg_y[3:0]};
wire [12:0] bg_gaddr = 13'h1000 + {1'b0, bg_tile[6:0], 5'd0}
                         + {8'd0, bg_x[3] ? 5'd16 : 5'd0}
                         + {9'd0, bg_y[3:0]};
wire [7:0] gfx_fg_q [0:2];
wire [7:0] gfx_bg_q [0:2];
wire [7:0] gfx_cpu_q [0:2];
genvar gi;
generate
  for (gi = 0; gi < 3; gi = gi + 1) begin : g_gfxram
    // The original board exposes the writable graphics RAM to both tile
    // generators while the CPU can update it concurrently.  Replicate each
    // plane so inferred dual-port M10Ks provide one CPU port plus independent
    // foreground/background read ports.  Both copies receive identical CPU
    // writes.
    bram_tdp #(.DW(8), .AW(13)) u_gfx (
      .clk(clk_sys),
      .a_addr(gfx_cpu_off[12:0]),
      .a_din(cpu_dout),
      .a_we(cpu_stb && !cpu_rw && cpu_ab >= 16'h2000 && cpu_ab < 16'h4000 &&
            mapmask[7:6] != 0 && gfx_cpu_plane == gi[1:0]),
      .a_dout(gfx_cpu_q[gi]),
      .b_addr(fg_gaddr), .b_din(8'd0), .b_we(1'b0), .b_dout(gfx_fg_q[gi])
    );
    bram_tdp #(.DW(8), .AW(13)) u_gfx_bg (
      .clk(clk_sys),
      .a_addr(gfx_cpu_off[12:0]), .a_din(cpu_dout),
      .a_we(cpu_stb && !cpu_rw && cpu_ab >= 16'h2000 && cpu_ab < 16'h4000 &&
            mapmask[7:6] != 0 && gfx_cpu_plane == gi[1:0]),
      .a_dout(),
      .b_addr(bg_gaddr), .b_din(8'd0), .b_we(1'b0), .b_dout(gfx_bg_q[gi])
    );
  end
endgenerate

// MAME numbers a byte's graphics bits MSB-first: layout offset 7 selects the
// physical LSB.  Its x offsets 7..0 therefore put RAM bits 0..7 left-to-right.
wire [2:0] fg_bit = fg_x[2:0];
wire [2:0] bg_bit = bg_x[2:0];
reg [7:0] fg_plane [0:2];
reg [7:0] bg_plane [0:2];
// The layout's first plane is the high RAM third and becomes color bit 2;
// the low/mid/high RAM thirds therefore become color bits 0/1/2.
wire [2:0] fg_pix = {fg_plane[2][fg_bit], fg_plane[1][fg_bit], fg_plane[0][fg_bit]};
wire [2:0] bg_pix = {bg_plane[2][bg_bit], bg_plane[1][bg_bit], bg_plane[0][bg_bit]};
wire [5:0] fg_pen = {2'b01, fg_tile[7], fg_pix};
wire [5:0] bg_pen = {2'b11, bg_tile[7], bg_pix};

// Character ROM: two 2K planes.
wire [26:0] char_off = ioctl_addr - char_base;
wire in_char = ioctl_addr >= char_base && ioctl_addr < char_base + 27'h01000;
wire [10:0] char_gaddr = {char_code, sy8[2:0]};
wire [7:0] char_plane_q [0:1];
generate
  for (gi = 0; gi < 2; gi = gi + 1) begin : g_charrom
    bram_sdp #(.DW(8), .AW(11)) u_rom (
      .clk(clk_sys), .wr_addr(char_off[10:0]), .wr_din(ioctl_dout),
      .wr_en(ioctl_stb && in_char && char_off[11] == gi[0]),
      .rd_addr(char_gaddr), .rd_dout(char_plane_q[gi])
    );
  end
endgenerate
reg [7:0] char_p0, char_p1;
wire [2:0] char_bit = sx8[2:0];
wire [1:0] char_pix = {char_p0[char_bit], char_p1[char_bit]};
wire [5:0] char_pen = {4'b0000, char_pix};

// Sprite RAM and static three-plane ROM.
wire [6:0] spr_slot_rd;
wire [7:0] spr_lane_q [0:3];
wire [7:0] spr_cpu_q [0:3];
generate
  for (gi = 0; gi < 4; gi = gi + 1) begin : g_sprram
    bram_tdp #(.DW(8), .AW(7)) u_ram (
      .clk(clk_sys), .a_addr(cpu_ab[8:2]), .a_din(cpu_dout),
      .a_we(cpu_stb && !cpu_rw && cpu_ab >= 16'h1800 && cpu_ab < 16'h1a00 && cpu_ab[1:0] == gi[1:0]),
      .a_dout(spr_cpu_q[gi]), .b_addr(spr_slot_rd), .b_din(8'd0), .b_we(1'b0), .b_dout(spr_lane_q[gi])
    );
  end
endgenerate

wire [26:0] spr_off = ioctl_addr - sprite_base;
wire in_spr_rom = ioctl_addr >= sprite_base && ioctl_addr < sprite_base + 27'h0c000;
wire [13:0] spr_gaddr;
wire [7:0] spr_rom_q [0:2];
generate
  for (gi = 0; gi < 3; gi = gi + 1) begin : g_sprrom
    bram_sdp #(.DW(8), .AW(14)) u_rom (
      .clk(clk_sys), .wr_addr(spr_off[13:0]), .wr_din(ioctl_dout),
      .wr_en(ioctl_stb && in_spr_rom && spr_off[15:14] == gi[1:0]),
      .rd_addr(spr_gaddr), .rd_dout(spr_rom_q[gi])
    );
  end
endgenerate

// 64 x 9-bit palette RAM: low R/G bits are written at $1a00; blue is latched
// through scroll register 6 and appears in the read-only extension window.
reg [7:0] palette_lo [0:63];
reg [2:0] palette_hi [0:63];
always @(posedge clk_sys)
  if (cpu_stb && !cpu_rw && cpu_ab >= 16'h1a00 && cpu_ab < 16'h1a40) begin
    palette_lo[cpu_ab[5:0]] <= cpu_dout & 8'h77;
    palette_hi[cpu_ab[5:0]] <= palatch[2:0];
  end

// Sprite scanline renderer. Lower RAM offsets win because MAME scans 1fc->0.
localparam [2:0] SP_CLEAR=0, SP_SCAN0=1, SP_SCAN1=2, SP_FETCH=3, SP_DRAW=4, SP_DONE=5;
reg [2:0] sp_state;
reg [7:0] sp_clear;
reg [7:0] sp_slot;
reg [4:0] sp_px;
reg [2:0] sp_fetch_cnt;
reg       sp_bank;
reg [7:0] render_y;
reg [8:0] sp_code;
reg [3:0] sp_line;
reg signed [9:0] sp_x;
reg sp_fx, sp_fy, sp_color;
reg [7:0] sp_left [0:2];
reg [7:0] sp_right [0:2];
reg [8:0] lb_addr;
reg [7:0] lb_data;
reg lb_we;
wire [7:0] lb_q;
bram_tdp #(.DW(8), .AW(9)) u_linebuf (
  .clk(clk_sys), .a_addr(lb_addr), .a_din(lb_data), .a_we(lb_we), .a_dout(),
  .b_addr({sp_bank, h[7:0]}), .b_din(8'd0), .b_we(1'b0), .b_dout(lb_q)
);

assign spr_slot_rd = sp_slot[6:0];
wire [7:0] sa = spr_lane_q[0], sc = spr_lane_q[1];
wire signed [9:0] raw_x = sa[6] ? $signed({2'b11, spr_lane_q[3]}) : $signed({2'b00, spr_lane_q[3]});
wire signed [9:0] raw_y = sa[7] ? $signed({2'b11, spr_lane_q[2]}) : $signed({2'b00, spr_lane_q[2]});
wire signed [9:0] ent_x = cocktail ? (10'sd240 - raw_x) : raw_x;
wire signed [9:0] ent_y = cocktail ? (10'sd240 - raw_y) : raw_y;
wire ent_fx = cocktail ? ~sa[2] : sa[2];
wire ent_fy = cocktail ? sa[1] : ~sa[1];
wire [5:0] ent_height = sa[4] ? 6'd32 : 6'd16;
wire signed [10:0] ent_dy = $signed({1'b0, render_y}) - ent_y;
wire ent_hit = sa[0] && ent_dy >= 0 && ent_dy < $signed({5'd0, ent_height});
wire [3:0] ent_src_y = sa[4] ? ent_dy[4:1] : ent_dy[3:0];
assign spr_gaddr = {sp_code, 5'd0}
                 + {9'd0, (sp_fetch_cnt == 0) ? 5'd0 : 5'd16}
                 + {10'd0, sp_line};
wire [3:0] sp_src_x = sp_fx ? (4'd15 - sp_px[3:0]) : sp_px[3:0];
wire [2:0] sp_src_bit = sp_src_x[2:0];
wire [2:0] sp_pix = sp_src_x[3]
  ? {sp_right[2][sp_src_bit], sp_right[1][sp_src_bit], sp_right[0][sp_src_bit]}
  : {sp_left[2][sp_src_bit],  sp_left[1][sp_src_bit],  sp_left[0][sp_src_bit]};
wire signed [10:0] sp_draw_x = sp_x + $signed({6'd0, sp_px});

always @(posedge clk_sys) begin
  lb_we <= 1'b0;
  if (reset) begin
    sp_state <= SP_DONE; sp_bank <= 1'b0; sp_slot <= 8'd127;
  end else if (h == 0 && dot == 0) begin
    sp_bank <= ~sp_bank; render_y <= v[7:0] + 8'd1;
    sp_state <= SP_CLEAR; sp_clear <= 0; sp_slot <= 8'd127;
  end else case (sp_state)
    SP_CLEAR: begin
      lb_addr <= {~sp_bank, sp_clear}; lb_data <= 8'd0; lb_we <= 1'b1;
      if (sp_clear == 8'hff) sp_state <= SP_SCAN0;
      sp_clear <= sp_clear + 1'd1;
    end
    SP_SCAN0: sp_state <= SP_SCAN1;
    SP_SCAN1: begin
      if (ent_hit) begin
        sp_code <= {sa[5], sc}; sp_x <= ent_x; sp_fx <= ent_fx; sp_fy <= ent_fy;
        sp_color <= sa[3];
        sp_line <= ent_fy ? (4'd15 - ent_src_y) : ent_src_y;
        sp_fetch_cnt <= 0; sp_state <= SP_FETCH;
      end else if (sp_slot == 0) sp_state <= SP_DONE;
      else begin sp_slot <= sp_slot - 1'd1; sp_state <= SP_SCAN0; end
    end
    SP_FETCH: begin
      if (sp_fetch_cnt == 1) begin
        sp_left[0] <= spr_rom_q[0]; sp_left[1] <= spr_rom_q[1]; sp_left[2] <= spr_rom_q[2];
      end
      if (sp_fetch_cnt == 2) begin
        sp_right[0] <= spr_rom_q[0]; sp_right[1] <= spr_rom_q[1]; sp_right[2] <= spr_rom_q[2];
        sp_px <= 0; sp_state <= SP_DRAW;
      end
      sp_fetch_cnt <= sp_fetch_cnt + 1'd1;
    end
    SP_DRAW: begin
      if (sp_pix != 0 && sp_draw_x >= 0 && sp_draw_x < 256) begin
        lb_addr <= {~sp_bank, sp_draw_x[7:0]};
        lb_data <= {1'b1, sp_color, 2'b10, sp_color, sp_pix}; lb_we <= 1'b1;
      end
      if (sp_px == 15) begin
        if (sp_slot == 0) sp_state <= SP_DONE;
        else begin sp_slot <= sp_slot - 1'd1; sp_state <= SP_SCAN0; end
      end
      sp_px <= sp_px + 1'd1;
    end
    default: ;
  endcase
end

always @(posedge clk_sys) if (dot == 3) begin
  for (int j = 0; j < 3; j++) begin
    fg_plane[j] <= gfx_fg_q[j];
    bg_plane[j] <= gfx_bg_q[j];
  end
  char_p0 <= char_plane_q[0]; char_p1 <= char_plane_q[1];
end

wire sprite_valid = lb_q[7];
wire sprite_color = lb_q[6];
wire [5:0] sprite_pen = lb_q[5:0];
reg [5:0] pen;
always @* begin
  pen = mapmask[0] ? 6'h30 : bg_pen;
  if (sprite_valid && !sprite_color) pen = sprite_pen;
  if (!mapmask[1] && fg_pix != 0) pen = fg_pen;
  if (sprite_valid && sprite_color) pen = sprite_pen;
  if (char_pix != 0) pen = char_pen;
end

reg [5:0] pen_r;
always @(posedge clk_sys) if (dot == 6) pen_r <= pen;
wire [7:0] pal_lo = palette_lo[pen_r];
wire [2:0] pal_hi = palette_hi[pen_r];
wire [2:0] pr = ~pal_lo[2:0];
wire [2:0] pg = ~pal_lo[6:4];
wire [2:0] pb = ~pal_hi;
always @* begin
  // 3-bit resistor ladder rounded to 4-bit RGB: 0,2,4,6,9,B,D,F.
  red   = {pr, pr[2]};
  green = {pg, pg[2]};
  blue  = {pb, pb[2]};
end

always @* begin
  cpu_dout_mux = 8'hff;
  if (cpu_ab >= 16'h1000 && cpu_ab < 16'h1400) cpu_dout_mux = char_cpu_q;
  else if (cpu_ab >= 16'h1800 && cpu_ab < 16'h1a00) cpu_dout_mux = spr_cpu_q[cpu_ab[1:0]];
  else if (cpu_ab >= 16'h1a00 && cpu_ab < 16'h1a40) cpu_dout_mux = palette_lo[cpu_ab[5:0]];
  else if (cpu_ab >= 16'h1a40 && cpu_ab < 16'h1a80) cpu_dout_mux = {5'd0, palette_hi[cpu_ab[5:0]]};
  else if (cpu_ab >= 16'h2000 && cpu_ab < 16'h3000 && mapmask[7:6] == 0) cpu_dout_mux = fg_cpu_q;
  else if (cpu_ab >= 16'h3000 && cpu_ab < 16'h4000 && mapmask[7:6] == 0) cpu_dout_mux = bg_cpu_q;
  else if (cpu_ab >= 16'h2000 && cpu_ab < 16'h4000 && mapmask[7:6] != 0) cpu_dout_mux = gfx_cpu_q[gfx_cpu_plane];
end

endmodule
