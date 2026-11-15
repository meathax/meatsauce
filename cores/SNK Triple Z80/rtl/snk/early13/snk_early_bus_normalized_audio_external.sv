// SPDX-License-Identifier: GPL-3.0-or-later
// Private exact root-bus extraction: physical state/sound RAM stays external.
// Controller/Wave unchanged; one source-pinned normalized AY pair preserves raw ports.
module snk_early_bus_normalized_audio_external #(parameter integer CLK_HZ=96000000)(
 input wire clk,reset,pause_cpu,input wire [7:0] profile,
 input wire vblank,ce_sound,ce_ay,ce_wave,
 input wire [7:0] in0,in1,in2,dsw1,dsw2,
 input wire [7:0] in3,in4,in5,
 input wire [47:0] cpu_addr,input wire [23:0] cpu_dout,cpu_rom,
 input wire [2:0] cpu_m1_n,cpu_mreq_n,cpu_iorq_n,cpu_rd_n,cpu_wr_n,
 output wire [23:0] cpu_din,output wire [2:0] cpu_irq_n,cpu_nmi_n,cpu_wait_n,
 input wire [7:0] shared_qa,shared_qb,ram_qs,input wire memory_b_wait_n,
 output wire [13:0] ram_addr_a,ram_addr_b,ram_hs_addr,
 output wire ram_write_a,ram_write_b,ram_hs_req,cpu_ram_commit_allowed,
 output wire [7:0] ram_data_a,ram_data_b,
 output wire [11:0] sound_ram_addr,output wire [7:0] sound_ram_data,
 output wire sound_ram_write,
 output wire tnk_active,output wire [15:0] tnk_snd_addr,output wire [7:0] tnk_snd_data,
 output wire tnk_snd_mem,tnk_snd_rd,tnk_snd_wr,tnk_snd_cmd_wr,output wire [7:0] tnk_snd_cmd,
 output wire tnk_snd_audio_rd,
 input wire memory_commit,input wire [13:0] committed_addr,input wire [7:0] committed_data,
 input wire memory_hs_ack,input wire [7:0] memory_hs_rdata,input wire memory_drained,
 output wire memory_reset,memory_hs_grant,
 input wire hs_grant,hs_req,hs_write,input wire [15:0] hs_addr,
 input wire [7:0] hs_wdata,output wire hs_ack,output wire [7:0] hs_rdata,
 output wire drained,canonical_wr,output wire [15:0] canonical_addr,video_commit_addr,
 output wire [7:0] canonical_data,
 output wire flip,sound_busy,supported,
 output wire [8:0] bg_x,bg_y,sprite_x,sprite_y,fg_x,
 output wire [7:0] fg_y,sprite_split,
 output wire bg_tile_bank,output wire [3:0] bg_palette_bank,
 output wire [6:0] bg_palette_offset,fg_palette_offset,
 output wire [10:0] ay_unsigned,output wire ay_sample,
 output wire signed [25:0] ay_normalized_q23,output wire ay_normalized_valid,
 output wire signed [15:0] wave_pcm,output wire wave_sample
);
 wire [3:0] ay_addr0,ay_addr1;wire ay_write0,ay_write1;
 wire [7:0] sound_data;wire wave_write;wire [2:0] wave_addr;
 snk_early_controller_union #(.CLK_HZ(CLK_HZ)) controller(.*);
 assign memory_reset=reset||!supported;
 assign memory_hs_grant=hs_grant&&supported;
 assign drained=memory_drained;
 snk_timed_ay_pair ay_pair(.clk(clk),.reset(reset||!supported),
  .ay_ce(ce_ay&&!pause_cpu&&supported),.addr0(ay_addr0),.addr1(ay_addr1),
  .write0(ay_write0),.write1(ay_write1),.data(sound_data),
  .audio_unsigned(ay_unsigned),.audio_sample(ay_sample),
  .audio_normal(ay_normalized_q23),.normal_valid(ay_normalized_valid));
 snk_wave waveform(.clk(clk),.reset(reset||profile>8'd2),
  .ce_wave(ce_wave&&!pause_cpu&&profile<=8'd2),.wr(wave_write),.addr(wave_addr),
  .data(sound_data),.pcm(wave_pcm),.sample_valid(wave_sample));
endmodule
