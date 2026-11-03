// SPDX-License-Identifier: GPL-3.0-or-later
// Board plus physical ROM loader/memory; MiSTer presentation attaches outside.
// Global init is shared by loader/controller. Logical game reset never resets
// their accepted ownership or the running raster.
module thunderjaws_board (
 input wire clk_sys,clk_sdram,init_reset,game_reset,
 input wire flip_request,
 input wire pause_request,
 output wire paused,
 input wire score_read,score_write,
 input wire [23:0] score_address,
 input wire [7:0] score_write_data,
 output wire [7:0] score_read_data,
 output wire score_data_ready,score_signature_ready,score_busy,score_error,
 input wire ioctl_download,ioctl_wr,
 input wire [26:0] ioctl_addr,
 input wire [7:0] ioctl_dout,
 input wire [15:0] ioctl_index,
 output wire ioctl_wait,rom_loaded,load_error,
 input wire [1:0] p1_buttons,p2_buttons,
 input wire [3:0] p1_directions,p2_directions,
 input wire service_test,
 input wire [2:0] coin,
 input wire eeprom_restore,eeprom_load_we,
 input wire [10:0] eeprom_load_address,eeprom_dump_address,
 input wire [7:0] eeprom_load_data,
 output wire [7:0] eeprom_dump_data,
 output wire eeprom_modified,
 output wire video_ce,video_de,
 output wire [8:0] video_h,video_v,beam_h,beam_v,
 output wire [7:0] video_r,video_g,video_b,
 output wire signed [15:0] audio_l,audio_r,
 output wire video_fault,watchdog_expired,
 inout wire [15:0] SDRAM_DQ,
 output wire [12:0] SDRAM_A,
 output wire [1:0] SDRAM_BA,
 output wire SDRAM_CLK,
 output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_CKE,SDRAM_nCS,SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE
);
 wire write_valid,write_ready,write_reply;
 wire [23:0] write_address;wire [15:0] write_data;
 wire char_wr,sound_wr;wire [15:0] char_address,sound_address;wire [7:0] char_data,sound_data;
 wire initialized,loader_busy;
 wire loading=!rom_loaded || (ioctl_download && ioctl_index==0) || load_error;
 wire cpu_valid,cpu_ready,cpu_owner,cpu_reply;
 wire [23:1] cpu_address;wire [15:0] cpu_data;
 wire pf1_fetch,pf2_fetch,mo_fetch;
 wire [17:0] pf1_address,pf2_address,mo_address;
 wire [31:0] pf1_data,pf2_data,mo_data;
 wire pf1_valid,pf2_valid,mo_valid;
 wire [2:0] rom_late;
 wire [14:0] alpha_address;wire [15:0] alpha_data;
 wire oki_req,oki_ack;wire [17:0] oki_address;wire [7:0] oki_data;
 wire game_fault,game_de;
 assign video_fault=game_fault || |rom_late;
 assign video_de=game_de && !loading;
 thunderjaws_sdram_clock forward_clock(.clk_source(clk_sdram),.sdram_clock(SDRAM_CLK));
 thunderjaws_rom_loader loader(.clk(clk_sys),.reset(init_reset),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
  .ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),.ioctl_index(ioctl_index),.ioctl_wait(ioctl_wait),
  .write_valid(write_valid),.write_ready(write_ready),.write_address(write_address),.write_data(write_data),.write_response_valid(write_reply),
  .char_wr(char_wr),.char_addr(char_address),.char_data(char_data),.sound_wr(sound_wr),.sound_addr(sound_address),.sound_data(sound_data),
  .rom_loaded(rom_loaded),.load_error(load_error),.busy(loader_busy));
 thunderjaws_rom_memory memory(.clk_sys(clk_sys),.init_reset(init_reset),.invalidate(loading),
  .cpu_valid(cpu_valid),.cpu_ready(cpu_ready),.cpu_owner(cpu_owner),.cpu_address(cpu_address),.cpu_response_valid(cpu_reply),.cpu_response_data(cpu_data),
  .pf1_fetch(pf1_fetch),.pf2_fetch(pf2_fetch),.mo_fetch(mo_fetch),.pf1_address(pf1_address),.pf2_address(pf2_address),.mo_address(mo_address),
  .pf1_data(pf1_data),.pf2_data(pf2_data),.mo_data(mo_data),.pf1_data_valid(pf1_valid),.pf2_data_valid(pf2_valid),.mo_data_valid(mo_valid),.graphics_late(rom_late),
  .char_wr(char_wr),.char_address(char_address),.char_data(char_data),.alpha_address(alpha_address),.alpha_data(alpha_data),
  .oki_request(oki_req),.oki_address(oki_address),.oki_ack(oki_ack),.oki_data(oki_data),
  .write_valid(write_valid),.write_ready(write_ready),.write_address(write_address),.write_data(write_data),.write_response_valid(write_reply),.initialized(initialized),
  .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
  .SDRAM_CKE(SDRAM_CKE),.SDRAM_nCS(SDRAM_nCS),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nWE(SDRAM_nWE));
 thunderjaws_game game(.clk_sys(clk_sys),.init_reset(init_reset || !initialized),.flip_request(flip_request),.game_reset(game_reset),.rom_loading(loading),
  .pause_request(pause_request),.paused(paused),
  .score_read(score_read),.score_write(score_write),.score_address(score_address),.score_write_data(score_write_data),
  .score_read_data(score_read_data),.score_data_ready(score_data_ready),.score_signature_ready(score_signature_ready),.score_busy(score_busy),.score_error(score_error),
  .p1_buttons(p1_buttons),.p2_buttons(p2_buttons),.p1_directions(p1_directions),.p2_directions(p2_directions),.service_test(service_test),.coin(coin),
  .cpu_rom_valid(cpu_valid),.cpu_rom_ready(cpu_ready),.cpu_rom_owner(cpu_owner),.cpu_rom_address(cpu_address),.cpu_rom_response_valid(cpu_reply),.cpu_rom_response_data(cpu_data),
  .pf1_rom_fetch(pf1_fetch),.pf2_rom_fetch(pf2_fetch),.pf1_rom_address(pf1_address),.pf2_rom_address(pf2_address),
  .pf1_rom_data(pf1_data),.pf2_rom_data(pf2_data),.pf1_rom_valid(pf1_valid),.pf2_rom_valid(pf2_valid),
  .mo_rom_fetch(mo_fetch),.mo_rom_address(mo_address),.mo_rom_data(mo_data),.mo_rom_valid(mo_valid),
  .alpha_rom_address(alpha_address),.alpha_rom_data(alpha_data),
  .sound_rom_wr(sound_wr),.sound_rom_address(sound_address),.sound_rom_data(sound_data),
  .oki_rom_req(oki_req),.oki_rom_address(oki_address),.oki_rom_ack(oki_ack),.oki_rom_data(oki_data),
  .eeprom_restore(eeprom_restore),.eeprom_load_we(eeprom_load_we),.eeprom_load_address(eeprom_load_address),.eeprom_dump_address(eeprom_dump_address),
  .eeprom_load_data(eeprom_load_data),.eeprom_dump_data(eeprom_dump_data),.eeprom_modified(eeprom_modified),
  .video_ce(video_ce),.video_de(game_de),.video_h(video_h),.video_v(video_v),.video_r(video_r),.video_g(video_g),.video_b(video_b),
  .audio_l(audio_l),.audio_r(audio_r),.video_fault(game_fault),.watchdog_expired(watchdog_expired),.beam_h(beam_h),.beam_v(beam_v));
endmodule
