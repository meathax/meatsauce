// Shared-clock Psycho frontend. ROM bridge and actual MiSTer wrapper are
// external integration dependencies; this stage alone is not a release core.
module snk_union_board_shared #(parameter HISCORE_ENABLE=0,parameter DISPLAY_FLIP_ENABLE=0)(
 input wire [7:0] profile_id,
 input wire clk,reset_n,ce_opl,pxl_cen,
 input wire [47:0] cpu_addr,input wire [23:0] cpu_data,cpu_rom,
 input wire [2:0] cpu_m1_n,cpu_mreq_n,cpu_iorq_n,cpu_rd_n,cpu_wr_n,
 output wire [23:0] cpu_din,output wire [2:0] cpu_wait_n,cpu_irq_n,cpu_nmi_n,
 input wire display_flip,pause_cpu,
 input wire early_s_p,early_ay_ce,early_wave_ce,early_pixel_ce,
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
 wire early_valid=profile_id<=8'd10; // 0..5 wave/hsj, 6..10 TNK3-class
 wire tnk_valid=profile_id>=8'd6&&profile_id<=8'd10;
 wire [15:0] tnk_snd_addr;wire [7:0] tnk_snd_data,tnk_snd_cmd;wire tnk_snd_mem,tnk_snd_rd,tnk_snd_wr,tnk_snd_cmd_wr,tnk_snd_audio_rd;
 wire ikari_valid=profile_id==8'd14||profile_id==8'd18; // Ikari Warriors / Victory Road ride on the late bus/RAM/video/audio
 wire late_valid=profile_id==8'd11||profile_id==8'd12||profile_id==8'd13||profile_id==8'd16||profile_id==8'd19||ikari_valid;
 wire sports_valid=profile_id==8'd15||profile_id==8'd17;
 wire board_reset_n=reset_n&&(late_valid||sports_valid);
 // One early RAM/graphics/audio board shares the global native CPU/program bank.
 wire [23:0] early_cpu_din;wire [2:0] early_cpu_irq_n,early_cpu_nmi_n,early_cpu_wait_n;
 wire early_hs_ack;wire [7:0] early_hs_rdata;
 wire [7:0] early_red,early_green,early_blue;
 wire early_hblank,early_vblank,early_hsync,early_vsync,early_ce_response,early_wave_busy;
 wire [31:0] early_wave_overruns;wire signed [15:0] early_audio_mono;wire early_sound_busy_internal;
 wire wave_hb,wave_vb,wave_hs,wave_vs;
 wire [14:0] txrom_addr;wire [7:0] txrom_data;
 wire [9:0] pal_addr;wire [3:0] palr,palg,palb;
 snk_early_group_b_raster early_raster(.clk(clk),.reset(!reset_n||!early_valid),.pce(early_pixel_ce),
  .hblank(wave_hb),.vblank(wave_vb),.hsync(wave_hs),.vsync(wave_vs),.hc(),.vc());
 // Early boards run only on the 93.8 MHz PLL setting (HSJ periodic sound IRQ timer counts real clk_sys cycles).
 snk_early_board_storage_audio #(.CLK_HZ(93800000)) early_board(
  .display_flip(DISPLAY_FLIP_ENABLE && display_flip),
  .load_wr(ioctl_wr),.load_addr(ioctl_addr),.load_data(ioctl_data),
  .legacy_active(!early_valid),.legacy_tx_addr(txrom_addr),.legacy_prom_addr(pal_addr),
  .legacy_tx_data(txrom_data),.legacy_prom_data({palb,palg,palr}),
  .ay_normalized_q23(),.ay_normalized_valid(),.audio_mono_pcm(early_audio_mono),.audio_sample_valid(),
  .clk(clk),
  .reset(!reset_n||!early_valid),
  .pause_cpu(pause_cpu||!early_valid),
  .profile(profile_id),
  .irq_vblank(early_vblank),
  .ce_sound(early_s_p),
  .ce_ay(early_ay_ce),
  .ce_wave(early_wave_ce),
  .in0(in0),
  .in1(in1),
  .in2(in2),
  .in3(in3),
  .in4(sports_inputs[39:32]),
  .in5(sports_inputs[47:40]),
  .tnk_active(),
  .tnk_snd_addr(tnk_snd_addr),.tnk_snd_data(tnk_snd_data),.tnk_snd_mem(tnk_snd_mem),.tnk_snd_rd(tnk_snd_rd),.tnk_snd_wr(tnk_snd_wr),
  .tnk_snd_cmd_wr(tnk_snd_cmd_wr),.tnk_snd_cmd(tnk_snd_cmd),.tnk_snd_audio_rd(tnk_snd_audio_rd),
  .dsw1(dsw1),
  .dsw2(dsw2),
  .cpu_addr(cpu_addr),
  .cpu_dout(cpu_data),
  .cpu_rom(cpu_rom),
  .cpu_m1_n(cpu_m1_n),
  .cpu_mreq_n(cpu_mreq_n),
  .cpu_iorq_n(cpu_iorq_n),
  .cpu_rd_n(cpu_rd_n),
  .cpu_wr_n(cpu_wr_n),
  .cpu_din(early_cpu_din),
  .cpu_irq_n(early_cpu_irq_n),
  .cpu_nmi_n(early_cpu_nmi_n),
  .cpu_wait_n(early_cpu_wait_n),
  .hs_grant(hs_grant&&early_valid),
  .hs_req(hs_req&&early_valid),
  .hs_write(hs_write),
  .hs_addr(hs_addr),
  .hs_wdata(hs_wdata),
  .hs_ack(early_hs_ack),
  .hs_rdata(early_hs_rdata),
  .drained(early_drained),
  .canonical_wr(),
  .canonical_addr(),
  .video_commit_addr(),
  .canonical_data(),
  .flip(),
  .sound_busy(early_sound_busy_internal),
  .bg_x(),
  .bg_y(),
  .sprite_x(),
  .sprite_y(),
  .fg_x(),
  .fg_y(),
  .sprite_split(),
  .bg_tile_bank(),
  .bg_palette_bank(),
  .bg_palette_offset(),
  .fg_palette_offset(),
  .ay_unsigned(),
  .ay_sample(),
  .wave_pcm(),
  .wave_sample(),
  .video_reset(!reset_n||!early_valid),
  .layer_ena_dbg(3'b111),
  .wave_pce(early_pixel_ce),
  .wave_hblank(wave_hb),
  .wave_vblank(wave_vb),
  .wave_hsync(wave_hs),
  .wave_vsync(wave_vs),
  .graphics_socket_high(),
  .family_wave(),
  .family_hsj(),
  .ce_wave_response(),
  .ce_hsj_response(),
  .ce_pixel_response(early_ce_response),
  .red(early_red),
  .green(early_green),
  .blue(early_blue),
  .hsj_rgb_nibbles(),
  .wave_rgb_bytes(),
  .hblank(early_hblank),
  .vblank(early_vblank),
  .hsync(early_hsync),
  .vsync(early_vsync),
  .hsj_scr_x(),
  .hsj_scr_y(),
  .hsj_pix_clk(),
  .hsj_vbl(),
  .hsj_sync(),
  .hsj_vs(),
  .hsj_hs(),
  .hsj_disp(),
  .wave_line_overruns(early_wave_overruns),
  .wave_busy_any(early_wave_busy),
  .supported());
 wire [10:0] vbg_addr,vtx_addr;wire [6:0] vspr_addr;
 wire [7:0] vbg_data,vtx_data;wire [31:0] vspr_data;
 wire [23:0] late_cpu_din,sports_cpu_din;wire [2:0] late_cpu_wait_n,late_cpu_irq_n,late_cpu_nmi_n,sports_cpu_wait_n,sports_cpu_irq_n,sports_cpu_nmi_n;
 wire [15:0] late_sound_bus_addr,sports_sound_bus_addr,sound_bus_addr;
 wire [7:0] late_sound_bus_data,sports_sound_bus_data,sound_bus_data,sound_din;
 wire late_sound_bus_mem,late_sound_bus_rd,late_sound_bus_wr,sports_sound_bus_mem,sports_sound_bus_rd,sports_sound_bus_wr,sound_bus_mem,sound_bus_rd,sound_bus_wr,sound_busy,sound_irq_n;
 assign early_sound_busy=early_valid&&(tnk_valid?sound_busy:early_sound_busy_internal);
 wire late_sound_command_wr,sports_sound_command_wr;wire [7:0] late_sound_command,sports_sound_command;
 wire [8:0] late_bg_x,late_bg_y,late_s16_x,late_s16_y,late_s32_x,late_s32_y,sports_bg_x,sports_bg_y,sports_s32_x,sports_s32_y,bg_x,bg_y,s16_x,s16_y,s32_x,s32_y;
 wire late_flip_screen,sports_flip_screen,flip_screen;wire [7:0] late_text_attrs,late_sprite_split,sports_text_attrs,text_attrs,sprite_split;
 wire [7:0] late_vbg_data,late_vtx_data,sports_vbg_data,sports_vtx_data;wire [31:0] late_vspr_data,sports_vspr_data;
 wire late_hs_ack,sports_hs_ack;wire [7:0] late_hs_rdata,sports_hs_rdata;
 wire late_coin_write,sports_coin_write;wire [7:0] late_coin_data,sports_coin_data;
 wire [15:0] late_debug_a_addr,late_debug_b_addr,late_debug_s_addr;
 wire [7:0] late_debug_a_data,late_debug_b_data,late_debug_s_data,late_debug_a_din,late_debug_b_din,late_debug_s_din;
 wire [4:0] late_debug_a_ctl,late_debug_b_ctl,late_debug_s_ctl;
 snk_late_cpu_bus #(.HISCORE_ENABLE(HISCORE_ENABLE)) bus(
 .profile_id(profile_id),
 .hs_grant(hs_grant),.hs_req(hs_req),.hs_write(hs_write),.hs_addr(hs_addr),
 .hs_wdata(hs_wdata),.hs_ack(late_hs_ack),.hs_rdata(late_hs_rdata),
 .clk(clk),.reset_n(reset_n&&late_valid),.vblank(vblank),
 .a_addr(cpu_addr[15:0]),.b_addr(cpu_addr[31:16]),.s_addr(cpu_addr[47:32]),
 .a_data(cpu_data[7:0]),.b_data(cpu_data[15:8]),.s_data(cpu_data[23:16]),
 .a_rom(cpu_rom[7:0]),.b_rom(cpu_rom[15:8]),.s_rom(cpu_rom[23:16]),
 .a_m1_n(cpu_m1_n[0]),.b_m1_n(cpu_m1_n[1]),.s_m1_n(cpu_m1_n[2]),
 .a_mreq_n(cpu_mreq_n[0]),.b_mreq_n(cpu_mreq_n[1]),.s_mreq_n(cpu_mreq_n[2]),
 .a_iorq_n(cpu_iorq_n[0]),.b_iorq_n(cpu_iorq_n[1]),.s_iorq_n(cpu_iorq_n[2]),
 .a_rd_n(cpu_rd_n[0]),.b_rd_n(cpu_rd_n[1]),.s_rd_n(cpu_rd_n[2]),
 .a_wr_n(cpu_wr_n[0]),.b_wr_n(cpu_wr_n[1]),.s_wr_n(cpu_wr_n[2]),
 .a_din(late_cpu_din[7:0]),.b_din(late_cpu_din[15:8]),.s_din(late_cpu_din[23:16]),
 .a_wait_n(late_cpu_wait_n[0]),.b_wait_n(late_cpu_wait_n[1]),.s_wait_n(late_cpu_wait_n[2]),
 .a_irq_n(late_cpu_irq_n[0]),.b_irq_n(late_cpu_irq_n[1]),.s_irq_n(late_cpu_irq_n[2]),
 .a_nmi_n(late_cpu_nmi_n[0]),.b_nmi_n(late_cpu_nmi_n[1]),.s_nmi_n(late_cpu_nmi_n[2]),
 .in0(in0),.in1(in1),.in2(in2),.in3(in3),.dsw1(dsw1),.dsw2(dsw2),
 .sound_busy(sound_busy),.sound_irq_n(sound_irq_n),.sound_din(sound_din),
 .sound_bus_addr(late_sound_bus_addr),.sound_bus_data(late_sound_bus_data),
 .sound_bus_mem(late_sound_bus_mem),.sound_bus_rd(late_sound_bus_rd),.sound_bus_wr(late_sound_bus_wr),
 .sound_command_wr(late_sound_command_wr),.sound_command(late_sound_command),
 .bg_x(late_bg_x),.bg_y(late_bg_y),.s16_x(late_s16_x),.s16_y(late_s16_y),.s32_x(late_s32_x),.s32_y(late_s32_y),
 .flip_screen(late_flip_screen),.text_attrs(late_text_attrs),.sprite_split(late_sprite_split),
 .coin_write(late_coin_write),.coin_data(late_coin_data),
 .vbg_addr(vbg_addr),.vtx_addr(vtx_addr),.vbg_data(late_vbg_data),.vtx_data(late_vtx_data),
 .vspr_addr(vspr_addr),.vspr_data(late_vspr_data),
 .debug_a_addr(late_debug_a_addr),.debug_b_addr(late_debug_b_addr),.debug_s_addr(late_debug_s_addr),
 .debug_a_data(late_debug_a_data),.debug_b_data(late_debug_b_data),.debug_s_data(late_debug_s_data),
 .debug_a_din(late_debug_a_din),.debug_b_din(late_debug_b_din),.debug_s_din(late_debug_s_din),
 .debug_a_ctl(late_debug_a_ctl),.debug_b_ctl(late_debug_b_ctl),.debug_s_ctl(late_debug_s_ctl));

 snk_sports_bus_hs #(.HISCORE_ENABLE(HISCORE_ENABLE)) sports_bus(
 .hs_grant(hs_grant&&sports_valid),.hs_req(hs_req&&sports_valid),.hs_write(hs_write),.hs_addr(hs_addr),.hs_wdata(hs_wdata),.hs_ack(sports_hs_ack),.hs_rdata(sports_hs_rdata),
 .clk(clk),.reset_n(reset_n&&sports_valid),.vblank(vblank),.profile_id(profile_id),.inputs(sports_inputs),.dsw1(dsw1),.dsw2(dsw2),
 .sound_busy(sound_busy),.sound_irq_n(sound_irq_n),.sound_din(sound_din),
 .a_addr(cpu_addr[15:0]),.b_addr(cpu_addr[31:16]),.s_addr(cpu_addr[47:32]),
 .a_data(cpu_data[7:0]),.b_data(cpu_data[15:8]),.s_data(cpu_data[23:16]),.a_rom(cpu_rom[7:0]),.b_rom(cpu_rom[15:8]),.s_rom(cpu_rom[23:16]),
 .a_m1_n(cpu_m1_n[0]),.a_mreq_n(cpu_mreq_n[0]),.a_iorq_n(cpu_iorq_n[0]),.a_rd_n(cpu_rd_n[0]),.a_wr_n(cpu_wr_n[0]),
 .b_m1_n(cpu_m1_n[1]),.b_mreq_n(cpu_mreq_n[1]),.b_iorq_n(cpu_iorq_n[1]),.b_rd_n(cpu_rd_n[1]),.b_wr_n(cpu_wr_n[1]),
 .s_m1_n(cpu_m1_n[2]),.s_mreq_n(cpu_mreq_n[2]),.s_iorq_n(cpu_iorq_n[2]),.s_rd_n(cpu_rd_n[2]),.s_wr_n(cpu_wr_n[2]),
 .a_din(sports_cpu_din[7:0]),.b_din(sports_cpu_din[15:8]),.s_din(sports_cpu_din[23:16]),
 .a_wait_n(sports_cpu_wait_n[0]),.b_wait_n(sports_cpu_wait_n[1]),.s_wait_n(sports_cpu_wait_n[2]),
 .a_irq_n(sports_cpu_irq_n[0]),.b_irq_n(sports_cpu_irq_n[1]),.s_irq_n(sports_cpu_irq_n[2]),
 .a_nmi_n(sports_cpu_nmi_n[0]),.b_nmi_n(sports_cpu_nmi_n[1]),.s_nmi_n(sports_cpu_nmi_n[2]),
 .sound_command_wr(sports_sound_command_wr),.sound_command(sports_sound_command),
 .sound_bus_addr(sports_sound_bus_addr),.sound_bus_data(sports_sound_bus_data),.sound_bus_mem(sports_sound_bus_mem),.sound_bus_rd(sports_sound_bus_rd),.sound_bus_wr(sports_sound_bus_wr),
 .bg_x(sports_bg_x),.bg_y(sports_bg_y),.s32_x(sports_s32_x),.s32_y(sports_s32_y),.flip_screen(sports_flip_screen),.text_attrs(sports_text_attrs),.coin_write(sports_coin_write),.coin_data(sports_coin_data),
 .video_addr(16'b0),.video_data(),.vbg_addr(vbg_addr),.vtx_addr(vtx_addr),.vbg_data(sports_vbg_data),.vtx_data(sports_vtx_data),.vspr_addr(vspr_addr[4:0]),.vspr_data(sports_vspr_data),
 .video_commit(),.video_commit_addr(),.video_commit_data(),.radar_commit());
 // TNK3-class sound CPU: reads of the virtual late sound map (command latch/OPL status/status register) come from the shared OPL block, its IRQ is the OPL IRQ.
 wire [23:0] early_cpu_din_x=(tnk_valid&&tnk_snd_audio_rd) ? {sound_din,early_cpu_din[15:0]} : early_cpu_din;
 wire [2:0] early_cpu_irq_n_x=tnk_valid ? {sound_irq_n,early_cpu_irq_n[1:0]} : early_cpu_irq_n;
 assign cpu_din=early_valid?early_cpu_din_x:sports_valid?sports_cpu_din:late_cpu_din;
 assign cpu_wait_n=early_valid?early_cpu_wait_n:sports_valid?sports_cpu_wait_n:late_cpu_wait_n;
 assign cpu_irq_n=early_valid?early_cpu_irq_n_x:sports_valid?sports_cpu_irq_n:late_cpu_irq_n;
 assign cpu_nmi_n=early_valid?early_cpu_nmi_n:sports_valid?sports_cpu_nmi_n:late_cpu_nmi_n;
 assign sound_bus_addr=tnk_valid?tnk_snd_addr:sports_valid?sports_sound_bus_addr:late_sound_bus_addr;
 assign sound_bus_data=tnk_valid?tnk_snd_data:sports_valid?sports_sound_bus_data:late_sound_bus_data;
 assign sound_bus_mem=tnk_valid?tnk_snd_mem:sports_valid?sports_sound_bus_mem:late_sound_bus_mem;
 assign sound_bus_rd=tnk_valid?tnk_snd_rd:sports_valid?sports_sound_bus_rd:late_sound_bus_rd;
 assign sound_bus_wr=tnk_valid?tnk_snd_wr:sports_valid?sports_sound_bus_wr:late_sound_bus_wr;
 assign sound_command_wr=tnk_valid?tnk_snd_cmd_wr:sports_valid?sports_sound_command_wr:late_sound_command_wr;
 assign sound_command=tnk_valid?tnk_snd_cmd:sports_valid?sports_sound_command:late_sound_command;
 assign bg_x=sports_valid?sports_bg_x:late_bg_x;
 assign bg_y=sports_valid?sports_bg_y:late_bg_y;
 assign s32_x=sports_valid?sports_s32_x:late_s32_x;
 assign s32_y=sports_valid?sports_s32_y:late_s32_y;
 assign flip_screen=sports_valid?sports_flip_screen:late_flip_screen;
 assign text_attrs=sports_valid?sports_text_attrs:late_text_attrs;
 assign vbg_data=sports_valid?sports_vbg_data:late_vbg_data;
 assign vtx_data=sports_valid?sports_vtx_data:late_vtx_data;
 assign vspr_data=sports_valid?sports_vspr_data:late_vspr_data;
 assign s16_x=sports_valid?9'd0:late_s16_x;assign s16_y=sports_valid?9'd0:late_s16_y;assign sprite_split=sports_valid?8'd0:late_sprite_split;
 // Both families borrow their scheduled CPU RAM port only while paused/drained.
 assign hs_ack=early_valid?early_hs_ack:late_valid?late_hs_ack:(sports_valid?sports_hs_ack:1'b0);assign hs_rdata=early_valid?early_hs_rdata:late_valid?late_hs_rdata:(sports_valid?sports_hs_rdata:8'hff);
 assign debug_a_addr=cpu_addr[15:0];
 assign debug_b_addr=cpu_addr[31:16];
 assign debug_s_addr=cpu_addr[47:32];
 assign debug_a_data=cpu_data[7:0];
 assign debug_b_data=cpu_data[15:8];
 assign debug_s_data=cpu_data[23:16];
 assign debug_a_din=cpu_din[7:0];
 assign debug_b_din=cpu_din[15:8];
 assign debug_s_din=cpu_din[23:16];
 assign debug_a_ctl={cpu_m1_n[0],cpu_mreq_n[0],cpu_iorq_n[0],cpu_rd_n[0],cpu_wr_n[0]};
 assign debug_b_ctl={cpu_m1_n[1],cpu_mreq_n[1],cpu_iorq_n[1],cpu_rd_n[1],cpu_wr_n[1]};
 assign debug_s_ctl={cpu_m1_n[2],cpu_mreq_n[2],cpu_iorq_n[2],cpu_rd_n[2],cpu_wr_n[2]};
 snk_union_opl_audio audio(
 .profile_id(profile_id),
 .clk(clk),.rst(!(board_reset_n||(reset_n&&tnk_valid))),.ce_opl(tnk_valid?early_s_p:ce_opl),
 .cpu_addr(sound_bus_addr),.cpu_din(sound_bus_data),
 .cpu_mem(sound_bus_mem),.cpu_rd(sound_bus_rd),.cpu_wr(sound_bus_wr),
 .cpu_dout(sound_din),.cpu_data_cs(),.cpu_irq_n(sound_irq_n),
 .cmd_data(sound_command),.cmd_wr(sound_command_wr),.cmd_busy(sound_busy),.sound_status(sound_status),
 .sample_addr(sample_addr),.sample_req(sample_req),.sample_data(sample_data),.sample_ack(sample_ack),
 .ym3526_pcm(ym3526_pcm),.y8950_pcm(y8950_pcm),
 .ym3526_sample(ym3526_sample),.y8950_sample(y8950_sample),
 .ym3526_irq_n(),.y8950_irq_n(),.adpcm_pcm(),.adpcm_valid(),.adpcm_status());
 // MAME Psycho routes each chip to mono at gain2. Preserve widened sum before
 // final signed16 saturation. Sports routes both present chips at unity.
 wire signed [16:0] chip_sum=$signed({ym3526_pcm[15],ym3526_pcm})+
                             $signed({y8950_pcm[15],y8950_pcm});
 wire signed [19:0] chip_sum_wide=$signed({{3{chip_sum[16]}},chip_sum});
 // The US Psycho Soldier set is documented as quieter than psychosj (MAME
 // issue 08153). Apply a Psycho-only +6 dB level trim after both chips so the
 // music and Y8950 effects rise together; preserve headroom by saturating below.
 wire signed [19:0] mixed=sports_valid ? chip_sum_wide : (profile_id==8'd16 ?
  $signed({{4{ym3526_pcm[15]}},ym3526_pcm})+($signed({{4{y8950_pcm[15]}},y8950_pcm}) <<< 1) :
  profile_id==8'd13 ? chip_sum_wide <<< 2 : chip_sum_wide <<< 1);
 // TNK3-class (6..10) has no AY: its sound is the shared OPL path (MAME ym1/ym2 gain 2.0)
 assign audio_mono=(early_valid&&profile_id<=8'd5) ? early_audio_mono : mixed>20'sd32767 ? 16'sh7fff :
  (mixed< -20'sd32768 ? 16'sh8000 : mixed[15:0]);
 wire legacy_hsync,legacy_vsync;wire [2:0] legacy_render_busy,legacy_line_overrun;
 wire active_h,active_v;wire [7:0] raw_r,raw_g,raw_b;
 snk_union_video #(.DISPLAY_FLIP_ENABLE(DISPLAY_FLIP_ENABLE)) video(
 .is_psychos(profile_id==8'd13),.is_sports(sports_valid),.is_ik(ikari_valid),.is_chopper(profile_id==8'd16),.big_sp16(profile_id==8'd19),.is_16m(profile_id==8'd11||profile_id==8'd12||profile_id==8'd13||profile_id==8'd19||sports_valid),
 .bg_tile_count(sports_valid ? 13'd2560 : 13'd2048),
 .display_flip(display_flip),.rst(!board_reset_n),.clk(clk),.pxl_cen(pxl_cen),
 .bg_scrollx(bg_x),.bg_scrolly(bg_y),.sp16_scrollx(s16_x),.sp16_scrolly(s16_y),
 .sp32_scrollx(s32_x),.sp32_scrolly(s32_y),.split(sprite_split),.txbank(text_attrs),.flip(flip_screen),
 .vbg_addr(vbg_addr),.vbg_data(vbg_data),.vtx_addr(vtx_addr),.vtx_data(vtx_data),.vspr_addr(vspr_addr),.vspr_data(vspr_data),
 .bgrom_addr(bgrom_addr),.bgrom_cs(bgrom_req),.bgrom_data(bgrom_data),.bgrom_ok(bgrom_ack),
 .s16rom_addr(s16rom_addr),.s16rom_cs(s16rom_req),.s16rom_data(s16rom_data),.s16rom_ok(s16rom_ack),
 .s32rom_addr(s32rom_addr),.s32rom_cs(s32rom_req),.s32rom_data(s32rom_data),.s32rom_ok(s32rom_ack),
 .blank_en(1'b0),.op16_addr(),.op16(1'b1),.op32_addr(),.op32(1'b1),
 .txrom_addr(txrom_addr),.txrom_data(txrom_data),.pal_addr(pal_addr),.palr(palr),.palg(palg),.palb(palb),
 .LHBL(active_h),.LVBL(active_v),.HS(legacy_hsync),.VS(legacy_vsync),.red(raw_r),.green(raw_g),.blue(raw_b),
 .gfx_en(4'b1111),.obj_cycles(),.render_busy(legacy_render_busy),.line_overrun(legacy_line_overrun));
 // HSJ / TNK3-class donor video (profiles 3..10) is re-emitted at a constant 14 clk/pixel = 6.7 MHz, 416x262 (clock plan R2); the CPU-side
 // IRQ keeps the donor vblank. Wave (0..2) already runs on the clk/14 integer pixel enable (416x262 group-B raster).
 wire hsj_fam=profile_id>=8'd3&&profile_id<=8'd10;
 wire [23:0] rt_rgb;wire rt_ce,rt_hb,rt_vb,rt_hs,rt_vs,rt_locked;
 snk_early_output_retimer #(.N(14),.MARGIN(3)) early_retimer(
  .clk(clk),.rst(!reset_n||!hsj_fam),.fill(profile_id==8'd6 ? 6'd0 : 6'd2),.in_ce(early_ce_response),.in_rgb({early_red,early_green,early_blue}),
  .in_hb(early_hblank),.in_vb(early_vblank),.in_hs(early_hsync),.in_vs(early_vsync),
  .out_ce(rt_ce),.out_rgb(rt_rgb),.out_hb(rt_hb),.out_vb(rt_vb),.out_hs(rt_hs),.out_vs(rt_vs),.locked(rt_locked));
 wire early_hblank_o=hsj_fam?rt_hb:early_hblank,early_vblank_o=hsj_fam?rt_vb:early_vblank;
 wire early_hsync_o=hsj_fam?rt_hs:early_hsync,early_vsync_o=hsj_fam?rt_vs:early_vsync;
 wire early_ce_o=hsj_fam?rt_ce:early_ce_response;
 wire [7:0] early_red_o=hsj_fam?rt_rgb[23:16]:early_red,early_green_o=hsj_fam?rt_rgb[15:8]:early_green,early_blue_o=hsj_fam?rt_rgb[7:0]:early_blue;
 assign hblank=early_valid?early_hblank_o:!active_h;assign vblank=early_valid?early_vblank_o:!active_v;
 assign hsync=early_valid?early_hsync_o:legacy_hsync;assign vsync=early_valid?early_vsync_o:legacy_vsync;
 assign render_busy=early_valid?{2'b0,early_wave_busy}:legacy_render_busy;
 assign line_overrun=early_valid?{2'b0,|early_wave_overruns}:legacy_line_overrun;
 assign pixel_response_ce=early_valid?early_ce_o:pxl_cen;
 // Fill the alternating line buffers before exposing the first full frame.
 reg seen_active,frame_primed;
 always @(posedge clk) begin
  if(!board_reset_n)begin seen_active<=0;frame_primed<=0;end
  else begin
   if(active_v)seen_active<=1;
   if(seen_active&&!active_v)frame_primed<=1;
  end
 end
 assign red=early_valid?early_red_o:frame_primed ? raw_r : 8'd0;
 assign green=early_valid?early_green_o:frame_primed ? raw_g : 8'd0;
 assign blue=early_valid?early_blue_o:frame_primed ? raw_b : 8'd0;
endmodule
