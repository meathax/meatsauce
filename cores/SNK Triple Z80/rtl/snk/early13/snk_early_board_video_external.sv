// SPDX-License-Identifier: GPL-3.0-or-later
// Private source-review proposal. No CPUs, controller, audio, program/graphics ROM,
// full state RAM, or raster provider. The caller owns all shared providers.
// Local profiles: 0 Marvins, 1 Vanguard II, 2 Mad Crasher, 3 JCross,
// 4 Super Gladiator, 5 HAL21. Hold reset while changing profile/provider state.
module snk_early_board_video_external(
 input wire clk, reset, video_reset,
 input wire [7:0] profile,
 // Accepted root bus register outputs, unchanged physical bit widths.
 input wire display_flip,
 input wire flip, bg_tile_bank,
 input wire [3:0] bg_palette_bank,
 input wire [8:0] bg_x, bg_y, sprite_x, sprite_y, fg_x,
 input wire [7:0] fg_y, sprite_split,
 input wire [6:0] bg_palette_offset, fg_palette_offset,
 input wire [2:0] layer_ena_dbg,
 // Wave producer raster/enable remain external and physically unqualified.
 input wire wave_pce, wave_hblank, wave_vblank, wave_hsync, wave_vsync,
 // One-clock shared state responses, selected byte lanes and little-endian words.
 input wire [31:0] memory_video_data,
 input wire [127:0] memory_video_words,
 output wire [3:0] memory_video_valid,
 output wire [13:0] memory_video_addr0, memory_video_addr1,
 output wire [13:0] memory_video_addr2, memory_video_addr3,
 // Public shared graphics ports: Wave toggle handshakes, HSJ synchronous bytes.
 output wire graphics_tile_req, output wire [1:0] graphics_tile_sel,
 output wire [10:0] graphics_tile_addr,
 input wire graphics_tile_ack, input wire [31:0] graphics_tile_data,
 output wire graphics_sp_req, output wire [12:0] graphics_sp_addr,
 input wire graphics_sp_ack, input wire [31:0] graphics_sp_data,
 output wire [14:0] graphics_tx_byte_addr, graphics_bg_socket_addr,
 output wire [14:0] graphics_sp_socket_addr,
 input wire [7:0] graphics_tx_byte_data, graphics_bg_byte_data,
 input wire [23:0] graphics_sp_plane_data,
 output wire [9:0] graphics_prom_addr,
 input wire [11:0] graphics_prom_data,
 // Socket bit14 remains explicit; caller must resolve capacity/padding policy.
 output wire graphics_socket_high,
 output wire supported, family_wave, family_hsj,
 output wire ce_wave_response, ce_hsj_response, ce_pixel_response,
 output wire [7:0] red, green, blue,
 output wire [11:0] hsj_rgb_nibbles,
 output wire [23:0] wave_rgb_bytes,
 output wire hblank, vblank, hsync, vsync,
 output wire [8:0] hsj_scr_x, hsj_scr_y,
 output wire hsj_pix_clk, hsj_vbl, hsj_sync, hsj_vs, hsj_hs, hsj_disp,
 output wire [31:0] wave_line_overruns, output wire wave_busy_any
);
 assign family_wave = profile <= 8'd2;
 assign family_hsj = profile >= 8'd3 && profile <= 8'd10; // 6..10: TNK3-class on the hal21 renderer
 assign supported = family_wave || family_hsj;
 wire wave_reset = reset || video_reset || !family_wave;
 wire hsj_reset_n = !reset && family_hsj;
 wire hsj_video_reset_n = !reset && !video_reset && family_hsj;
 wire [3:0] hm_valid;
 wire [13:0] hm_addr0,hm_addr1,hm_addr2,hm_addr3;
 wire [14:0] ht_addr,hb_addr,hs_addr;
 wire [9:0] hp_addr,wp_addr;
 wire [3:0] hr,hg,hb;
 wire hhblank,hvblank,hhsync,hvsync,hce;
 snk_hsj_renderer_shared hsj(
  .display_flip(display_flip),
  .RESETn(hsj_reset_n),.VIDEO_RSTn(hsj_video_reset_n),.i_clk(clk),.profile(profile),
  .flip(flip),.bg_tile_bank(bg_tile_bank),.bg_palette_bank(bg_palette_bank),
  .bg_x(bg_x),.bg_y(bg_y),.sprite_x(sprite_x),.sprite_y(sprite_y),
  .layer_ena_dbg(layer_ena_dbg),.tnk_bg_bank(sprite_split[1:0]),.tnk_tx_bank(sprite_split[2]),
  .memory_video_data(memory_video_data),.memory_video_words(memory_video_words),
  .txd(graphics_tx_byte_data),.bgd(graphics_bg_byte_data),
  .spd(graphics_sp_plane_data),.prd(graphics_prom_data),
  .memory_video_valid(hm_valid),.memory_video_addr0(hm_addr0),
  .memory_video_addr1(hm_addr1),.memory_video_addr2(hm_addr2),.memory_video_addr3(hm_addr3),
  .tx_byte_addr(ht_addr),.bg_socket_addr(hb_addr),.sp_socket_addr(hs_addr),.prom_addr(hp_addr),
  .R(hr),.G(hg),.B(hb),.HBLANK(hhblank),.VBLANK(hvblank),.HSYNC(hhsync),.VSYNC(hvsync),
  .SCR_X(hsj_scr_x),.SCR_Y(hsj_scr_y),.PIX_CLK(hsj_pix_clk),.CE_PIXEL(hce),
  .VBL(hsj_vbl),.SYNC(hsj_sync),.VS(hsj_vs),.HS(hsj_hs),.DISP(hsj_disp));
 wire [10:0] wb_addr,wf_addr,wt_addr;
 wire [7:0] ws_addr;
 wire wt_req,ws_req;
 wire [1:0] wt_sel;
 wire [10:0] wt_word_addr;
 wire [12:0] ws_word_addr;
 wire [7:0] wr,wg,wb;
 wire whblank,wvblank,whsync,wvsync;
 wave_video_union_external wave(
  .display_flip(display_flip),
  .clk(clk),.reset(wave_reset),.pce(wave_pce),
  .hblank(wave_hblank),.vblank(wave_vblank),.hsync(wave_hsync),.vsync(wave_vsync),
  .bg_x(bg_x),.fg_x(fg_x),.sprite_x(sprite_x),
  .bg_y(bg_y[7:0]),.fg_y(fg_y),.sprite_y(sprite_y[7:0]),.sprite_split(sprite_split),
  .flip(flip),.bg_palette_offset(bg_palette_offset),.fg_palette_offset(fg_palette_offset),
  .bg_ram_addr(wb_addr),.bg_ram_q(memory_video_data[7:0]),
  .fg_ram_addr(wf_addr),.fg_ram_q(memory_video_data[15:8]),
  .tx_ram_addr(wt_addr),.tx_ram_q(memory_video_data[23:16]),
  .spr_ram_addr(ws_addr),.spr_ram_q(memory_video_data[31:24]),
  .tile_req(wt_req),.tile_ack(graphics_tile_ack),.tile_sel(wt_sel),
  .tile_addr(wt_word_addr),.tile_data(graphics_tile_data),
  .sp_req(ws_req),.sp_ack(graphics_sp_ack),.sp_addr(ws_word_addr),.sp_data(graphics_sp_data),
  .palette_addr(wp_addr),.palette_data(graphics_prom_data),
  .red(wr),.green(wg),.blue(wb),.out_hblank(whblank),.out_vblank(wvblank),
  .out_hsync(whsync),.out_vsync(wvsync),.line_overruns(wave_line_overruns),.busy_any(wave_busy_any));
 // The Wave RGB/blank registers update on the consumed pce edge. This response
 // tag publishes with that NBA response, rather than with the next DDS strobe.
 reg wave_response_valid = 1'b0;
 always @(posedge clk) begin
  if (wave_reset) wave_response_valid <= 1'b0;
  else wave_response_valid <= wave_pce;
 end
 assign ce_wave_response = family_wave && wave_response_valid;
 assign ce_hsj_response = family_hsj && hce;
 assign ce_pixel_response = ce_wave_response || ce_hsj_response;
 assign memory_video_valid = family_wave ? 4'b1111 : family_hsj ? hm_valid : 4'b0000;
 assign memory_video_addr0 = family_wave ? 14'h2000 + {3'b000,wb_addr} : family_hsj ? hm_addr0 : 14'b0;
 assign memory_video_addr1 = family_wave ? 14'h1000 + {3'b000,wf_addr} : family_hsj ? hm_addr1 : 14'b0;
 assign memory_video_addr2 = family_wave ? 14'h3000 + {3'b000,wt_addr} : family_hsj ? hm_addr2 : 14'b0;
 assign memory_video_addr3 = family_wave ? {6'b0,ws_addr} : family_hsj ? hm_addr3 : 14'b0;
 assign graphics_tile_req = family_wave ? wt_req : 1'b0;
 assign graphics_tile_sel = family_wave ? wt_sel : 2'b0;
 assign graphics_tile_addr = family_wave ? wt_word_addr : 11'b0;
 assign graphics_sp_req = family_wave ? ws_req : 1'b0;
 assign graphics_sp_addr = family_wave ? ws_word_addr : 13'b0;
 assign graphics_tx_byte_addr = family_hsj ? ht_addr : 15'b0;
 assign graphics_bg_socket_addr = family_hsj ? hb_addr : 15'b0;
 assign graphics_sp_socket_addr = family_hsj ? hs_addr : 15'b0;
 assign graphics_socket_high = family_hsj && profile <= 8'd5 && (hb_addr[14] || hs_addr[14]);
 assign graphics_prom_addr = family_wave ? wp_addr : family_hsj ? hp_addr : 10'b0;
 // Exact nibble-to-byte weights used by all accepted HSJ/MAME RGB proofs.
 // Raw nibbles are also exported so the caller retains explicit DAC ownership.
 function [7:0] hsj_dac;
  input [3:0] n;
  begin hsj_dac = (n[0] ? 8'd14 : 8'd0) + (n[1] ? 8'd31 : 8'd0)
                    + (n[2] ? 8'd67 : 8'd0) + (n[3] ? 8'd143 : 8'd0); end
 endfunction
 assign hsj_rgb_nibbles = {hr,hg,hb};
 assign wave_rgb_bytes = {wr,wg,wb};
 assign red = family_wave ? wr : family_hsj ? hsj_dac(hr) : 8'b0;
 assign green = family_wave ? wg : family_hsj ? hsj_dac(hg) : 8'b0;
 assign blue = family_wave ? wb : family_hsj ? hsj_dac(hb) : 8'b0;
 assign hblank = family_wave ? whblank : family_hsj ? hhblank : 1'b1;
 assign vblank = family_wave ? wvblank : family_hsj ? hvblank : 1'b1;
 assign hsync = family_wave ? whsync : family_hsj ? hhsync : 1'b0;
 assign vsync = family_wave ? wvsync : family_hsj ? hvsync : 1'b0;
endmodule
