//============================================================================
// DataEastLiberation — universal Liberation / B-Wings / DECO Cassette core
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

// OSD Rotate (status[3:2]): Native follows the MRA profile (ROT270, or ROT90 when flag bit 3),
// 90 CW / 90 CCW force a direction, Horizontal disables rotation. Rotate 180 = status[4].
wire [1:0] rot_mode = status[3:2];   // 0 Native, 1 90 CW, 2 90 CCW, 3 Horizontal
wire no_rotate  = (rot_mode == 2'd3) | direct_video;
wire decocass_cocktail_flip;
wire effective_flip = status[4] ^ decocass_cocktail_flip;
// In rotated mode a 180-degree flip is the opposite 90-degree rotation. In
// horizontal mode screen_rotate consumes `flip` directly.
wire base_ccw   = (rot_mode == 2'd0) ? ((game_flags & PROFILE_FLAG_ROT90) == 8'd0) : (rot_mode == 2'd2);
wire rotate_ccw = base_ccw ^ effective_flip;
wire flip       = effective_flip;
wire video_rotated;

wire [1:0] ar = status[122:121];
// Portrait when rotated, landscape when Orientation=Horizontal / direct video
wire [12:0] aspect_arx = (!ar) ? (no_rotate ? 13'd4 : 13'd3)
                                      : ({11'd0, ar} - 13'd1);
wire [12:0] aspect_ary = (!ar) ? (no_rotate ? 13'd3 : 13'd4) : 13'd0;

`include "build_id.v"
localparam CONF_STR = {
  "DataEastLiberation;;",
  "P1,Video Settings;",
  "P2,Game Settings;",
  "-;",
  "DIP;",
  "R[120],Credits;",
  "-;",
  "R[0],Reset;",
  "H0P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
  "H0P1O[3:2],Rotation,Native,90 CW,90 CCW,Horizontal;",
  "H0P1O[4],Rotate 180,Off,On;",
  "H0P1O[11:9],Scaling,Normal,V-Integer,HV-Integer,HV-Integer-;",
  "H4P1O[12],HV Integer rounding,Down,Up;",
  "H0P1O[17:15],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
  "P1-;",
  "H0P1O[101],CRT Adjust,Off,On;",
  "H0H1P1O[100:96],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
  "H0H1P1O[85:79],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
  "H0H1P1O[78:74],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
  "H2P2O[8],Autosave Hiscores,On,Off;",
  "P2O[5],Pause when OSD is open,Off,On;",
  "P2O[6],Dim video after 10s,On,Off;",
  "P2O[123],Pause,Off,On;",
  "H3P2O[124],Cassette loading,Fast,Original;",
  "J1,Fire/Bowl/Brake,Land/Dive/Pass,Start1,Start2,Coin1,Coin2,Service,Tilt;",
  "jn,A,B,Start,Select,R,L,X,Y;",
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
wire        ioctl_upload, ioctl_upload_req;
wire  [7:0] ioctl_din;
wire        hs_configured;

wire [15:0] joy0;
wire [15:0] joy1;
wire [31:0] credits_joy2, credits_joy3, credits_joy4, credits_joy5;
wire [10:0] credits_key;
wire [24:0] credits_mouse;
wire [21:0] gamma_bus;
wire main_rom_wait;

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
  .ioctl_wait         ( main_rom_wait       ),
  .ioctl_index        ( ioctl_index        ),
  .ioctl_upload       ( ioctl_upload       ),
  .ioctl_upload_req   ( ioctl_upload_req   ),
  .ioctl_upload_index ( 8'd4               ),
  .ioctl_din          ( ioctl_din          ),
  .buttons            ( buttons            ),
  .status             ( status             ),
  .status_menumask    ( { 11'd0, (direct_video || status[11:9] != 3'd3), ~select_decocass, ~hs_configured, ~status[101], direct_video } ),
  .joystick_0         ( joy0               ),
  .joystick_1         ( joy1               ),
  .joystick_2         ( credits_joy2       ),
  .joystick_3         ( credits_joy3       ),
  .joystick_4         ( credits_joy4       ),
  .joystick_5         ( credits_joy5       ),
  .ps2_key            ( credits_key        ),
  .ps2_mouse          ( credits_mouse      )
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_ram, clk_sdram;
wire pll_locked;
pll pll
(
  .refclk(CLK_50M),
  .rst(0),
  .outclk_0(clk_sys),
  .outclk_1(clk_ram),
  .outclk_2(clk_sdram),
  .locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

// MiSTer holds status[0] throughout arcade ROM loading. Keep the media path
// alive under that game reset; only platform reset/PLL loss aborts a transfer.
wire loader_reset = RESET | ~pll_locked;
wire reset = loader_reset | status[0] | buttons[1];

//////////////////////////////////////////////////////////////////

reg [7:0] sw[8];
always @(posedge clk_sys)
  if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout[7:0];

wire core_download = ioctl_download && (ioctl_index==0);

// One RBF/profile serves every supplied ROM set.  The first 16 bytes of each
// index-0 stream carry this stable selector contract; keep the IDs named here
// so engine routing cannot drift away from the MRA profile table.
localparam [7:0] ENGINE_LIBERATION = 8'h00;
localparam [7:0] ENGINE_BWING      = 8'h01;
localparam [7:0] ENGINE_DECOCASS   = 8'h02;
localparam [7:0] VARIANT_YELLOWCAB = 8'h00;
localparam [7:0] VARIANT_LIBERATE  = 8'h01;
localparam [7:0] VARIANT_BOOMERANG = 8'h02;
localparam [7:0] VARIANT_PROSPORT  = 8'h03;
localparam [7:0] VARIANT_BWINGS    = 8'h10;
localparam [7:0] VARIANT_ZAVIGA    = 8'h11;
localparam [7:0] VARIANT_PROBOWL   = 8'h20;
localparam [7:0] VARIANT_PROSOCCER = 8'h21;
localparam [7:0] PROFILE_FLAG_NIBBLE_SWAP = 8'h01;
localparam [7:0] PROFILE_FLAG_OPCODE_DECRYPT = 8'h02;
localparam [7:0] PROFILE_FLAG_BANK_BIT2 = 8'h04;
localparam [7:0] PROFILE_FLAG_ROT90 = 8'h08;

// Every universal index-0 ROM begins with a 16-byte DELU header. Capture the
// selector before releasing reset, then present engine-local address zero for
// the first actual ROM byte.
reg [31:0] meta_magic    = 32'h00000000;
reg  [7:0] meta_format   = 8'h00;
reg  [7:0] game_engine   = 8'h00;
reg  [7:0] game_variant  = 8'h00;
reg  [7:0] game_flags    = PROFILE_FLAG_NIBBLE_SWAP | PROFILE_FLAG_BANK_BIT2;
reg        reserved_zero = 1'b0;
reg        meta_valid    = 1'b0;
reg        index0_closed = 1'b0;
reg        rom_loaded    = 1'b0;
reg        dongle_loaded = 1'b0;
reg        download_attempted = 1'b0;
reg        core_download_d = 1'b0;
reg        dongle_download_d = 1'b0;
reg [27:0] index0_byte_count = 28'd0;
reg [27:0] dongle_byte_count = 28'd0;
reg        index0_sequence_error = 1'b0;
reg        dongle_sequence_error = 1'b0;

// Accept only tuples published in docs/UNIVERSAL_PROFILE.md. A valid magic
// with an unknown format/engine/variant/flag combination must never release a
// reset engine whose video mux happens to look selected.
wire header_tuple_valid =
  (meta_format == 8'h01) &&
  (((game_engine == ENGINE_LIBERATION) &&
    (((game_variant == VARIANT_YELLOWCAB) && (game_flags == 8'h05)) ||
     ((game_variant == VARIANT_LIBERATE)  && (game_flags == 8'h02)) ||
     ((game_variant == VARIANT_BOOMERANG) && (game_flags == 8'h01)) ||
     ((game_variant == VARIANT_PROSPORT)  && (game_flags == 8'h01)))) ||
   ((game_engine == ENGINE_BWING) &&
    (((game_variant == VARIANT_BWINGS) && (game_flags == 8'h08)) ||
     ((game_variant == VARIANT_ZAVIGA) && (game_flags == 8'h08)))) ||
   ((game_engine == ENGINE_DECOCASS) &&
    (((game_variant == VARIANT_PROBOWL)   && (game_flags == 8'h00)) ||
     ((game_variant == VARIANT_PROSOCCER) && (game_flags == 8'h00)))));

wire [26:0] expected_index0_size =
  (game_engine == ENGINE_LIBERATION) ? 27'h32030 :
  (game_engine == ENGINE_BWING)      ? 27'h2F010 :
  (game_variant == VARIANT_PROBOWL)  ? 27'h0B010 :
  (game_variant == VARIANT_PROSOCCER)? 27'h13010 : 27'd0;

wire [26:0] engine_ioctl_addr = ioctl_addr - 27'd16;
wire engine_ioctl_wr = ioctl_wr && core_download && (ioctl_addr >= 27'd16);
// ioctl_wr is already a clk_sys-domain write strobe.  Do not edge-detect it
// again here: hps_io may legally present writes on consecutive clocks and an
// extra edge detector would silently discard every write after the first.
wire engine_ioctl_stb = engine_ioctl_wr;

wire [2:0] fx = direct_video ? 3'd0 : status[17:15];
wire [3:0] vred, vgreen, vblue;
wire [3:0] pred, pgreen, pblue;
wire HBlank, VBlank;
wire HSync, VSync;
wire ce_pix;
wire [15:0] audio_l, audio_r;

wire select_liberation = (game_engine == ENGINE_LIBERATION);
wire select_bwing      = (game_engine == ENGINE_BWING);
wire select_decocass   = (game_engine == ENGINE_DECOCASS);
wire dongle_download = ioctl_download && (ioctl_index == 8'd1) && select_decocass;
wire decocass_download = ioctl_download && select_decocass &&
                         ((ioctl_index == 8'd0) || (ioctl_index == 8'd1));

// The engines are mutually exclusive. Liberation/B-Wings main ROM and the
// DECO cassette image occupy separate cached SDRAM regions. A compact local
// 32 KiB dual-port bank packs Liberation audio or B-Wings sub+sound ROM while
// retaining their synchronous one-cycle reads.
wire [15:0] lib_main_addr, lib_aux_addr;
wire [15:0] bw_main_addr, bw_sub_addr;
wire lib_main_req, bw_main_req;
wire [12:0] bw_sound_addr;
wire [15:0] dc_tape_rd_addr, dc_tape_wr_addr;
wire [7:0]  dc_tape_wr_data;
wire        dc_tape_wr_en;
wire [15:0] shared_main_rd_addr = select_bwing ? bw_main_addr : lib_main_addr;
wire [14:0] shared_aux_a_rd_addr = select_bwing ?
                                   (bw_sub_addr[14:0] - 15'h2000) :
                                   lib_aux_addr[14:0];
wire [14:0] shared_aux_b_rd_addr = 15'h6000 + {2'b00, bw_sound_addr};
wire [7:0] shared_main_q, shared_aux_a_q, shared_aux_b_q;

wire shared_main_wr = engine_ioctl_stb &&
                      (select_liberation || select_bwing) &&
                      (engine_ioctl_addr < 27'h10000);
// MAME's Yellow Cab/Pro Sports init swaps the main-ROM nibbles only; graphics
// and all other engine payload bytes remain in their MRA order.
wire [7:0] shared_main_din = select_liberation && (game_flags & PROFILE_FLAG_NIBBLE_SWAP)
                           ? {ioctl_dout[3:0], ioctl_dout[7:4]}
                           : ioctl_dout[7:0];

wire lib_aux_wr = engine_ioctl_stb && select_liberation &&
                  (engine_ioctl_addr >= 27'h10000) &&
                  (engine_ioctl_addr < 27'h14000);
wire bw_aux_wr = engine_ioctl_stb && select_bwing &&
                 (engine_ioctl_addr >= 27'h1a000) &&
                 (engine_ioctl_addr < 27'h20000);
wire bw_sound_wr = engine_ioctl_stb && select_bwing &&
                   (engine_ioctl_addr >= 27'h20000) &&
                   (engine_ioctl_addr < 27'h22000);
wire shared_aux_wr = select_bwing ? (bw_aux_wr || bw_sound_wr) : lib_aux_wr;
wire [14:0] shared_aux_wr_addr = bw_sound_wr ?
                                  (15'h6000 + {2'b00, engine_ioctl_addr[12:0]}) :
                                  bw_aux_wr ? (engine_ioctl_addr[14:0] - 15'h2000) :
                                              engine_ioctl_addr[14:0];
wire [7:0] shared_aux_din = bw_sound_wr ?
                             {ioctl_dout[3:0], ioctl_dout[7:4]} : ioctl_dout[7:0];

// Main program ROM is the one large sequential-read bank that can leave the
// M10Ks without disturbing the graphics pipelines. Downloads are paired into
// SDRAM words and throttled until the controller acknowledges each write.
reg [7:0]  main_wr_low;
reg [15:0] main_wr_word;
reg [24:1] main_wr_addr;
reg        main_wr_busy = 1'b0;
reg [7:0]  tape_wr_low;
reg [15:0] tape_wr_word;
reg [24:1] tape_wr_addr;
reg        tape_wr_busy = 1'b0;
reg        main_wr_ack_s, main_wr_ack_ss;
wire       main_wr_ack;

always @(posedge clk_sys) begin
  main_wr_ack_s  <= main_wr_ack;
  main_wr_ack_ss <= main_wr_ack_s;
  if (loader_reset) begin
    main_wr_busy <= 1'b0;
    tape_wr_busy <= 1'b0;
    main_wr_low  <= 8'd0;
    tape_wr_low  <= 8'd0;
    main_wr_ack_s  <= 1'b0;
    main_wr_ack_ss <= 1'b0;
  end else begin
    if (main_wr_ack_ss) begin
      main_wr_busy <= 1'b0;
      tape_wr_busy <= 1'b0;
    end
    if (shared_main_wr && !engine_ioctl_addr[0])
      main_wr_low <= shared_main_din;
    if (shared_main_wr && engine_ioctl_addr[0] && !main_wr_busy) begin
      main_wr_word <= {shared_main_din, main_wr_low};
      main_wr_addr <= {9'd0, engine_ioctl_addr[15:1]};
      main_wr_busy <= 1'b1;
    end
    if (dc_tape_wr_en && !dc_tape_wr_addr[0])
      tape_wr_low <= dc_tape_wr_data;
    if (dc_tape_wr_en && dc_tape_wr_addr[0] && !tape_wr_busy) begin
      tape_wr_word <= {dc_tape_wr_data, tape_wr_low};
      tape_wr_addr <= 24'h008000 + {9'd0, dc_tape_wr_addr[15:1]};
      tape_wr_busy <= 1'b1;
    end
  end
end

assign main_rom_wait = main_wr_busy || tape_wr_busy ||
                       main_wr_ack_s || main_wr_ack_ss;

// Synchronize the SDRAM controller's launch qualification into clk_sys. ROM
// writes may start while the controller initializes, but no engine or cache is
// allowed to run until initialization and the complete download contract close.
wire sdram_ready;
reg sdram_ready_s = 1'b0;
reg sdram_ready_ss = 1'b0;
always @(posedge clk_sys) begin
  sdram_ready_s  <= sdram_ready;
  sdram_ready_ss <= sdram_ready_s;
end

always @(posedge clk_sys) begin
  core_download_d   <= core_download;
  dongle_download_d <= dongle_download;

  if (core_download && !core_download_d) begin
    meta_magic         <= 32'h00000000;
    meta_format        <= 8'h00;
    game_engine        <= ENGINE_LIBERATION;
    game_variant       <= VARIANT_YELLOWCAB;
    game_flags         <= PROFILE_FLAG_NIBBLE_SWAP | PROFILE_FLAG_BANK_BIT2;
    reserved_zero      <= 1'b1;
    meta_valid         <= 1'b0;
    index0_closed      <= 1'b0;
    rom_loaded         <= 1'b0;
    dongle_loaded      <= 1'b0;
    download_attempted <= 1'b0;
    index0_byte_count   <= 28'd0;
    index0_sequence_error <= 1'b0;
  end

  if (core_download && ioctl_wr) begin
    // A final address alone does not prove that all bytes were delivered.
    // Require every write in order, including all reserved header bytes.
    if ({1'b0, ioctl_addr} != (core_download_d ? index0_byte_count : 28'd0))
      index0_sequence_error <= 1'b1;
    index0_byte_count <= (core_download_d ? index0_byte_count : 28'd0) + 28'd1;
    case (ioctl_addr)
      27'd0: meta_magic[31:24] <= ioctl_dout[7:0];
      27'd1: meta_magic[23:16] <= ioctl_dout[7:0];
      27'd2: meta_magic[15:8]  <= ioctl_dout[7:0];
      27'd3: meta_magic[7:0]   <= ioctl_dout[7:0];
      27'd4: meta_format       <= ioctl_dout[7:0];
      27'd5: game_engine       <= ioctl_dout[7:0];
      27'd6: game_variant      <= ioctl_dout[7:0];
      27'd7: game_flags        <= ioctl_dout[7:0];
      27'd8, 27'd9, 27'd10, 27'd11, 27'd12, 27'd13, 27'd14:
        if (ioctl_dout[7:0] != 8'h00) reserved_zero <= 1'b0;
      27'd15: meta_valid <= (meta_magic == 32'h44454C55) &&
                             header_tuple_valid && reserved_zero &&
                             (ioctl_dout[7:0] == 8'h00);
      default: ;
    endcase
  end

  // hps_io leaves ioctl_addr at the byte count when a transfer closes. Exact
  // length rejects truncated, overlong, and wrong-profile index-0 streams.
  if (core_download_d && !core_download) begin
    download_attempted <= 1'b1;
    index0_closed <= meta_valid && (ioctl_addr == expected_index0_size) &&
                     (index0_byte_count == {1'b0, expected_index0_size}) &&
                     !index0_sequence_error;
  end

  // Do not release the board on the same cycle as the final HPS byte. Wait for
  // the paired SDRAM writer and its synchronized acknowledgement to drain.
  if (index0_closed && !core_download && !main_rom_wait && sdram_ready_ss)
    rom_loaded <= 1'b1;

  if (dongle_download && !dongle_download_d) begin
    dongle_loaded <= 1'b0;
    dongle_byte_count <= 28'd0;
    dongle_sequence_error <= 1'b0;
  end
  if (dongle_download && ioctl_wr) begin
    if ({1'b0, ioctl_addr} != (dongle_download_d ? dongle_byte_count : 28'd0))
      dongle_sequence_error <= 1'b1;
    dongle_byte_count <= (dongle_download_d ? dongle_byte_count : 28'd0) + 28'd1;
  end
  if (dongle_download_d && !dongle_download)
    dongle_loaded <= (ioctl_addr == 27'h01000) &&
                     (dongle_byte_count == 28'h01000) && !dongle_sequence_error;

  // Reset clears the SDRAM writer's pending transaction. A stream interrupted
  // by it cannot qualify merely because the HPS still supplies every address.
  // Ordinary resets retain already completed media for normal game restart.
  if (loader_reset && (core_download || core_download_d || (index0_closed && !rom_loaded))) begin
    index0_sequence_error <= 1'b1;
    index0_closed <= 1'b0;
    rom_loaded <= 1'b0;
    meta_valid <= 1'b0;
  end
  if (loader_reset && (dongle_download || dongle_download_d)) begin
    dongle_sequence_error <= 1'b1;
    dongle_loaded <= 1'b0;
  end
end

wire cassette_media_ready = !select_decocass || dongle_loaded;
wire boot_ready = meta_valid && rom_loaded && cassette_media_ready && sdram_ready_ss;

wire selected_main_req = select_bwing ? bw_main_req : lib_main_req;
wire main_cache_ready, main_cache_req;
wire [24:1] main_cache_addr;
wire [15:0] main_cache_word;
wire main_cache_ack;
rom_cache u_main_cache (
  .clk(clk_sys), .reset(reset | core_download | ~boot_ready),
  .rom_cs(selected_main_req), .cpu_rw(1'b1),
  .cpu_addr(shared_main_rd_addr), .cpu_data(shared_main_q),
  .ready(main_cache_ready), .req(main_cache_req), .addr(main_cache_addr),
  .dout(main_cache_word), .ack(main_cache_ack), .sdram_base(25'd0)
);

// Tape addresses change at only 4.8 kHz. Prefetch each requested word through
// SDRAM port 1; the result settles many system clocks before the next serial
// tape bit is sampled, so no additional deck-state stall is required.
wire [7:0] tape_cache_data;
wire tape_cache_ready, tape_cache_req;
wire [24:1] tape_cache_addr;
wire [15:0] tape_cache_word;
wire tape_cache_ack;
rom_cache u_tape_cache (
  .clk(clk_sys), .reset(reset | decocass_download | ~boot_ready),
  .rom_cs(select_decocass), .cpu_rw(1'b1),
  .cpu_addr(dc_tape_rd_addr), .cpu_data(tape_cache_data),
  .ready(tape_cache_ready), .req(tape_cache_req), .addr(tape_cache_addr),
  .dout(tape_cache_word), .ack(tape_cache_ack), .sdram_base(25'h10000)
);

wire sdram_wr_req = main_wr_busy || tape_wr_busy;
wire [24:1] sdram_wr_addr = tape_wr_busy ? tape_wr_addr : main_wr_addr;
wire [15:0] sdram_wr_data = tape_wr_busy ? tape_wr_word : main_wr_word;

sdram u_sdram (
  .clk(clk_ram), .init(loader_reset), .ready(sdram_ready),
  .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
  .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
  .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
  .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
  .wr_req(sdram_wr_req), .wr_addr(sdram_wr_addr), .wr_din(sdram_wr_data),
  .wr_be(2'b11), .wr_ack(main_wr_ack),
  .p0_req(main_cache_req), .p0_addr(main_cache_addr),
  .p0_dout(main_cache_word), .p0_ack(main_cache_ack),
  .p1_req(tape_cache_req), .p1_addr(tape_cache_addr),
  .p1_dout(tape_cache_word), .p1_ack(tape_cache_ack),
  .p2_req(1'b0), .p2_addr(24'd0), .p2_dout(), .p2_ack()
);

bram_tdp #(.DW(8), .AW(15)) u_shared_aux_rom (
  .clk(clk_sys),
  .a_addr(shared_aux_wr ? shared_aux_wr_addr : shared_aux_a_rd_addr),
  .a_din(shared_aux_din), .a_we(shared_aux_wr), .a_dout(shared_aux_a_q),
  .b_addr(shared_aux_b_rd_addr), .b_din(8'd0), .b_we(1'b0),
  .b_dout(shared_aux_b_q)
);

wire [3:0] lib_r, lib_g, lib_b, bw_r, bw_g, bw_b, dc_r, dc_g, dc_b;
wire lib_hs, lib_vs, lib_hb, lib_vb, lib_ce;
wire bw_hs, bw_vs, bw_hb, bw_vb, bw_ce;
wire dc_hs, dc_vs, dc_hb, dc_vb, dc_ce;
wire [15:0] lib_audio_l, lib_audio_r;
wire [15:0] bw_audio_l, bw_audio_r;
wire [15:0] dc_audio_l, dc_audio_r;
wire dc_tape_active;

assign vred   = select_bwing ? bw_r  : select_decocass ? dc_r  : lib_r;
assign vgreen = select_bwing ? bw_g  : select_decocass ? dc_g  : lib_g;
assign vblue  = select_bwing ? bw_b  : select_decocass ? dc_b  : lib_b;
assign HSync  = select_bwing ? bw_hs : select_decocass ? dc_hs : lib_hs;
assign VSync  = select_bwing ? bw_vs : select_decocass ? dc_vs : lib_vs;
assign HBlank = select_bwing ? bw_hb : select_decocass ? dc_hb : lib_hb;
assign VBlank = select_bwing ? bw_vb : select_decocass ? dc_vb : lib_vb;
assign ce_pix = select_bwing ? bw_ce : select_decocass ? dc_ce : lib_ce;
assign audio_l = select_bwing ? bw_audio_l : select_decocass ? dc_audio_l : lib_audio_l;
assign audio_r = select_bwing ? bw_audio_r : select_decocass ? dc_audio_r : lib_audio_r;

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

// Pause: OSD-open pause plus the standard 10 s screen dim.
wire pause_cpu;
pause #(.RW(4), .GW(4), .BW(4), .CLKSPD(48)) u_pause (
  .clk_sys      ( clk_sys                  ),
  .reset        ( reset                    ),
  .user_button  ( 1'b0                     ),
  .pause_request( status[123]              ),
  .options      ( { ~status[6], status[5] } ),
  .OSD_STATUS   ( OSD_STATUS               ),
  .r            ( vred                     ),
  .g            ( vgreen                   ),
  .b            ( vblue                    ),
  .pause_cpu    ( pause_cpu                ),
  .rgb_out      ( { pred, pgreen, pblue }  )
);

// ---------------------------------------------------------------------------
// Hi-score save/restore (MAME hiscore.dat semantics; JimmyStones Hiscores_MiSTer).
// Config arrives on ioctl index 3 (MRA), the score dump is index 4 (nvram).
// While the module accesses game RAM it pauses both engine CPUs and drives the
// selected engine's main-CPU bus through the engine's hs_* port.
// ---------------------------------------------------------------------------
// The module starts its restore on the falling edge of reset and needs the save data flagged as loaded by then.
reg  [4:0]  hs_dl_cnt = 5'd0;
wire        hs_dl_hold = (hs_dl_cnt != 5'd0);
always @(posedge clk_sys) begin
  if (ioctl_download) hs_dl_cnt <= 5'd31;
  else if (hs_dl_cnt != 5'd0) hs_dl_cnt <= hs_dl_cnt - 5'd1;
end
wire        hs_pause, hs_rd, hs_wint, hs_wr;
wire [15:0] hs_addr;
wire  [7:0] hs_wdata;
wire  [7:0] lib_hs_rdata, bw_hs_rdata, dc_hs_rdata;
wire        hs_bus_active = hs_rd | hs_wint;
wire        engine_pause  = pause_cpu | hs_pause;
wire  [7:0] hs_rdata = select_bwing ? bw_hs_rdata : select_decocass ? dc_hs_rdata : lib_hs_rdata;

hiscore #(
  .HS_ADDRESSWIDTH ( 16 ),
  .HS_SCOREWIDTH   ( 8  ),
  .HS_CONFIGINDEX  ( 3  ),
  .HS_DUMPINDEX    ( 4  ),
  .CFG_ADDRESSWIDTH( 2  ),
  .CFG_LENGTHWIDTH ( 1  )
) u_hiscore (
  .clk              ( clk_sys                 ),
  .paused           ( engine_pause            ),
  .reset            ( reset | ioctl_download | hs_dl_hold | ~boot_ready ),   // held through ROM/config/save downloads + settle time
  .autosave         ( ~status[8]              ),   // default On: hi-score saved whenever the OSD opens
  .ioctl_upload     ( ioctl_upload            ),
  .ioctl_upload_req ( ioctl_upload_req        ),
  .ioctl_download   ( ioctl_download          ),
  .ioctl_wr         ( ioctl_wr                ),
  .ioctl_addr       ( ioctl_addr[24:0]        ),
  .ioctl_index      ( ioctl_index             ),
  .OSD_STATUS       ( OSD_STATUS              ),
  .data_from_hps    ( ioctl_dout[7:0]         ),
  .data_from_ram    ( hs_rdata                ),
  .ram_address      ( hs_addr                 ),
  .data_to_hps      ( ioctl_din               ),
  .data_to_ram      ( hs_wdata                ),
  .ram_write        ( hs_wr                   ),
  .ram_intent_read  ( hs_rd                   ),
  .ram_intent_write ( hs_wint                 ),
  .pause_cpu        ( hs_pause                ),
  .configured       ( hs_configured           )
);

// CRT Adjust (rmonic79/MiSTer-CRT-Adjust). Every supported engine uses a
// 384-pixel line with a narrow 256-pixel active area, so SYNCSHIFT is the
// appropriate horizontal-position implementation. At 48 MHz / 6 MHz the
// neutral read period is 8 clocks = 32 quarter-clock steps.
reg crt_on = 1'b0;
reg signed [4:0] crt_hsize = 5'sd0;
reg [6:0] crt_hpos_raw = 7'd0;
reg signed [5:0] crt_vshift = 6'sd0;
always @(posedge clk_sys) if (ce_pix) begin
  // Direct video must remain native. The menu is hidden in that mode, but a
  // previously enabled status bit persists, so gate the datapath explicitly.
  crt_on       <= status[101] & ~direct_video;
  crt_hsize    <= $signed(status[100:96]);
  crt_hpos_raw <= status[85:79];
  crt_vshift   <= $signed(status[78:74]);
end

wire signed [8:0] crt_hpos = (crt_hpos_raw <= 7'd48)
  ? $signed({2'b00, crt_hpos_raw})
  : (crt_hpos_raw <= 7'd96)
    ? ($signed({2'b00, crt_hpos_raw}) - 9'sd97) : 9'sd0;

// The universal module is sized for the 272-line B-Wings/cassette raster.
// Liberation-family games use 263 lines, so compensate only their negative
// wrap-around tap by the nine-line total difference.
wire engine_uses_272_lines = meta_valid && (game_engine != ENGINE_LIBERATION);
wire signed [5:0] crt_vshift_module =
  (!engine_uses_272_lines && crt_vshift[5]) ? (crt_vshift - 6'sd9)
                                             : crt_vshift;

wire crt_hs_ref;
reg crt_hs_ref_d = 1'b0;
always @(posedge clk_sys) crt_hs_ref_d <= crt_hs_ref;
wire crt_hs_ref_rise = crt_hs_ref & ~crt_hs_ref_d;

wire signed [8:0] crt_period_calc = 9'sd32 + crt_hsize;
wire [7:0] crt_rd_period = crt_period_calc[7:0];
reg [7:0] crt_rd_acc = 8'd0;
wire [8:0] crt_rd_sum = {1'b0, crt_rd_acc} + 9'd4;
wire crt_rd_tick = crt_rd_sum >= {1'b0, crt_rd_period};
always @(posedge clk_sys) begin
  if (!crt_on || crt_hs_ref_rise) crt_rd_acc <= 8'd0;
  else if (crt_rd_tick) crt_rd_acc <= crt_rd_sum - {1'b0, crt_rd_period};
  else crt_rd_acc <= crt_rd_sum[7:0];
end

wire [23:0] native_rgb = {pred, pred, pgreen, pgreen, pblue, pblue};
wire [23:0] credits_rgb;
wire credits_hs, credits_vs, credits_hblank, credits_vblank;
wire credits_dismiss = |(joy0 | joy1) |
                       |(credits_joy2 | credits_joy3 | credits_joy4 | credits_joy5) |
                       |buttons | credits_key[9] | |credits_mouse[2:0] | OSD_STATUS;
// Direct-video cabinets use the selected physical rotation even without the
// HDMI rotator. Horizontal is the existing unrotated viewing option.
wire [1:0] credits_rotation = (rot_mode == 2'd3) ? (flip ? 2'd2 : 2'd0) :
                             (rotate_ccw ? 2'd3 : 2'd1);
// All three engines have a 256x240 active raster. Insert before CRT adjustment
// so its variable read cadence and OSD anchor see matching RGB and timing.
credits_overlay #(.WIDTH(256), .HEIGHT(240)) u_credits (
  .clk_video(clk_sys), .reset(reset), .ce_pixel(ce_pix),
  .menu_trigger(status[120]), .dismiss(credits_dismiss),
  .rotation(credits_rotation),
  .r_in(native_rgb[23:16]), .g_in(native_rgb[15:8]), .b_in(native_rgb[7:0]),
  .hs_in(HSync), .vs_in(VSync), .hblank_in(HBlank), .vblank_in(VBlank),
  .r_out(credits_rgb[23:16]), .g_out(credits_rgb[15:8]), .b_out(credits_rgb[7:0]),
  .hs_out(credits_hs), .vs_out(credits_vs),
  .hblank_out(credits_hblank), .vblank_out(credits_vblank),
  .de_out(), .active()
);
wire [7:0] crt_r, crt_g, crt_b;
wire crt_hs, crt_vs, crt_hblank, crt_vblank;
crt_adjust #(
  .VTOTAL(272),
  .HTOTAL(384),
  .HPOS_MODE(`HPOS_SYNCSHIFT)
) u_crt_adjust (
  .clk       ( clk_sys           ),
  .pxl_cen   ( ce_pix            ),
  .pxl2_cen  ( crt_rd_tick       ),
  .active    ( crt_on            ),
  .hsize     ( crt_hsize         ),
  .hoffset   ( crt_hpos          ),
  .voffset   ( crt_vshift_module ),
  .r_in      ( credits_rgb[23:16] ),
  .g_in      ( credits_rgb[15:8]  ),
  .b_in      ( credits_rgb[7:0]   ),
  .hs_in     ( credits_hs        ),
  .vs_in     ( credits_vs        ),
  .hb_in     ( credits_hblank | credits_vblank ),
  .vb_in     ( credits_vblank    ),
  .r_out     ( crt_r             ),
  .g_out     ( crt_g             ),
  .b_out     ( crt_b             ),
  .hs_out    ( crt_hs            ),
  .vs_out    ( crt_vs            ),
  .hb_out    ( crt_hblank        ),
  .vb_out    ( crt_vblank        ),
  .hs_ref_out( crt_hs_ref        )
);

wire video_ce = crt_on ? crt_rd_tick : ce_pix;
wire [23:0] video_rgb = crt_on ? {crt_r, crt_g, crt_b} : credits_rgb;
wire video_hblank = crt_on ? crt_hblank : credits_hblank;
wire video_vblank = crt_on ? crt_vblank : credits_vblank;
wire video_hs = crt_on ? crt_hs : credits_hs;
wire video_vs = crt_on ? crt_vs : credits_vs;

// Keep the downstream OSD anchored to the native active area's leading edge
// while allowing the adjusted image and its trailing edge to move.
reg raw_hs_d = 1'b0;
always @(posedge clk_sys) if (ce_pix) raw_hs_d <= credits_hs;
wire native_line_tick = ce_pix && credits_hs && !raw_hs_d;
reg vblank_1l = 1'b0;
always @(posedge clk_sys) if (native_line_tick) vblank_1l <= credits_vblank;
wire native_active = ~(credits_hblank | vblank_1l);
reg native_active_d = 1'b0;
always @(posedge clk_sys) if (ce_pix) native_active_d <= native_active;
wire native_active_rise = native_active & ~native_active_d;

wire crt_active = ~crt_hblank;
reg crt_active_d = 1'b0;
always @(posedge clk_sys) if (crt_rd_tick) crt_active_d <= crt_active;
wire crt_active_fall = crt_active_d & ~crt_active;
reg de_osd = 1'b0;
always @(posedge clk_sys) begin
  if (native_active_rise) de_osd <= 1'b1;
  else if (crt_active_fall) de_osd <= 1'b0;
end

wire video_de;
arcade_video #(256,24,0) arcade_video(
  .clk_video          ( clk_sys             ),
  .ce_pix             ( video_ce            ),
  .RGB_in             ( video_rgb           ),
  .HBlank             ( video_hblank        ),
  .VBlank             ( video_vblank        ),
  .HSync              ( video_hs            ),
  .VSync              ( video_vs            ),
  .CLK_VIDEO          ( CLK_VIDEO           ),
  .CE_PIXEL           ( CE_PIXEL            ),
  .VGA_R              ( VGA_R               ),
  .VGA_G              ( VGA_G               ),
  .VGA_B              ( VGA_B               ),
  .VGA_HS             ( VGA_HS              ),
  .VGA_VS             ( VGA_VS              ),
  .VGA_DE             ( video_de            ),
  .VGA_SL             ( VGA_SL              ),
  .fx                 ( fx                  ),
  .forced_scandoubler ( forced_scandoubler  ),
  .gamma_bus          ( gamma_bus           )
);

// Darkmist's four choices map onto the framework's five scaling modes.
// The last choice selects the narrower/wider result using the rounding toggle.
wire [2:0] scale_mode = (direct_video || status[11:9] > 3'd3) ? 3'd0 :
                        (status[11:9] == 3'd2) ? 3'd4 :
                        (status[11:9] == 3'd3) ? (status[12] ? 3'd3 : 3'd2) : status[11:9];
wire integer_scaling = (scale_mode != 3'd0);
wire scaling_de_in = crt_on ? de_osd : video_de;
wire integer_de;
wire [12:0] integer_arx, integer_ary;
wire [12:0] native_integer_arx, native_integer_ary;
wire [12:0] rotated_integer_arx, rotated_integer_ary;
video_freak u_video_freak (
  .CLK_VIDEO ( CLK_VIDEO          ),
  .CE_PIXEL  ( CE_PIXEL           ),
  .VGA_VS    ( VGA_VS             ),
  .HDMI_WIDTH( HDMI_WIDTH         ),
  .HDMI_HEIGHT(HDMI_HEIGHT        ),
  .VGA_DE    ( integer_de         ),
  .VIDEO_ARX ( native_integer_arx ),
  .VIDEO_ARY ( native_integer_ary ),
  .VGA_DE_IN ( scaling_de_in      ),
  .ARX       ( aspect_arx[11:0]   ),
  .ARY       ( aspect_ary[11:0]   ),
  .CROP_SIZE ( 12'd0              ),
  .CROP_OFF  ( 5'd0               ),
  .SCALE     ( no_rotate ? scale_mode : 3'd0 )
);

// Match integer multiples to the displayed framebuffer dimensions after rotation.
video_scale_int u_rotated_scaling (
  .CLK_VIDEO ( CLK_VIDEO          ),
  .HDMI_WIDTH( HDMI_WIDTH         ),
  .HDMI_HEIGHT(HDMI_HEIGHT        ),
  .SCALE     ( no_rotate ? 3'd0 : scale_mode ),
  .hsize     ( FB_WIDTH           ),
  .vsize     ( FB_HEIGHT          ),
  .arx_i     ( aspect_arx[11:0]   ),
  .ary_i     ( aspect_ary[11:0]   ),
  .arx_o     ( rotated_integer_arx ),
  .ary_o     ( rotated_integer_ary )
);
assign integer_arx = no_rotate ? native_integer_arx : rotated_integer_arx;
assign integer_ary = no_rotate ? native_integer_ary : rotated_integer_ary;

assign VGA_DE = integer_scaling ? integer_de : scaling_de_in;
assign VIDEO_ARX = integer_scaling ? integer_arx : aspect_arx;
assign VIDEO_ARY = integer_scaling ? integer_ary : aspect_ary;

// HDMI framebuffer rotate (needs MISTER_FB). Default: vertical / CCW (ROT270).
screen_rotate screen_rotate (.*);

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
// MRA button bit immediately following SERVICE1. Liberation boards route
// TILT through their IO input, while B-Wings uses its edge as main-CPU FIRQ.
wire tilt     = joy0[11] | joy1[11];

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
  // Hold the complete board, not only its CPUs, until the ROM stream closes.
  // meta_valid becomes true at header byte 7, long before payload completion.
  .reset          ( reset | core_download | ~boot_ready | ~select_liberation ),
  .clk_sys        ( clk_sys          ),
  .p1             ( in1              ),
  .p2             ( in2              ),
  .p3             ( in3              ),
  .dsw1           ( sw[0]            ),
  .dsw2           ( sw[1]            ),
  .tilt           ( tilt             ),
  .pause          ( engine_pause     ),
  .hs_active      ( hs_bus_active && select_liberation ),
  .hs_addr        ( hs_addr          ),
  .hs_wr          ( hs_wr            ),
  .hs_wdata       ( hs_wdata         ),
  .hs_rdata       ( lib_hs_rdata     ),
  .game_variant   ( game_variant     ),
  .game_flags     ( game_flags       ),
  .ioctl_download ( core_download && select_liberation ),
  .ioctl_addr     ( engine_ioctl_addr),
  .ioctl_dout     ( ioctl_dout[7:0]  ),
  .ioctl_wr       ( engine_ioctl_wr && select_liberation ),
  .ext_main_addr  ( lib_main_addr    ),
  .ext_main_data  ( shared_main_q     ),
  .ext_main_req   ( lib_main_req      ),
  .ext_main_ready ( main_cache_ready  ),
  .ext_aux_addr   ( lib_aux_addr      ),
  .ext_aux_data   ( shared_aux_a_q    ),
  .red            ( lib_r            ),
  .green          ( lib_g            ),
  .blue           ( lib_b            ),
  .vs             ( lib_vs           ),
  .vb             ( lib_vb           ),
  .hs             ( lib_hs           ),
  .hb             ( lib_hb           ),
  .ce_pix         ( lib_ce           ),
  .audio_l        ( lib_audio_l      ),
  .audio_r        ( lib_audio_r      )
);

bwing_core u_bwing (
  .reset          ( reset | core_download | ~boot_ready | ~select_bwing ),
  .clk_sys        ( clk_sys          ),
  .pause          ( engine_pause     ),
  .hs_active      ( hs_bus_active && select_bwing ),
  .hs_addr        ( hs_addr          ),
  .hs_wr          ( hs_wr            ),
  .hs_wdata       ( hs_wdata         ),
  .hs_rdata       ( bw_hs_rdata      ),
  .p1             ( in1              ),
  .p2             ( in2              ),
  .p3             ( in3              ),
  .dsw1           ( sw[0]            ),
  .dsw2           ( sw[1]            ),
  .tilt           ( tilt             ),
  .ioctl_download ( core_download && select_bwing ),
  .ioctl_addr     ( engine_ioctl_addr),
  .ioctl_dout     ( ioctl_dout[7:0]  ),
  .ioctl_wr       ( engine_ioctl_wr && select_bwing ),
  .ext_main_addr  ( bw_main_addr     ),
  .ext_main_data  ( shared_main_q     ),
  .ext_main_req   ( bw_main_req      ),
  .ext_main_ready ( main_cache_ready ),
  .ext_sub_addr   ( bw_sub_addr       ),
  .ext_sub_data   ( shared_aux_a_q    ),
  .ext_sound_addr ( bw_sound_addr     ),
  .ext_sound_data ( shared_aux_b_q    ),
  .red            ( bw_r             ),
  .green          ( bw_g             ),
  .blue           ( bw_b             ),
  .hs             ( bw_hs            ),
  .vs             ( bw_vs            ),
  .hb             ( bw_hb            ),
  .vb             ( bw_vb            ),
  .ce_pix         ( bw_ce            ),
  .audio_l        ( bw_audio_l       ),
  .audio_r        ( bw_audio_r       )
);

wire decocass_wr = ioctl_wr && select_decocass &&
                   (((ioctl_index == 8'd0) && (ioctl_addr >= 27'd16)) ||
                    (ioctl_index == 8'd1));
wire [26:0] decocass_addr = (ioctl_index == 8'd0) ? engine_ioctl_addr
                                                   : ioctl_addr;
decocass_core u_decocass (
  .clk_sys        ( clk_sys                  ),
  .reset_in       ( reset | ~boot_ready | ~select_decocass ),
  .original_tape_speed ( status[124] ),
  .pause          ( engine_pause             ),
  .hs_active      ( hs_bus_active && select_decocass ),
  .hs_addr        ( hs_addr                  ),
  .hs_wr          ( hs_wr                    ),
  .hs_wdata       ( hs_wdata                 ),
  .hs_rdata       ( dc_hs_rdata              ),
  .p1             ( in1                      ),
  .p2             ( in2                      ),
  .p3             ( in3                      ),
  .dsw1           ( sw[3]                    ),
  .dsw2           ( sw[2]                    ),
  .ioctl_download ( decocass_download        ),
  .ioctl_index    ( ioctl_index              ),
  .ioctl_addr     ( decocass_addr[24:0]      ),
  .ioctl_dout     ( ioctl_dout[7:0]          ),
  .ioctl_wr       ( decocass_wr              ),
  .ext_tape_rd_addr( dc_tape_rd_addr         ),
  .ext_tape_rd_data( tape_cache_data          ),
  .ext_tape_wr_addr( dc_tape_wr_addr         ),
  .ext_tape_wr_data( dc_tape_wr_data         ),
  .ext_tape_wr_en  ( dc_tape_wr_en           ),
  .red            ( dc_r                     ),
  .green          ( dc_g                     ),
  .blue           ( dc_b                     ),
  .hs             ( dc_hs                    ),
  .vs             ( dc_vs                    ),
  .hb             ( dc_hb                    ),
  .vb             ( dc_vb                    ),
  .ce_pix         ( dc_ce                    ),
  .audio_l        ( dc_audio_l               ),
  .audio_r        ( dc_audio_r               ),
  .flip_screen    ( decocass_cocktail_flip   ),
  .tape_active    ( dc_tape_active           )
);

assign LED_USER = ioctl_download | (download_attempted && !boot_ready) |
                  (select_decocass && dc_tape_active);

endmodule
