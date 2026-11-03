// SPDX-License-Identifier: GPL-3.0-or-later
// Framework-free game board. Memory ports are served by SDRAM in hardware,
// and by time-zero-loaded behavioral memories in native simulation.
module pwb_board #(parameter ALLOW_6809_COMPAT=0)(
 input wire clk,reset,pause,profile,
 input wire [7:0] system_in,p1_in,p2_in,p3_in,p4_in,dip1,dip2,dip3,
 input wire state_req,state_we,input wire [15:0] state_addr,input wire [7:0] state_din,
 output wire [7:0] state_dout,output wire state_grant,
 output wire main_req,output wire [15:0] main_addr,input wire [7:0] main_data,input wire main_ok,
 output wire sound_req,output wire [14:0] sound_addr,input wire [7:0] sound_data,input wire sound_ok,
 output wire [16:0] f_addr,a_addr,b_addr,output wire f_cs,a_cs,b_cs,
 input wire [31:0] f_data,a_data,b_data,input wire a_ok,
 output wire [17:0] o_addr,output wire o_cs,input wire [31:0] o_data,input wire o_ok,
 output wire pcm_req,output wire [18:0] pcm_addr,input wire [7:0] pcm_data,input wire pcm_ok,
 output wire upd_req,output wire [18:0] upd_addr,input wire [7:0] upd_data,input wire upd_ok,
 output wire [7:0] red,green,blue,output wire ce_pix,hs,vs,hblank,vblank,
 output wire signed [15:0] audio_l,audio_r,output wire audio_valid,
 output wire [15:0] debug_cpu_addr,output wire [7:0] debug_cpu_dout,debug_cpu_din,
 output wire debug_cpu_rnw,debug_cpu_transfer,debug_cpu_op,
 output wire [111:0] debug_regs,output wire execution_enabled,hd6309_supported,watchdog_reset
);
 reg [2:0] pixel_phase;
 wire [3:0] cpu_phase;
 wire cpu_paused;
 wire board_reset=reset || watchdog_reset;
 wire cpu_ok;
 wire stop_cpu,ce_e,ce_q,cpu_primed,cpu_debt_overflow;
 wire [31:0] cpu_debt;
 pwb_cpu_clock u_cpu_clock(.clk(clk),.reset(board_reset),.pause(pause),.cpu_ok(cpu_ok),
  .phase(cpu_phase),.paused(cpu_paused),.stop_cpu(stop_cpu),.ce_e(ce_e),.ce_q(ce_q),
  .primed(cpu_primed),.debt(cpu_debt),.debt_overflow(cpu_debt_overflow));
 wire pxl_cen=pixel_phase==0;
 wire pxl2_cen=pixel_phase[1:0]==0;
 always @(posedge clk) begin
   if(board_reset)pixel_phase<=0;
   else pixel_phase<=pixel_phase+1'b1;
 end
 wire [15:0] cpu_addr;
 wire [7:0] cpu_dout,cpu_din;
 wire cpu_rnw,cpu_avma,cpu_bs,cpu_ba,cpu_lic,cpu_op,irq,nmi;
 wire transfer=ce_q && !board_reset;
 pwb_main #(.ALLOW_6809_COMPAT(ALLOW_6809_COMPAT)) u_cpu(
  .clk(clk),.reset(board_reset),.ce_e(ce_e),.ce_q(ce_q),.pause(stop_cpu),.cpu_ok(cpu_ok),
  .irq(irq),.nmi(nmi),.din(cpu_din),.addr(cpu_addr),.dout(cpu_dout),.rnw(cpu_rnw),
  .avma(cpu_avma),.bs(cpu_bs),.ba(cpu_ba),.lic(cpu_lic),.opcode(cpu_op),
  .debug_regs(debug_regs),.execution_enabled(execution_enabled),.hd6309_supported(hd6309_supported));
 wire vid_cs,vid_wr,rmrd,pal_wr,vid_ok,irq_n;
 wire [13:0] vid_addr;
 wire [8:0] pal_addr,hdump,vdump,beam_h,beam_v;
 wire [7:0] vid_dout,vid_din,pal_data,pal_din,sound_latch,coin_lamps;
 wire sound_irq,watchdog_access,lhbl,lvbl;
 wire line_start=pxl_cen && beam_h==0;
 reg math_vblank;
 // The donor advances its render-line counter during horizontal blanking.
 // Sample it at H0 to express the physical line epoch used by MAME's timer.
 always @(posedge clk)if(board_reset)math_vblank<=1'b1;
 else if(line_start)math_vblank<=beam_v<16 || beam_v>=240;
 pwb351024_mainbus u_bus(.clk(clk),.reset(board_reset),.profile_devstors(!profile),
  .ce_bus(transfer),.ce_12m(pxl2_cen),.cpu_addr(cpu_addr),.cpu_dout(cpu_dout),
  .cpu_rnw(cpu_rnw),.cpu_valid(execution_enabled),.cpu_din(cpu_din),.cpu_ok(cpu_ok),
  .rom_addr(main_addr),.rom_data(main_data),.rom_ok(main_ok),
  .vid_cs(vid_cs),.vid_wr(vid_wr),.vid_addr(vid_addr),.vid_dout(vid_dout),.vid_din(vid_din),.vid_ok(vid_ok),
  .rmrd(rmrd),.pal_wr(pal_wr),.pal_addr(pal_addr),.pal_data(pal_data),.pal_din(pal_din),
  .in_system(system_in),.in_p1(p1_in),.in_p2(p2_in),.in_p3(p3_in),.in_p4(p4_in),
  .dsw1(dip1),.dsw2(dip2),.dsw3(dip3),.tile_irq(!irq_n),.vblank(math_vblank),.irq(irq),.nmi(nmi),
  .state_req(state_req),.state_we(state_we),.state_pause_ack(cpu_paused && cpu_phase==0),
  .state_addr(state_addr),.state_din(state_din),.state_dout(state_dout),.state_grant(state_grant),
  .sound_latch(sound_latch),.sound_irq(sound_irq),.coin_lamps(coin_lamps),.watchdog_access(watchdog_access));
 pwb_watchdog u_watchdog(.clk(clk),.reset(board_reset),.pause(pause),.service(watchdog_access),.expired(watchdog_reset),.armed());
 assign main_req=execution_enabled && cpu_rnw && cpu_addr>=16'h6000;
 pwb_video u_video(.clk(clk),.reset(board_reset),.pxl_cen(pxl_cen),.pxl2_cen(pxl2_cen),.video_enable(1'b1),
  .game_mainevt(profile),.cpu_cs(vid_cs),.cpu_we(vid_wr),.cpu_rnw(cpu_rnw),.cpu_addr(vid_addr),.cpu_dout(vid_dout),
  .cpu_din(vid_din),.cpu_ok(vid_ok),.rmrd(rmrd),.pal_we(pal_wr),.pal_addr(pal_addr),.pal_data(pal_data),.pal_dout(pal_din),.irq_n(irq_n),
  .f_addr(f_addr),.a_addr(a_addr),.b_addr(b_addr),.o_addr(o_addr),.f_cs(f_cs),.a_cs(a_cs),.b_cs(b_cs),.o_cs(o_cs),
  .f_data(f_data),.a_data(a_data),.b_data(b_data),.o_data(o_data),.a_ok(a_ok),.o_ok(o_ok),
  .red(red),.green(green),.blue(blue),.ce_pix(ce_pix),.hs(hs),.vs(vs),.lhbl(lhbl),.lvbl(lvbl),.hdump(hdump),.vdump(vdump),.beam_h(beam_h),.beam_v(beam_v));
 assign hblank=!lhbl;assign vblank=!lvbl;
 pwb_sound u_sound(.clk(clk),.reset(board_reset),.pause(pause),.profile_mainevt(profile),
  .main_latch(sound_latch),.main_irq(sound_irq),.line_start(line_start),.scanline(beam_v),
  .rom_req(sound_req),.rom_addr(sound_addr),.rom_data(sound_data),.rom_ok(sound_ok),
  .pcm_req(pcm_req),.pcm_addr(pcm_addr),.pcm_data(pcm_data),.pcm_ok(pcm_ok),
  .upd_req(upd_req),.upd_addr(upd_addr),.upd_data(upd_data),.upd_ok(upd_ok),
  .audio(),.audio_l(audio_l),.audio_r(audio_r),.sample_valid(audio_valid),
  .debug_wr(),.debug_rd(),.debug_addr(),.debug_data(),.debug_banks(),.debug_irq_n(),.debug_nmi_n(),.debug_clip(),.debug_cen());
 assign debug_cpu_addr=cpu_addr;assign debug_cpu_dout=cpu_dout;assign debug_cpu_din=cpu_din;
 assign debug_cpu_rnw=cpu_rnw;assign debug_cpu_transfer=transfer;assign debug_cpu_op=cpu_op;
endmodule
