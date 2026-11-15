// SPDX-License-Identifier: GPL-3.0-or-later
// Private integration adapter. Controllers retain their pinned source maps.
// No CPU, program ROM, shared RAM, audio chip or raster is instantiated here.
module snk_early_controller_union #(parameter integer CLK_HZ=53600000)(
 input wire clk,reset,pause_cpu,input wire [7:0] profile,
 input wire vblank,ce_sound,
 input wire [7:0] in0,in1,in2,dsw1,dsw2,
 input wire [7:0] in3,in4,in5,
 input wire [47:0] cpu_addr,input wire [23:0] cpu_dout,cpu_rom,
 input wire [2:0] cpu_m1_n,cpu_mreq_n,cpu_iorq_n,cpu_rd_n,cpu_wr_n,
 output wire [23:0] cpu_din,output wire [2:0] cpu_irq_n,cpu_nmi_n,cpu_wait_n,
 input wire [7:0] shared_qa,shared_qb,ram_qs,input wire memory_b_wait_n,
 output wire [13:0] ram_addr_a,ram_addr_b,ram_hs_addr,
 output wire ram_write_a,ram_write_b,ram_hs_req,
 output wire cpu_ram_commit_allowed,
 output wire [7:0] ram_data_a,ram_data_b,
 output wire [11:0] sound_ram_addr,output wire [7:0] sound_ram_data,
 output wire sound_ram_write,
 // TNK3-class virtual late sound bus (profiles 6..10); consumed by the shared late OPL block
 output wire tnk_active,output wire [15:0] tnk_snd_addr,output wire [7:0] tnk_snd_data,
 output wire tnk_snd_mem,tnk_snd_rd,tnk_snd_wr,tnk_snd_cmd_wr,output wire [7:0] tnk_snd_cmd,
 output wire tnk_snd_audio_rd,
 input wire memory_commit,input wire [13:0] committed_addr,input wire [7:0] committed_data,
 output wire canonical_wr,output wire [15:0] canonical_addr,video_commit_addr,
 output wire [7:0] canonical_data,
 input wire hs_grant,hs_req,hs_write,input wire [15:0] hs_addr,input wire [7:0] hs_wdata,
 input wire memory_hs_ack,input wire [7:0] memory_hs_rdata,
 output wire hs_ack,output wire [7:0] hs_rdata,
 output wire [3:0] ay_addr0,ay_addr1,output wire ay_write0,ay_write1,
 output wire [7:0] sound_data,output wire wave_write,output wire [2:0] wave_addr,
 output wire flip,sound_busy,supported,
 output wire [8:0] bg_x,bg_y,sprite_x,sprite_y,fg_x,
 output wire [7:0] fg_y,sprite_split,
 output wire bg_tile_bank,output wire [3:0] bg_palette_bank,
 output wire [6:0] bg_palette_offset,fg_palette_offset
);
 wire is_wave=profile<=8'd2;
 wire is_hsj=profile>=8'd3&&profile<=8'd5;
 wire is_tnk=profile>=8'd6&&profile<=8'd10;
 wire enabled=!reset&&!pause_cpu;
 assign supported=is_wave||is_hsj||is_tnk;
 assign tnk_active=is_tnk;
 wire [23:0] h_din,w_din;
 wire [2:0] h_irq,h_nmi,w_irq,w_nmi;
 wire h_wait,w_wait;
 wire [12:0] h_ra,h_rb,h_hsa;
 wire [13:0] w_ra,w_rb;
 wire h_wa,h_wb,w_wa,w_wb,h_hsreq;
 wire [7:0] h_da,h_db,w_da,w_db;
 wire [10:0] h_sa,w_sa;
 wire [7:0] h_sd,w_sd;
 wire h_sw,w_sw;
 wire [3:0] h_ay0,h_ay1,w_ay0,w_ay1;
 wire h_ayw0,h_ayw1,w_ayw0,w_ayw1,w_wave;
 wire [7:0] h_sound,w_sound;
 wire [2:0] w_wave_addr;
 wire h_flip,w_flip,h_busy,w_busy,h_bg_bank;
 wire [3:0] h_palette;
 wire [6:0] w_bg_palette,w_fg_palette;
 wire [8:0] h_bgx,h_bgy,h_sx,h_sy,w_bgx,w_sx,w_fgx;
 wire [7:0] w_bgy,w_sy,w_fgy,w_split;
 wire [15:0] h_canonical,w_canonical;
 wire w_commit;
 wire [7:0] w_commit_data;
 snk_early_hsj_controller #(.CLK_HZ(CLK_HZ)) hsj(
  .clk(clk),.reset(reset||!is_hsj),.pause_cpu(pause_cpu),.profile(profile),
  .shared_qa(shared_qa),.shared_qb(shared_qb),.ram_qs(ram_qs),.memory_b_wait(memory_b_wait_n),
  .committed_addr(committed_addr[12:0]),.canonical_wr(memory_commit&&!reset&&is_hsj),.canonical_data(committed_data),
  .hs_ack(memory_hs_ack),.hs_rdata(memory_hs_rdata),
  .ram_addr_a(h_ra),.ram_addr_b(h_rb),.ram_hs_addr(h_hsa),
  .ram_write_a(h_wa),.ram_write_b(h_wb),.ram_hs_req(h_hsreq),.ram_data_a(h_da),.ram_data_b(h_db),
  .sound_ram_addr(h_sa),.sound_ram_data(h_sd),.sound_ram_write(h_sw),
  .ay_register0(h_ay0),.ay_register1(h_ay1),.ay_write0(h_ayw0),.ay_write1(h_ayw1),.ay_data(h_sound),
  .in0(in0),.in1(in1),.in2(in2),.dsw1(dsw1),.dsw2(dsw2),.vblank(vblank),.ay_ce(1'b0),
  .rom_qa(cpu_rom[7:0]),.rom_qb(cpu_rom[15:8]),.rom_qs(cpu_rom[23:16]),
  .a_addr(cpu_addr[15:0]),.b_addr(cpu_addr[31:16]),.s_addr(cpu_addr[47:32]),
  .a_dout(cpu_dout[7:0]),.b_dout(cpu_dout[15:8]),.s_dout(cpu_dout[23:16]),
  .a_m1_n(cpu_m1_n[0]),.b_m1_n(cpu_m1_n[1]),.s_m1_n(cpu_m1_n[2]),
  .a_mreq_n(cpu_mreq_n[0]),.b_mreq_n(cpu_mreq_n[1]),.s_mreq_n(cpu_mreq_n[2]),
  .a_iorq_n(cpu_iorq_n[0]),.b_iorq_n(cpu_iorq_n[1]),.s_iorq_n(cpu_iorq_n[2]),
  .a_rd_n(cpu_rd_n[0]),.b_rd_n(cpu_rd_n[1]),.s_rd_n(cpu_rd_n[2]),
  .a_wr_n(cpu_wr_n[0]),.b_wr_n(cpu_wr_n[1]),.s_wr_n(cpu_wr_n[2]),
  .a_din(h_din[7:0]),.b_din(h_din[15:8]),.s_din(h_din[23:16]),
  .a_int_n(h_irq[0]),.b_int_n(h_irq[1]),.s_int_n(h_irq[2]),
  .a_nmi_n(h_nmi[0]),.b_nmi_n(h_nmi[1]),.s_nmi_n(h_nmi[2]),.b_wait_n(h_wait),
  .sound_busy(h_busy),.audio_unsigned(11'd0),.audio_sample(1'b0),
  .video_ram_addr(13'd0),.video_ram_data(),
  .flip(h_flip),.bg_tile_bank(h_bg_bank),.bg_palette_bank(h_palette),
  .bg_x(h_bgx),.bg_y(h_bgy),.sprite_x(h_sx),.sprite_y(h_sy),
  .hs_grant(hs_grant),.hs_req(hs_req&&is_hsj&&!reset),.hs_write(hs_write),.hs_addr(hs_addr),.hs_wdata(hs_wdata),
  .a_reads(),.b_reads(),.s_reads(),.shared_writes(),.sound_commands(),.ay_writes(),.input_polls(),
  .canonical_addr(h_canonical));
 snk_wave_controller_external wave(
  .clk(clk),.reset(reset||!is_wave),.profile(profile),.vblank(vblank),.ce_sound(ce_sound&&!pause_cpu),
  .in0(in0),.in1(in1),.in2(in2),.dsw1(dsw1),.dsw2(dsw2),
  .a_addr(cpu_addr[15:0]),.b_addr(cpu_addr[31:16]),.s_addr(cpu_addr[47:32]),
  .a_dout(cpu_dout[7:0]),.b_dout(cpu_dout[15:8]),.s_dout(cpu_dout[23:16]),
  .rom_qa(cpu_rom[7:0]),.rom_qb(cpu_rom[15:8]),.rom_qs(cpu_rom[23:16]),
  .a_m1_n(cpu_m1_n[0]),.b_m1_n(cpu_m1_n[1]),.s_m1_n(cpu_m1_n[2]),
  .a_mreq_n(cpu_mreq_n[0]),.b_mreq_n(cpu_mreq_n[1]),.s_mreq_n(cpu_mreq_n[2]),
  .a_iorq_n(cpu_iorq_n[0]),.b_iorq_n(cpu_iorq_n[1]),.s_iorq_n(cpu_iorq_n[2]),
  .a_rd_n(cpu_rd_n[0]),.b_rd_n(cpu_rd_n[1]),.s_rd_n(cpu_rd_n[2]),
  .a_wr_n(cpu_wr_n[0]),.b_wr_n(cpu_wr_n[1]),.s_wr_n(cpu_wr_n[2]),
  .a_din(w_din[7:0]),.b_din(w_din[15:8]),.s_din(w_din[23:16]),
  .a_irq_n(w_irq[0]),.b_irq_n(w_irq[1]),.s_irq_n(w_irq[2]),
  .a_nmi_n(w_nmi[0]),.b_nmi_n(w_nmi[1]),.s_nmi_n(w_nmi[2]),
  .memory_b_wait_n(memory_b_wait_n),.b_wait_n(w_wait),
  .ram_addr_a(w_ra),.ram_addr_b(w_rb),.ram_write_a(w_wa),.ram_write_b(w_wb),.ram_data_a(w_da),.ram_data_b(w_db),
  .shared_qa(shared_qa),.shared_qb(shared_qb),
  .sound_ram_addr(w_sa),.sound_ram_data(w_sd),.sound_ram_write(w_sw),.ram_qs(ram_qs),
  .ay_addr0(w_ay0),.ay_addr1(w_ay1),.ay_write0(w_ayw0),.ay_write1(w_ayw1),
  .sound_data(w_sound),.wave_write(w_wave),.wave_addr(w_wave_addr),
  .flip(w_flip),.bg_palette_offset(w_bg_palette),.fg_palette_offset(w_fg_palette),
  .bg_x(w_bgx),.fg_x(w_fgx),.sprite_x(w_sx),.bg_y(w_bgy),.fg_y(w_fgy),.sprite_y(w_sy),.sprite_split(w_split),
  .memory_commit(memory_commit&&!reset&&is_wave),.committed_addr(committed_addr),.committed_data(committed_data),
  .canonical_wr(w_commit),.canonical_addr(w_canonical),.canonical_data(w_commit_data),
  .sound_busy(w_busy),.supported(),.input_polls(),.sound_commands(),.ay_writes(),.wave_writes());
 // ---- TNK3-class family (profiles 6..10)
 wire [23:0] t_din;wire t_wait;
 wire [13:0] t_ra,t_rb;wire t_wa,t_wb;wire [7:0] t_da,t_db;
 wire [11:0] t_sa;wire [7:0] t_sd;wire t_sw;
 wire t_flip,t_txb;wire [1:0] t_bgb;wire [3:0] t_bgp;
 wire [8:0] t_bgx,t_bgy,t_sx,t_sy;
 wire t_ai,t_bi,t_an,t_bn,t_si,t_sn;
 snk_early_tnk_controller #(.CLK_HZ(CLK_HZ)) tnk(
  .profile(profile),.shared_qa(shared_qa),.shared_qb(shared_qb),.ram_qs(ram_qs),.memory_b_wait(memory_b_wait_n),
  .ram_addr_a(t_ra),.ram_addr_b(t_rb),.ram_write_a(t_wa),.ram_write_b(t_wb),.ram_data_a(t_da),.ram_data_b(t_db),
  .sound_ram_addr(t_sa),.sound_ram_data(t_sd),.sound_ram_write(t_sw),
  .clk(clk),.reset(reset||!is_tnk),.pause_cpu(pause_cpu),
  .in0(in0),.in1(in1),.in2(in2),.in3(in3),.in4(in4),.in5(in5),.dsw1(dsw1),.dsw2(dsw2),
  .vblank(vblank),.rom_qa(cpu_rom[7:0]),.rom_qb(cpu_rom[15:8]),.rom_qs(cpu_rom[23:16]),
  .a_addr(cpu_addr[15:0]),.b_addr(cpu_addr[31:16]),.s_addr(cpu_addr[47:32]),
  .a_dout(cpu_dout[7:0]),.b_dout(cpu_dout[15:8]),.s_dout(cpu_dout[23:16]),
  .a_m1_n(cpu_m1_n[0]),.b_m1_n(cpu_m1_n[1]),.s_m1_n(cpu_m1_n[2]),
  .a_mreq_n(cpu_mreq_n[0]),.b_mreq_n(cpu_mreq_n[1]),.s_mreq_n(cpu_mreq_n[2]),
  .a_iorq_n(cpu_iorq_n[0]),.b_iorq_n(cpu_iorq_n[1]),.s_iorq_n(cpu_iorq_n[2]),
  .a_rd_n(cpu_rd_n[0]),.b_rd_n(cpu_rd_n[1]),.s_rd_n(cpu_rd_n[2]),
  .a_wr_n(cpu_wr_n[0]),.b_wr_n(cpu_wr_n[1]),.s_wr_n(cpu_wr_n[2]),
  .a_din(t_din[7:0]),.b_din(t_din[15:8]),.s_din(t_din[23:16]),
  .a_int_n(t_ai),.b_int_n(t_bi),.s_int_n(t_si),.a_nmi_n(t_an),.b_nmi_n(t_bn),.s_nmi_n(t_sn),.b_wait_n(t_wait),
  .flip(t_flip),.tx_bank(t_txb),.bg_tile_bank(t_bgb),.bg_palette_bank(t_bgp),
  .bg_x(t_bgx),.bg_y(t_bgy),.sprite_x(t_sx),.sprite_y(t_sy),
  .snd_addr(tnk_snd_addr),.snd_data(tnk_snd_data),.snd_mem(tnk_snd_mem),.snd_rd(tnk_snd_rd),.snd_wr(tnk_snd_wr),
  .snd_cmd_wr(tnk_snd_cmd_wr),.snd_cmd(tnk_snd_cmd),.snd_audio_rd(tnk_snd_audio_rd));
 assign cpu_din=reset||!supported?24'hffffff:is_tnk?t_din:is_wave?w_din:h_din;
 assign cpu_irq_n=reset||!supported?3'b111:is_tnk?{t_si,t_bi,t_ai}:is_wave?w_irq:h_irq;
 assign cpu_nmi_n=reset||!supported?3'b111:is_tnk?{t_sn,t_bn,t_an}:is_wave?w_nmi:h_nmi;
 assign cpu_wait_n={1'b1,(!reset&&supported?(is_tnk?t_wait:is_wave?w_wait:h_wait):1'b1),1'b1};
 assign ram_addr_a=is_tnk?t_ra:is_wave?w_ra:{1'b0,h_ra};
 assign ram_addr_b=is_tnk?t_rb:is_wave?w_rb:{1'b0,h_rb};
 // Wave exports held request levels. Keep them visible to the arbiter's edge
 // history through pause; gate its CPU commit, not these request strobes.
 assign cpu_ram_commit_allowed=enabled&&supported;
 assign ram_write_a=!reset&&supported&&(is_tnk?t_wa:is_wave?w_wa:h_wa);
 assign ram_write_b=!reset&&supported&&(is_tnk?t_wb:is_wave?w_wb:h_wb);
 assign ram_data_a=is_tnk?t_da:is_wave?w_da:h_da;assign ram_data_b=is_tnk?t_db:is_wave?w_db:h_db;
 assign sound_ram_addr=is_tnk?t_sa:is_wave?{1'b0,w_sa}:{1'b0,h_sa};assign sound_ram_data=is_tnk?t_sd:is_wave?w_sd:h_sd;
 assign sound_ram_write=!reset&&supported&&(is_tnk?t_sw:is_wave?w_sw:h_sw);
 wire wave_hs_range=hs_addr>=16'hc000&&hs_addr<=16'hf7ff;
 wire tnk_hs_range=hs_addr>=(profile==8'd6 ? 16'hd800 : 16'hd000);
 wire [13:0] tnk_hs_offset=hs_addr-(profile==8'd6 ? 16'hd800 : 16'hd000);
 assign ram_hs_addr=is_tnk?tnk_hs_offset:is_wave?hs_addr[13:0]:{1'b0,h_hsa};
 assign ram_hs_req=!reset&&hs_grant&&hs_req&&(is_tnk?tnk_hs_range:is_wave?wave_hs_range:is_hsj&&h_hsreq);
 assign hs_ack=ram_hs_req&&memory_hs_ack;assign hs_rdata=ram_hs_req?memory_hs_rdata:8'hff;
 // The arbiter's acknowledged restore commit must reach video even while CPUs pause.
 assign canonical_wr=!reset&&supported&&memory_commit;
 assign canonical_addr=is_wave?w_canonical:h_canonical;
 // JC's HAL-derived video alone needs the +0800 alias. CPU RAM stays native.
 assign video_commit_addr=profile==8'd3 ? canonical_addr+16'h0800:canonical_addr;
 assign canonical_data=committed_data;
 assign ay_addr0=is_wave?w_ay0:h_ay0;assign ay_addr1=is_wave?w_ay1:h_ay1;
 assign ay_write0=enabled&&supported&&!is_tnk&&(is_wave?w_ayw0:h_ayw0);
 assign ay_write1=enabled&&supported&&!is_tnk&&(is_wave?w_ayw1:h_ayw1);
 assign sound_data=is_wave?w_sound:h_sound;
 assign wave_write=enabled&&is_wave&&w_wave;assign wave_addr=w_wave_addr;
 assign sound_busy=!reset&&supported&&!is_tnk&&(is_wave?w_busy:h_busy);
 assign flip=is_tnk?t_flip:is_wave?w_flip:h_flip;
 assign bg_x=is_tnk?t_bgx:is_wave?w_bgx:h_bgx;assign bg_y=is_tnk?t_bgy:is_wave?{1'b0,w_bgy}:h_bgy;
 assign sprite_x=is_tnk?t_sx:is_wave?w_sx:h_sx;assign sprite_y=is_tnk?t_sy:is_wave?{1'b0,w_sy}:h_sy;
 assign fg_x=is_wave?w_fgx:9'd0;assign fg_y=is_wave?w_fgy:8'd0;
 // TNK3-class extra video attributes ride on the otherwise unused (hsj) sprite_split bus:
 // [1:0] bg tile bank (aso CF00 bits5:4), [2] text char bank (tnk3 C800 bit6).
 assign sprite_split=is_wave?w_split:is_tnk?{5'd0,t_txb,t_bgb}:8'd0;
 assign bg_tile_bank=is_hsj&&h_bg_bank;assign bg_palette_bank=is_tnk?t_bgp:is_hsj?h_palette:4'd0;
 assign bg_palette_offset=is_wave?w_bg_palette:7'd0;assign fg_palette_offset=is_wave?w_fg_palette:7'd0;
endmodule
