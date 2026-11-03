//============================================================================
//
//  Seta X1-010 hardware for MiSTer -- seta/seta.cpp, Group A.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================
//
//
// Framework glue: hps_io, PLL, resets and fast ROM load, input assembly, the
// debug probes and the video output chain. The game is
// rtl/seta_core.sv.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports this core does not use /////////

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

// MISTER_FB is defined for the rotator; the forced blank is unused.
assign FB_FORCE_BLANK = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

wire signed [15:0] core_audio_l, core_audio_r;
assign AUDIO_S   = 1;
assign AUDIO_L   = core_audio_l;
assign AUDIO_R   = core_audio_r;
// OSD Audio mix: Mono (default), None, 25%, 50%; AUDIO_MIX 3 is mono
assign AUDIO_MIX = (status[124:123] == 2'd0) ? 2'd3 : status[124:123] - 2'd1;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

wire  [1:0] game_rot;   // from seta_core, driven by the mod byte

// Rotation: Auto follows the set's ROT (seta_board_cfg.sv game_rot).
wire [1:0] rot_sel   = status[64:63];
wire       rotate_en = (rot_sel == 2'd0) ? (game_rot != 2'd0)
                     : (rot_sel != 2'd1);
wire       rotate_ccw = (rot_sel == 2'd0) ? (game_rot == 2'd2)
                      : (rot_sel == 2'd3);
wire       flip_180   = status[65];
// Undo the framebuffer rotation for screen-relative analog movement and aim.
// Direct video keeps the native raster. The rotator ignores flip during 90deg rotation.
wire direct_video;
// Hardware feedback: the game's movement/aim basis is 90deg clockwise
// from the quantizer's compass. Undo that before the display transform.
wire [2:0] stick_screen_to_game = 3'd6 + (direct_video ? 3'd0 :
    rotate_en ? (rotate_ccw ? 3'd2 : 3'd6) : (flip_180 ? 3'd4 : 3'd0));

// 4:3 screen (3:4 when rotated).
wire [11:0] base_arx = rotate_en ? 12'd3 : 12'd4;
wire [11:0] base_ary = rotate_en ? 12'd4 : 12'd3;

`include "build_id.v"

// The Debug page (H1) is hidden in the release revision.
`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif
wire debug_menu_hide = DEBUG_MENU_HIDE;
localparam CORE_NAME = "Seta_Downtown";
// rotary joysticks as the Ikari Warriors core has them (rtl/downtown/rotary_input.sv)
`define CONF_ROT "H3P2O[114:113],Rotary Speed,Normal,Slow,Fast,Very Fast;", "H3P2O[115],GRS Keystroke Mode,Off,On;", "H3P2-;",
`define CONF_J1 "J1,Punch,Kick,Rotate Left,Rotate Right,-,-,Start,Coin,Pause,Service;",
localparam CONF_STR = {
	CORE_NAME, ";;",
	"P1,Video Settings;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[64:63],Rotation,Auto,Off,CW,CCW;",
	"P1O[65],Flip 180,Off,On;",
	"P1O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1O[70:69],Crop,Off,216 lines,224 lines;",
	"P1O[75:71],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P2O[124:123],Audio mix,Mono,None,25%,50%;",
	"-;",
	"P1O[94],CRT Adjust,Off,On;",
	"H2P1O[99:95],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2P1O[106:100],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2P1O[112:107],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"P2,Game Settings;",
	`CONF_ROT
	"DIP;",
	"-;",
	"H1P3,Debug;",
	"H1P3-;",
	"H1P3O[80],Sprites,On,Off;",
	"H1P3O[83],Tilemap 0,On,Off;",
	"H1P3O[84],Tilemap 1,On,Off;",
	"H1P3O[81],PCM sound,On,Off;",
	"H1P3O[82],Pause CPU,Off,On;",
	"H1P3O[93],Tile row cache,On,Off;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// entry i is joystick bit 4 + i, matching the .mra <buttons>
	`CONF_J1
	"jn,A,B,Start,Select,R;",
	"v,0;",
	"P2O[117:116],Aim Speed,Normal,Slow,Instant;",
"P2O[119:118],Aim Deadzone,Normal,Small,Large,Extra Large;",
"P2O[120],Stick Autofire,Off,On;",
"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire  [7:0] ioctl_din;
wire        nvram_save;
wire        ioctl_upload;
wire  [1:0] dbg_nv_state;
wire  [7:0] dbg_nv_saves;

// H4: the rotary options, shown for DownTown and Caliber 50 only (set below)
wire rot_menu_hide;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	.status_menumask({12'd0, rot_menu_hide, ~status[94], debug_menu_hide, 1'b0}),  // H1 Debug, H2 CRT adjust, H3 rotary

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.joystick_l_analog_0(joystick_l_analog_0),
.joystick_r_analog_0(ts_r0),.joystick_r_analog_1(ts_r1),
	.joystick_l_analog_1(joystick_l_analog_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

		// .mra <nvram index="4"> file, read back on seta_core's request
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 96 MHz: every clock enable is an integer divide. outclk_1 is 96 MHz at 180
// degrees for SDRAM_CLK.
wire clk_sys, clk_sdram_shifted, clk_video, clk_sdram_capture, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.outclk_2(clk_video),
	.outclk_3(clk_sdram_capture),
	.locked(pll_locked)
);

// Forward the same96MHz/+180degree waveform through a dedicated DDIO.
// The previous shifted-PLL-to-pad fabric route added nearly6ns of skew.
// PLL frequencies/phases remain unchanged; STA models the actual DDIO pin.
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_sys),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

///////////////////////   RESET   ////////////////////////////////

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// core_reset holds the game; mem_reset keeps the memory path live during the
// download, when MiSTer holds reset. The fast load holds the game in reset
// until a ROM is in SDRAM (rom_loaded) and while the copy runs (ldr_active).
wire ldr_active;
reg  rom_loaded = 1'b0, dl_index0_seen = 1'b0, ldr_active_d = 1'b0;
always @(posedge clk_sys) begin
	ldr_active_d <= ldr_active;
	if (ioctl_wr && ioctl_index == 16'd0)  dl_index0_seen <= 1'b1;   // the byte path wrote SDRAM
	if (dl_index0_seen && !ioctl_download) rom_loaded     <= 1'b1;
	if (ldr_active_d && !ldr_active)       rom_loaded     <= 1'b1;   // the copy finished
end

wire core_reset = reset | (ioctl_download && ioctl_index != 16'd254) | ~rom_loaded | ldr_active;
wire mem_reset  = reset & ~ioctl_download;

// Fast ROM load (rtl/memory/rom_loader.sv). With address="0x30000000" on the
// .mra's index-0 ROM the HPS loads DDR3 and the download has no ioctl_wr; the
// copy starts on the next reset release. ldr_done stops later resets copying
// again.
reg  dl_active_d = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0;
reg  ldr_done    = 1'b0, dl_seen_wr  = 1'b0;
wire dl_index0 = ioctl_download && (ioctl_index == 16'd0);

always @(posedge clk_sys) begin
	ldr_start   <= 1'b0;
	dl_active_d <= dl_index0;
	if (dl_index0 && !dl_active_d)  dl_seen_wr <= 1'b0;   // a new index-0 load begins
	else if (dl_index0 && ioctl_wr) dl_seen_wr <= 1'b1;   // ...and it is streaming bytes

	if (dl_index0 && !dl_active_d) ldr_done <= 1'b0;

	if (reset) begin
		ldr_pending <= 1'b1;
	end else if (ldr_pending && !ioctl_download && !ldr_active) begin
		ldr_pending <= 1'b0;
		if (!dl_seen_wr && !ldr_done) begin
			ldr_start <= 1'b1;
			ldr_done  <= 1'b1;
		end
	end
end

// the loader's side of the DDR3 mux
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;
wire [7:0]  ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
wire [63:0] ldr_DDRAM_DIN;

ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(reset),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT),
	.DDRAM_ADDR(ldr_DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);

///////////////////   .mra: mod byte and DIPs   //////////////////

// <rom index="1">: the game (downtown_board_cfg.sv)
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd1)) mod_byte <= ioctl_dout;

// downtown_board_cfg.sv: DT_DOWNTOWN..DT_DOWNTOWNP 0-3, DT_CALIBR50 7
assign rot_menu_hide = !(mod_byte[4:0] <= 5'd3 || mod_byte[4:0] == 5'd7);

// <switches> (index 254): sw[0] = DSW offset 0 (high byte, SW1), sw[1] =
// offset 1 (SW2), sw[2] = DIP bits in the COINS port's top nibble.
reg [7:0] sw[8];
reg [7:0] sw_pending[8];
integer dip_i;
initial for(dip_i=0;dip_i<8;dip_i=dip_i+1) begin
 sw[dip_i]=8'hff;sw_pending[dip_i]=8'hff;
end
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
		sw_pending[ioctl_addr[2:0]] <= ioctl_dout;
 if(reset || !rom_loaded || dl_index0)
  for(integer d=0;d<8;d=d+1) sw[d]<=sw_pending[d];
end

wire [15:0] dsw_in = {sw[0], sw[1]};

///////////////////////   INPUTS   ///////////////////////////////

wire [2:0] input_layout;

// Driver ports are active low. input_layout 0 is common_type1 (LEFT 0,
// RIGHT 1, UP 2, DOWN 3), 1 is common_type2 (UP 0, DOWN 1, LEFT 2, RIGHT 3);
// both have B1 B2 at 4-5 and START at 7. COINS: type1 COIN1 0, COIN2 1,
// START1 2, START2 3, SERVICE1 4, TILT 5; type2 TILT 4, SERVICE1 5, COIN2 6,
// COIN1 7. MiSTer joystick: 0 R, 1 L, 2 D, 3 U, buttons 1-6 at 4-9, Start 10,
// Coin 11, Pause 12, Service 13.
function automatic [7:0] dt_port(input [31:0] j, input [2:0] layout);
	dt_port = (layout == 3'd1) ? {j[10], 1'b0, j[5], j[4], j[0], j[1], j[2], j[3]}
	                           : {j[10], 1'b0, j[5], j[4], j[2], j[3], j[0], j[1]};
endfunction
// downtown.cpp's coins are PORT_IMPULSE(5): a press is five frames of coin,
// however long the button is held (a held coin miscounted on DownTown and
// Twin Eagle). dt_coin[i] is player i+1's, driven below after core_vb.
reg  [1:0] dt_coin = 2'b00;
wire [31:0] screen_joystick0,screen_joystick1;
screen_relative_dpad map_dpad0(.joystick(joystick_0),.screen_to_game(mod_byte[4:0]==0 ? stick_screen_to_game : 3'd0),.mapped(screen_joystick0));
screen_relative_dpad map_dpad1(.joystick(joystick_1),.screen_to_game(mod_byte[4:0]==0 ? stick_screen_to_game : 3'd0),.mapped(screen_joystick1));
wire [15:0] p1_in = ~{8'h00, dt_port(screen_joystick0 | {27'd0,ts_fire0,ts_move0}, input_layout)};
wire [15:0] p2_in = ~{8'h00, dt_port(screen_joystick1 | {27'd0,ts_fire1,ts_move1}, input_layout)};
wire [15:0] coins_in = (input_layout == 3'd1)
	? ~{8'h00, dt_coin[0], dt_coin[1], joystick_0[13], 1'b0, 4'h0}
	: ~{8'h00, 2'b00, 1'b0, joystick_0[13], joystick_1[10], joystick_0[10], dt_coin[1], dt_coin[0]};

// Rotary joysticks: Rotate Left / Rotate Right (buttons 3 and 4), stepping
// while held, as the Ikari Warriors core. DownTown reads a 12-position switch;
// Caliber 50 a uPD4701 count, 4 counts a position.
wire [15:0] ts_r0,ts_r1;wire [3:0] ts_move0,ts_move1;
wire ts_fire0,ts_fire1;wire [11:0] ts_rot0,ts_rot1;wire [1:0] ts_strobe;wire [2:0] ts_actual0,ts_actual1;
function automatic [3:0] ts_position(input [11:0] raw);
 integer k;begin ts_position=0;for(k=0;k<12;k=k+1)if(raw==(12'b1<<k))ts_position=k>=4?k-4:k+8;end
endfunction
relative8_aim_controls #(.CLOCK_HZ(96000000)) ts_controls(
 .clk(clk_sys),.reset(reset),.paused(pause_core),.enabled(mod_byte[4:0]==0),.screen_to_game(stick_screen_to_game),
 .legacy_mode(2'b0),.legacy0(12'd0),.legacy1(12'd0),
 .left0(joystick_l_analog_0),.right0(ts_r0),.left1(joystick_l_analog_1),.right1(ts_r1),
 .speed(status[117:116]),.deadzone(status[119:118]),.autofire(status[120]),.manual_fast(1'b0),
 .manual_left(rot_step_l),.manual_right(rot_step_r),
 .actual_strobe(ts_strobe),.actual0(ts_actual0),.actual1(ts_actual1),
 .move0(ts_move0),.move1(ts_move1),.rotary0(ts_rot0),.rotary1(ts_rot1),.fire0(ts_fire0),.fire1(ts_fire1));
wire [1:0] rot_step_l, rot_step_r;
rotary_input u_rot (
	.clk(clk_sys), .reset(reset),
	.speed(status[114:113]), .grs(status[115]), .ps2_key(ps2_key),
	.btn_left({joystick_1[6], joystick_0[6]}),
	.btn_right({joystick_1[7], joystick_0[7]}),
	.step_left(rot_step_l), .step_right(rot_step_r)
);
reg  [3:0] rot_pos [0:1];
reg [11:0] rot_cnt [0:1];
integer ri;
always @(posedge clk_sys) begin
	for (ri = 0; ri < 2; ri = ri + 1) begin
		if (reset) begin
			rot_pos[ri] <= 4'd0;
			rot_cnt[ri] <= 12'd0;
		end else if (rot_step_l[ri]) begin
			rot_pos[ri] <= (rot_pos[ri] == 4'd0) ? 4'd11 : rot_pos[ri] - 4'd1;
			rot_cnt[ri] <= rot_cnt[ri] - 12'd4;
		end else if (rot_step_r[ri]) begin
			rot_pos[ri] <= (rot_pos[ri] == 4'd11) ? 4'd0 : rot_pos[ri] + 4'd1;
			rot_cnt[ri] <= rot_cnt[ri] + 12'd4;
		end
	end
end

// Pause: joystick bit 12 toggles; the Debug page's Pause CPU is ORed in.
wire pause_btn = joystick_0[12] | joystick_1[12];
reg  pause_btn_d, pause_toggle;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                          pause_toggle <= 1'b0;
	else if (pause_btn & ~pause_btn_d)  pause_toggle <= ~pause_toggle;
end
wire        dbg_rd_en;
wire [12:0] dbg_rd_idx;
wire [31:0] dbg_spr_rd;
wire pause_core = pause_toggle | status[82] | dbg_rd_en;

///////////////////////   THE GAME   /////////////////////////////

wire [7:0] core_r, core_g, core_b;
wire       core_hs, core_vs, core_hb, core_vb, core_de, core_ce;

// core_ce is one clk_sys cycle; stretched to two so exactly one clk_video
// (48 MHz) edge samples it.
reg core_ce_d;
always @(posedge clk_sys) core_ce_d <= core_ce;
wire core_ce_v = core_ce | core_ce_d;

// dt_coin: a Coin press starts five frames of coin, counted on vblank rise
reg       core_vb_d;
reg [1:0] dt_coin_btn_d = 2'b00;
reg [2:0] dt_coin_left [0:1];
always @(posedge clk_sys) begin
	core_vb_d <= core_vb;
	for (int c = 0; c < 2; c++) begin
		dt_coin_btn_d[c] <= c ? joystick_1[11] : joystick_0[11];
		if (reset) begin
			dt_coin[c]      <= 1'b0;
			dt_coin_left[c] <= 3'd0;
		end else if ((c ? joystick_1[11] : joystick_0[11]) && !dt_coin_btn_d[c] && !dt_coin[c]) begin
			dt_coin[c]      <= 1'b1;
			dt_coin_left[c] <= 3'd5;
		end else if (dt_coin[c] && core_vb && !core_vb_d) begin
			if (dt_coin_left[c] == 3'd1) dt_coin[c] <= 1'b0;
			dt_coin_left[c] <= dt_coin_left[c] - 3'd1;
		end
	end
end

wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun;
wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped;
wire [63:0] dbg_snap;
wire [15:0] dbg_snd_samples, dbg_snd_overrun, dbg_snd_rom_reads;
wire  [7:1] dbg_irq_pending;
wire [23:0] dbg_last_rom;
wire [15:0] dbg_rom_fetches, dbg_wram_writes, dbg_io_reads;
wire [23:0] dbg_last_io;
wire [23:0] dbg_last_vec;
wire [479:0] dbg_pc_ring;
wire         dbg_pc_frozen;
wire [23:3] dbg_l0_last_addr;
wire [63:0] dbg_l0_last_data;
wire [15:0] dbg_l0_cut, dbg_l0_hits, dbg_l0_overrun;
wire [15:0] dbg_l1_cut, dbg_l1_hits, dbg_l1_overrun;

// download high-water mark, 4 KB units
reg [13:0] dbg_dl_max4k = 14'd0;
always @(posedge clk_sys) begin
	if (ioctl_download && ioctl_wr && ioctl_addr[26:12] > {1'b0, dbg_dl_max4k})
		dbg_dl_max4k <= ioctl_addr[25:12];
end

wire [15:0] dbg_w_pal, dbg_w_l0v, dbg_w_l1v, dbg_w_l0c, dbg_w_l1c, dbg_w_vregs, dbg_w_sprc, dbg_w_x1snd;
wire        dbg_cpu_stb, dbg_cpu_we;
wire [23:1] dbg_cpu_addr;
wire [15:0] dbg_cpu_data;

seta_core seta_core
(
	.clk(clk_sys),
	.clk_capture(clk_sdram_capture),
	.reset(core_reset),
	.mem_reset(mem_reset),
	.init(~pll_locked),

	.game(mod_byte[4:0]),
	.game_rot(game_rot), .input_layout(input_layout),
	.narrow_320(),

	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
	// driven by the PLL
	.SDRAM_CLK(),

	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_din(ioctl_din), .nvram_save(nvram_save),
	.ldr_start(ldr_start), .ldr_active(ldr_active),
	.ldr_ddr_req(ldr_ddr_req), .ldr_ddr_addr(ldr_ddr_addr),
	.ldr_ddr_busy(ldr_ddr_busy), .ldr_ddr_valid(ldr_ddr_valid),
	.ldr_ddr_rdata(ldr_ddr_rdata),

	.p1_in(p1_in), .p2_in(p2_in), .coins_in(coins_in), .dsw_in(dsw_in),
	.aim_strobe(ts_strobe),.aim_actual0(ts_actual0),.aim_actual1(ts_actual1),
.rot1(mod_byte[4:0]==0 ? ts_position(ts_rot0):rot_pos[0]), .rot2(mod_byte[4:0]==0 ? ts_position(ts_rot1):rot_pos[1]),
	.dial1(rot_cnt[0]), .dial2(rot_cnt[1]),

	.pause_cpu(pause_core),
	.dbg_rd_en(dbg_rd_en), .dbg_rd_idx(dbg_rd_idx), .dbg_spr_rd(dbg_spr_rd),
	.en_spr(~status[80]),
	.en_pcm(~status[81]),
	.en_l0(~status[83]), .en_l1(~status[84]),
	.tile_cache_en(~status[93]),

	.video_r(core_r), .video_g(core_g), .video_b(core_b),
	.video_hs(core_hs), .video_vs(core_vs),
	.video_hb(core_hb), .video_vb(core_vb),
	.video_de(core_de), .video_ce(core_ce),

	.audio_l(core_audio_l), .audio_r(core_audio_r),

	.dbg_last_rom(dbg_last_rom), .dbg_rom_fetches(dbg_rom_fetches),
	.dbg_wram_writes(dbg_wram_writes), .dbg_io_reads(dbg_io_reads),
	.dbg_last_io(dbg_last_io), .dbg_last_vec(dbg_last_vec),
	.dbg_pc_ring(dbg_pc_ring), .dbg_pc_frozen(dbg_pc_frozen),
	.dbg_l0_last_addr(dbg_l0_last_addr),
	.dbg_l0_last_data(dbg_l0_last_data),
	.dbg_l0_cut(dbg_l0_cut), .dbg_l0_hits(dbg_l0_hits),
	.dbg_l0_overrun(dbg_l0_overrun),
	.dbg_l1_cut(dbg_l1_cut), .dbg_l1_hits(dbg_l1_hits),
	.dbg_l1_overrun(dbg_l1_overrun),
	.dbg_w_pal(dbg_w_pal),
	.dbg_w_l0v(dbg_w_l0v),
	.dbg_w_l1v(dbg_w_l1v),
	.dbg_w_l0c(dbg_w_l0c),
	.dbg_w_l1c(dbg_w_l1c),
	.dbg_w_vregs(dbg_w_vregs),
	.dbg_w_sprc(dbg_w_sprc),
	.dbg_w_x1snd(dbg_w_x1snd),
	.dbg_lines(dbg_lines), .dbg_sprites(dbg_sprites),
	.dbg_fetches(dbg_fetches), .dbg_overrun(dbg_overrun),
	.dbg_worst_line(dbg_worst_line), .dbg_worst_sprites(dbg_worst_sprites),
	.dbg_dropped(dbg_dropped), .dbg_snap(dbg_snap),
	.dbg_snd_samples(dbg_snd_samples), .dbg_snd_overrun(dbg_snd_overrun),
	.dbg_snd_rom_reads(dbg_snd_rom_reads),
	.dbg_irq_pending(dbg_irq_pending),
	.dbg_cpu_stb(dbg_cpu_stb), .dbg_cpu_addr(dbg_cpu_addr),
	.dbg_cpu_we(dbg_cpu_we), .dbg_cpu_data(dbg_cpu_data),
	.dbg_nv_state(dbg_nv_state), .dbg_nv_saves(dbg_nv_saves)
);

// Probes: Seta_stp revision only (`DEBUG_ISSP).
`ifdef DEBUG_ISSP
// Instance F, 128 bits (scripts/read_issp.tcl decodes):
//   [ 15:  0]  dbg_lines           [ 31: 16]  dbg_sprites
//   [ 47: 32]  dbg_overrun         [ 63: 48]  dbg_dropped
//   [ 79: 64]  dbg_worst_sprites   [ 95: 80]  dbg_snd_samples
//   [111: 96]  dbg_snd_rom_reads   [119:112]  dbg_snd_overrun[7:0]
//   [126:120]  dbg_irq_pending     [    127]  pll_locked
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_issp (
	.clk(clk_sys),
	.probe({
		pll_locked,
		dbg_irq_pending,
		dbg_snd_overrun[7:0],
		dbg_snd_rom_reads,
		dbg_snd_samples,
		dbg_worst_sprites,
		dbg_dropped,
		dbg_overrun,
		dbg_sprites,
		dbg_lines
	}),
	.source()
);

// Instance A, 488 bits: pc0 (newest) .. pc19 at 24-bit steps, [480] frozen.
issp_probe #(.INSTANCE_ID("A"), .PROBE_W(488), .SOURCE_W(8)) u_issp_pc (
	.clk(clk_sys),
	.probe({7'd0, dbg_pc_frozen, dbg_pc_ring}),
	.source()
);

// Instance B: [63:0] dbg_l0_last_data, [84:64] dbg_l0_last_addr (x8 = byte in
// gfx2), [108:85] dbg_last_vec.
issp_probe #(.INSTANCE_ID("B"), .PROBE_W(128), .SOURCE_W(8)) u_issp_gran (
	.clk(clk_sys),
	.probe({19'd0, dbg_last_vec, dbg_l0_last_addr, dbg_l0_last_data}),
	.source()
);

// Instance C: dbg_l0_cut, _hits, _overrun at [15:0], [31:16], [47:32]; layer 1
// at [63:48], [79:64], [95:80]; [127:96] stick inputs (below).
issp_probe #(.INSTANCE_ID("C"), .PROBE_W(128), .SOURCE_W(8)) u_issp_tile (
	.clk(clk_sys),
	.probe({
		// [99:96] joystick_0[3:0], [103:100] joystick_1[3:0],
		// [113:104] P1 analog {y[7:3], x[7:3]}, [123:114] P2
		4'd0,
		joystick_l_analog_1[15:11], joystick_l_analog_1[7:3],
		joystick_l_analog_0[15:11], joystick_l_analog_0[7:3],
		joystick_1[3:0], joystick_0[3:0],
		dbg_l1_overrun, dbg_l1_hits, dbg_l1_cut,
		dbg_l0_overrun, dbg_l0_hits, dbg_l0_cut
	}),
	.source()
);

// Instance D: [23:0] dbg_last_rom, [39:24] dbg_rom_fetches, [55:40]
// dbg_wram_writes, [71:56] dbg_io_reads, [85:72] dbg_dl_max4k, [109:86]
// dbg_last_io, [110] OSD open, [111] nv_armed, [112] nv_dirty, [113]
// ioctl_upload, [121:114] dbg_nv_saves.
issp_probe #(.INSTANCE_ID("D"), .PROBE_W(128), .SOURCE_W(8)) u_issp_cpu (
	.clk(clk_sys),
	.probe({
		6'd0,
		dbg_nv_saves, ioctl_upload, dbg_nv_state, OSD_STATUS,
		dbg_last_io,
		dbg_dl_max4k,
		dbg_io_reads,
		dbg_wram_writes,
		dbg_rom_fetches,
		dbg_last_rom
	}),
	.source()
);

// Instance E, CPU writes per region: pal, l0v, l1v, l0c, l1c, vregs, sprc,
// x1snd at 16 bits each from [15:0].
issp_probe #(.INSTANCE_ID("E"), .PROBE_W(128), .SOURCE_W(8)) u_issp_io (
	.clk(clk_sys),
	.probe({
		dbg_w_x1snd,
		dbg_w_sprc,
		dbg_w_vregs,
		dbg_w_l1c,
		dbg_w_l0c,
		dbg_w_l1v,
		dbg_w_l0v,
		dbg_w_pal
	}),
	.source()
);
// Instance G, sprite snapshot timing: [15:0] code writes dropped under setac_eof,
// [31:16] frames with a sprite write during setac_eof or the snapshot, [47:32]
// line of the last sprite write at the latest snapshot, [63:48] its maximum.
issp_probe #(.INSTANCE_ID("G"), .PROBE_W(64), .SOURCE_W(8)) u_issp_snap (
	.clk(clk_sys),
	.probe(dbg_snap),
	.source()
);
// Instance H, sprite RAM readback: source {en, 2'b0, idx[12:0]} pauses the CPU
// and selects a code word / Y byte / control byte; probe {ctrl, ylow, code}.
wire [15:0] dbg_rd_src;
issp_probe #(.INSTANCE_ID("H"), .PROBE_W(32), .SOURCE_W(16)) u_issp_sprrd (
	.clk(clk_sys),
	.probe(dbg_spr_rd),
	.source(dbg_rd_src)
);
assign dbg_rd_en  = dbg_rd_src[15];
assign dbg_rd_idx = dbg_rd_src[12:0];
`else
assign dbg_rd_en  = 1'b0;
assign dbg_rd_idx = 13'd0;
`endif  // DEBUG_ISSP

///////////////////////   VIDEO   ////////////////////////////////

// CLK_VIDEO and CE_PIXEL are driven by arcade_video.
wire vga_de_raw;

// The output chain runs at clk_video, 48 MHz (half clk_sys, same PLL): the
// scandoubler/HQ2x blender does not meet timing at 96 MHz.
//
// CRT adjust (rtl/video/seta_crt.sv); bypassed when it is off or the
// scandoubler runs.
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb, crt_on, crt_ce;

seta_crt u_crt (
	.clk(clk_sys), .ce(core_ce),
	.adjust(status[94] & ~forced_scandoubler),
	.hsize_idx(status[99:95]), .hpos_idx(status[106:100]), .vshift_idx(status[112:107]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.active(crt_on), .ce_out(crt_ce),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_video),
	.ce_pix(crt_on ? crt_ce : core_ce_v),

	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : {core_r, core_g, core_b}),
	.HBlank(crt_on ? crt_hb : core_hb),
	.VBlank(crt_on ? crt_vb : core_vb),
	.HSync(crt_on ? crt_hs : core_hs),
	.VSync(crt_on ? crt_vs : core_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// lines kept of 240: 216 (5x on 1080) or 224
wire  [1:0] vcrop_sel = status[70:69];
wire [11:0] crop_size = (vcrop_sel == 2'd1) ? 12'd216 :
                        (vcrop_sel == 2'd2) ? 12'd224 : 12'd0;

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX((!ar) ? base_arx : (ar - 1'd1)),
	.ARY((!ar) ? base_ary : 12'd0),
	.CROP_SIZE(crop_size),
	.CROP_OFF(status[75:71]),
	.SCALE(status[68:66])
);

// HDMI rotation and flip: screen_rotate_two taps the output into DDR3 for the
// HPS framebuffer; the analog output keeps the native raster. Not the game's
// Flip Screen DIP.
wire        rot_DDRAM_CLK, rot_DDRAM_WE, rot_DDRAM_RD;
wire [7:0]  rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;

screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(flip_180),
	.two_screen(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	// DDR3 goes to the ROM loader while it runs (core in reset, no picture)
	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_active),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR(rot_DDRAM_ADDR),
	.DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE),
	.DDRAM_WE(rot_DDRAM_WE),
	.DDRAM_RD(rot_DDRAM_RD)
);

assign DDRAM_CLK      = ldr_active ? clk_sys            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : rot_DDRAM_RD;

endmodule
