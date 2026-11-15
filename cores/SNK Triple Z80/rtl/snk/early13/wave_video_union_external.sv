// Wave family (marvins/vangrd2/madcrash) video block, union-ready.
//  - clock: master clk plus pce (pixel clock enable, 53.6 MHz/8 = 6.7 MHz); timing arrives as hblank/vblank/hsync/vsync
//    (414x262 from snk_early_timing; the 288x216 active window is whatever the timing marks unblanked, 288 px per line).
//  - all line rendering (BG/FG/TX tile runs and the 25-sprite pass) runs one line ahead into double-buffered line
//    buffers; the scan path is buffer read -> compose -> PROM -> RGB, one pixel per pce, outputs delayed by one pixel.
//  - ROM ports: tile_* (tx/fg/bg selected by tile_sel, 32-bit word index within the 8 KB region) and sp_* (24 KB sprite
//    region word index {plane,code,row[3:1]}); both toggle req/ack, data little-endian 32-bit words.
//  - drawing state (scroll, flip, palette banks, split) is latched at each line start (draw-time capture).
module wave_video_union_external(
  input clk, input reset, input pce,
  input hblank, vblank, hsync, vsync,
  input [8:0] bg_x, fg_x, sprite_x, input [7:0] bg_y, fg_y, sprite_y, sprite_split,
  input display_flip,
  input flip, input [6:0] bg_palette_offset, fg_palette_offset,
  output [10:0] bg_ram_addr, input [7:0] bg_ram_q,
  output [10:0] fg_ram_addr, input [7:0] fg_ram_q,
  output [10:0] tx_ram_addr, input [7:0] tx_ram_q,
  output [7:0] spr_ram_addr, input [7:0] spr_ram_q,
  output tile_req, input tile_ack, output [1:0] tile_sel, output [10:0] tile_addr, input [31:0] tile_data,
  output sp_req, input sp_ack, output [12:0] sp_addr, input [31:0] sp_data,
  output [9:0] palette_addr,input [11:0] palette_data,
  output reg [7:0] red, green, blue,
  output reg out_hblank, out_vblank, out_hsync, out_vsync,
  output reg [31:0] line_overruns, output busy_any);
  // ---- line scheduling ----
  reg hb_prev, hs_prev, vs_prev, vb_prev, vb_at_e; reg wbank; reg [7:0] render_row; reg start_d;
  reg [8:0] l_bgx, l_fgx, l_spx; reg [7:0] l_bgy, l_fgy, l_spy, l_split; reg [6:0] l_bgp, l_fgp; reg l_flip;
  wire e_line = pce && hb_prev && !hblank;
  // Independent presentation transform; cabinet state remains l_flip.
  reg display_flip_latched;
  wire [7:0] draw_row = display_flip_latched ? (8'd215 - render_row) : render_row;
  always @(posedge clk) begin
    if (reset) display_flip_latched <= 1'b0;
    else if (e_line && vblank) display_flip_latched <= display_flip;
  end
  wire bg_busy, fg_busy, tx_busy, sp_busy;
  assign busy_any = bg_busy | fg_busy | tx_busy | sp_busy;
  always @(posedge clk) begin
    start_d <= 0;
    if (reset) begin hb_prev <= 1; hs_prev <= 0; vs_prev <= 0; vb_prev <= 1; vb_at_e <= 1; wbank <= 0; render_row <= 0; line_overruns <= 0; end
    else if (pce) begin
      hb_prev <= hblank; hs_prev <= hsync; vs_prev <= vsync; vb_prev <= vblank;
      if (e_line) begin
        l_bgx <= bg_x; l_fgx <= fg_x; l_spx <= sprite_x; l_bgy <= bg_y; l_fgy <= fg_y; l_spy <= sprite_y; l_split <= sprite_split;
        l_bgp <= bg_palette_offset; l_fgp <= fg_palette_offset; l_flip <= flip;
        wbank <= ~wbank; vb_at_e <= vblank;
        render_row <= vblank ? 8'd0 : (vb_at_e ? 8'd1 : render_row + 8'd1);
        start_d <= 1;
        if (busy_any) line_overruns <= line_overruns + 1'b1;
      end
    end
  end
  // ---- renderers ----
  wire [2:0] c_req, c_ack; wire [31:0] c_data;
  wire [10:0] a_tx, a_fg, a_bg;
  wire [7:0] bgq, fgq, txq; wire [8:0] xa;
  wave_tile_line #(0,0) u_bg(.clk(clk), .reset(reset), .start(start_d), .row(draw_row), .sx(l_bgx), .sy(l_bgy), .flip(l_flip), .busy(bg_busy),
    .ram_addr(bg_ram_addr), .ram_q(bg_ram_q), .rom_req(c_req[2]), .rom_ack(c_ack[2]), .rom_addr(a_bg), .rom_data(c_data),
    .wbank(wbank), .rd_x(xa), .rd_q(bgq));
  wave_tile_line #(0,1) u_fg(.clk(clk), .reset(reset), .start(start_d), .row(draw_row), .sx(l_fgx), .sy(l_fgy), .flip(l_flip), .busy(fg_busy),
    .ram_addr(fg_ram_addr), .ram_q(fg_ram_q), .rom_req(c_req[1]), .rom_ack(c_ack[1]), .rom_addr(a_fg), .rom_data(c_data),
    .wbank(wbank), .rd_x(xa), .rd_q(fgq));
  wave_tile_line #(1,0) u_tx(.clk(clk), .reset(reset), .start(start_d), .row(draw_row), .sx(9'd0), .sy(8'd0), .flip(l_flip), .busy(tx_busy),
    .ram_addr(tx_ram_addr), .ram_q(tx_ram_q), .rom_req(c_req[0]), .rom_ack(c_ack[0]), .rom_addr(a_tx), .rom_data(c_data),
    .wbank(wbank), .rd_x(xa), .rd_q(txq));
  wave_rom_arb3 arb(.clk(clk), .reset(reset), .c_req(c_req), .c_ack(c_ack), .a0(a_tx), .a1(a_fg), .a2(a_bg), .c_data(c_data),
    .p_req(tile_req), .p_ack(tile_ack), .p_sel(tile_sel), .p_addr(tile_addr), .p_data(tile_data));
  wire [7:0] lo_c, hi_c; wire lo_s, hi_s;
  wave_sprite_line_db u_sp(.clk(clk), .reset(reset), .start(start_d), .oy(draw_row), .busy(sp_busy),
    .sp_sx(l_spx), .sp_sy(l_spy), .split(l_split), .flip(l_flip), .sr_addr(spr_ram_addr), .sr_q(spr_ram_q),
    .rom_req(sp_req), .rom_ack(sp_ack), .rom_addr(sp_addr), .rom_data(sp_data),
    .wbank(wbank), .rd_x(xa), .lo_c(lo_c), .hi_c(hi_c), .lo_s(lo_s), .hi_s(hi_s));
  // ---- scan path ----
  // Parallel address capture preserves the original scan counter/register.
  // A direct registered RAM address lets Quartus retain native block memories.
  reg [8:0] lowcnt, xa_r, scan_x_r; assign xa = scan_x_r;
  wire [8:0] native_x_next = hblank ? 9'd0 : ((lowcnt > 9'd287) ? 9'd287 : lowcnt);
  wire scan_flip_next = reset ? 1'b0 : ((e_line && vblank) ? display_flip : display_flip_latched);
  always @(posedge clk) begin
    if (pce) begin
      if (hblank) begin lowcnt <= 0; xa_r <= 0; end
      else begin xa_r <= (lowcnt > 9'd287) ? 9'd287 : lowcnt; lowcnt <= lowcnt + 9'd1; end
      scan_x_r <= scan_flip_next ? (9'd287 - native_x_next) : native_x_next;
    end else if (reset) scan_x_r <= xa_r;
  end
  wire [8:0] bg_idx = 9'h100 + {2'b0, l_bgp} + {5'b0, bgq[3:0]};
  wire [8:0] fg_idx = 9'h080 + {2'b0, l_fgp} + {5'b0, fgq[3:0]};
  wire [8:0] tx_idx = 9'h180 + {2'b0, txq[6:4], 4'b0} + {5'b0, txq[3:0]};
  wire [9:0] vidx;
  wave_compose cmp(.bg_idx(bg_idx), .fg_idx(fg_idx), .tx_idx(tx_idx), .fg_opq(fgq[7]), .tx_opq(txq[7]),
    .lo_c(lo_c), .hi_c(hi_c), .lo_s(lo_s), .hi_s(hi_s), .idx(vidx));
  // Shared store supplies the same one-master-clock PROM response.
  assign palette_addr=vidx;
  wire [3:0] p0=palette_data[3:0],p1=palette_data[7:4],p2=palette_data[11:8];
  wire [7:0] pr, pg, pb;
  wave_palette_tnk3 pal(.p0(p0), .p1(p1), .p2(p2), .r(pr), .g(pg), .b(pb));
  always @(posedge clk) if (pce) begin
    red <= hb_prev ? 8'd0 : pr; green <= hb_prev ? 8'd0 : pg; blue <= hb_prev ? 8'd0 : pb;
    out_hblank <= hb_prev; out_vblank <= vb_prev; out_hsync <= hs_prev; out_vsync <= vs_prev;
  end
endmodule
