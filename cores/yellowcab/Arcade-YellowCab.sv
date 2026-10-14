//============================================================================
// Arcade-YellowCab — Data East Yellow Cab / Kamikaze Cabbie (1984)
// MiSTer FPGA core scaffold
//
// Based on MiSTer Template / Arcade-ExpressRaider patterns.
// Game logic from MAME liberate.cpp (kamikcab / yellowcb*).
// CPU16 adapted from Arcade-ExpressRaider_MiSTer.
// AY cores: jt49 (Jotego).
//
// GPL-2.0-or-later (MiSTer platform); see LICENSE and rtl/sound/jt49/LICENSE
//============================================================================

module emu
(
  input         CLK_50M,
  input         RESET,
  inout  [48:0] HPS_BUS,

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

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
`ifdef MISTER_DUAL_SDRAM
assign {SDRAM2_CLK, SDRAM2_A, SDRAM2_BA, SDRAM2_nCS, SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE} = '0;
assign SDRAM2_DQ = 'Z;
`endif

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 2'd3;

`ifdef MISTER_FB
assign FB_FORCE_BLANK = 0;
`endif

// status[2]=1 → force horizontal (no rotate); default vertical (ROT270)
wire no_rotate  = status[2] | direct_video;
// status[3]=0 → CCW (default Yes); MAME yellowcbj is ROT270
wire rotate_ccw = ~status[3];
wire flip       = status[4];
wire video_rotated;

wire [1:0] ar = status[122:121];
// Portrait when rotated, landscape when Orientation=Horizontal / direct video
assign VIDEO_ARX = (!ar) ? (no_rotate ? 12'd4 : 12'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (no_rotate ? 12'd3 : 12'd4) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
  "YellowCab;;",
  "-;",
  "H0O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
  "H0O[2],Orientation,Vertical,Horizontal;",
  "O[3],Rotate CCW,Yes,No;",
  "O[4],Flip screen,Off,On;",
  "OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
  "-;",
  "DIP;",
  "-;",
  "O[5],Pause when OSD is open,Off,On;",
  "O[6],Dim video after 10s,On,Off;",
  "P1,Pause;",
  "-;",
  "T[0],Reset;",
  "R[0],Reset and close OSD;",
  "J1,Button1,Button2,Start1,Start2,Coin1,Coin2,Service;",
  "jn,A,B,Start,Select,R,L,X;",
  "V,v",`BUILD_DATE
};

wire         direct_video;
wire         forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;

wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_download;
wire  [7:0] ioctl_index;

wire [15:0] joy0;
wire [15:0] joy1;
wire [21:0] gamma_bus;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
  .clk_sys(clk_sys),
  .HPS_BUS(HPS_BUS),
  .EXT_BUS(),
  .gamma_bus          ( gamma_bus          ),
  .direct_video       ( direct_video       ),
  .forced_scandoubler ( forced_scandoubler ),
  .video_rotated      ( video_rotated      ),
  .ioctl_download     ( ioctl_download     ),
  .ioctl_wr           ( ioctl_wr           ),
  .ioctl_addr         ( ioctl_addr         ),
  .ioctl_dout         ( ioctl_dout         ),
  .ioctl_wait         ( 1'b0               ),
  .ioctl_index        ( ioctl_index        ),
  .buttons            ( buttons            ),
  .status             ( status             ),
  .status_menumask    ( { direct_video }   ),
  .joystick_0         ( joy0               ),
  .joystick_1         ( joy1               )
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
  .refclk(CLK_50M),
  .rst(0),
  .outclk_0(clk_sys),
  .locked(pll_locked)
);

// No SDRAM: every ROM region fits in BRAM. Park the pins.
assign SDRAM_CLK  = 1'b0;
assign SDRAM_CKE  = 1'b0;
assign SDRAM_A    = 13'd0;
assign SDRAM_BA   = 2'd0;
assign SDRAM_DQ   = 16'hZZZZ;
assign SDRAM_DQML = 1'b1;
assign SDRAM_DQMH = 1'b1;
assign SDRAM_nCS  = 1'b1;
assign SDRAM_nCAS = 1'b1;
assign SDRAM_nRAS = 1'b1;
assign SDRAM_nWE  = 1'b1;

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

//////////////////////////////////////////////////////////////////

reg [7:0] sw[8];
always @(posedge clk_sys)
  if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout[7:0];

wire core_download = ioctl_download && (ioctl_index==0);

wire [2:0] fx = status[17:15];
wire [3:0] vred, vgreen, vblue;
wire [3:0] pred, pgreen, pblue;
wire HBlank, VBlank;
wire HSync, VSync;
wire ce_pix;
wire [15:0] audio_l, audio_r;

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

arcade_video #(256,12,0) arcade_video(
  .*,
  .clk_video          ( clk_sys                 ),
  .ce_pix             ( ce_pix                  ),
  .RGB_in             ( { pred, pgreen, pblue } ),
  .HBlank             ( HBlank                  ),
  .VBlank             ( VBlank                  ),
  .HSync              ( HSync                   ),
  .VSync              ( VSync                   ),
  .fx                 ( fx                      ),
  .forced_scandoubler ( forced_scandoubler      ),
  .gamma_bus          ( gamma_bus               )
);

// HDMI framebuffer rotate (needs MISTER_FB). Default: vertical / CCW (ROT270).
screen_rotate screen_rotate (.*);

// Pause: OSD-open pause plus the standard 10 s screen dim.
wire pause_cpu;
pause #(.RW(4), .GW(4), .BW(4), .CLKSPD(48)) u_pause (
  .clk_sys      ( clk_sys                  ),
  .reset        ( reset                    ),
  .user_button  ( 1'b0                     ),
  .pause_request( 1'b0                     ),
  .options      ( { ~status[6], status[5] } ),
  .OSD_STATUS   ( OSD_STATUS               ),
  .r            ( vred                     ),
  .g            ( vgreen                   ),
  .b            ( vblue                    ),
  .pause_cpu    ( pause_cpu                ),
  .rgb_out      ( { pred, pgreen, pblue }  )
);

// Inputs (active low in MAME ports — joy bits active high from HPS)
wire p1_right = joy0[0];
wire p1_left  = joy0[1];
wire p1_down  = joy0[2];
wire p1_up    = joy0[3];
wire p1_b1    = joy0[4];
wire p1_b2    = joy0[5];
wire p1_start = joy0[6];
wire p2_start = joy0[7];
wire coin1    = joy0[8] | joy1[8];
wire coin2    = joy0[9] | joy1[9];
// IN3 bit 6 = SERVICE1 (MAME generic_input). Part of the 0x43 coin-IRQ mask.
wire service  = joy0[10] | joy1[10];

wire p2_right = joy1[0];
wire p2_left  = joy1[1];
wire p2_down  = joy1[2];
wire p2_up    = joy1[3];
wire p2_b1    = joy1[4];
wire p2_b2    = joy1[5];

// IN1 / IN2 / IN3 as MAME (active low)
// MAME generic_input: IN2 bit7 is the VBLANK line and is IP_ACTIVE_HIGH, so it
// must NOT be inverted along with the active-low player-2 controls.
wire [7:0] in1 = ~{ 2'b00, p1_b2, p1_b1, p1_down, p1_up, p1_left, p1_right };
wire [7:0] in2 = { VBlank, ~{ 1'b0, p2_b2, p2_b1, p2_down, p2_up, p2_left, p2_right } };
wire [7:0] in3 = ~{ 1'b0, service, 1'b0, 1'b0, p2_start, p1_start, coin2, coin1 };

yellowcab_core u_core(
  .reset          ( reset            ),
  .clk_sys        ( clk_sys          ),
  .p1             ( in1              ),
  .p2             ( in2              ),
  .p3             ( in3              ),
  .dsw1           ( sw[0]            ),
  .dsw2           ( sw[1]            ),
  .tilt           ( 1'b0             ),
  .pause          ( pause_cpu        ),
  .ioctl_download ( core_download    ),
  .ioctl_addr     ( ioctl_addr       ),
  .ioctl_dout     ( ioctl_dout[7:0]  ),
  .ioctl_wr       ( ioctl_wr         ),
  .red            ( vred             ),
  .green          ( vgreen           ),
  .blue           ( vblue            ),
  .vs             ( VSync            ),
  .vb             ( VBlank           ),
  .hs             ( HSync            ),
  .hb             ( HBlank           ),
  .ce_pix         ( ce_pix           ),
  .audio_l        ( audio_l          ),
  .audio_r        ( audio_r          )
);

assign LED_USER = ioctl_download;
assign CLK_VIDEO = clk_sys;

endmodule
