// Shared late system: exactly one native CPU trio and one program bank.
module snk_union_system_shared #(parameter HISCORE_ENABLE=0,parameter DISPLAY_FLIP_ENABLE=0)(
 input wire [7:0] profile_id,
 input wire clk,reset_n,cen_p,cen_n,ce_opl,pxl_cen,
 input wire gwar_ab_p,gwar_ab_n,
 input wire display_flip,pause_cpu,
 input wire early_ab_p,early_ab_n,early_s_p,early_s_n,early_ay_ce,early_wave_ce,early_pixel_ce,
 output wire pixel_response_ce,early_drained,early_sound_busy,
 input wire hs_grant,hs_req,hs_write,
 input wire [15:0] hs_addr,input wire [7:0] hs_wdata,
 output wire hs_ack,output wire [7:0] hs_rdata,

 input wire [24:0] ioctl_addr,input wire [7:0] ioctl_data,input wire ioctl_wr,
 input wire [7:0] in0,in1,in2,in3,dsw1,dsw2,
 input wire [79:0] sports_inputs,
 output wire [18:2] bgrom_addr,
 output wire [17:2] s16rom_addr,
 output wire [18:2] s32rom_addr,
 output wire bgrom_req,s16rom_req,s32rom_req,
 input wire [31:0] bgrom_data,s16rom_data,s32rom_data,
 input wire bgrom_ack,s16rom_ack,s32rom_ack,
 output wire [20:0] sample_addr,output wire sample_req,
 input wire [7:0] sample_data,input wire sample_ack,
 output wire [7:0] red,green,blue,
 output wire hsync,vsync,hblank,vblank,
 output wire signed [15:0] audio_mono,
 output wire signed [15:0] ym3526_pcm,y8950_pcm,
 output wire ym3526_sample,y8950_sample,
 output wire [3:0] sound_status,
 output wire [2:0] render_busy,line_overrun,
 output wire [15:0] debug_a_addr,debug_b_addr,debug_s_addr,
 output wire [7:0] debug_a_data,debug_b_data,debug_s_data,
 output wire [7:0] debug_a_din,debug_b_din,debug_s_din,
 output wire [4:0] debug_a_ctl,debug_b_ctl,debug_s_ctl,
 output wire sound_command_wr,output wire [7:0] sound_command
);
 wire early_valid=profile_id<=8'd10;
 // Ikari uses 3.33MHz A/B phases. Victory Road uses the existing 4MHz phases
 // for 20% more game-CPU budget; sound and raster keep their original rates.
 wire ikari_valid=profile_id==8'd14||profile_id==8'd18;
 wire tnk_clk=early_valid||profile_id==8'd14;
 // Gladiator alone gives its game CPUs the existing 4MHz phase pair to reduce
 // busy-scene slowdown. Keep the sound CPU, chips and video on their prior CEs.
 wire sgladiat_boost=profile_id==8'd4;
 // Guerrilla War game CPUs A/B take the root's selectable gwar_ab enables (PCB 4MHz or the
 // OSD slowdown-free 6/8MHz); B keeps the opposite phase of A so their bus writes never share
 // a master edge. Sound CPU/OPL stay on cen_p/cen_n.
 wire gwar_cpu=profile_id==8'd19;
  wire union_valid=early_valid||ikari_valid||profile_id==8'd11||profile_id==8'd12||profile_id==8'd13||profile_id==8'd16||profile_id==8'd19||profile_id==8'd15||profile_id==8'd17;
 wire [47:0] cpu_addr;wire [23:0] cpu_data,cpu_rom,cpu_din;
 wire [2:0] cpu_m1_n,cpu_mreq_n,cpu_iorq_n,cpu_rd_n,cpu_wr_n;
 wire [2:0] cpu_wait_n,cpu_irq_n,cpu_nmi_n;
 snk_cpu_union engine(.clk(clk),.profile(profile_id),.load_wr(ioctl_wr&&union_valid),
  .load_addr(ioctl_addr),.load_data(ioctl_data),.reset_n({3{reset_n&&union_valid}}),
  .cen_p(tnk_clk?{early_s_p,(sgladiat_boost?early_s_n:early_ab_n),(sgladiat_boost?early_s_p:early_ab_p)}:
         gwar_cpu?{cen_p,gwar_ab_n,gwar_ab_p}:{cen_p,cen_n,cen_p}),
  .cen_n(tnk_clk?{early_s_n,(sgladiat_boost?early_s_p:early_ab_p),(sgladiat_boost?early_s_n:early_ab_n)}:
         gwar_cpu?{cen_n,gwar_ab_p,gwar_ab_n}:{cen_n,cen_p,cen_n}),
  .wait_n(cpu_wait_n),.irq_n(cpu_irq_n),.nmi_n(cpu_nmi_n),.din(cpu_din),
  .rom_data(cpu_rom),.dout(cpu_data),.addr(cpu_addr),
  .m1_n(cpu_m1_n),.mreq_n(cpu_mreq_n),.iorq_n(cpu_iorq_n),.rd_n(cpu_rd_n),.wr_n(cpu_wr_n),
  .rfsh_n(),.halt_n(),.busack_n());
 wire [20:0] sample_raw_addr;
 snk_sample_rom_mask mask(.profile(profile_id),.raw_addr(sample_raw_addr),.masked_addr(sample_addr),.supported());
 snk_union_board_shared #(.HISCORE_ENABLE(HISCORE_ENABLE),.DISPLAY_FLIP_ENABLE(DISPLAY_FLIP_ENABLE)) board(
  .sample_addr(sample_raw_addr),.*);
endmodule
