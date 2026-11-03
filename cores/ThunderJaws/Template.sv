// SPDX-License-Identifier: GPL-3.0-or-later
module emu (
 `include "sys/emu_ports.vh"
);
 `include "build_id.v"
 localparam CRT_HSIZE_MIN=-2,CRT_HSIZE_MAX=2,CRT_HPOS_MIN=-32,CRT_HPOS_MAX=31,CRT_VPOS_MIN=-16,CRT_VPOS_MAX=15;
 `include "donors/framework/rtl/heavyunit_crt_menu.vh"
 `ifdef MISTER_FB
 localparam ROTATION_AVAILABLE=1'b1;
 `else
 localparam ROTATION_AVAILABLE=1'b0;
 `endif
 localparam CONF_STR={"ThunderJaws;;","P1,Video;",
 "P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
 "H0P1O[47:46],Scaling,Normal,V-Integer,HV-Integer;",
 "H1P1O[52:50],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
 "H2P1O[45:44],Rotation,Normal,CW 90,CCW 90,180;",
 "P1O[53],Flip screen,Off,On;",
 "P1O[54],CRT Adjust,Off,On;",
 "P1O[59:55],H-Size,",CRT_HSIZE_OPTIONS,";",
 "P1O[66:60],H-Position,",CRT_HPOS_OPTIONS,";",
 "P1O[71:67],V-Shift,",CRT_VPOS_OPTIONS,";",
 "P2,Game;","P2O[41],Pause when OSD is open,Off,On;",
 "P2O[42],Autosave high scores,On,Off;","P2O[43],Service test,Off,On;",
 "P2-,Game settings are in Service test;","-;",
 "J1,Start/Fire,Jump,Start,Coin,Pause,Service;",
 "T[0],Reset;","R[0],Reset and close OSD;","v,1;","V,v",`BUILD_DATE};
 wire clk_sys,clk_sdram,locked;
 thunderjaws_pll pll(.refclk(CLK_50M),.rst(1'b0),.outclk_0(clk_sys),.outclk_1(clk_sdram),.locked(locked));
 reg [2:0] init_pipe=3'b111;
 always @(posedge clk_sys or negedge locked)
  if(!locked)init_pipe<=3'b111;else init_pipe<={init_pipe[1:0],1'b0};
 wire init_reset=init_pipe[2];
 wire [127:0] status;wire [1:0] buttons;
 wire [31:0] joystick_0,joystick_1;wire [10:0] ps2_key;
 wire forced_scandoubler,direct_video;wire [21:0] gamma_bus;
 wire ioctl_download,ioctl_upload,ioctl_wr;wire [15:0] ioctl_index;
 wire [26:0] ioctl_addr;wire [7:0] ioctl_dout,ioctl_din;
 wire loader_wait,nv_wait,nv_upload_request;
 wire native_direct=direct_video && !forced_scandoubler;
 wire rotate90=ROTATION_AVAILABLE && !direct_video && (status[45:44]==1 || status[45:44]==2);
 hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps_io(
 .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(gamma_bus),
 .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),
 .buttons(buttons),.status(status),.status_menumask({13'd0,direct_video || !ROTATION_AVAILABLE,native_direct,direct_video}),.video_rotated(rotate90),
 .joystick_0(joystick_0),.joystick_1(joystick_1),.ps2_key(ps2_key),
 .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),
 .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),
 .ioctl_wait(init_reset || loader_wait || nv_wait),.ioctl_din(ioctl_din),
 .ioctl_upload_req(nv_upload_request),.ioctl_upload_index(8'd4));
 wire [3:0] p1_directions,p2_directions;wire [1:0] p1_buttons,p2_buttons;
 wire [2:0] coin;wire service_test,user_pause;
 thunderjaws_controls controls(.clk_sys(clk_sys),.init_reset(init_reset),.service_menu(status[43]),
 .joystick_0(joystick_0),.joystick_1(joystick_1),.ps2_key(ps2_key),
 .p1_directions(p1_directions),.p2_directions(p2_directions),.p1_buttons(p1_buttons),.p2_buttons(p2_buttons),
 .coin(coin),.service_test(service_test),.pause_request(user_pause));
 wire paused,hs_pause,nv_pause,score_busy,score_signature,score_error;
 wire hs_read,hs_write,score_data_ready;wire [23:0] hs_ram_address;
 wire [7:0] hs_ram_write_data,hs_ram_read_data;
 wire nv_restore,nv_restore_pending,ep_we,ep_modified,nv_dirty,nv_error;
 wire [10:0] ep_load_address,ep_dump_address;wire [7:0] ep_load_data,ep_dump_data;
 wire hs_upload,hs_download,hs_wr,hs_upload_request,hs_configured;
 wire [24:0] hs_address;wire [7:0] hs_index,hs_data,hs_upload_data;
 wire rom_loaded,load_error;
 reg reset_pending=1;
 wire reset_requested=RESET || status[0] || buttons[1];
 wire service_idle=!hs_pause && !score_busy;
 wire logical_reset=reset_pending && service_idle;
 always @(posedge clk_sys)begin
  if(init_reset || reset_requested)reset_pending<=1;
  else if(logical_reset)reset_pending<=0;
 end
 // Drain an existing score transaction before resetting the engine for restore.
 wire restore_barrier=nv_restore_pending && service_idle;
 wire game_reset=logical_reset || nv_restore;
 wire video_ce,video_de,video_fault,watchdog_expired;
 wire [8:0] video_h,video_v,beam_h,beam_v;wire [7:0] video_r,video_g,video_b;
 thunderjaws_board board(.clk_sys(clk_sys),.clk_sdram(clk_sdram),.init_reset(init_reset),.flip_request(status[53] || (!direct_video && status[45:44]==3)),.game_reset(game_reset),
 .pause_request(user_pause || (OSD_STATUS && status[41]) || hs_pause || nv_pause),.paused(paused),
 .score_read(hs_read),.score_write(hs_write),.score_address(hs_ram_address),.score_write_data(hs_ram_write_data),
 .score_read_data(hs_ram_read_data),.score_data_ready(score_data_ready),.score_signature_ready(score_signature),
 .score_busy(score_busy),.score_error(score_error),
 .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),.ioctl_index(ioctl_index),
 .ioctl_wait(loader_wait),.rom_loaded(rom_loaded),.load_error(load_error),
 .p1_buttons(p1_buttons),.p2_buttons(p2_buttons),.p1_directions(p1_directions),.p2_directions(p2_directions),.service_test(service_test),.coin(coin),
 .eeprom_restore(nv_restore),.eeprom_load_we(ep_we),.eeprom_load_address(ep_load_address),.eeprom_dump_address(ep_dump_address),
 .eeprom_load_data(ep_load_data),.eeprom_dump_data(ep_dump_data),.eeprom_modified(ep_modified),
 .video_ce(video_ce),.video_de(video_de),.video_h(video_h),.video_v(video_v),.beam_h(beam_h),.beam_v(beam_v),
 .video_r(video_r),.video_g(video_g),.video_b(video_b),.audio_l(AUDIO_L),.audio_r(AUDIO_R),
 .video_fault(video_fault),.watchdog_expired(watchdog_expired),
 .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_CLK(SDRAM_CLK),
 .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_CKE(SDRAM_CKE),
 .SDRAM_nCS(SDRAM_nCS),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nWE(SDRAM_nWE));
 thunderjaws_hiscore scores(.clk_sys(clk_sys),.game_reset(game_reset || restore_barrier),
 .rom_loading(!rom_loaded),.signature_ready(score_signature),.paused(paused),
 .autosave(!status[42] && !nv_restore_pending),.osd_status(OSD_STATUS && !nv_restore_pending),.v_sync(raw_vs),
 .ioctl_upload(hs_upload),.ioctl_download(hs_download),.ioctl_wr(hs_wr),.ioctl_addr(hs_address),.ioctl_index(hs_index),.ioctl_data(hs_data),
 .upload_request(hs_upload_request),.configured(hs_configured),.pause_request(hs_pause),.upload_data(hs_upload_data),
 .ram_read(hs_read),.ram_write(hs_write),.ram_address(hs_ram_address),.ram_write_data(hs_ram_write_data),
 .ram_read_data(hs_ram_read_data),.ram_data_ready(score_data_ready));
 thunderjaws_nvram persistence(.clk_sys(clk_sys),.init_reset(init_reset),.osd_status(OSD_STATUS),.autosave(!status[42]),
 .paused(paused),.can_restore(service_idle),.ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),
 .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_data(ioctl_dout),.ioctl_wait(nv_wait),
 .upload_request(nv_upload_request),.upload_data(ioctl_din),.pause_request(nv_pause),.restore(nv_restore),.restore_pending(nv_restore_pending),
 .load_we(ep_we),.load_address(ep_load_address),.load_data(ep_load_data),.dump_address(ep_dump_address),.dump_data(ep_dump_data),
 .eeprom_modified(ep_modified),.dirty(nv_dirty),.storage_error(nv_error),
 .hs_upload_request(hs_upload_request),.hs_pause_request(hs_pause),.hs_configured(hs_configured),.signature_ready(score_signature),
 .hs_upload_data(hs_upload_data),.hs_upload(hs_upload),.hs_download(hs_download),.hs_wr(hs_wr),.hs_address(hs_address),.hs_index(hs_index),.hs_data(hs_data));
 wire raw_ce,raw_de,raw_hb,raw_vb,raw_hs,raw_vs;wire [7:0] raw_r,raw_g,raw_b;
 wire [8:0] raw_h,raw_v;
 thunderjaws_video_timing timing(.clk_sys(clk_sys),.init_reset(init_reset),.ce_in(video_ce),.de_in(video_de),
 .h_in(video_h),.v_in(video_v),.r_in(video_r),.g_in(video_g),.b_in(video_b),
 .ce_out(raw_ce),.de_out(raw_de),.hblank(raw_hb),.vblank(raw_vb),.hsync(raw_hs),.vsync(raw_vs),.r_out(raw_r),.g_out(raw_g),.b_out(raw_b),.h_out(raw_h),.v_out(raw_v));
 wire signed [4:0] crt_size=5'(crt_menu_decode(int'(status[59:55]),CRT_HSIZE_MIN,CRT_HSIZE_MAX,5));
 wire signed [6:0] crt_horizontal=7'(crt_menu_decode(int'(status[66:60]),CRT_HPOS_MIN,CRT_HPOS_MAX,7));
 wire signed [4:0] crt_vertical=5'(crt_menu_decode(int'(status[71:67]),CRT_VPOS_MIN,CRT_VPOS_MAX,5));
 wire rotation_overflow,fb_enable;wire [4:0] fb_format;wire [11:0] fb_width,fb_height;wire [31:0] fb_base;wire [13:0] fb_stride;
 wire fb_blank;
 `ifdef MISTER_FB
 assign fb_blank=FB_VBL;
 `else
 assign fb_blank=1'b0;
 `endif
 thunderjaws_video_output presentation(.clk_sys(clk_sys),.init_reset(init_reset),.raw_ce(raw_ce),.raw_de(raw_de),.raw_hs(raw_hs),.raw_vs(raw_vs),
 .raw_h(raw_h),.raw_v(raw_v),.raw_rgb({raw_r,raw_g,raw_b}),.crt_enable(status[54]),.crt_size(crt_size),.crt_horizontal(crt_horizontal),.crt_vertical(crt_vertical),
 .direct_video(direct_video),.forced_scandoubler(forced_scandoubler),.effect(status[52:50]),.aspect_choice(status[122:121]),.scale_mode(status[47:46]),
 .rotate90(rotate90),.rotate_ccw(status[45:44]==2),.hdmi_width(HDMI_WIDTH),.hdmi_height(HDMI_HEIGHT),.gamma_bus(gamma_bus),
 .ce_pixel(CE_PIXEL),.vga_de(VGA_DE),.vga_hs(VGA_HS),.vga_vs(VGA_VS),.vga_rgb({VGA_R,VGA_G,VGA_B}),.vga_sl(VGA_SL),.video_arx(VIDEO_ARX),.video_ary(VIDEO_ARY),
 .fb_vblank(fb_blank),.ddram_busy(DDRAM_BUSY),.fb_enable(fb_enable),.fb_format(fb_format),.fb_width(fb_width),.fb_height(fb_height),.fb_base(fb_base),.fb_stride(fb_stride),
 .ddram_clk(DDRAM_CLK),.ddram_we(DDRAM_WE),.ddram_rd(DDRAM_RD),.ddram_address(DDRAM_ADDR),.ddram_data(DDRAM_DIN),
 .ddram_byteenable(DDRAM_BE),.ddram_burstcount(DDRAM_BURSTCNT),.rotation_overflow(rotation_overflow));
 assign CLK_VIDEO=clk_sys;
 assign AUDIO_S=1'b1;assign AUDIO_MIX=0;
 assign LED_USER=ioctl_download || nv_upload_request || load_error || nv_error || score_error || video_fault || rotation_overflow;
 assign LED_DISK=0;assign LED_POWER=0;assign BUTTONS=0;
 assign ADC_BUS='Z;assign USER_OUT='1;assign {UART_RTS,UART_TXD,UART_DTR}=0;assign {SD_SCK,SD_MOSI,SD_CS}='Z;
 assign VGA_F1=0;assign VGA_SCALER=0;assign VGA_DISABLE=0;
 assign HDMI_FREEZE=0;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
 `ifdef MISTER_FB
 assign FB_EN=fb_enable;assign FB_FORMAT=fb_format;assign FB_WIDTH=fb_width;assign FB_HEIGHT=fb_height;assign FB_BASE=fb_base;assign FB_STRIDE=fb_stride;
 assign FB_FORCE_BLANK=0;
 `ifdef MISTER_FB_PALETTE
 assign FB_PAL_CLK=0;assign FB_PAL_ADDR=0;assign FB_PAL_DOUT=0;assign FB_PAL_WR=0;
 `endif
 `endif
 `ifdef MISTER_DUAL_SDRAM
 assign {SDRAM2_CLK,SDRAM2_A,SDRAM2_BA,SDRAM2_DQ,SDRAM2_nCS,SDRAM2_nCAS,SDRAM2_nRAS,SDRAM2_nWE}='Z;
 `endif
endmodule

