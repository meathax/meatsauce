//============================================================================
// 
//  Port to MiSTer.
//  Copyright (C) 2021 Sorgelig
//
//  Jackal for MiSTer
//  Copyright (C) 2020, 2021 Ace, brknglass, Ash Evans (aka ElectronAsh/OzOnE),
//  Shane Lynch, JimmyStones and Kitrinx (aka Rysha)
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the 
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
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

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign VGA_F1 = 0;
wire signed [15:0] audio_l, audio_r;
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

///////////////////////////////////////////////////

wire [1:0] ar = status[14:13];

assign VIDEO_ARX = status[12] ? ((!ar) ? 13'd15 : (ar - 1'd1)) : ((!ar) ? 13'd14 : (ar - 1'd1));
assign VIDEO_ARY = status[12] ? ((!ar) ? 13'd14 : 12'd0) : ((!ar) ? 13'd15 : 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	"A.JACKAL;;",
	"ODE,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"OC,Orientation,Vert,Horz;",
	"OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"H3OR,Autosave Hiscores,On,Off;",
	"P1,Pause Options;",
	"P1OP,Pause when OSD is open,On,Off;",
	"P1OQ,Dim video after 10s,On,Off;",
	"-;",
	"DIP;",
	"-;",
	"P2,Screen Centering;",
	"P2O36,H Center,0,-1,-2,-3,-4,-5,-6,-7,+7,+6,+5,+4,+3,+2,+1;",
	"P2O7A,V Center,0,-1,-2,-3,-4,-5,-6,-7,-8,-9,-10,-11,-12;",
	"H2-;",
	"H2OB,Rotary speed,Normal,Fast;",
	"H2O[29:28],Aim speed,Normal,Slow,Instant;",
	"H2O[30],Stick autofire,Off,On;",
	"H2O[32:31],Aim deadzone,25%,10%,30%,40%;",
	"-;",
	"R0,Reset;",
	"J1,Machine Gun,Grenades/Rockets,Rotary Left,Rotary Right,Start,Coin,Pause;",
	"jn,B,A,L,R,Start,Select,X;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;
wire        ioctl_wait;

wire [15:0] joystick_0, joystick_1;
wire [15:0] left_analog0,right_analog0,left_analog1,right_analog1;
wire [15:0] joy = joystick_0 | joystick_1;

wire [21:0] gamma_bus;
wire        direct_video;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_49M),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({~hs_configured,~is_rotary,is_bootleg[0],direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(left_analog0),
	.joystick_r_analog_0(right_analog0),
	.joystick_l_analog_1(left_analog1),
	.joystick_r_analog_1(right_analog1),
	.ps2_key(ps2_key)
);


////////////////////   CLOCKS   ///////////////////

wire CLK_98M;
wire CLK_49M;
wire locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(CLK_98M),
	.outclk_1(CLK_49M),
	.reconfig_to_pll(64'd0),
	.reconfig_from_pll(),
	.locked(locked)
);

wire reset = RESET | status[0] | buttons[1];

////////////////////   SDRAM   ////////////////////

sdram #(.CLOCK_HZ(49_152_000)) sdram
(
	.*,
	.init(~locked),
	.clk(CLK_49M),
	.refresh_allow(gfx_refresh_allow || (ioctl_download && ioctl_index==0)),

	.addr0(rom_read_addr[23:0]),
	.din0({ioctl_dout[7:0], ioctl_dout[7:0]}),
	.dout0(),
	.wrl0((ioctl_addr >= 24'h40000 & ioctl_addr < 24'h50000) | (ioctl_addr >= 24'h80000 & ioctl_addr < 24'h90000)),
	.wrh0((ioctl_addr >= 24'h20000 & ioctl_addr < 24'h30000) | (ioctl_addr >= 24'h60000 & ioctl_addr < 24'h70000)),
	.req0(rom_wr),
	.ack0(sdram_wrack),

	.addr1(rom_addr[23:0]),
	.din1(0),
	.dout1(sdram_data),
	.wrl1(0),
	.wrh1(0),
	.req1(rom_req),
	.ack1(sdram_rdack),

	.addr2(rom_addr2[23:0]),
	.din2(0),
	.dout2(sdram_data2),
	.wrl2(0),
	.wrh2(0),
	.req2(rom_req2),
	.ack2(sdram_rdack2)
);

wire [23:0] rom_read_addr = ioctl_addr[23:0] < 24'h40000 ? ioctl_addr[23:0] - 24'h20000:
                            ioctl_addr[23:0] < 24'h60000 ? ioctl_addr[23:0] - 24'h40000:
                            ioctl_addr[23:0] < 24'h80000 ? ioctl_addr[23:0] - 24'h50000:
                            ioctl_addr[23:0] - 24'h70000;

wire [23:0] rom_addr;
wire [15:0] sdram_data;
wire rom_req, sdram_rdack;
wire [23:0] rom_addr2;
wire [15:0] sdram_data2;
wire rom_req2,sdram_rdack2,gfx_refresh_allow;

reg rom_wr = 0;
wire sdram_wrack;

wire rom_download = ((ioctl_addr >= 24'h20000) & (ioctl_addr < 24'h30000)) | ((ioctl_addr >= 24'h40000) & (ioctl_addr < 24'h50000))|
                    ((ioctl_addr >= 24'h60000) & (ioctl_addr < 24'h70000)) | ((ioctl_addr >= 24'h80000) & (ioctl_addr < 24'h90000)) & ioctl_download;
always @(posedge CLK_49M) begin
	if(rom_download & ioctl_wr) begin
		ioctl_wait <= 1;
		rom_wr <= ~rom_wr;
	end
	else if(ioctl_wait && (rom_wr == sdram_wrack))
		ioctl_wait <= 0;
end

///////////////////         Keyboard           //////////////////

reg btn_up       = 0;
reg btn_down     = 0;
reg btn_left     = 0;
reg btn_right    = 0;
reg btn_shot     = 0;
reg btn_missile  = 0;
reg btn_up2      = 0;
reg btn_down2    = 0;
reg btn_left2    = 0;
reg btn_right2   = 0;
reg btn_shot2    = 0;
reg btn_missile2 = 0;
reg btn_coin1    = 0;
reg btn_coin2    = 0;
reg btn_1p_start = 0;
reg btn_2p_start = 0;
reg btn_pause    = 0;
reg btn_service  = 0;

wire pressed = ps2_key[9];
wire [7:0] code = ps2_key[7:0];
always @(posedge CLK_49M) begin
	reg old_state;
	old_state <= ps2_key[10];
	if(old_state != ps2_key[10]) begin
		case(code)
			'h16: btn_1p_start <= pressed; // 1
			'h1E: btn_2p_start <= pressed; // 2
			'h2E: btn_coin1    <= pressed; // 5
			'h36: btn_coin2    <= pressed; // 6
			'h46: btn_service  <= pressed; // 9
			'h4D: btn_pause    <= pressed; // P

			'h75: btn_up      <= pressed; // up
			'h72: btn_down    <= pressed; // down
			'h6B: btn_left    <= pressed; // left
			'h74: btn_right   <= pressed; // right
			'h14: btn_shot    <= pressed; // ctrl
			'h11: btn_missile <= pressed; // alt

			'h1d: btn_up2     <= pressed; // w
			'h1b: btn_down2   <= pressed; // s
			'h1c: btn_left2   <= pressed; // a
			'h23: btn_right2  <= pressed; // d
			'h2a: btn_shot2   <= pressed; // v
			'h32: btn_missile2<= pressed; // b
		endcase
	end
end

//////////////////  Arcade Buttons/Interfaces   ///////////////////////////

//Player 1
wire m_up1       = btn_up      | joystick_0[3] | stick_move0[3];
wire m_down1     = btn_down    | joystick_0[2] | stick_move0[2];
wire m_left1     = btn_left    | joystick_0[1] | stick_move0[1];
wire m_right1    = btn_right   | joystick_0[0] | stick_move0[0];
wire m_shot1     = btn_shot    | joystick_0[4] | stick_fire0;
wire m_missile1  = btn_missile | joystick_0[5];
wire m_rotary1_l = joystick_0[7];
wire m_rotary1_r = joystick_0[6];

//Player 2
wire m_up2       = btn_up2     | joystick_1[3] | stick_move1[3];
wire m_down2     = btn_down2   | joystick_1[2] | stick_move1[2];
wire m_left2     = btn_left2   | joystick_1[1] | stick_move1[1];
wire m_right2    = btn_right2  | joystick_1[0] | stick_move1[0];
wire m_shot2     = btn_shot2   | joystick_1[4] | stick_fire1;
wire m_missile2  = btn_missile2| joystick_1[5];
wire m_rotary2_l = joystick_1[7];
wire m_rotary2_r = joystick_1[6];

//Start/coin
wire m_start1   = btn_1p_start | joystick_0[8];
wire m_start2   = btn_2p_start | joystick_1[8];
wire m_coin1    = btn_coin1    | joy[9];
wire m_coin2    = btn_coin2;
wire m_pause    = btn_pause    | joy[10];

// The original jackalr program keeps a separate eight-way gun angle.
wire [3:0] stick_move0,stick_move1;
wire stick_fire0,stick_fire1;
wire [7:0] rotary1,rotary2;
wire [1:0] aim_strobe;
wire [2:0] actual_aim0,actual_aim1;
jackal_aim_controls aim_controls(
    .clk(CLK_49M),.reset(reset || (ioctl_download && ioctl_index==0)),
    .paused(pause_cpu),.enabled(is_rotary && is_bootleg==0),
    .left0(left_analog0),.right0(right_analog0),.left1(left_analog1),.right1(right_analog1),
    .speed(status[29:28]),.deadzone(status[32:31]),.autofire(status[30]),.manual_fast(status[11]),
    .manual_left({m_rotary2_r,m_rotary1_r}),.manual_right({m_rotary2_l,m_rotary1_l}),
    .actual_strobe(aim_strobe),.actual0(actual_aim0),.actual1(actual_aim1),
    .move0(stick_move0),.move1(stick_move1),.rotary0(rotary1),.rotary1(rotary2),
    .fire0(stick_fire0),.fire1(stick_fire1));
wire [7:0] p1_rotary = (is_bootleg == 2'b01) ? 8'hFF : rotary1;
wire [7:0] p2_rotary = (is_bootleg == 2'b01) ? 8'hFF : rotary2;

// PAUSE SYSTEM
wire pause_cpu;
wire [23:0] rgb_out;
pause #(8,8,8,49) pause
(
	.*,
	.clk_sys(CLK_49M),
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[26:25])
);

reg [7:0] dip_sw[8];	// Active-LOW
reg [1:0] is_bootleg;
reg is_rotary;
always @(posedge CLK_49M) begin
	if((ioctl_index == 1) && (ioctl_addr == 0)) begin
		is_bootleg <= ioctl_dout[1:0];
		is_rotary <= ioctl_dout[4];
	end
	if(ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end

///////////////                 Video                  ////////////////

wire hblank, vblank;
wire hs, vs;
wire [4:0] r_out, g_out, b_out;

//Adjust the color tones based on the measured outputs of the weighted resistor DAC
//(these values are based on those found on Jackal bootleg PCBs and may not match those
//from the DAC integrated within the 007327 custom palette RAM + DAC module)
wire [7:0] jackal_color[32] =
'{
	8'd0,   8'd7,   8'd14,  8'd21,
	8'd30,  8'd37,  8'd44,  8'd51,
	8'd65,  8'd71,  8'd79,  8'd85,
	8'd96,  8'd102, 8'd110, 8'd116,
	8'd139, 8'd146, 8'd153, 8'd160,
	8'd170, 8'd176, 8'd184, 8'd190,
	8'd205, 8'd210, 8'd218, 8'd224,
	8'd234, 8'd241, 8'd248, 8'd255
};
wire [7:0] r = jackal_color[r_out];
wire [7:0] g = jackal_color[g_out];
wire [7:0] b = jackal_color[b_out];

wire ce_pix;
jackal_pixel_ce pixel_clock(.clk(CLK_49M),.ce(ce_pix));

wire rotate_ccw = 0;
wire no_rotate = status[12] | direct_video;
wire flip = video_rotated;
wire video_rotated;
screen_rotate screen_rotate(.*);

arcade_video #(240, 24) arcade_video
(
	.*,

	.clk_video(CLK_49M),

	.RGB_in(rgb_out),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(~hs),
	.VSync(~vs),

	.fx(status[17:15])
);

//Instantiate Jackal top-level module
Jackal Jackal_inst
(
	.reset(~reset),                      // input reset
	
	.clk_49m(CLK_49M),                   // input clk_49m

	.coins({~m_coin2, ~m_coin1}),        // input coins
	.btn_service(~btn_service),          // input btn_service
	
	.btn_start({~m_start2, ~m_start1}),  // input [1:0] btn_start
	
	.p1_joystick({~m_down1, ~m_up1, ~m_right1, ~m_left1}),
	.p2_joystick({~m_down2, ~m_up2, ~m_right2, ~m_left2}),
	.p1_rotary(~p1_rotary),
	.p2_rotary(~p2_rotary),
	.aim_strobe(aim_strobe),
	.actual_aim0(actual_aim0),
	.actual_aim1(actual_aim1),
	.p1_buttons({~m_missile1, ~m_shot1}),
	.p2_buttons({~m_missile2, ~m_shot2}),
	
	.dipsw({~dip_sw[2], ~dip_sw[1], ~dip_sw[0]}), // input [24:0] dipsw
	
	.is_bootleg(is_bootleg),             // Flag to reconfigure core for differences
	                                     // present on bootleg Jackal PCBs
	
	.sound_l(audio_l),                   // output [15:0] sound_l
	.sound_r(audio_r),                   // output [15:0] sound_r
	
	.h_center(status[6:3]),              // Screen centering
	.v_center(status[10:7]),
	
	.video_hsync(hs),                    // output video_hsync
	.video_vsync(vs),                    // output video_vsync
	.video_vblank(vblank),               // output video_vblank
	.video_hblank(hblank),               // output video_hblank
	
	.video_r(r_out),                     // output [4:0] video_r
	.video_g(g_out),                     // output [4:0] video_g
	.video_b(b_out),                     // output [4:0] video_b

	.ioctl_addr(ioctl_addr),
	.ioctl_wr(ioctl_wr && !ioctl_index),
	.ioctl_data(ioctl_dout),
	
	.rom_addr(rom_addr),
	.rom_data(sdram_data),
	.rom_req(rom_req),
	.rom_ack(sdram_rdack),
	.rom_addr2(rom_addr2),.rom_data2(sdram_data2),
	.rom_req2(rom_req2),.rom_ack2(sdram_rdack2),
	.rom_loading(ioctl_download && ioctl_index==0),
	.gfx_refresh_allow(gfx_refresh_allow),
	
	.pause(~pause_cpu),
	.cpu_paused(cpu_paused),
	
	.underclock(1'b0),             //Flag to signal that Jackal has been underclocked to normalize video timings in order to maintain consistent sound pitch
	
	.hs_address(hs_address),
	.hs_data_out(hs_data_out),
	.hs_data_in(hs_data_in),
	.hs_write(hs_write_enable),
	.hs_access(hs_access_read|hs_access_write)
);

// HISCORE SYSTEM
// --------------

wire [12:0] hs_address;
wire [7:0] hs_data_in;
wire [7:0] hs_data_out;
wire hs_write_enable;
wire hs_access_read;
wire hs_access_write;
wire hs_pause;
wire hs_configured;
wire cpu_paused;

hiscore #(
	.HS_ADDRESSWIDTH(13),
	.CFG_ADDRESSWIDTH(3),
	.CFG_LENGTHWIDTH(2)
) hi (
	.*,
	.clk(CLK_49M),
	.paused(cpu_paused),
	.autosave(~status[27]),
	.ram_address(hs_address),
	.data_from_ram(hs_data_out),
	.data_to_ram(hs_data_in),
	.data_from_hps(ioctl_dout),
	.data_to_hps(ioctl_din),
	.ram_write(hs_write_enable),
	.ram_intent_read(hs_access_read),
	.ram_intent_write(hs_access_write),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

endmodule

