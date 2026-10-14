//============================================================================
//  Arcade: Ikki (Sun Electronics, 1985)
//
//  MiSTer emu wrapper — dual Z80 + 2×SN76489A + discrete video.
//  All ROM and RAM lives in on-chip BRAM; the SDRAM stick is not used and its
//  pins are held deselected (see rtl/ikki_top.sv).
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

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
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
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
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

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
// DDRAM driven by screen_rotate (even when no_rotate=1)
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign FB_FORCE_BLANK = 0;

assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;
assign AUDIO_MIX = 0;
assign AUDIO_S   = 1;

wire [1:0] ar = status[23:22];
// Native is horizontal; Vert enables framebuffer rotate. Aspect tracks orientation.
wire orientation = ~status[2];
// VIDEO_ARX/ARY are driven by video_freak in the video section below; the
// aspect selection reaches it as ar_x/ar_y so integer scaling can override it.

`include "build_id.v"
localparam CONF_STR = {
	"A.IKKI;;",
	"H0O2,Orientation,Horz,Vert;",
	"O1,Rotate CW,Off,On;",
	"H0OMN,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[73:71],Scaling,Normal,V-Integer,HV-Integer-,HV-Integer+,HV-Integer;",
	"-;",
	"P1,DIP Switches;",
	"P1O6,Lives,3,5;",
	"P1O7,2 Players Game,2 Credits,1 Credit;",
	"P1O8,Flip Screen,Off,On;",
	"P1O9,Unknown 1-4,Off,On;",
	"P1OAD,Coin1 / Coin2,1C1C/1C1C,2C1C/2C1C,2C1C/1C3C,1C1C/1C2C,1C1C/1C3C,1C1C/1C4C,1C1C/1C5C,1C1C/1C6C,1C2C/1C2C,1C2C/1C4C,1C2C/1C5C,1C2C/1C10C,1C2C/1C11C,1C2C/1C12C,1C2C/1C6C,Free Play;",
	"P1OE,Demo Sounds,On,Off;",
	"P1OFG,Difficulty,1 Normal,2,3,4 Difficult;",
	"P1OH,Unknown 2-4,Off,On;",
	"P1OI,Unknown 2-5,Off,On;",
	"P1OJ,Unknown 2-6,Off,On;",
	"P1OK,Unknown 2-7,Off,On;",
	"P1OL,Freeze,Off,On;",
	"-;",
	"P2,Pause options;",
	"P2OP,Pause when OSD is open,On,Off;",
	"P2OQ,Dim video after 10s,On,Off;",
	"-;",
	"P3,CRT Adjust;",
	"P3-,Analog geometry for 15kHz CRTs.;",
	"P3-,Leave Off for an untouched HDMI image.;",
	"P3O[101],CRT Adjust,Off,On;",
	"H1P3O[100:96],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P3O[85:79],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P3O[78:74],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"R0,Reset;",
	"J1,Fire,-,Start 2P,Start 1P,Coin,Service,Pause;",
	"jn,A,B,R,Start,Select,X,L;",
	"V,v",`BUILD_DATE
};

// outclk_0 (98.304 MHz) and outclk_2 are left over from the PLL this project
// was scaffolded from and drive nothing; the core runs entirely from outclk_1.
// Removing them means regenerating the Altera PLL IP, so they are named for
// what they are instead.  rtl/pll.qip's metadata matches the generated RTL.
wire clk_sys, clk_vid, clk_unused_98m, clk_unused_40m;
wire pll_locked;

// Ikki's CPU, video renderer, and PSG enables share one exact 40 MHz
// reference.  This preserves the original 4 MHz : 5 MHz CPU/pixel ratio and
// removes frame-to-frame drift between the game state and sprite display.
assign clk_sys = clk_vid;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_unused_98m),
	.outclk_1(clk_vid),
	.outclk_2(clk_unused_40m),
	.locked(pll_locked)
);

assign CLK_VIDEO = clk_vid;

// hps_io always drives 128 bits; the core used to take only the low 32.  The
// CRT Adjust controls live at 74..101, following the upstream bit assignment
// so its documentation and OSD strings transfer unchanged.
wire [127:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;
wire        video_rotated;

wire        ioctl_download;
wire        ioctl_wr;
wire  [7:0] ioctl_index;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joy = joystick_0 | joystick_1;
wire [21:0] gamma_bus;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.buttons(buttons),
	.status(status),
	// bit0 -> H0 (hide orientation/aspect on direct video)
	// bit1 -> H1 (hide the CRT Adjust amounts until CRT Adjust is On)
	.status_menumask({14'd0, ~status[101], direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1)
);

wire reset = RESET | status[0] | buttons[1] | ~pll_locked | (ioctl_download && !ioctl_index);

// Pack OSD DIPs to match MAME DSW1/DSW2 (bits 6+; 3-5 = scandoubler)
wire [7:0] dip_sw1 = {
	status[13:10], // coin nibble
	status[9],     // unknown 1-4
	status[8],     // flip
	status[7],     // 2P credit mode
	status[6]      // lives
};
wire [7:0] dip_sw2 = {
	status[21],    // freeze
	status[20],    // unk 2-7
	status[19],    // unk 2-6
	status[18],    // unk 2-5
	status[17],    // unk 2-4
	status[16:15], // difficulty
	status[14]     // demo sounds (MAME: 1=off)
};

wire hblank, vblank;
wire hs, vs;
wire [3:0] r, g, b;
wire ce_pix;

wire        pause_cpu;
wire [11:0] rgb_out;
wire m_pause = joy[10];

pause #(4,4,4,40) pause
(
	.*,
	.user_button(m_pause),
	.pause_request(1'b0),
	.options(~status[26:25])
);

wire no_rotate  = orientation | direct_video;
wire rotate_ccw = ~status[1];
wire flip       = 1'b0;
screen_rotate screen_rotate (.*);

//////////////////////////  CRT ADJUST  //////////////////////////////////////
//
// rtl/crt_adjust/ — analog geometry for 15 kHz CRTs, by rmonic79.
// Core-side variant: it sits at the core's video-output boundary and needs no
// sys/ changes.  The picture content is resized and shifted through a line
// buffer while the sync stays native, so the CRT never loses lock.
//
// HPOS_MODE: Ikki's active area is 240 pixels on a 320-pixel line, sitting at
// raster 8..247 — an 8-pixel front margin against a 72-pixel back porch.  That
// is the narrow, side-anchored geometry the module documents as SYNCSHIFT;
// CONTENTSHIFT would push the picture out of the buffer window and show a
// black block at the edge.
//
// Read rate: clk_vid is 40 MHz and ce_pix is 5 MHz, so a native pixel is 8
// whole cycles.  Stepping in eighth-cycles gives base = 64 and a step of
// 1/64 ≈ 1.6 %, matching the granularity the module was tuned for.
localparam CRT_HTOTAL = 320;
localparam CRT_VTOTAL = 262;

reg crt_on;
always @(posedge clk_vid) if (ce_pix) crt_on <= status[101];

reg signed [4:0] crt_hsize;
always @(posedge clk_vid) if (ce_pix) crt_hsize <= $signed(status[100:96]);

// H-Position is wrap-encoded: 0..48 means +0..+48, 79..127 means -48..-1.
reg [6:0] crt_hpos_raw;
always @(posedge clk_vid) if (ce_pix) crt_hpos_raw <= status[85:79];
wire signed [8:0] crt_hpos = (crt_hpos_raw <= 7'd48)
	? $signed({2'b0, crt_hpos_raw})
	: $signed({2'b0, crt_hpos_raw}) - 9'sd128;

reg signed [5:0] crt_vshift;
always @(posedge clk_vid) if (ce_pix) crt_vshift <= $signed({status[78], status[78:74]});

// Read clock enable.  It must restart on the module's own hs_ref_out rather
// than the raw HSync, so the write side, the module's read counter and this
// generator all share one line reference — that is what stops the picture
// desyncing when H-Size shrinks.
wire       crt_hs_ref;
reg        crt_hs_ref_d;
always @(posedge clk_vid) crt_hs_ref_d <= crt_hs_ref;
wire       crt_hs_ref_rise = crt_hs_ref & ~crt_hs_ref_d;

wire [8:0] crt_rd_period = 9'd64 + {{4{crt_hsize[4]}}, crt_hsize}; // 48..79
reg  [8:0] crt_rd_acc;
wire [8:0] crt_rd_next  = crt_rd_acc + 9'd8;
wire       crt_rd_tick  = (crt_rd_next >= crt_rd_period);
always @(posedge clk_vid) begin
	if      (crt_hs_ref_rise) crt_rd_acc <= 9'd0;
	else if (crt_rd_tick)     crt_rd_acc <= crt_rd_next - crt_rd_period;
	else                      crt_rd_acc <= crt_rd_next;
end
wire crt_rd_ce = crt_on ? crt_rd_tick : ce_pix;

// The module works in 8-bit RGB; rgb_out is 4:4:4.  Replicating each nibble
// and taking the top nibble back is an exact round trip.
wire [7:0] crt_r_in = {rgb_out[11:8], rgb_out[11:8]};
wire [7:0] crt_g_in = {rgb_out[7:4],  rgb_out[7:4]};
wire [7:0] crt_b_in = {rgb_out[3:0],  rgb_out[3:0]};

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb;

crt_adjust #(
	.VTOTAL   (CRT_VTOTAL),
	.HTOTAL   (CRT_HTOTAL),
	.HPOS_MODE(0)              // 0 = SYNCSHIFT, see note above
) crt_adjust
(
	.clk      (clk_vid),
	.pxl_cen  (ce_pix),
	.pxl2_cen (crt_rd_ce),
	.active   (crt_on),
	.hsize    (crt_hsize),
	.hoffset  (crt_hpos),
	.voffset  (crt_vshift),
	.r_in     (crt_r_in), .g_in(crt_g_in), .b_in(crt_b_in),
	.hs_in    (hs),
	.vs_in    (vs),
	.hb_in    (hblank),
	.vb_in    (vblank),
	.r_out    (crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out   (crt_hs), .vs_out(crt_vs),
	.hb_out   (crt_hb), .vb_out(crt_vb),
	.hs_ref_out(crt_hs_ref)
);

wire [11:0] av_rgb    = {crt_r[7:4], crt_g[7:4], crt_b[7:4]};
wire        av_hs     = crt_on ? crt_hs : hs;
wire        av_vs     = crt_on ? crt_vs : vs;
wire        av_hblank = crt_on ? crt_hb : hblank;
wire        av_vblank = crt_on ? crt_vb : vblank;

//////////////////////////  VIDEO OUT  ///////////////////////////////////////

wire vga_de_raw;

arcade_video #(240,12) arcade_video
(
	.clk_video(clk_vid),
	.ce_pix(crt_rd_ce),
	.RGB_in(av_rgb),
	.HBlank(av_hblank),
	.VBlank(av_vblank),
	.HSync(av_hs),
	.VSync(av_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[5:3]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// Scaling.  arcade_video has no video_freak, so integer scaling needs it added
// here; it also takes over driving VIDEO_ARX/ARY from the aspect selection.
wire [11:0] ar_x = (!ar) ? (orientation ? 12'd4 : 12'd3) : {10'd0, (ar - 2'd1)};
wire [11:0] ar_y = (!ar) ? (orientation ? 12'd3 : 12'd4) : 12'd0;

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
	.ARX(ar_x),
	.ARY(ar_y),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[73:71])
);

wire [15:0] audio_l, audio_r;
// MiSTer consumes the continuously-running sample stream here. Registering
// it in the unrelated CLK_AUDIO domain made that clock the effective sample
// and hold for the PSG mix.
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

ikki_top ikki_top
(
	.clk_sys(clk_sys),
	.clk_vid(clk_vid),
	.clk_mem(clk_unused_98m),
	.pll_locked(pll_locked),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.dip_sw1(dip_sw1),
	.dip_sw2(dip_sw2),
	.pause(pause_cpu),
	.ce_pix(ce_pix),
	.r(r), .g(g), .b(b),
	.hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
	.audio_l(audio_l),
	.audio_r(audio_r),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE)
);

endmodule
