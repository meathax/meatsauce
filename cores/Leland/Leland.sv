//============================================================================
//  Leland - MiSTer FPGA Core
//  Leland Corp. 1989
//
//  Copyright (C) 2026 shimian5
//
//  This program is free software: you can redistribute it and/or modify it under the
//  terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
//  PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with this
//  program. If not, see <https://www.gnu.org/licenses/>.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

//----------------------------------------------------------------
// Unused port defaults
//----------------------------------------------------------------
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// SDRAM pins are driven by leland_board. The DDR3 port is shared by leland_ddr_loader and
// leland_retimer (see the DDR3 mux below).

assign VGA_F1       = 0;
assign VGA_SCALER   = 0;
assign VGA_DISABLE  = 0;
assign HDMI_FREEZE  = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Signed 16-bit mono audio from the sound board, duplicated to both channels (the real
// board is mono).
assign AUDIO_S   = 1;
assign AUDIO_L   = audio_out;
assign AUDIO_R   = audio_out;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = 0;
assign BUTTONS   = 0;

//----------------------------------------------------------------
// OSD / HPS configuration
//----------------------------------------------------------------
wire [1:0] ar = status[122:121];
wire [12:0] display_arx, display_ary;
assign VIDEO_ARX = display_arx;
assign VIDEO_ARY = display_ary;

`include "build_id.v"
// CRT Adjust ranges (Asylum fixed-cadence resampler, see docs/CRT_FIXED_CANDIDATE.md).
localparam integer CRT_HSIZE_MIN=-16,CRT_HSIZE_MAX=16,CRT_HPOS_MIN=-16,CRT_HPOS_MAX=15,CRT_VPOS_MIN=-1,CRT_VPOS_MAX=11;
`include "rtl/leland_crt_menu.vh"
localparam CONF_STR = {
	"Leland;;",
	"-;",
	// Video Settings submenu, root-level game options, Credits and Reset.
	// Status bits in use: 0,10,12:22,46:55..71,120:122.
	"P1,Video Settings;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H4P1O[49:48],Rotation,Rotate 270,Rotate 90,Normal,Flip 180;",
	"H2P1O[47:46],Scaling,Normal,V-Integer,HV-Integer;",
	"H6P1O[52:50],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1-;",
	// Polarity is inverted on purpose: the default (0) is the retimed 60 Hz
	// output, because native 65.95 Hz will not sync on many CRTs and the
	// OSD is then unreadable, so the option could never be changed.
	"P1O[12],Video Timing,CRT 60Hz,Native 66Hz;",
	// Retimer-only (60 Hz) photometric/position controls.
	"H1P1O[16:13],CRT V Position,0,Up 1,Up 2,Up 3,Up 4,Up 5,Up 6,Up 7,Up 8,Up 9,Up 10,Up 11,Up 12,Down 1,Down 2,Down 3;",
	"H1P1O[19:17],CRT V Size,240 (native),236,232,228,224,220,216,208;",
	// Native-timing CRT geometry (HeavyUnit CRT Adjust): shown only when the raster qualifies.
	"H3P1-;",
	"H3P1O[54],CRT Adjust,Off,On;",
	"H3H5P1O[61:55],CRT H-Size,",CRT_HSIZE_OPTIONS,";",
	"H3H5P1O[66:62],CRT H-Position,",CRT_HPOS_OPTIONS,";",
	"H3H5P1O[71:67],CRT V-Shift,",CRT_VPOS_OPTIONS,";",
	"O[10],D-Pad Steering,Velocity,Position;",
	"O[22:20],Player Order,1/2/3,1/3/2,2/1/3,2/3/1,3/1/2,3/2/1;",
	"-;",
	"R[120],Credits;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// Fallback only; each MRA supplies its target-specific J1 action order. Asylum's
	// MRA must list Button 1, Button 2, Start, Coin (see docs/MISTER_FEATURES.md).
	"J1,Gas,Nitro,Menu Enter,Coin,Start;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire direct_video;
wire video_rotated;
wire  [1:0] buttons;
wire [127:0] status;
wire  [15:0] status_menumask;
wire  [10:0] ps2_key;

// ROM loading
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
// ioctl_wait comes from leland_ddr_loader (which passes through leland_board's
// stall, see board_wait below) -- stalls HPS during SDRAM writes / init
wire        ioctl_wait;

// EEPROM save. nv_dirty (a game write since the last save) requests an upload;
// hps_io then reads the image byte by byte, addressed by its own ioctl_addr.
// MRAs declare it as <nvram index="4" size="128"/>.
wire        ioctl_upload;
wire        nv_dirty;
wire  [7:0] nv_rd_data;
reg         ioctl_upload_d;
always @(posedge clk_sys) ioctl_upload_d <= ioctl_upload;
wire        nv_dirty_clr = ioctl_upload & ~ioctl_upload_d;

// Three-player digital buttons ([3]=coin, [2]=btn2, [1]=btn1, [0]=btn0)
wire [31:0] joy1, joy2, joy3;
// 4th player (Pig Out only)
wire [31:0] joy4;
// Analog: signed -127..+127, [15:8]=Y (unused -- gas is digital, see p1_pedal
// below), [7:0]=X (one of three steering inputs combined by steering_input.sv)
wire [15:0] joy1_ana, joy2_ana, joy3_ana;
// Spinner: [8]=toggle (flips on every host update), [7:0]=signed delta
wire  [8:0] spinner1, spinner2, spinner3;
// Mouse: PS/2 packet, [24] toggles per update, [15:8] X delta, [23:16] Y delta, [0] left button
wire [24:0] ps2_mouse;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.video_rotated(video_rotated),
	.buttons(buttons),
	.status(status),
	.status_menumask(status_menumask),
	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nv_dirty),
	.ioctl_upload_index(8'd4),
	.ioctl_din(nv_rd_data),

	.joystick_0(joy1),
	.joystick_1(joy2),
	.joystick_2(joy3),
	.joystick_3(joy4),
	.joystick_l_analog_0(joy1_ana),
	.joystick_l_analog_1(joy2_ana),
	.joystick_l_analog_2(joy3_ana),

	.spinner_0(spinner1),
	.spinner_1(spinner2),
	.spinner_2(spinner3),

	// Unused rumble outputs
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0)
);

//----------------------------------------------------------------
// Clock: the PLL turns the DE10-Nano 50 MHz reference into the 630 MHz / 11
// system clock. The raw MiSTer pixel cadence is an integer divide-by-8 CE.
//----------------------------------------------------------------
wire clk_sys;
wire clk_sdram; // phase-shifted 630 MHz / 11 PLL output for SDRAM_CLK
wire clk_cap;   // 630 MHz / 11 PLL output phased to the SDRAM read-data window
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_cap),
	.locked(pll_locked)
);

//----------------------------------------------------------------
// Fast ROM loading: an MRA <rom index="0" address="0x30000000"> makes the
// HPS copy the ROM straight into DDR3; leland_ddr_loader then replays it to
// the board as a normal download (or passes a streamed ROM through).
//----------------------------------------------------------------
wire        ld_download, ld_wr, ld_active;
wire [15:0] ld_index;
wire [26:0] ld_addr;
wire  [7:0] ld_data;
wire        board_wait;

wire        ld_acq, ld_ddr_read;
wire [28:0] ld_ddr_addr;
wire        ld_ddr_busy, ld_ddr_rdata_ready;
wire [63:0] ld_ddr_rdata;

leland_ddr_loader ddr_loader
(
	.clk(clk_sys),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_addr(ioctl_addr),
	.ioctl_wr(ioctl_wr),
	.ioctl_data(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.o_download(ld_download),
	.o_index(ld_index),
	.o_addr(ld_addr),
	.o_wr(ld_wr),
	.o_data(ld_data),
	.b_wait(board_wait),
	.active(ld_active),

	.ddr_acquire(ld_acq),
	.ddr_addr(ld_ddr_addr),
	.ddr_read(ld_ddr_read),
	.ddr_busy(ld_ddr_busy),
	.ddr_rdata(ld_ddr_rdata),
	.ddr_rdata_ready(ld_ddr_rdata_ready)
);

wire reset      = RESET | status[0] | buttons[1] | ioctl_download | ld_active | ~pll_locked;
wire sdram_init = RESET | ~pll_locked;

//----------------------------------------------------------------
// Video signals from board
//----------------------------------------------------------------
wire       ce_pix;
wire       HBlank, HSync, VBlank, VSync;
wire [23:0] rgb;        // 24-bit colour after palette lookup

wire signed [15:0] audio_out; // mono, from the sound board's DAC mixer
wire  [7:0] game_id;
wire        ax_video;

localparam [7:0] GAME_ASYLUM = 8'd6;


//----------------------------------------------------------------
// Steering: analog stick, d-pad and spinner are combined into the free-running virtual
// dial that leland_board's p*_wheel ports expect (the real wheel is a free-spinning
// encoder, see leland_master.sv).
//----------------------------------------------------------------
reg vblank_d;
always @(posedge clk_sys) vblank_d <= VBlank;
wire ce_frame = VBlank & ~vblank_d; // once-per-frame pulse for the steering ramp

wire [7:0] p1_wheel_pos, p2_wheel_pos, p3_wheel_pos;

steering_input steer1
(
	.clk_sys(clk_sys), .reset(reset), .ce_frame(ce_frame),
	.dpad_pos_mode(status[10]),
	.analog_x(joy1_ana[7:0]),
	.dpad_left(joy1[1]), .dpad_right(joy1[0]),
	.spinner(spinner1),
	.wheel_pos(p1_wheel_pos)
);

steering_input steer2
(
	.clk_sys(clk_sys), .reset(reset), .ce_frame(ce_frame),
	.dpad_pos_mode(status[10]),
	.analog_x(joy2_ana[7:0]),
	.dpad_left(joy2[1]), .dpad_right(joy2[0]),
	.spinner(spinner2),
	.wheel_pos(p2_wheel_pos)
);

steering_input steer3
(
	.clk_sys(clk_sys), .reset(reset), .ce_frame(ce_frame),
	.dpad_pos_mode(status[10]),
	.analog_x(joy3_ana[7:0]),
	.dpad_left(joy3[1]), .dpad_right(joy3[0]),
	.spinner(spinner3),
	.wheel_pos(p3_wheel_pos)
);

// Ataxx trackballs: D-pad steps, stick with a dead zone, spinner (X only) and the mouse on
// player 1. Y positive is down, like the MiSTer analog axis.
wire [7:0] p1_tb_x, p1_tb_y, p2_tb_x, p2_tb_y;

trackball_input tb1x
(
	.clk_sys(clk_sys), .reset(reset), .ce_frame(ce_frame),
	.analog(joy1_ana[7:0]), .dpad_neg(joy1[1]), .dpad_pos(joy1[0]),
	.spinner(spinner1), .mouse({ps2_mouse[24], ps2_mouse[15:8]}), .mouse_invert(1'b0), .pos(p1_tb_x)
);

trackball_input tb1y
(
	.clk_sys(clk_sys), .reset(reset), .ce_frame(ce_frame),
	.analog(joy1_ana[15:8]), .dpad_neg(joy1[3]), .dpad_pos(joy1[2]),
	.spinner(9'd0), .mouse({ps2_mouse[24], ps2_mouse[23:16]}), .mouse_invert(1'b1), .pos(p1_tb_y)
);

trackball_input tb2x
(
	.clk_sys(clk_sys), .reset(reset), .ce_frame(ce_frame),
	.analog(joy2_ana[7:0]), .dpad_neg(joy2[1]), .dpad_pos(joy2[0]),
	.spinner(spinner2), .mouse(9'd0), .mouse_invert(1'b0), .pos(p2_tb_x)
);

trackball_input tb2y
(
	.clk_sys(clk_sys), .reset(reset), .ce_frame(ce_frame),
	.analog(joy2_ana[15:8]), .dpad_neg(joy2[3]), .dpad_pos(joy2[2]),
	.spinner(9'd0), .mouse(9'd0), .mouse_invert(1'b0), .pos(p2_tb_y)
);

//----------------------------------------------------------------
// Button order: each game lists its buttons as player controls, then coin, then start (see
// button_map.sv), so the J1 bits are reordered per game before the board sees them.
//----------------------------------------------------------------
wire [7:0] j1, j2, j3, j4;
wire       menu1, menu2_unused, menu3_unused, menu4_unused;
wire       service_test1; // Asylum MRA's fifth Service/Test control, separate from player buttons.
wire [7:0] menu_p3_1, menu_p3_2_unused, menu_p3_3_unused, menu_p3_4_unused;
button_map bmap1 (.game_id(game_id), .joy(joy1[8:0]), .board(j1), .menu(menu1), .menu_p3(menu_p3_1), .service(service_test1));
button_map bmap2 (.game_id(game_id), .joy(joy2[8:0]), .board(j2), .menu(menu2_unused), .menu_p3(menu_p3_2_unused));
button_map bmap3 (.game_id(game_id), .joy(joy3[8:0]), .board(j3), .menu(menu3_unused), .menu_p3(menu_p3_3_unused));
button_map bmap4 (.game_id(game_id), .joy(joy4[8:0]), .board(j4), .menu(menu4_unused), .menu_p3(menu_p3_4_unused));

// Preserve the complete controller level, including Coin, through slot routing.
wire [7:0] j1_play = j1;
wire [7:0] j2_play = j2;
wire [7:0] j3_play = j3;

// Gas: MiSTer has no analog trigger, so it is a digital button (3rd J1 entry) driving the
// pedal to its two endpoints (0 = released, 255 = full).
wire [7:0] p1_gas = j1[6] ? 8'hFF : 8'h00;
wire [7:0] p2_gas = j2[6] ? 8'hFF : 8'h00;
wire [7:0] p3_gas = j3[6] ? 8'hFF : 8'h00;

// 4-player digital joystick for Pig Out: MiSTer's standard joystick vector low byte
// already matches leland_board's p*_joy layout ([0]=right [1]=left [2]=down [3]=up
// [4]=btn1 [5]=btn2), with the two spare fire bits used as start and coin.
// Each OSD tuple lists the slots assigned to controllers 1, 2 and 3.
// Choose before Coin/Start. Whole-port permutations preserve both actions,
// directions, Start and Coin, and cannot assign two controllers to one slot.
// Reserved values 6/7 and other games retain the ordinary assignment.
wire [2:0] asylum_slots = (game_id == GAME_ASYLUM) ? status[22:20] : 3'd0;
reg [7:0] slot1_joy, slot2_joy, slot3_joy;
always @(*) begin
	case (asylum_slots)
		3'd1: begin slot1_joy = j1_play; slot2_joy = j3_play; slot3_joy = j2_play; end // 1/3/2
		3'd2: begin slot1_joy = j2_play; slot2_joy = j1_play; slot3_joy = j3_play; end // 2/1/3
		3'd3: begin slot1_joy = j3_play; slot2_joy = j1_play; slot3_joy = j2_play; end // 2/3/1
		3'd4: begin slot1_joy = j2_play; slot2_joy = j3_play; slot3_joy = j1_play; end // 3/1/2
		3'd5: begin slot1_joy = j3_play; slot2_joy = j2_play; slot3_joy = j1_play; end // 3/2/1
		default: begin slot1_joy = j1_play; slot2_joy = j2_play; slot3_joy = j3_play; end
	endcase
end
wire [7:0] p1_joy = slot1_joy | {3'd0, ps2_mouse[0], 4'd0};
wire [7:0] p2_joy = slot2_joy;
wire [7:0] p3_joy = slot3_joy | menu_p3_1; // Legacy operator-menu helper; inactive for Asylum.
wire [7:0] p4_joy = j4;

//----------------------------------------------------------------
// Service / operator menu
//
// Asylum's P1 Service/Test assignment fires one timed press of the Test switch.
// The ROM checks player buttons after Test releases, so P1 Start stays held 50 ms longer.
//
// Inside the Off-Road menus P1's "Menu Enter" button (J1 bit 7, unused by the game)
// acts as Blue Nitro, so one controller can select (Nitro) and enter. The press is short
// enough that Blue Nitro is released before the menu is drawn; otherwise it would enter
// the first item. Only p3_btn and p1_joy[6] are touched.
//----------------------------------------------------------------
localparam [24:0] SVC_WINDOW = 25'd17_181_819;        // 300 ms at 630 MHz / 11
localparam [24:0] SVC_TEST_AT = 25'd14_318_182;       // Test + Blue Nitro for the last 250 ms
localparam [24:0] SVC_ASYLUM_WINDOW = 25'd20_045_455; // 350 ms Start hold
localparam [24:0] SVC_ASYLUM_TEST_AT = 25'd17_181_819;// Test begins after 50 ms
localparam [24:0] SVC_ASYLUM_RELEASE = 25'd2_863_636; // Start remains held 50 ms after Test
reg  [24:0] svc_cnt = 25'd0;
reg         svc_trig_d = 1'b0;
wire        svc_trigger = service_test1;
always @(posedge clk_sys) begin
	svc_trig_d <= svc_trigger;
	if (svc_trigger & ~svc_trig_d)
		svc_cnt <= (game_id == GAME_ASYLUM) ? SVC_ASYLUM_WINDOW : SVC_WINDOW;
	else if (svc_cnt != 25'd0)   svc_cnt <= svc_cnt - 1'd1;
end
wire svc_start = (svc_cnt != 25'd0);
wire svc_req = (svc_cnt != 25'd0) &&
	(svc_cnt <= ((game_id == GAME_ASYLUM) ? SVC_ASYLUM_TEST_AT : SVC_TEST_AT)) &&
	((game_id != GAME_ASYLUM) || (svc_cnt > SVC_ASYLUM_RELEASE));
// Asylum ROM 042f..0450 waits for Test release before checking player buttons.
// Keep board P1 Start held through that check, independent of controller routing.
wire svc_start_hold = svc_start;
wire svc_p3_button_hold = svc_req && (game_id != GAME_ASYLUM);
wire p3_nitro  = j3[4] | svc_p3_button_hold | menu1;

//----------------------------------------------------------------
// Completed foreground snapshot DDR client.
wire [28:0] snap_addr, video_ddr_addr;
wire [63:0] snap_din, snap_dout, video_ddr_din, video_ddr_dout;
wire snap_rd, snap_we, snap_busy, snap_ready;
wire video_ddr_rd, video_ddr_we, video_ddr_busy, video_ddr_ready, snapshot_mux_fault;
wire ddr_transport_fault;
// Board
//----------------------------------------------------------------
leland_board #(
	.FIXED_GAME_ID(GAME_ASYLUM),
	.ASYLUM_RENDER_SNAPSHOT(1),
	.TARGET_CLOCK_PROFILE(2),
	.CPU_PACING_PROFILE(1),
	.Z80_RECOVERY_PROFILE(1),
	.DL_SETTLE_CYCLES(14_318_182)
) board
(
	.clk_sys(clk_sys),
	.clk_sdram(clk_sdram),
	.clk_cap(clk_cap),
	.reset(reset),
	.sdram_init(sdram_init),

	// ROM loading
	.ioctl_download(ld_download),
	.ioctl_index(ld_index),
	.ioctl_wr(ld_wr),
	.ioctl_addr(ld_addr),
	.ioctl_data(ld_data),
	.ioctl_wait(board_wait),

	// EEPROM save: restore stream comes straight from hps_io (the DDR loader
	// replaces ld_* while it replays the ROM)
	.nvl_download(ioctl_download),
	.nvl_index(ioctl_index),
	.nvl_wr(ioctl_wr),
	.nvl_addr(ioctl_addr),
	.nvl_data(ioctl_dout),
	.nv_rd_addr(ioctl_addr[7:0]),
	.nv_rd_data(nv_rd_data),
	.nv_dirty(nv_dirty),
	.nv_dirty_clr(nv_dirty_clr),

	// SDRAM
	.SDRAM_DQ  (SDRAM_DQ),
	.SDRAM_A   (SDRAM_A),
	.SDRAM_BA  (SDRAM_BA),
	.SDRAM_CLK (SDRAM_CLK),
	.SDRAM_CKE (SDRAM_CKE),
	.SDRAM_nCS (SDRAM_nCS),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nWE (SDRAM_nWE),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),

	// Video output
	.ce_pix(ce_pix),
	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),
	.rgb(rgb),
 .snapshot_ddr_addr(snap_addr), .snapshot_ddr_din(snap_din),
 .snapshot_ddr_rd(snap_rd), .snapshot_ddr_we(snap_we),
 .snapshot_ddr_busy(snap_busy), .snapshot_ddr_dout(snap_dout),
 .snapshot_ddr_ready(snap_ready), .snapshot_transport_fault(snapshot_mux_fault | ddr_transport_fault),
 .snapshot_init(~pll_locked),

	// Player inputs (digital buttons + analog)
	//
	// Nitro and Coin are J1 buttons 1-2 (joystick bits 4-5): p1_btn[1] is nitro and
	// p1_btn[3] is coin, matching MAME's GIN0/GIN1 bit layout.
	.p1_btn({j1[5], 1'b0, j1[4], 1'b0}),
	.p2_btn({j2[5], 1'b0, j2[4], 1'b0}),
	.p3_btn({j3[5], 1'b0, p3_nitro, 1'b0}),
	// Wheel: free-running virtual dial from steering_input.sv.
	.p1_wheel(p1_wheel_pos),
	.p2_wheel(p2_wheel_pos),
	.p3_wheel(p3_wheel_pos),
	.p1_tb_x(p1_tb_x), .p1_tb_y(p1_tb_y),
	.p2_tb_x(p2_tb_x), .p2_tb_y(p2_tb_y),
	// Gas: digital button (J1's 3rd entry), 0/255 -- see p1_gas comment above.
	.p1_pedal(p1_gas),
	.p2_pedal(p2_gas),
	.p3_pedal(p3_gas),

	// 4-player digital joystick (Pig Out only).
	.p1_joy(p1_joy | {1'b0, svc_start_hold, 6'd0}),
	.p2_joy(p2_joy),
	.p3_joy(p3_joy),
	.p4_joy(p4_joy),

	// Service (Test) switch, driven by the OSD "Service Menu" action
	.service(svc_req),
	.game_id(game_id),
	.ax_video(ax_video),

	.audio_out(audio_out)
);

//----------------------------------------------------------------
// Video output to MiSTer framework
//----------------------------------------------------------------
// CRT retimer (rtl/video/leland_retimer.sv): by default the output is regenerated at NTSC 240p
// (15.73 kHz / 60.03 Hz) from a frame buffer while the game keeps running at its native
// 65.95 Hz. With Video Timing set to Native the game's own timing goes straight to the
// framework.
wire        rt_ce, rt_hb, rt_hs, rt_vb, rt_vs;
wire [23:0] rt_rgb;
wire [28:0] rt_ddr_addr;
wire [63:0] rt_ddr_din;
wire        rt_ddr_rd, rt_ddr_we;
wire        rt_ddr_busy, rt_ddr_rdata_ready;
wire [63:0] rt_ddr_rdata;
wire        rot_fb_vbl, rot_fb_ll;
wire        rot_fb_en, rot_fb_force_blank, rot_video_rotated, rot_active;
wire        rot_source_hs, rot_source_vs, rot_source_de;
wire [23:0] rot_source_rgb;
wire  [4:0] rot_fb_format;
wire [11:0] rot_fb_width, rot_fb_height;
wire [31:0] rot_fb_base;
wire [13:0] rot_fb_stride;
wire        rot_ddr_clk, rot_ddr_we, rot_ddr_rd;
wire  [7:0] rot_ddr_burstcnt, rot_ddr_be;
wire [28:0] rot_ddr_addr;
wire [63:0] rot_ddr_din;
wire        rot_queue_empty;

leland_retimer #(.TARGET_CLOCK_PROFILE(2)) retimer
(
	.clk_sys(clk_sys),
	// keep off the shared DDR3 bus while a ROM is downloading / replaying
 .stop(RESET | ~pll_locked | ioctl_download | ld_active | snapshot_mux_fault | ddr_transport_fault),

	.g_ce_pix(ce_pix),
	.g_hblank(HBlank),
	.g_vblank(VBlank),
	.g_rgb(rgb),
	.g_ax(ax_video),
	.vpos(status[16:13]),
	.vsize(status[19:17]),
	.o_ce_pix(rt_ce),
	.o_hblank(rt_hb),
	.o_hsync(rt_hs),
	.o_vblank(rt_vb),
	.o_vsync(rt_vs),
	.o_rgb(rt_rgb),

	.DDRAM_CLK(),
	.DDRAM_BUSY(rt_ddr_busy),
	.DDRAM_BURSTCNT(),
	.DDRAM_ADDR(rt_ddr_addr),
	.DDRAM_DOUT(rt_ddr_rdata),
	.DDRAM_DOUT_READY(rt_ddr_rdata_ready),
	.DDRAM_RD(rt_ddr_rd),
	.DDRAM_DIN(rt_ddr_din),
	.DDRAM_BE(),
	.DDRAM_WE(rt_ddr_we),
	.wf_overflow()
);

`ifdef MISTER_FB
assign rot_fb_vbl = FB_VBL;
assign rot_fb_ll = FB_LL;
assign FB_EN = rot_fb_en;
assign FB_FORMAT = rot_fb_format;
assign FB_WIDTH = rot_fb_width;
assign FB_HEIGHT = rot_fb_height;
assign FB_BASE = rot_fb_base;
assign FB_STRIDE = rot_fb_stride;
assign FB_FORCE_BLANK = rot_fb_force_blank;
`else
assign rot_fb_vbl = 1'b0;
assign rot_fb_ll = 1'b0;
`endif

leland_rotation_path rotation
(
	.reset(reset),
	.clk_video(clk_sys),
	.ce_pixel(CE_PIXEL),
	.rgb(rot_source_rgb),
	.hsync(rot_source_hs),
	.vsync(rot_source_vs),
	.de(rot_source_de),
	.asylum_game(game_id == GAME_ASYLUM),
	.direct_video(direct_video),
	.orientation(status[49:48]),
	.stream_busy(ioctl_download | ld_active),
	.fb_vbl(rot_fb_vbl),
	.fb_ll(rot_fb_ll),
	.ddram_busy(DDRAM_BUSY),
	.write_queue_empty(rot_queue_empty),
	.transport_fault(ddr_transport_fault),
	.video_rotated(rot_video_rotated),
	.rotation_active(rot_active),
	.fb_en(rot_fb_en),
	.fb_format(rot_fb_format),
	.fb_width(rot_fb_width),
	.fb_height(rot_fb_height),
	.fb_base(rot_fb_base),
	.fb_stride(rot_fb_stride),
	.fb_force_blank(rot_fb_force_blank),
	.rot_ddram_clk(rot_ddr_clk),
	.rot_burstcnt(rot_ddr_burstcnt),
	.rot_addr(rot_ddr_addr),
	.rot_din(rot_ddr_din),
	.rot_be(rot_ddr_be),
	.rot_we(rot_ddr_we),
	.rot_rd(rot_ddr_rd)
);

leland_ddr_client_mux render_ddr_mux (
 .clk(clk_sys), .reset(~pll_locked),
 .a_addr(rt_ddr_addr), .a_din(rt_ddr_din), .a_rd(rt_ddr_rd), .a_we(rt_ddr_we),
 .a_busy(rt_ddr_busy), .a_dout(rt_ddr_rdata), .a_ready(rt_ddr_rdata_ready),
 .b_addr(snap_addr), .b_din(snap_din), .b_rd(snap_rd), .b_we(snap_we),
 .b_busy(snap_busy), .b_dout(snap_dout), .b_ready(snap_ready),
 .addr(video_ddr_addr), .din(video_ddr_din), .rd(video_ddr_rd), .we(video_ddr_we),
 .busy(video_ddr_busy), .dout(video_ddr_dout), .ready(video_ddr_ready),
 .fault(snapshot_mux_fault));

leland_ddr_arbiter rotation_ddr
(
	.clk(clk_sys),
 .reset(~pll_locked),
	.rot_we(rot_ddr_we),
	.rot_addr(rot_ddr_addr),
	.rot_din(rot_ddr_din),
	.rot_be(rot_ddr_be),
	.rot_burstcnt(rot_ddr_burstcnt),
	.write_queue_empty(rot_queue_empty),
	.fault(ddr_transport_fault),
	.loader_acquire(ld_acq),
	.loader_addr(ld_ddr_addr),
	.loader_read(ld_ddr_read),
	.loader_busy(ld_ddr_busy),
	.loader_rdata(ld_ddr_rdata),
	.loader_rdata_ready(ld_ddr_rdata_ready),
	.retimer_addr(video_ddr_addr),
	.retimer_din(video_ddr_din),
	.retimer_read(video_ddr_rd),
	.retimer_we(video_ddr_we),
	.retimer_busy(video_ddr_busy),
	.retimer_rdata(video_ddr_dout),
	.retimer_rdata_ready(video_ddr_ready),
	.ddram_busy(DDRAM_BUSY),
	.ddram_rdata(DDRAM_DOUT),
	.ddram_rdata_ready(DDRAM_DOUT_READY),
	.ddram_addr(DDRAM_ADDR),
	.ddram_din(DDRAM_DIN),
	.ddram_be(DDRAM_BE),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_read(DDRAM_RD),
	.ddram_we(DDRAM_WE)
);

assign DDRAM_CLK = clk_sys;

wire crt_mode = ~status[12];

assign CLK_VIDEO = clk_sys;
wire [23:0] vid_rgb = crt_mode ? rt_rgb : rgb;
wire        vid_ce  = crt_mode ? rt_ce : ce_pix;
wire        vid_hs  = crt_mode ? rt_hs : HSync;
wire        vid_vs  = crt_mode ? rt_vs : VSync;
wire        vid_hb  = crt_mode ? rt_hb : HBlank;
wire        vid_vb  = crt_mode ? rt_vb : VBlank;

// Portable Credits overlay (MIT, credits/). Inserted before the presentation mixer and the
// downstream rotation, on the same video clock and pixel enable. Its inverse glyph
// orientation follows the rotation the presentation path will actually apply.
wire [23:0] credits_rgb;
wire        credits_hs, credits_vs, credits_hb, credits_vb, credits_de, credits_active;
wire        credits_dismiss = |{joy1, joy2, joy3, joy4} | |buttons | ps2_key[9] | |ps2_mouse[2:0] | OSD_STATUS;
wire  [1:0] credits_rotation = !(game_id == GAME_ASYLUM) || direct_video ? 2'd0 :
                               status[49:48] == 2'd0 ? 2'd3 :
                               status[49:48] == 2'd1 ? 2'd1 :
                               status[49:48] == 2'd3 ? 2'd2 : 2'd0;
credits_overlay #(.WIDTH(320), .HEIGHT(240)) credits
(
	.clk_video(clk_sys),
	.reset(RESET | ~pll_locked),
	.ce_pixel(vid_ce),
	.menu_trigger(status[120]),
	.dismiss(credits_dismiss),
	.rotation(credits_rotation),
	.r_in(vid_rgb[23:16]), .g_in(vid_rgb[15:8]), .b_in(vid_rgb[7:0]),
	.hs_in(vid_hs), .vs_in(vid_vs),
	.hblank_in(vid_hb), .vblank_in(vid_vb),
	.r_out(credits_rgb[23:16]), .g_out(credits_rgb[15:8]), .b_out(credits_rgb[7:0]),
	.hs_out(credits_hs), .vs_out(credits_vs),
	.hblank_out(credits_hb), .vblank_out(credits_vb),
	.de_out(credits_de), .active(credits_active)
);

// CRT Adjust: fixed-cadence H-Size / H-Position / V-Shift on the native raster. The picture
// content moves through a line buffer while sync stays native, so a CRT never loses lock.
// Available only for native timing without HDMI rotation (leland_crt_fixed.crt_eligible).
wire        crt_ce, crt_hs, crt_vs, crt_hb, crt_vb;
wire [23:0] crt_rgb;
wire        crt_eligible, crt_range_clamped, crt_cadence_fault, crt_raster_fault, crt_cadence_ok, crt_raster_ok;
wire        crt_dv_unused, crt_fs_unused;
wire        crt_on = status[54] && crt_eligible;
leland_crt_fixed crt_adjust
(
	.clk_sys(clk_sys),
	.reset(RESET | ~pll_locked),
	.ce_pix(vid_ce),
	.hsize_pixels($signed(7'(crt_menu_decode(int'(status[61:55]), CRT_HSIZE_MIN, CRT_HSIZE_MAX, 7)))),
	.hposition($signed(8'(crt_menu_decode(int'(status[66:62]), CRT_HPOS_MIN, CRT_HPOS_MAX, 5)))),
	.vshift($signed(6'(crt_menu_decode(int'(status[71:67]), CRT_VPOS_MIN, CRT_VPOS_MAX, 5)))),
	.native_profile(1'b1),
	.retimer_selected(crt_mode),
	.rotation_active(rot_active),
	.direct_video(direct_video),
	.forced_scandoubler(forced_scandoubler),
	.direct_video_out(crt_dv_unused),
	.forced_scandoubler_out(crt_fs_unused),
	.crt_eligible(crt_eligible),
	.pixel_cadence_ok(crt_cadence_ok),
	.raster_qualified(crt_raster_ok),
	.range_clamped(crt_range_clamped),
	.cadence_fault(crt_cadence_fault),
	.raster_fault(crt_raster_fault),
	.rgb_in(credits_rgb),
	.hs_in(credits_hs),
	.vs_in(credits_vs),
	.hb_in(credits_hb),
	.vb_in(credits_vb),
	.ce_out(crt_ce),
	.rgb_out(crt_rgb),
	.hs_out(crt_hs),
	.vs_out(crt_vs),
	.hb_out(crt_hb),
	.vb_out(crt_vb)
);

leland_display display
(
	.clk_video(clk_sys),
	.rgb_in(crt_on ? crt_rgb : credits_rgb),
	.ce_pix_in(vid_ce),
	.hsync_in(crt_on ? crt_hs : credits_hs),
	.vsync_in(crt_on ? crt_vs : credits_vs),
	.hblank_in(crt_on ? crt_hb : credits_hb),
	.vblank_in(crt_on ? crt_vb : credits_vb),
	.fx((direct_video || rot_active) ? 3'd0 : status[52:50]),
	.forced_scandoubler(forced_scandoubler),
	.aspect_mode(ar),
	.scale_mode(status[47:46]),
	.rotation_active(rot_active),
	.video_rotated(rot_video_rotated),
	.rotated_width(rot_fb_width),
	.rotated_height(rot_fb_height),
	.hdmi_width(HDMI_WIDTH),
	.hdmi_height(HDMI_HEIGHT),
	.ce_pixel(CE_PIXEL),
	.vga_hs(VGA_HS),
	.vga_vs(VGA_VS),
	.vga_sl(VGA_SL),
	.vga_de(VGA_DE),
	.vga_r(VGA_R),
	.vga_g(VGA_G),
	.vga_b(VGA_B),
	.video_arx(display_arx),
	.video_ary(display_ary),
	.rotate_rgb(rot_source_rgb),
	.rotate_hs(rot_source_hs),
	.rotate_vs(rot_source_vs),
	.rotate_de(rot_source_de)
);

assign video_rotated = rot_video_rotated;

// Menu visibility (H flags): 0 steering (not Asylum), 1 retimer-only controls hidden in native
// timing, 2 host scaling hidden in Direct Video, 3 CRT Adjust unavailable, 4 orientation outside
// Asylum or Direct Video, 5 CRT sub-options while Off, 6 Scandoubler Fx in Direct Video/rotation.
assign status_menumask = {9'd0, (direct_video || rot_active), !status[54], ((game_id != GAME_ASYLUM) || direct_video),
						  !crt_eligible, direct_video, status[12], (game_id == GAME_ASYLUM)};

endmodule
