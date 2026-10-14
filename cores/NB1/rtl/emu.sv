//============================================================================
//  Namco ND-1 (Namco Classic Collection Vol.1 / Vol.2) for MiSTer.
//
//  The machine (rtl/nd1/*) and the SDRAM partition (rtl/mem/*) are the
//  Analogue Pocket core by plasticbugs (github.com/plasticbugs/
//  analogue-pocket-namco-volume-1, f290879), used with the author's
//  permission. This file replaces its Pocket platform layer with the MiSTer
//  framework (Template_MiSTer sys/).
//
//  Clocks: clk_sys = 96 MHz (the donor's proven rate and clock-enable ratios),
//  clk_sdram = 96 MHz phase-shifted for the SDRAM pin. CLK_VIDEO = clk_sys with
//  CE_PIXEL = the core's 6.4 MHz pixel enable (one clock domain).
//
//  ioctl: index 0 = the 7.5 MB flat ROM image (mra/*.mra), index 4 = the
//  2 KB AT28C16 EEPROM (MRA <nvram index="4" size="2048"/>).
//============================================================================
module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign FB_FORCE_BLANK = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;
assign AUDIO_MIX = 0;

//////////////////////////////////////////////////////////////////

// Orientation: the ND-1 monitor is vertical (MAME ROT90). "Horz" and direct video
// (CRT / RetroTink-4K via DV1) pass the native 288x224 raster unrotated.
wire [1:0] ar = status[122:121];
wire       no_rotate  = status[2] | direct_video;
// Rotate CCW / Flip Screen are done in the core as a 180-degree native raster flip, so they
// also work on CRT / direct video (analog and DV1 carry the native raster). The HDMI
// framebuffer always rotates CW: CW rotation of the flipped raster is the CCW picture.
wire       core_flip  = status[3] ^ status[4];
wire       rotate_ccw = 1'b0;
wire       flip       = 1'b0;
wire [11:0] arx = (!ar) ? (no_rotate ? 12'd4 : 12'd3) : (ar - 1'd1);
wire [11:0] ary = (!ar) ? (no_rotate ? 12'd3 : 12'd4) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"A.NamcoND1;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[13:12],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O[2],Orientation,Vert,Horz;",
	"O[3],Rotate CCW,No,Yes;",
	"O[4],Flip Screen,Off,On;",
	"O[17:15],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"O[9:8],Cabinet Reverb,Off,Light,Medium,Heavy;",
	"-;",
	"DIP;",
	"-;",
	"R[0],Reset;",
	"J1,Button 1,Button 2,Button 3,Start 1P,Start 2P,Coin,Service;",
	"jn,A,B,X,Start,R,Select,L;",
	"V,v",`BUILD_DATE
};


wire        forced_scandoubler;
wire        direct_video;
wire  [1:0] buttons;
wire [127:0] status;
wire        video_rotated;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_wr;
wire        ioctl_rd;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
wire        ioctl_wait;
wire [15:0] ioctl_index;

wire [31:0] joy0, joy1;
wire [21:0] gamma_bus;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.video_rotated(video_rotated),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd4),
	.ioctl_wr(ioctl_wr),
	.ioctl_rd(ioctl_rd),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joy0),
	.joystick_1(joy1)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_sdram, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

///////////////////////   MACHINE   //////////////////////////////

// DIP switches from the MRA (<switches>, ioctl index 254): the board's DSW bits 8-9,
// MAME namcond1 "Freeze" and "Test". sw0[0] = Freeze, sw0[1] = Test (1 = On).
reg [7:0] sw0 = 8'h00;
always @(posedge clk_sys) if (ioctl_wr && ioctl_download && ioctl_index == 16'd254 && !ioctl_addr[24:3] && ioctl_addr[2:0] == 3'd0) sw0 <= ioctl_dout;

wire [15:0] snd_l, snd_r;
wire        ga_cen_pix, ga_hs, ga_vs, ga_hb, ga_vb, ga_de;
wire [23:0] ga_rgb;

nd1_top nd1
(
	.clk_sys(clk_sys),
	.clk_sdram(clk_sdram),
	.pll_locked(pll_locked),
	.reset_in(RESET | status[0] | buttons[1]),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index[7:0]),

	.joy0(joy0),
	.joy1(joy1),
	.test_sw(sw0[1]),
	.freeze_sw(sw0[0]),
	.reverb_mode(status[9:8]),
	.screen_flip(core_flip),

	.cen_pix(ga_cen_pix),
	.hsync(ga_hs), .vsync(ga_vs), .hblank(ga_hb), .vblank(ga_vb), .de(ga_de),
	.rgb(ga_rgb),
	.snd_l(snd_l), .snd_r(snd_r),

	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
);

assign AUDIO_S = 1;
assign AUDIO_L = snd_l;
assign AUDIO_R = snd_r;

///////////////////////   VIDEO   ////////////////////////////////

wire [2:0] fx = status[17:15];
wire       vga_de;

arcade_video #(288, 24) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(ga_cen_pix),
	.RGB_in(ga_rgb),
	.HBlank(ga_hb),
	.VBlank(ga_vb),
	.HSync(ga_hs),
	.VSync(ga_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de),
	.VGA_SL(VGA_SL),

	.fx(fx),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// Aspect / scaling (OSD Scale: Normal, V-Integer, Narrower/Wider HV-Integer)
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de), .ARX(arx), .ARY(ary),
	.CROP_SIZE(12'd0), .CROP_OFF(5'd0), .SCALE({1'b0, status[13:12]})
);

screen_rotate screen_rotate (.*);

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = ioctl_download | (act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0]);

endmodule
