//============================================================================
// Universal Do! Castle hardware family — MiSTer wrapper
//============================================================================
module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [45:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R, VGA_G, VGA_B,
	output        VGA_HS, VGA_VS, VGA_DE, VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER, VGA_DISABLE,
	input  [11:0] HDMI_WIDTH, HDMI_HEIGHT,
	output        HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT,
`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH, FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL, FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif
	output        LED_USER,
	output  [1:0] LED_POWER, LED_DISK, BUTTONS,
	input         CLK_AUDIO,
	output [15:0] AUDIO_L, AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,
	inout   [3:0] ADC_BUS,
	output        SD_SCK, SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,
	output        SDRAM_CLK, SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE,
`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS, SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE,
`endif
	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD, UART_DTR,
	input         UART_DSR,
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,
	input         OSD_STATUS
);

assign {SD_SCK,SD_MOSI,SD_CS} = 'Z;
assign {UART_RTS,UART_TXD,UART_DTR} = 0;
assign {SDRAM_DQ,SDRAM_A,SDRAM_BA,SDRAM_CLK,SDRAM_CKE,
	SDRAM_DQML,SDRAM_DQMH,SDRAM_nWE,SDRAM_nCAS,SDRAM_nRAS,SDRAM_nCS} = 'Z;
assign ADC_BUS = 'Z;
assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign FB_FORCE_BLANK = 0;
assign LED_USER = ioctl_download;
assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;
assign AUDIO_MIX = 0;
assign AUDIO_S = 1;

`include "build_id.v"
localparam CONF_STR = {
	"A.UNIVERSAL_DOCASTLE;;",
	"H0O2,Orientation,Vert,Horz;",
	"O1,Rotate,CCW,CW;",
	"-;",
	"P3,Video;",
	"P3O[57:54],CRT H offset,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[61:58],CRT V offset,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[62],CRT scale enable,Off,On;",
	"P3O[66:63],CRT scale factor,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3-;",
	"P3O[69:67],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P3OMN,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P3O[71:70],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P3O[72],Vertical Crop,Disabled,216p(5x);",
	"-;",
	"DIP;",
	"-;",
	"O[40],User port,Off,DB15 Joystick;",
	"-;",
	"P1,Pause options;",
	"P1OP,Pause when OSD is open,On,Off;",
	"P1OQ,Dim video after 10s,On,Off;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Start 1P,Start 2P,Coin 1,Coin 2,Service Mode,Pause,Right Left,Right Right,Right Up,Right Down,Service Credit;",
	"jn,A,B,Start,Select,R,L,X,Y;",
	"V,v",`BUILD_DATE
};

wire clk_unused_98m, clk_sys, clk_unused_24m, pll_locked;
pll pll
(
	.refclk(CLK_50M), .rst(0),
	.outclk_0(clk_unused_98m), .outclk_1(clk_sys),
	.outclk_2(clk_unused_24m), .locked(pll_locked)
);

wire [127:0] status;
wire [1:0] hps_buttons;
wire forced_scandoubler, direct_video, video_rotated;
wire ioctl_download, ioctl_wr;
wire [15:0] ioctl_index;
wire [7:0] ioctl_dout;
wire [26:0] ioctl_addr;
wire [31:0] joystick_0, joystick_1;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire [15:0] joystick_r_analog_0, joystick_r_analog_1;
wire [21:0] gamma_bus;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .buttons(hps_buttons), .status(status),
	.status_menumask({15'd0,direct_video}), .forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus), .direct_video(direct_video), .video_rotated(video_rotated),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index),
	.joystick_0(joystick_0), .joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.joystick_r_analog_0(joystick_r_analog_0),
	.joystick_r_analog_1(joystick_r_analog_1)
);

reg [7:0] sw[0:7];
integer si;
always @(posedge clk_sys) begin
	if (RESET) begin
		for (si=0;si<8;si=si+1) sw[si] <= 8'hff;
		sw[0] <= 8'hdf;
	end
	else if (ioctl_wr && (ioctl_index == 16'd254) && (ioctl_addr[26:3] == 0))
		sw[ioctl_addr[2:0]] <= ioctl_dout;
end

// DB15 splitter (Villena, via joy_db15.v) merges into P1/P2 alongside the
// normal USB/wireless joypad path when the "User port" OSD option selects it.
// Only R/L/D/U/B1/B2/Start/Select exist on a DB15 port; service mode, pause
// and service credit stay USB-only, matching jtframe_joymux's own convention.
wire p1_right = joystick_0[0] | (db15_en & db15_left_joys[0]);
wire p1_left  = joystick_0[1] | (db15_en & db15_left_joys[1]);
wire p1_down  = joystick_0[2] | (db15_en & db15_left_joys[2]);
wire p1_up    = joystick_0[3] | (db15_en & db15_left_joys[3]);
wire p1_b1    = joystick_0[4] | (db15_en & db15_left_joys[4]);
wire p1_b2    = joystick_0[5] | (db15_en & db15_left_joys[5]);
wire p2_right = joystick_1[0] | (db15_en & db15_right_joys[0]);
wire p2_left  = joystick_1[1] | (db15_en & db15_right_joys[1]);
wire p2_down  = joystick_1[2] | (db15_en & db15_right_joys[2]);
wire p2_up    = joystick_1[3] | (db15_en & db15_right_joys[3]);
wire p2_b1    = joystick_1[4] | (db15_en & db15_right_joys[4]);
wire p2_b2    = joystick_1[5] | (db15_en & db15_right_joys[5]);
wire start1=joystick_0[6]|joystick_1[6]|(db15_en & db15_start1);
wire start2=joystick_0[7]|joystick_1[7]|(db15_en & db15_start2);
wire coin1=joystick_0[8]|joystick_1[8]|(db15_en & db15_coin1);
wire coin2=joystick_0[9]|joystick_1[9]|(db15_en & db15_coin2);
wire service_mode=joystick_0[10]|joystick_1[10];
wire user_pause=joystick_0[11]|joystick_1[11];
wire service_credit=joystick_0[16]|joystick_1[16];
wire [7:0] standard_joys = ~{p2_down,p2_left,p2_up,p2_right,p1_down,p1_left,p1_up,p1_right};
wire [7:0] game_buttons = ~{start2,1'b0,p2_b2,p2_b1,start1,1'b0,p1_b2,p1_b1};
// MAME's input table and the PCB expose two active-low coin lines:
// SYSTEM[5] is COIN1 and SYSTEM[4] is COIN2.
wire [7:0] game_system = ~{2'b00,coin1,coin2,1'b0,service_credit,service_mode,1'b0};

wire core_reset = RESET | status[0] | hps_buttons[1] | ~pll_locked
	| (ioctl_download && ((ioctl_index == 16'd0) || (ioctl_index == 16'd1)));

wire p1_la_right, p1_la_left, p1_la_down, p1_la_up;
wire p2_la_right, p2_la_left, p2_la_down, p2_la_up;
wire p1_ra_right, p1_ra_left, p1_ra_down, p1_ra_up;
wire p2_ra_right, p2_ra_left, p2_ra_down, p2_ra_up;
docastle_analog p1_left_analog
(
	.clk(clk_sys), .reset(core_reset), .analog(joystick_l_analog_0),
	.right(p1_la_right), .left(p1_la_left), .down(p1_la_down), .up(p1_la_up)
);
docastle_analog p2_left_analog
(
	.clk(clk_sys), .reset(core_reset), .analog(joystick_l_analog_1),
	.right(p2_la_right), .left(p2_la_left), .down(p2_la_down), .up(p2_la_up)
);
docastle_analog p1_right_analog
(
	.clk(clk_sys), .reset(core_reset), .analog(joystick_r_analog_0),
	.right(p1_ra_right), .left(p1_ra_left), .down(p1_ra_down), .up(p1_ra_up)
);
docastle_analog p2_right_analog
(
	.clk(clk_sys), .reset(core_reset), .analog(joystick_r_analog_1),
	.right(p2_ra_right), .left(p2_ra_left), .down(p2_ra_down), .up(p2_ra_up)
);

wire [7:0] game_id_wire;
// Real-PCB behaviour is now the only mode: watchdog/sprite-CPU timing runs at
// full fidelity, the AC-coupled output-stage filter is always applied, and
// the raster uses the fixed /10 divider (deterministic HSYNC cadence,
// matches the measured hardware rate). The alternate fractional pixel-clock
// accumulator that exact_pixel_clock used to select is simulation-only (see
// the ce_pix_r comment in docastle_core.sv) and was never a real-hardware
// option, so removing its OSD toggle carries no hardware-verification risk.
// Previously these were user-togglable via CONF_STR O[102]/O[103]/O[104].
wire pcb_fidelity = 1'b1;
wire pcb_audio_filter = 1'b1;
wire exact_pixel_clock = 1'b0;
wire soccer_mode = (game_id_wire == 8'h07) || (game_id_wire == 8'h08);
wire [7:0] soccer_left_joys = ~{
	p2_down|p2_la_down,p2_left|p2_la_left,p2_up|p2_la_up,p2_right|p2_la_right,
	p1_down|p1_la_down,p1_left|p1_la_left,p1_up|p1_la_up,p1_right|p1_la_right
};
wire [7:0] soccer_right_joys = ~{
	joystick_1[15]|p2_ra_down,joystick_1[12]|p2_ra_left,
	joystick_1[14]|p2_ra_up,joystick_1[13]|p2_ra_right,
	joystick_0[15]|p1_ra_down,joystick_0[12]|p1_ra_left,
	joystick_0[14]|p1_ra_up,joystick_0[13]|p1_ra_right
};
wire [7:0] joys_to_core = soccer_mode ? soccer_right_joys : standard_joys;
wire [7:0] joys2_to_core = soccer_mode ? soccer_left_joys : 8'hff;

wire ce_pix, hblank, vblank, hs, vs;
wire [7:0] r,g,b;
wire signed [15:0] core_audio;
wire pause_cpu;
wire [23:0] rgb_out;
pause #(8,8,8,49) pause
(
	.*,
	.reset(core_reset),
	.r(r), .g(g), .b(b), .user_button(user_pause), .pause_request(1'b0),
	.options(~status[26:25])
);

docastle_core core
(
	.clk(clk_sys), .reset(core_reset), .pause(pause_cpu),
	.pcb_fidelity(pcb_fidelity), .pcb_audio_filter(pcb_audio_filter),
	.pcb_framebuffer(1'b0), .pcb_cursor_irq(1'b0), .exact_pixel_clock(exact_pixel_clock),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index[7:0]),
	.ioctl_addr(ioctl_addr[24:0]), .ioctl_dout(ioctl_dout),
	.dsw1(sw[0]), .dsw2(sw[1]), .joys(joys_to_core), .joys2(joys2_to_core),
	.buttons(game_buttons), .system(game_system),
	.ce_pix(ce_pix), .r(r), .g(g), .b(b), .hs(hs), .vs(vs),
	.hblank(hblank), .vblank(vblank), .audio(core_audio),
	.main_pc_debug(), .sub_pc_debug(), .sprite_pc_debug(),
	.main_wait_debug(), .psg_ready_debug(), .renderer_busy_debug(),
	.renderer_overrun_debug(), .game_id_debug(game_id_wire),
	.profile_debug(), .profile_valid_debug(), .adpcm_busy_debug(),
	.adpcm_nibble_debug(), .adpcm_strobe_debug(),
	.watchdog_reset_debug(), .sprite_copy_debug(), .cf_write_debug(),
	.crtc_cursor_debug(), .cf_irq_debug(), .cf_overrun_debug(),
	.cf_reg2_debug(), .cf_addr_debug(), .cf_data_debug(),
	.crtc_write_debug(), .crtc_reg_debug(), .crtc_data_debug()
);
assign AUDIO_L = core_audio;
assign AUDIO_R = core_audio;

// jtframe-style OSD video chain, replacing rmonic79/MiSTer-CRT-Adjust.
// Pipeline order matches jtcores' own jtframe_board.v -> jtframe_mister.sv:
//   raw game video -> CRT H/V offset (resync) ->
//   CRT H-scale (hsize) -> arcade_video (Scandoubler Fx/HQ2x/scanlines) ->
//   video_freak (Scale / Vertical Crop, HDMI-side).
wire db15_en   = status[40];

// --- DB15 splitter (Antonio Villena, via joy_db15.v) ---
wire joy_clk, joy_load, joy_din = USER_IN[5];
wire [15:0] joydb15_1, joydb15_2;
joy_db15 u_db15
(
	.clk(clk_sys), .JOY_CLK(joy_clk), .JOY_LOAD(joy_load), .JOY_DATA(joy_din),
	.joystick1(joydb15_1), .joystick2(joydb15_2)
);
assign USER_OUT = db15_en ? {5'h1f, joy_clk, joy_load} : 7'h7f;
// joydb15_n bit layout (see joy_db15.v): 0=R 1=L 2=D 3=U 4=A 5=B 10=Start 11=Select.
// Bits 0-5 line up exactly with this core's own standard_joys RLDUB1B2 order.
// Start/Select are the only extra controls a DB15 splitter exposes; there is
// no DB15 equivalent for service mode, pause or service credit, so those stay
// unavailable while db15_en is set (matching jtframe_joymux's own convention).
// joy_db15.v already outputs active-high (it inverts the raw active-low
// shift-register bits internally): pass through directly, no re-inversion.
wire [7:0] db15_left_joys  = joydb15_1[7:0];
wire [7:0] db15_right_joys = joydb15_2[7:0];
wire db15_start1 = joydb15_1[10], db15_coin1 = joydb15_1[11];
wire db15_start2 = joydb15_2[10], db15_coin2 = joydb15_2[11];

wire orientation = status[2];
wire [1:0] ar = status[24:23];
wire [12:0] aspect_arx = (ar == 0) ? (orientation ? 13'd4 : 13'd3)
	: ({11'd0,ar} - 13'd1);
wire [12:0] aspect_ary = (ar == 0) ? (orientation ? 13'd3 : 13'd4) : 13'd0;
wire no_rotate = orientation | direct_video;
wire rotate_ccw = ~status[1];
wire flip = 1'b0;

// --- CRT H/V offset (raw-analog side; replaces CRT Adjust's H-Position/V-Shift) ---
wire [3:0] crt_hoffset = status[57:54];
wire [3:0] crt_voffset = status[61:58];
wire resync_hs, resync_vs;
jtframe_resync #(.WIDE(0)) u_resync
(
	.clk(clk_sys), .pxl_cen(ce_pix),
	.hs_in(hs), .vs_in(vs), .LVBL(~vblank), .LHBL(~hblank),
	.hoffset(crt_hoffset), .voffset(crt_voffset),
	.hs_out(resync_hs), .vs_out(resync_vs)
);

// --- CRT H-scale (raw-analog side; replaces CRT Adjust's H-Size) ---
wire hsize_enable = status[62];
wire [3:0] hsize_scale = status[66:63];
wire [7:0] hsize_r, hsize_g, hsize_b;
wire hsize_hs, hsize_vs, hsize_hb, hsize_vb;
jtframe_hsize #(.COLORW(8)) u_hsize
(
	.clk(clk_sys), .pxl_cen(ce_pix), .pxl2_cen(1'b1), // see commit message: safe
	                                                   // maximum-rate choice, no
	                                                   // verified target ratio
	.scale(hsize_scale), .offset(5'd0), .enable(hsize_enable),
	.r_in(rgb_out[23:16]), .g_in(rgb_out[15:8]), .b_in(rgb_out[7:0]),
	.HS_in(resync_hs), .VS_in(resync_vs), .HB_in(hblank), .VB_in(vblank),
	.HS_out(hsize_hs), .VS_out(hsize_vs), .HB_out(hsize_hb), .VB_out(hsize_vb),
	.r_out(hsize_r), .g_out(hsize_g), .b_out(hsize_b)
);

screen_rotate screen_rotate (.*);

wire raw_de;
wire [2:0] fx_sel = status[69:67];
arcade_video #(240,24) arcade_video
(
	.*,
	.clk_video(clk_sys), .ce_pix(ce_pix),
	.RGB_in({hsize_r,hsize_g,hsize_b}),
	.HBlank(hsize_hb), .VBlank(hsize_vb),
	.HSync(hsize_hs), .VSync(hsize_vs), .VGA_DE(raw_de), .fx(fx_sel)
);

// --- Scale / Vertical Crop (HDMI-scaler side), video_freak.sv ---
wire [2:0] crop_scale = {1'b0, status[71:70]};
wire crop_en = status[72];
wire [11:0] crop_size = crop_en ? 12'd216 : 12'd0;
video_freak u_crop
(
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(raw_de), .ARX(aspect_arx[11:0]), .ARY(aspect_ary[11:0]),
	.CROP_SIZE(crop_size), .CROP_OFF(5'd0), .SCALE(crop_scale)
);

wire _unused = &{1'b0,CLK_AUDIO,SD_MISO,SD_CD,
	DDRAM_BUSY,DDRAM_DOUT,DDRAM_DOUT_READY,UART_CTS,UART_RXD,UART_DSR,OSD_STATUS,
	clk_unused_98m,clk_unused_24m};
endmodule
