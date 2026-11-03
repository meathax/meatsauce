// SPDX-License-Identifier: GPL-3.0-or-later
module pwb_game #(parameter ALLOW_6809_COMPAT=0)(
 input wire clk,clk_sdram,loader_reset,reset,pause,profile,
 input wire [7:0] system_in,p1_in,p2_in,p3_in,p4_in,dip1,dip2,dip3,
 input wire state_req,state_we,input wire [15:0] state_addr,input wire [7:0] state_din,
 output wire [7:0] state_dout,output wire state_grant,
 input wire dl_wr,input wire [26:0] dl_addr,input wire [7:0] dl_data,
 output wire dl_wait,image_ready,load_error,
 output wire [7:0] red,green,blue,output wire ce_pix,hs,vs,hblank,vblank,
 output wire signed [15:0] audio_l,audio_r,
 output wire watchdog_reset,
 inout wire [15:0] sdram_dq,output wire [12:0] sdram_a,output wire [1:0] sdram_ba,
 output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
 wire main_req,main_ok,sound_req,sound_ok,pcm_req,pcm_ok,upd_req,upd_ok;
 wire [15:0] main_addr;wire [14:0] sound_addr;wire [18:0] pcm_addr,upd_addr;
 wire [7:0] main_data,sound_data,pcm_data,upd_data;
 wire [16:0] f_addr,a_addr,b_addr;wire [17:0] o_addr;
 wire f_cs,a_cs,b_cs,o_cs,a_ok,o_ok;wire [31:0] f_data,a_data,b_data,o_data;
 pwb_roms u_roms(.clk(clk),.clk_sdram(clk_sdram),.reset(loader_reset),.gfx_reset(reset||watchdog_reset),
  .dl_wr(dl_wr),.dl_addr(dl_addr),.dl_data(dl_data),.dl_wait(dl_wait),.image_ready(image_ready),.load_error(load_error),
  .main_req(main_req),.main_addr(main_addr),.main_data(main_data),.main_ok(main_ok),
  .sound_req(sound_req),.sound_addr(sound_addr),.sound_data(sound_data),.sound_ok(sound_ok),
  .f_addr(f_addr),.a_addr(a_addr),.b_addr(b_addr),.f_cs(f_cs),.a_cs(a_cs),.b_cs(b_cs),
  .f_data(f_data),.a_data(a_data),.b_data(b_data),.a_ok(a_ok),
  .o_addr(o_addr),.o_cs(o_cs),.o_data(o_data),.o_ok(o_ok),
  .pcm_req(pcm_req),.pcm_addr(pcm_addr),.pcm_data(pcm_data),.pcm_ok(pcm_ok),
  .upd_req(upd_req),.upd_addr(upd_addr),.upd_data(upd_data),.upd_ok(upd_ok),
  .sdram_dq(sdram_dq),.sdram_a(sdram_a),.sdram_ba(sdram_ba),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
  .sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),.sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke));
 pwb_board #(.ALLOW_6809_COMPAT(ALLOW_6809_COMPAT)) u_board(
  .clk(clk),.reset(reset),.pause(pause),.profile(profile),
  .system_in(system_in),.p1_in(p1_in),.p2_in(p2_in),.p3_in(p3_in),.p4_in(p4_in),.dip1(dip1),.dip2(dip2),.dip3(dip3),
  .state_req(state_req),.state_we(state_we),.state_addr(state_addr),.state_din(state_din),.state_dout(state_dout),.state_grant(state_grant),
  .main_req(main_req),.main_addr(main_addr),.main_data(main_data),.main_ok(main_ok),
  .sound_req(sound_req),.sound_addr(sound_addr),.sound_data(sound_data),.sound_ok(sound_ok),
  .f_addr(f_addr),.a_addr(a_addr),.b_addr(b_addr),.f_cs(f_cs),.a_cs(a_cs),.b_cs(b_cs),
  .f_data(f_data),.a_data(a_data),.b_data(b_data),.a_ok(a_ok),.o_addr(o_addr),.o_cs(o_cs),.o_data(o_data),.o_ok(o_ok),
  .pcm_req(pcm_req),.pcm_addr(pcm_addr),.pcm_data(pcm_data),.pcm_ok(pcm_ok),
  .upd_req(upd_req),.upd_addr(upd_addr),.upd_data(upd_data),.upd_ok(upd_ok),
  .red(red),.green(green),.blue(blue),.ce_pix(ce_pix),.hs(hs),.vs(vs),.hblank(hblank),.vblank(vblank),
  .audio_l(audio_l),.audio_r(audio_r),.audio_valid(),.debug_cpu_addr(),.debug_cpu_dout(),.debug_cpu_din(),
  .debug_cpu_rnw(),.debug_cpu_transfer(),.debug_cpu_op(),.debug_regs(),.execution_enabled(),.hd6309_supported(),.watchdog_reset(watchdog_reset));
endmodule
