//============================================================================
//
//  Xybots (Atari Games, 1987) MiSTer FPGA core — top-level glue (emu).
//
//  This is the MiSTer `emu` wrapper around rtl/xybots_core.sv, which holds the
//  whole game: the SP-313 main board, the SYNGEN raster and video pipeline,
//  the motion-object engine and the JSA I audio PCB.  Everything here is
//  framework wiring — PLL clocks, hps_io (ROM download + controls), the /SW
//  bit assembly, the CRT Adjust stage, arcade_video, audio and the SDRAM
//  chip pins.
//
//  Xybots runs on a HORIZONTAL monitor (MAME ROT0), so there is no rotation:
//  the raster goes straight through arcade_video.  The Orientation option only
//  offers a 180-degree flip (for a monitor mounted the other way up), which
//  screen_rotate implements via the DDR framebuffer with no_rotate held high.
//
//  Clocking: clk_sys = 57.272727 MHz = 4 x the SP-313 sheet-4 14.318181 MHz
//  crystal.  ce_7m = clk_sys/8 is BOTH the 7.159091 MHz VIDCLK pixel rate and
//  the 68000 clock; ce_ym = /16 and ce_6502 = /32 cover the JSA I board
//  because its 3.579545 MHz crystal is exactly the video crystal / 4.  See
//  rtl/xybots_core.sv.
//
//  This program is free software under the GNU GPL v3 or later.
//
//============================================================================

`timescale 1ns/1ps

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT= 0;
assign FB_FORCE_BLANK= 0;

assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Horizontal cabinet: the native raster is 336 x 240 on a 4:3 monitor, and the
// Orientation option never rotates (only flips 180), so "Original" is 4:3 in
// every state.  VIDEO_ARX/ARY are actually driven by video_freak further down;
// these are the ratios it starts from.
wire  [1:0] ar  = status[122:121];
wire [11:0] arx = (ar == 2'd0) ? 12'd4 : 12'(ar - 1'd1);
wire [11:0] ary = (ar == 2'd0) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Xybots;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4],Orientation,Original,Flip;",
	"O[22:20],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer;",
	"-;",
	// CRT Adjust: rmonic79's MiSTer-CRT-Adjust engine (rtl/video/crt_adjust.sv)
	// behind an On/Off, with three amounts: CRT H-Size, CRT H-Position and CRT
	// V-Shift.  H-Position is built as a content shift (the engine can also
	// build it as a sync shift; which one is compiled in is set by crt_adjust's
	// HPOS_MODE, and the reasoning for this raster is in
	// rtl/video/xybots_analog_adjust.sv).
	//
	// Every amount is plain two's complement, so the list is 0,+1..+max then
	// -min..-1 and the decode is a $signed().  None of these touch the core's
	// timing; the stage sits between xybots_core and arcade_video.  Off is a
	// bit-exact bypass, so HDMI is untouched unless the user turns it On.
	//
	// The page lives on status[82:64], bits no earlier build used: the old
	// "Analog alignment" page held status[46:23], so a config saved before this
	// page decodes here as Off at all-zeros instead of switching the stage On
	// with leftover values.  status[46:23] is free again.
	//
	// H1 hides the three amounts while the stage is inactive, which includes the
	// case where the framework has forced the scandoubler and the stage gates
	// itself off (see `crt_enable`).
	"P1,CRT Adjust;",
	"P1-;",
	"P1O[64],CRT Adjust,Off,On;",
	"H1P1O[69:65],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[76:70],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,+49,+50,+51,+52,+53,+54,+55,+56,+57,+58,+59,+60,+61,+62,+63,-64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,-52,-51,-50,-49,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[82:77],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	// No DIP page.  Xybots has NO dip switches: MAME's INPUT_PORTS_START(xybots)
	// has only the 0x806100 control word and the 0x806200 service/status word,
	// and every operator setting lives in the X2804 EEPROM at 0x805000, changed
	// from the game's own self-test.  A "DIP;" line here
	// would ask MiSTer Main to splice in a menu the MRA can never populate.
	"O[6],Service,Off,On;",
	// Freeze the game while the OSD is open, as other MiSTer arcade cores do.
	// Default On (status[7] = 0).  See "OSD pause" in rtl/xybots_core.sv.
	"O[7],Pause when OSD is open,On,Off;",
	"-;",
	"T[0],Reset;",
	// Control panel (per player): 8-way stick + Fire + Twist Left + Twist Right
	// + Start/Zap; coins are on the JSA audio board.  See the 0x806100 assembly
	// below.
	"J1,Fire,Turn Left,Turn Right,Start/Zap,Coin;",
	"jn,A,B,X,Y,R;",
	"O[97:96],Aim Speed,Normal,Slow,Instant;",
"O[99:98],Aim Deadzone,Normal,Small,Large,Extra Large;",
"O[100],Stick Autofire,Off,On;",
"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire        direct_video;
wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;
wire        ioctl_upload, ioctl_upload_req;
wire  [7:0] ioctl_upload_index, ioctl_din;

wire [15:0] ts_lana0,ts_rana0,ts_lana1,ts_rana1;
wire [3:0] ts_move0,ts_aim0; wire ts_fire0,ts_l0,ts_r0,ts_active0;wire [2:0] ts_dir0;
 stick_controls #(.CLK_HZ(57272727),.RELATIVE(1)) ts0(.clk(clk_sys),.reset(reset),.paused(1'b0),.left(ts_lana0),.right(ts_rana0),.speed(status[97:96]),.deadzone(status[99:98]),.autofire(status[100]),.move(ts_move0),.aim(ts_aim0),.direction(ts_dir0),.fire(ts_fire0),.turn_left(ts_l0),.turn_right(ts_r0),.active(ts_active0));
wire [3:0] ts_move1,ts_aim1; wire ts_fire1,ts_l1,ts_r1,ts_active1;wire [2:0] ts_dir1;
 stick_controls #(.CLK_HZ(57272727),.RELATIVE(1)) ts1(.clk(clk_sys),.reset(reset),.paused(1'b0),.left(ts_lana1),.right(ts_rana1),.speed(status[97:96]),.deadzone(status[99:98]),.autofire(status[100]),.move(ts_move1),.aim(ts_aim1),.direction(ts_dir1),.fire(ts_fire1),.turn_left(ts_l1),.turn_right(ts_r1),.active(ts_active1));
wire [31:0] joystick_0, joystick_1;

// CRT Adjust master enable.  Declared here because status_menumask below reads
// it; what it means is documented at the stage itself (VIDEO section).  The
// forced-scandoubler term is upstream's own integration rule: the read-rate
// base assumes the native 15 kHz pixel-CE ratio, and once the framework has
// doubled the line rate there is no analog CRT geometry left to fit anyway.
wire crt_enable = status[64] & ~forced_scandoubler;

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
	// H1 = "hide while set": hide the three CRT Adjust amounts whenever the
	// stage is not actually doing anything.  `crt_enable` is the same signal
	// the stage itself runs on, so the menu never offers a control that is
	// being ignored.
	.status_menumask({14'd0, ~crt_enable, 1'b0}),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index),
	.ioctl_din(ioctl_din),

	.joystick_l_analog_0(ts_lana0),.joystick_r_analog_0(ts_rana0),
.joystick_l_analog_1(ts_lana1),.joystick_r_analog_1(ts_rana1),
.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;               // 57.272727 MHz = 4 x 14.318181 MHz
wire clk_sdram;             // same rate, +13095 ps for the SDRAM_CLK pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

///////////////////////   CONTROLS   /////////////////////////////

// The /SW word at 0x806100 in its SCHEMATIC bit order, but ACTIVE HIGH
// ("pressed") — the 18F/21E LS244 inversion lives in rtl/main/xybots_inputs.sv,
// which is where the sheet-4 wiring is transcribed and verified
// (MAME's FFE100 agrees bit for bit):
//   D0  P2 Start    D1  P2 Fire   D2  P2 Turn R   D3  P2 Turn L
//   D4  P2 Right    D5  P2 Left   D6  P2 Down     D7  P2 Up
//   D8  P1 Start    D9  P1 Fire   D10 P1 Turn R   D11 P1 Turn L
//   D12 P1 Right    D13 P1 Left   D14 P1 Down     D15 P1 Up
// MiSTer joystick bits: [0]=Right [1]=Left [2]=Down [3]=Up, then the CONF_STR
// J1 list "Fire,Turn Left,Turn Right,Start/Zap,Coin" gives [4]=Fire [5]=Turn Left
// [6]=Turn Right [7]=Start/Zap [8]=Coin — the same order as the MRA's
// <buttons names="Fire,Turn Left,Turn Right,Start/Zap,Coin">, which overrides these
// labels in the OSD mapping screen.  "Start/Zap" is the cabinet's own legend: the
// same centre button starts the game and, in play, fires the zap (the manual:
// it stuns every monster in the player's view).  The knob is two ordinary
// switches, not a stick direction, so Turn L / Turn R are independent bits.
wire [15:0] panel = {
	(joystick_0[3] | ts_move0[3]), (joystick_0[2] | ts_move0[2]), (joystick_0[1] | ts_move0[1]), (joystick_0[0] | ts_move0[0]),   // D15..D12 P1 Up/Down/Left/Right
	(joystick_0[5] | ts_l0), (joystick_0[6] | ts_r0), (joystick_0[4] | ts_fire0), joystick_0[7],   // D11..D8  P1 TurnL/TurnR/Fire/Start
	(joystick_1[3] | ts_move1[3]), (joystick_1[2] | ts_move1[2]), (joystick_1[1] | ts_move1[1]), (joystick_1[0] | ts_move1[0]),   // D7..D4   P2 Up/Down/Left/Right
	(joystick_1[5] | ts_l1), (joystick_1[6] | ts_r1), (joystick_1[4] | ts_fire1), joystick_1[7]    // D3..D0   P2 TurnL/TurnR/Fire/Start
};

// Coins are read on the JSA audio board and are SWAPPED on Xybots (MAME
// set_swapped_coins(true)); the swap is inside rtl/sound/xybots_jsa_io.sv, so
// coin1 here is the LEFT chute / player 1 exactly as the harness labels it.
// The Service switch is the JSA board's SW1: it fans out to /RDIO bit 7 on the
// sound board AND over JSCOM-1 to the main board's /SYSIN D8, so it is one
// signal handed to both models inside xybots_core.
wire coin1     = joystick_0[8];
wire coin2     = joystick_1[8];
wire self_test = status[6];

// OSD pause: a level request; xybots_core starts and ends the freeze on a
// frame boundary so the game resumes exactly where it stopped.
wire pause_req = OSD_STATUS & ~status[7];

///////////////////////   CORE   /////////////////////////////////

wire        ce_pix;
wire  [7:0] core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb;
wire signed [15:0] aud_l, aud_r;

xybots_core u_core
(
	.clk_sys(clk_sys), .reset(reset), .init_reset(~pll_locked),
	.pause(pause_req),

	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload), .ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din),

	.panel(panel), .self_test(self_test), .coin1(coin1), .coin2(coin2),

	.ce_pix(ce_pix), .vga_r(core_r), .vga_g(core_g), .vga_b(core_b),
	.hsync(core_hs), .vsync(core_vs), .hblank(core_hb), .vblank(core_vb),

	.aud_l(aud_l), .aud_r(aud_r),

	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE)
);

// SDRAM clock pin from the phase-shifted PLL output, not from ~clk_sys.  The
// +13095 ps (270 deg) phase is the centre of the working window measured on
// real hardware (tap 66; the window runs 225-315 deg).  Neither simulation nor
// STA can decide it — the behavioural SDRAM model clocks on the controller's
// own edge — so a new fit is re-checked on a board.  The graphics ROMs live
// here, so a wrong phase shows as corrupt tiles/sprites with a correct picture
// layout, not as a black screen.
assign SDRAM_CLK = clk_sdram;

///////////////////////   AUDIO   ////////////////////////////////

assign AUDIO_S = 1'b1;              // signed samples
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

///////////////////////   VIDEO   ////////////////////////////////

// CRT Adjust (H-Size / H-Position / V-Shift, rtl/video/xybots_analog_adjust.sv
// around the vendored crt_adjust engine).  Placed ahead of arcade_video so the
// mixer, scandoubler and video_freak all see the adjusted raster.  While On the
// output pixel rate is the stage's own read rate, not ce_pix, which is why
// arcade_video is clocked from adj_ce rather than ce_pix.  Off is a bit-exact
// bypass.  `crt_enable` is declared with the hps_io wires because
// status_menumask reads it.
wire [7:0] adj_r, adj_g, adj_b;
wire       adj_hs, adj_vs, adj_hb, adj_vb, adj_ce;

xybots_analog_adjust #(
	.H_TOTAL    (456),
	.V_TOTAL    (263),
	.CLK_PER_PIX(8),
	.HPOS_MODE  (1),     // CONTENTSHIFT; 0 (SYNCSHIFT) is the fallback, see the module
	.AW         (11)
) u_analog_adjust
(
	.clk        (clk_sys),
	.ce_pix     (ce_pix),
	.osd_on     (crt_enable),
	.osd_hsize  (status[69:65]),
	.osd_hpos   (status[76:70]),
	.osd_vshift (status[82:77]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.r_out(adj_r), .g_out(adj_g), .b_out(adj_b),
	.hs_out(adj_hs), .vs_out(adj_vs), .hb_out(adj_hb), .vb_out(adj_vb),
	.ce_out(adj_ce)
);

wire [7:0] R = adj_r;
wire [7:0] G = adj_g;
wire [7:0] B = adj_b;
wire       HSync  = adj_hs;
wire       VSync  = adj_vs;
wire       HBlank = adj_hb;
wire       VBlank = adj_vb;

// The cabinet raster is presented natively; MiSTer's forced_scandoubler stays
// framework-controlled for displays that need it.
wire [2:0] fx = 3'b000;

// Orientation (status[4]).  Xybots is ROT0 so the core NEVER rotates:
// screen_rotate is held with no_rotate = 1, where it derives
// do_flip = no_rotate && flip and fb_en = ~no_rotate | flip
// (sys/arcade_video.v), i.e. "Original" is a pure passthrough with the DDR
// framebuffer disabled, and "Flip" is a 180-degree flip through the
// framebuffer.  direct_video bypasses the scaler entirely, so it forces the
// passthrough state (the standard MiSTer arcade idiom).
wire       rotate_ccw = 1'b0;
wire       no_rotate  = 1'b1;
wire       flip       = status[4] & ~direct_video;
wire       video_rotated;

wire vga_de_raw;

// WIDTH = 336 = the visible width of the SP-313 raster (456 x 263 total).
// DW = 24: CRAM is I:R:G:B 4:4:4:4, but the intensity bit makes the sheet-9
// resistor-ladder DAC produce more than 16 levels per channel, so the core
// hands over the DAC's own 8-bit-per-channel output (rtl/video/xybots_dac.sv).
arcade_video #(.WIDTH(336), .DW(24)) arcade_video
(
	.clk_video (clk_sys),
	.ce_pix    (adj_ce),
	.RGB_in    ({R, G, B}),
	.HBlank    (HBlank),
	.VBlank    (VBlank),
	.HSync     (HSync),
	.VSync     (VSync),

	.CLK_VIDEO (CLK_VIDEO),
	.CE_PIXEL  (CE_PIXEL),
	.VGA_R     (VGA_R),
	.VGA_G     (VGA_G),
	.VGA_B     (VGA_B),
	.VGA_HS    (VGA_HS),
	.VGA_VS    (VGA_VS),
	.VGA_DE    (vga_de_raw),
	.VGA_SL    (VGA_SL),

	.fx                 (fx),
	.forced_scandoubler (forced_scandoubler),
	.gamma_bus          (gamma_bus)
);

// Scale (status[22:20]) maps onto video_freak's SCALE encoding, documented at
// sys/video_freak.sv as 0 normal, 1 V-integer, 2 HV-Integer-, 3 HV-Integer+,
// 4 HV-Integer.  "Narrower HV-Integer" is therefore 2 and plain "HV-Integer"
// is 4 — they are not adjacent, so menu order and encoding deliberately differ.
wire [2:0] scale_sel = (status[22:20] == 3'd0) ? 3'd0 :   // Normal
                       (status[22:20] == 3'd1) ? 3'd1 :   // V-Integer
                       (status[22:20] == 3'd2) ? 3'd4 :   // HV-Integer
                                                 3'd2;    // Narrower HV-Integer

video_freak video_freak
(
	.CLK_VIDEO  (CLK_VIDEO),
	.CE_PIXEL   (CE_PIXEL),
	.VGA_VS     (VGA_VS),
	.HDMI_WIDTH (HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE     (VGA_DE),
	.VIDEO_ARX  (VIDEO_ARX),
	.VIDEO_ARY  (VIDEO_ARY),
	.VGA_DE_IN  (vga_de_raw),
	.ARX        (arx),
	.ARY        (ary),
	.CROP_SIZE  (12'd0),
	.CROP_OFF   (5'd0),
	.SCALE      (scale_sel)
);

screen_rotate screen_rotate (.*);

///////////////////////   STATUS LED   ///////////////////////////

assign LED_USER = ioctl_download;

endmodule
