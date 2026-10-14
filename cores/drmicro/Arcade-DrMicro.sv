// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Template_MiSTer emu interface (GPL-2.0-or-later).
module emu (
 `include "sys/emu_ports.vh"
);
 import drmicro_pkg::*;
 assign ADC_BUS='z;assign USER_OUT='1;
 assign {UART_RTS,UART_TXD,UART_DTR}=3'd0;
 assign {SD_SCK,SD_MOSI,SD_CS}=3'bzzz;
 assign {SDRAM_DQ,SDRAM_A,SDRAM_BA,SDRAM_CLK,SDRAM_CKE,SDRAM_DQML,SDRAM_DQMH,SDRAM_nWE,SDRAM_nCAS,SDRAM_nRAS,SDRAM_nCS}='z;
 assign VGA_F1=0;assign VGA_SCALER=0;assign VGA_DISABLE=0;
 assign HDMI_FREEZE=0;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
 assign AUDIO_S=1;assign AUDIO_MIX=0;assign AUDIO_R=AUDIO_L;
 assign LED_DISK=0;assign LED_POWER=0;assign BUTTONS=0;
 wire [127:0] status;wire [1:0] buttons;wire [10:0] ps2_key;
 wire [31:0] joy0,joy1;wire forced_scandoubler,direct_video,rotated;
 wire [21:0] gamma_bus;
 wire [35:0] ext_bus;
 assign ext_bus[32]=1'b0;assign ext_bus[15:0]=16'd0;
 wire download,wr;wire [15:0] index;wire [26:0] address;wire [7:0] data;
 localparam CONF_STR={"DrMicro;;","O[2],Orientation,Vertical,Native;","O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
 "O[7:6],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];","DIP;","-;","T[0],Reset;","R[0],Reset and close OSD;",
 "J1,Action,Start 1,Start 2,Coin,Service;","jn,A,Start,Select,R,L;","V,Source development;"};
 hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps(
  .joystick_2(),
  .joystick_3(),
  .joystick_4(),
  .joystick_5(),
  .joystick_l_analog_0(),
  .joystick_l_analog_1(),
  .joystick_l_analog_2(),
  .joystick_l_analog_3(),
  .joystick_l_analog_4(),
  .joystick_l_analog_5(),
  .joystick_r_analog_0(),
  .joystick_r_analog_1(),
  .joystick_r_analog_2(),
  .joystick_r_analog_3(),
  .joystick_r_analog_4(),
  .joystick_r_analog_5(),
  .paddle_0(),
  .paddle_1(),
  .paddle_2(),
  .paddle_3(),
  .paddle_4(),
  .paddle_5(),
  .spinner_0(),
  .spinner_1(),
  .spinner_2(),
  .spinner_3(),
  .spinner_4(),
  .spinner_5(),
  .ps2_kbd_clk_out(),
  .ps2_kbd_data_out(),
  .ps2_mouse_clk_out(),
  .ps2_mouse_data_out(),
  .ps2_mouse(),
  .ps2_mouse_ext(),
  .img_mounted(),
  .img_readonly(),
  .img_size(),
  .sd_ack(),
  .sd_buff_addr(),
  .sd_buff_dout(),
  .sd_buff_wr(),
  .ioctl_upload(),
  .ioctl_rd(),
  .ioctl_file_ext(),
  .sdram_sz(),
  .RTC(),
  .TIMESTAMP(),
  .uart_mode(),
  .uart_speed(),
  .clk_sys(CLK_50M),.HPS_BUS(HPS_BUS),.EXT_BUS(ext_bus),.gamma_bus(gamma_bus),
  .joystick_0(joy0),.joystick_1(joy1),.ps2_key(ps2_key),
  .buttons(buttons),.status(status),.status_in(128'd0),.status_set(1'b0),.status_menumask(16'd0),
  .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),.video_rotated(rotated),.new_vmode(1'b0),
  .ioctl_download(download),.ioctl_wr(wr),.ioctl_index(index),.ioctl_addr(address),.ioctl_dout(data),
  .ioctl_wait(1'b0),.ioctl_upload_req(1'b0),.ioctl_upload_index(8'd0),.ioctl_din(8'd0),
  .info_req(1'b0),.info(8'd0),.sd_rd(1'b0),.sd_wr(1'b0),.sd_lba('{32'd0}),.sd_blk_cnt('{6'd0}),.sd_buff_din('{8'd0}),
  .joystick_0_rumble(16'd0),.joystick_1_rumble(16'd0),.joystick_2_rumble(16'd0),.joystick_3_rumble(16'd0),.joystick_4_rumble(16'd0),.joystick_5_rumble(16'd0),
  .ps2_kbd_clk_in(1'b1),.ps2_kbd_data_in(1'b1),.ps2_mouse_clk_in(1'b1),.ps2_mouse_data_in(1'b1),.ps2_kbd_led_status(3'd0),.ps2_kbd_led_use(3'd0)
 );
 logic [7:0] dip1=DIP1_DEFAULT,dip2=DIP2_DEFAULT;
 always_ff @(posedge CLK_50M) if(download&&wr&&index==254)begin
  if(address==0)dip1<=data;
  if(address==1)dip2<=data;
 end
 wire [7:0] r,g,b;wire hs,vs,hb,vb,ce,loaded,load_error,running;
 drmicro_core board(.clk(CLK_50M),.cold_reset(RESET),.game_reset(status[0]|buttons[1]),
  .download(download),.ioctl_wr(wr),.ioctl_index(index),.ioctl_addr(address),.ioctl_data(data),
  .joy0(joy0),.joy1(joy1),.ps2_key(ps2_key),.dip1(dip1),.dip2(dip2),
  .loaded(loaded),.load_error(load_error),.running(running),.red(r),.green(g),.blue(b),.hs(hs),.vs(vs),.hblank(hb),.vblank(vb),.pixel_ce(ce),.audio(AUDIO_L),
  .debug_x(),.debug_y(),.debug_addr(),.debug_data(),.debug_io_write(),.debug_mem_write(),.debug_fetch(),.debug_nmi(),.debug_halt(),.deadline_error(),.psg0(),.psg1(),.psg2(),.adpcm(),.debug_pen());
 assign LED_USER=download|load_error;
 wire native_mode=status[2]|direct_video;
 assign VIDEO_ARX=status[7:6]==0?(native_mode?13'd4:13'd3):{11'd0,status[7:6]}-13'd1;
 assign VIDEO_ARY=status[7:6]==0?(native_mode?13'd3:13'd4):13'd0;
 arcade_video #(.WIDTH(256),.DW(24),.GAMMA(1)) av(.clk_video(CLK_50M),.ce_pix(ce),.RGB_in({r,g,b}),.HBlank(hb),.VBlank(vb),.HSync(hs),.VSync(vs),
  .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),.VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),.VGA_SL(VGA_SL),.fx(status[5:3]),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus));
 `ifdef MISTER_FB
 assign FB_FORCE_BLANK=0;
 screen_rotate rotation(.CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),.VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),
  .rotate_ccw(1'b1),.no_rotate(native_mode),.flip(1'b0),.video_rotated(rotated),
  .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),.FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
  .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),.DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE),.DDRAM_RD(DDRAM_RD));
 `else
 assign rotated=0;
 assign {DDRAM_CLK,DDRAM_BURSTCNT,DDRAM_ADDR,DDRAM_DIN,DDRAM_BE,DDRAM_RD,DDRAM_WE}='0;
 `endif
endmodule
