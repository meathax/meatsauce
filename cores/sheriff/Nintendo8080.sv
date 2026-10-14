//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);


// Sheriff board, controls, sound and MiSTer video/persistence integration.
// Final simulation, exact-source timing and hardware qualification are pending.
assign ADC_BUS='Z;
assign USER_OUT='1;
assign {UART_RTS,UART_TXD,UART_DTR}=0;
assign {SD_SCK,SD_MOSI,SD_CS}='Z;
assign {SDRAM_DQ,SDRAM_A,SDRAM_BA,SDRAM_CLK,SDRAM_CKE,SDRAM_DQML,SDRAM_DQMH,SDRAM_nWE,SDRAM_nCAS,SDRAM_nRAS,SDRAM_nCS}='Z;
assign VGA_F1=0;
assign VGA_SCALER=0;
assign VGA_DISABLE=0;
assign HDMI_FREEZE=0;
assign HDMI_BLACKOUT=0;
assign HDMI_BOB_DEINT=0;
assign AUDIO_S=1;
assign AUDIO_L=game_paused ? 16'd0 : board_audio;
assign AUDIO_R=game_paused ? 16'd0 : board_audio;
assign AUDIO_MIX=0;
assign LED_DISK=0;
assign LED_POWER=0;
assign BUTTONS=0;

`include "build_id.v"
localparam CONF_STR={
    "Sheriff;;",
    "F,Sheriff ROM;",
    "P1,DIP switches;",
    "P1O[9:8],Lives,3,4,5,6;",
    "P1O[10],Cabinet,Upright,Cocktail;",
    "P1O[36],Unused SW1:3,Off,On;",
    "P1O[37],Unused SW1:4,Off,On;",
    "P1O[38],Unused SW1:5,Off,On;",
    "P1O[39],Unused SW1:6,Off,On;",
    "P1O[40],Unused SW1:7,Off,On;",
    "O[11],Aiming,Directions,Rotate;",
    "H1O[12],Orientation,Vertical,Horizontal;",
    "H1O[31],90 Degree Rotation,CCW,CW;",
    "O[32],Rotate 180,Off,On;",
    "H1O[35:33],Scale,Normal,V-Integer,HV-Integer-,HV-Integer+,HV-Integer;",
    "O[15:13],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "H1O[16],CRT Adjust,Off,On;",
    "H2O[20:17],CRT H-Size,0,+1,+2,+3,+4,-1,-2,-3,-4;",
    "H2O[24:21],CRT H-Position,0,+4,+8,+12,+16,-4,-8,-12,-16;",
    "H2O[28:25],CRT V-Position,0,+1,+2,+3,+4,-1,-2,-3,-4;",
    "H0O[29],Autosave Hiscore,On,Off;",
    "O[30],Pause,Off,On;",
    "J,Fire,Start 1,Start 2,Coin,Aim Right,Aim Left,Aim Up,Aim Down,Pause;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "V,v",`BUILD_DATE
};
wire clk_sys,pll_locked;
pll pll(.refclk(CLK_50M),.rst(1'b0),.outclk_0(clk_sys),.locked(pll_locked));
wire [127:0] status;
wire [1:0] buttons;
wire [31:0] joy0,joy1;
wire [15:0] analog_l0,analog_l1,analog_r0,analog_r1;
wire [10:0] ps2_key;
wire board_paused;
wire hs_pause,hs_configured,ioctl_upload,hs_upload_req;
wire [15:0] hs_address;
wire [7:0] hs_from_ram,hs_to_ram,hs_to_hps;
wire hs_write,hs_read_intent,hs_write_intent;
wire game_paused=board_paused||hs_pause||status[30];
wire forced_scandoubler,video_rotated,direct_video;
wire [21:0] gamma_bus;
wire ioctl_download,ioctl_wr;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout;
wire [15:0] ioctl_index;
hps_io #(.CONF_STR(CONF_STR)) hps_io(
    .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(gamma_bus),
    .status(status),.buttons(buttons),.joystick_0(joy0),.joystick_1(joy1),
    .joystick_l_analog_0(analog_l0),.joystick_l_analog_1(analog_l1),
    .joystick_r_analog_0(analog_r0),.joystick_r_analog_1(analog_r1),.ps2_key(ps2_key),
    .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),.video_rotated(video_rotated),
    .status_menumask({13'b0,(!status[16]||direct_video),direct_video,!hs_configured}),
    .ioctl_upload(ioctl_upload),.ioctl_upload_req(hs_upload_req),.ioctl_upload_index(8'd4),.ioctl_din(hs_to_hps),
    .ioctl_download(ioctl_download),.ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),.ioctl_index(ioctl_index),.ioctl_wr(ioctl_wr)
);
wire loading=ioctl_download && ioctl_index==0;
wire loading_persistence=ioctl_download && (ioctl_index==3 || ioctl_index==4);
reg was_loading=0,rom_loaded=0;
reg [7:0] reset_stretch=0;
always @(posedge clk_sys) begin
    was_loading<=loading;
    if (was_loading && !loading) rom_loaded<=1;
    if (RESET || status[0] || buttons[1] || loading || loading_persistence || !pll_locked || !rom_loaded)
        reset_stretch<=0;
    else if (reset_stretch!=255) reset_stretch<=reset_stretch+1'b1;
end
wire reset=reset_stretch!=255;
wire [7:0] input0,input1,input2;
n8080_controls controls(
    .clk(clk_sys),.reset(reset),.joy0(joy0),.joy1(joy1),
    .analog_l0(analog_l0),.analog_l1(analog_l1),.analog_r0(analog_r0),.analog_r1(analog_r1),
    .ps2_key(ps2_key),.rotate_aim(status[11]),.input0(input0),.input1(input1),.input2(input2),.paused(board_paused)
);
wire [7:0] input3={!status[10],~status[40:36],status[9:8]};
wire [2:0] board_rgb;
wire signed [15:0] board_audio;
wire board_ce;
wire board_hblank,board_vblank,board_hsync,board_vsync;
hiscore #(.HS_ADDRESSWIDTH(16),.HS_SCOREWIDTH(2),.CFG_ADDRESSWIDTH(1)) persistence (
    .clk(clk_sys),.reset(reset),.paused(game_paused),.autosave(!status[29]),
    .ioctl_upload(ioctl_upload),.ioctl_upload_req(hs_upload_req),
    .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr[24:0]),.ioctl_index(ioctl_index[7:0]),
    .OSD_STATUS(OSD_STATUS),.data_from_hps(ioctl_dout),.data_from_ram(hs_from_ram),
    .ram_address(hs_address),.data_to_hps(hs_to_hps),.data_to_ram(hs_to_ram),.ram_write(hs_write),
    .ram_intent_read(hs_read_intent),.ram_intent_write(hs_write_intent),
    .pause_cpu(hs_pause),.configured(hs_configured)
);
n8080_board board(
    .clk(clk_sys),.reset(reset),.pause(game_paused),.flip_screen(status[32]),
    .input0(input0),.input1(input1),.input2(input2),.input3(input3),
    .load_wr(ioctl_wr && loading),.load_addr(ioctl_addr[15:0]),.load_data(ioctl_dout),
    .debug_req(hs_read_intent||hs_write_intent),.debug_freeze(1'b0),.debug_wr(hs_write),
    .debug_addr(hs_address[13:0]),.debug_dout(hs_to_ram),.debug_data(hs_from_ram),
    .ce_pixel(board_ce),.pixel_x(),.pixel_y(),.rgb(board_rgb),
    .hblank(board_hblank),.vblank(board_vblank),.hsync(board_hsync),.vsync(board_vsync),
    .cpu_address(),.cpu_dout(),.cpu_din(),.cpu_status(),
    .cpu_sync(),.cpu_dbin(),.cpu_wr_n(),.cpu_inte(),.cpu_read(),.cpu_write(),.cpu_ack(),
    .irq(),.irq_vector(),.sound1(),.sound2(),.color_mode(),.color_data(),.flip(),.shift_data(),.shift_count(),
    .audio(board_audio),.audio_ce(),.sound_dac(),.sound_pc(),.sound_p1(),.sound_p2()
);
wire video_de;
n8080_video video (
    .clk(clk_sys),.reset(reset),.ce_native(board_ce),.rgb(board_rgb),
    .hblank(board_hblank),.vblank(board_vblank),.hsync(board_hsync),.vsync(board_vsync),
    .effects(status[15:13]),.forced_scandoubler(forced_scandoubler),.crt_enabled(status[16]&&!direct_video),
    .hsize_setting(status[20:17]),.hpos_setting(status[24:21]),.vpos_setting(status[28:25]),.gamma_bus(gamma_bus),
    .clk_video(CLK_VIDEO),.ce_video(CE_PIXEL),.red(VGA_R),.green(VGA_G),.blue(VGA_B),
    .hs(VGA_HS),.vs(VGA_VS),.de(video_de),.scanlines(VGA_SL)
);
`ifdef MISTER_FB
assign FB_FORCE_BLANK=reset;
n8080_rotation rotation (
    .RESET(reset),.overflow(),
    .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
    .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),
    .rotate_ccw(!status[31]),.no_rotate(status[12]||direct_video),.flip(1'b0),.video_rotated(video_rotated),
    .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
    .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
    .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR),.DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE),.DDRAM_RD(DDRAM_RD)
);
`else
assign video_rotated=0;
assign {DDRAM_CLK,DDRAM_BURSTCNT,DDRAM_ADDR,DDRAM_DIN,DDRAM_BE,DDRAM_RD,DDRAM_WE}='0;
`endif
// Scale dimensions follow the framebuffer orientation; DE/sync stay native.
n8080_scaling scaling (
    .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE_IN(video_de),.VGA_DE(VGA_DE),
    .VIDEO_ARX(VIDEO_ARX),.VIDEO_ARY(VIDEO_ARY),
    .ARX(video_rotated ? 12'd3 : 12'd4),.ARY(video_rotated ? 12'd4 : 12'd3),
    .CROP_SIZE(12'd0),.CROP_OFF(5'd0),
    .SCALE(direct_video ? 3'd0 : status[35:33]),.rotated(video_rotated)
);
assign LED_USER=loading;
endmodule
