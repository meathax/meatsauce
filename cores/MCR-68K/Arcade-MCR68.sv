`timescale 1ns/10ps

//============================================================================
//
//  Bally/Midway MCR-68000 ("MCR-68k") for MiSTer -- emu top-level wrapper.
//  Four MCR-68k profiles: Xenophobe (1987), Blasted, Arch Rivals and
//  Pigskin. Profile IDs are 0, 1, 3 and 4; ID 2 is reserved and rejected.
//
//  This file is the production MiSTer wrapper. The real top-level game board
//  below uses the SDRAM ROM loader/fabric and production RAM paths; the
//  host-file parameters remain only for standalone simulation harnesses that
//  instantiate mcr68_main_board directly.
//
//  Port list matches sys/emu_ports.vh (the exact interface sys/sys_top.v's
//  `emu emu (...)` instantiation drives, read verbatim from that file) and
//  follows the established pattern of this project's sibling cores
//  (D:\Arcade\AI\aCORES\Sega Y Board\Arcade-SegaYBoard.sv,
//  D:\Arcade\AI\narc\Arcade-NARC.sv): neither `MISTER_FB` nor
//  `MISTER_DUAL_SDRAM` is defined for this core, so only the base port set
//  (no framebuffer, no secondary SDRAM) is required -- confirmed against
//  emu_ports.vh's own `ifdef guards.
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
    inout  [45:0] HPS_BUS,

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

// Declare cross-section framework nets before the static tie-offs which use
// them. Some simulators accept later declarations, but standard ordering keeps
// the synthesis top portable and avoids implicit-net/elaboration ambiguity.
wire clk_sys;
wire ioctl_download;
wire [127:0] status;
wire [1:0] buttons;
wire video_field_out;
wire hdmi_blackout_en;

//============================================================================
// Static tie-offs for framework pins this core does not yet use.
//============================================================================
// The presentation boundary below is deliberately progressive.
assign VGA_F1         = video_field_out;
assign VGA_SCALER     = 1'b0;
assign VGA_DISABLE    = 1'b0;
assign HDMI_FREEZE    = 1'b0;
// The framework's HDMI blackout input is an enable for its resolution-change
// black-frame behavior, not a request to blank HDMI continuously.  A Video
// Rate or Direct Video change still alters the core-side input geometry/rate,
// so let sys_top's scaler black-frame that transition.
assign HDMI_BLACKOUT  = hdmi_blackout_en;
assign HDMI_BOB_DEINT = 1'b0;

assign AUDIO_S   = 1'b1;   // signed samples
assign AUDIO_MIX = 2'b00;  // no stereo mix -- mono DAC source, see audio section below

assign LED_USER  = ioctl_download;
assign LED_POWER = 2'b00;
assign LED_DISK  = 2'b00;
assign BUTTONS   = 2'b00;

// DDRAM is owned by the coherent video scanout below.  The scanout uses two
// completed 512x480 palette-index banks and small on-chip line stores; no
// other core block drives this interface.

// No ADC engine in this core; release the shared analog bus.
assign ADC_BUS = 4'bzzzz;

// No core-owned SD-card transaction engine.
assign SD_SCK  = 1'b0;
assign SD_MOSI = 1'b0;
assign SD_CS   = 1'b1;

assign UART_RTS = 1'b0;
assign UART_TXD = 1'b0;
assign UART_DTR = 1'b0;

assign USER_OUT = 7'b1111111;

//============================================================================
// Build-date OSD stamp (generated by sys/build_id.tcl at Quartus build
// time; degrades gracefully -- identically to every sibling core -- if
// build_id.v hasn't been generated yet, e.g. under Verilator).
//============================================================================
// mcr68_game_e -- per-title profile contract.
import mcr68_game_pkg::*;

// Elaborated title: sets graphics region sizes and sprite geometry for BOTH
// the main board and the hardware gfx ROM path. GAME_PIGSKIN is the union of
// all four supported titles' sizes.
localparam mcr68_game_e GAME_ELAB = GAME_PIGSKIN;

// Code-bus widths for the gfx1/gfx2 wires between u_mcr68_main_board and
// u_gfx_sdram below. MUST be computed with the exact same formula as
// mcr68_main_board.sv's own GFX1_CODE_W/GFX2_CODE_W parameters (see that
// file, ~line 330), or these top-level wires silently truncate the wider
// ext_gfx1_code/ext_gfx2_code driver -- no elaboration error, no synthesis
// warning, just aliased tile/sprite codes on any title whose gfx1/gfx2
// region exceeds Xenophobe's original 64K/256K (Arch Rivals, Blasted, Pigskin).
localparam int GFX1_CODE_W = $clog2(mcr68_gfx1_bytes(GAME_ELAB) / 32);
localparam int GFX2_CODE_W = $clog2(mcr68_gfx2_bytes(GAME_ELAB) / 512);

`include "build_id.v"
`ifndef BUILD_DATE
`define BUILD_DATE "MCR68"
`endif

//============================================================================
// CONF_STR
//
// The core exposes four MCR-68k titles through the profile byte in each MRA.
// Xenophobe remains the reference profile; the ROM stream below documents
// the common four-region contract consumed by every title:
//
//   ioctl_index 0 (rom index="0"): maincpu   0x40000 -- xeno_pro.3c/.3b/.2c/.2b,
//                                   16-bit interleaved (MRA <interleave output="16">)
//   ioctl_index 1 (rom index="1"): sg:cpu    0x40000 -- xeno_snd.u7/.u17/.u8/.u18,
//                                   16-bit interleaved, same shape as maincpu
//   ioctl_index 2 (rom index="2"): gfx1      0x10000 -- xeno_bg.11d/.12d,
//                                   NOT interleaved (straight concat); MRA
//                                   ROMREGION_INVERT note: bytes are the raw
//                                   dump matching MAME's CRC -- RTL/loader
//                                   must XOR every byte with 0xFF at the
//                                   point of tile decode, NOT at load time
//   ioctl_index 3 (rom index="3"): gfx2      0x40000 -- xeno_fg.7j/.8j/.9j/.10j,
//                                   NOT interleaved -- 4 separate bitplane
//                                   ROMs, one per quarter-region
//
// DIP switches are supplied by each MRA's <switches>/<dip> block, whose
// `default` byte HPS streams to the core through ioctl_index 254 at load;
// mcr68_dip_config receives that stream and exposes byte 0 as the
// CPU-visible DSW register. There is deliberately NO "DIP" token and no DIP
// page in the menu below: the switches are fixed at each title's MRA
// factory default and are not user-editable from the OSD. Removing the token
// removes only the menu -- the ioctl-254 default still arrives, so every
// title keeps its own title-specific switch byte.
//============================================================================
localparam CONF_STR = {
    "MCR68;;",
    "-;",
    "O[9:8],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    // Index 0 is HV Integer on purpose -- see the scale_mode comment near
    // video_freak for the 512x480/1.25-pixel-aspect derivation.
    "O[15:14],Scale,HV Integer,Normal,V-Integer,HV Integer+;",
    "O[16],Frame Rate,60Hz (frame x2),Native 30.8Hz;",
    // RETIRED 2026-09-12: status[101] (CRT Adjust On/Off), status[100:96]
    // (CRT H-Size), status[85:79] (CRT H-Position) and status[78:74]
    // (CRT V-Shift) are deliberately left unused/reserved. The core-side
    // `crt_adjust` geometry stage they drove was removed: its line buffer was
    // sized for a 384-dot line (AW=10 -> 512 samples/bank) while this core
    // writes 634 samples/line on Direct Video and 1268 on the scaler path, so
    // the line tail overwrote its own head, and its read cadence ignored the
    // Video Rate option (audit 2026-09-11, findings V-01/V-02). Do NOT reuse
    // these bit ranges for new options without renumbering: users who ever
    // enabled CRT Adjust have non-zero values saved in them, and the retired
    // semantics were h/v position/size knobs that no longer exist.
    // Presentation is fixed at the 60 Hz progressive default.
    "-;",
    "O[32],Test Mode,Off,On;",
    "O[33],Tilt,Off,On;",
    "O[34],Pause,Off,On;",
    "-;",
    "R[0],Reset;",
    // Fallback names only: a game is always loaded from an MRA, whose
    // per-title <buttons names="..."> block overrides this list entirely.
    // Each title's real names are transcribed from its INPUT_PORTS in
    // mcr68.cpp by tools/gen_mra.py, and the titles disagree on both button
    // count (Blasted has ONE) and on whether a START line exists (Xenophobe
    // and Blasted are coin-to-start and have none). This fallback therefore
    // just mirrors the default Xenophobe profile's field order so the pad is
    // usable if the core is ever started without an MRA: fire1..fire3 =
    // Fire/Left/Right, then Coin, Tilt and Service Credit. The cabinet's
    // maintained Self-Test slide remains available through OSD Test Mode.
    "J1,Fire,Left Button,Right Button,Coin,Tilt,Service Credit;",
    "V,v",`BUILD_DATE
};

//============================================================================
// Clock generation
//
// rtl/mcr68_main_board.sv takes a SINGLE shared `clk` for everything --
// both 68000s (main board CPU_HZ=7,723,800 fudged-MAME rate, and the sound
// board's own internal CPU_HZ=8,000,000, see that module's u_sound_board
// instantiation comment "match THIS module's own clk domain") plus the
// video timing generator's hardware-profile DOT_CLK_HZ=10,000,000 -- all
// three derived from one `clk` via clock-enable phase accumulators (see that
// file's "Clock-enable generation" section). MAME's live Xenophobe screen
// timing is exactly 30.000 Hz, represented by the simulation default of
// 9.984 MHz. The hardware top uses the PCB-derived 10 MHz dot cadence and
// the Arch Rivals schematic's own raster totals (634 dots/line, 512
// lines/frame -- manual 16-4001-K-101 sheet 7, see
// docs/ARCHRIVALS_PCB_RTL_PLAN.md): an exact /5 of clk_sys, 15.7729 kHz
// horizontal and 30.807 Hz vertical. This avoids unequal physical pixel
// dwell while leaving the pinned MAME-diff differential lane (which still
// uses the 640x520/9.984 MHz simulation defaults) unchanged.
//
// A core-owned PLL supplies 50 MHz game/video logic, a timing-centered SDRAM
// clock, and a retained 100 MHz auxiliary output.  Presentation stays in the
// native game domain: inserting a single-buffer 30-to-60 Hz framebuffer here
// produced unavoidable read/write tearing on real hardware.
//============================================================================
wire clk_core_pll;
wire clk_sdram_pll;
wire clk_video_pll;
wire clk_video_locked;

// The exact-rate CE accumulators preserve all emulated clocks at this rate,
// while the 50 MHz core output exceeds arcade_video's >40 MHz requirement.
// Running the whole core at the HDMI PLL's 148.5 MHz provided no behavioural
// benefit and failed real setup, hold and recovery timing by wide margins.
core_video_pll pll
(
    .refclk  (CLK_50M),
    // NEVER reset the PLL from RESET. sys_top's `reset` (sysmem reset_out) is
    // actively TOGGLED by Main during core init (the gp_out[31:30] combination
    // drives reset_req), so wiring it here killed clk_sys mid-SPI-transaction
    // on every hardware load: hps_io stopped acking and Main spun forever (the
    // observed instant NO SIGNAL with no ROM progress bar), or the CONF_STR
    // read raced PLL relock and returned an empty string ("Core name is
    // MENU"). Root-caused live on hardware 2026-08-14. The proven sibling
    // cores tie the PLL reset low for exactly this reason (Y Board: "ties
    // this to 1'b0; reset_request below already handles ~pll_locked");
    // PLL_AUTO_RESET ON in the QSF covers lock-loss recovery, and RESET still
    // resets the LOGIC via the poweron_rst chain below.
    .rst     (1'b0),
    .outclk_0(clk_core_pll),
    .outclk_1(clk_sdram_pll),
    .outclk_2(clk_video_pll),
    .locked  (clk_video_locked)
);

assign clk_sys = clk_core_pll;

assign CLK_VIDEO = clk_video_pll;

// Fixed-count power-up reset stretch after PLL lock. 2^16 clk_sys cycles at
// 50 MHz is ~1.31 ms, giving downstream state a deterministic quiet interval.
reg  [15:0] poweron_cnt = 16'd0;
reg         poweron_rst = 1'b1;
always @(posedge clk_sys or negedge clk_video_locked) begin
    if (!clk_video_locked) begin
        poweron_cnt <= 16'd0;
        poweron_rst <= 1'b1;
    end else if (~&poweron_cnt) begin
        poweron_cnt <= poweron_cnt + 16'd1;
        poweron_rst <= 1'b1;
    end
    else poweron_rst <= 1'b0;
end

// PLL lock is an asynchronous safety assertion and reset release is
// synchronized into the clock domain. This prevents any core/video state
// from leaving reset while the exported MiSTer video clock is not valid.
reg [1:0] reset_sr = 2'b11;
always @(posedge clk_sys or negedge clk_video_locked) begin
    if (!clk_video_locked) reset_sr <= 2'b11;
    else reset_sr <= {reset_sr[0], RESET | status[0] | buttons[1] | poweron_rst};
end
wire reset = reset_sr[1];

// Hold the core in reset for the duration of any ROM download, standard
// MiSTer practice -- avoids the CPU executing against a partially-written
// ROM image once the sibling agents' loader is wired in.
wire gfx1_cache_ready;
//============================================================================
// MRA profile-select byte  --  <rom index="8"><part>NN</part></rom>
//
// Emitted FIRST in every mra/*.mra (before index 0) precisely so it is latched
// before the maincpu download starts: mcr68_rom_loader.sv sizes its regions
// per title. See doc/rtl_game_select.md.
//
// DEFAULT SAFETY: this latch powers on to 8'h00 == GAME_XENOPHOB. An MRA with
// no index-8 block simply never writes it, so the verified Xenophobe profile
// is the default. Never renumber Xenophobe off profile 0.
//============================================================================
localparam [7:0] CFG_ROM_INDEX = 8'd8;
localparam [7:0] CFG_MAX_GAME  = 8'd4;   // highest implemented mcr68_game_e

// NVRAM save/load index (Arch Rivals 4B battery-backed work-RAM low byte --
// schematic sheet 2, manual 16-4001-K-101; see rtl/mcr68_mem_hw.sv and
// rtl/mem/mcr68_nvram_bridge.sv). Only meaningful when the loaded .mra
// declares <nvram index="9" size="8192"/> -- an MRA with no such tag never
// triggers ioctl_download/ioctl_upload at this index, so this is inert for
// every other title.
localparam [7:0] NVRAM_INDEX = 8'd9;

reg [7:0] cfg_game_byte = 8'h00;
always @(posedge clk_sys) begin
    // Reset on poweron_rst ONLY -- deliberately NOT on `reset`. `reset`
    // includes status[0]/buttons[1] (OSD and user Reset); clearing the latch
    // there would silently revert to Xenophobe's profile while another title's
    // ROM image is still resident in SDRAM.
    if (poweron_rst)
        cfg_game_byte <= 8'h00;
    else if (ioctl_download && ioctl_wr && (ioctl_index[7:0] == CFG_ROM_INDEX))
        cfg_game_byte <= ioctl_dout[7:0];
end

// mcr68_game_e is 3 bits, but truncation alone is NOT a validity check: 8'h08
// would truncate to 0 and alias onto Xenophobe, which contract rule 4 in
// rtl/mcr68_game_profile.svh forbids. Check all eight bits.
wire       cfg_game_ok = (cfg_game_byte <= CFG_MAX_GAME) && (cfg_game_byte != 8'd2);
wire [2:0] game_sel    = cfg_game_byte[2:0];
wire       nvram_profile_active = (game_sel == 3'd3); // Arch Rivals only

// ~cfg_game_ok holds the core inert on an unimplemented profile (the 0xFF
// sentinel or any out-of-range byte) -- contract rule 4, never alias onto
// Xenophobe.
wire core_reset = reset | ioctl_download | ~gfx1_cache_ready | ~cfg_game_ok;

//============================================================================
// HPS IO
//============================================================================
wire [21:0]  gamma_bus;

wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;
wire        ioctl_upload;
wire        ioctl_rd;
wire [15:0] ioctl_din;

// NVRAM save/load glue -- see NVRAM_INDEX comment and
// rtl/mem/mcr68_nvram_bridge.sv. periodic_upload_req pulses at ~1 Hz so HPS
// autosave (when enabled) picks up a dirty NVRAM promptly without the core
// needing to track a "dirty" bit itself; the bridge/mem_hw path is cheap to
// poll and idempotent when nothing changed.
reg [25:0] nvram_upload_div = 26'd0;
reg        periodic_upload_req = 1'b0;
always @(posedge clk_sys) begin
    if (poweron_rst || !nvram_profile_active) begin
        nvram_upload_div <= 26'd0;
        periodic_upload_req <= 1'b0;
    end else begin
        nvram_upload_div <= nvram_upload_div + 1'b1;
        if (&nvram_upload_div) periodic_upload_req <= ~periodic_upload_req;
    end
end

wire        nvram_wr;
wire [12:0] nvram_addr;
wire [7:0]  nvram_din;
wire [7:0]  nvram_dout;

mcr68_nvram_bridge #(.BYTES(8192)) u_nvram_bridge (
    .clk           (clk_sys),
    .rst           (poweron_rst),
    .ioctl_download(ioctl_download),
    .ioctl_upload  (ioctl_upload),
    .ioctl_wr      (ioctl_wr),
    .ioctl_addr    (ioctl_addr),
    .ioctl_dout    (ioctl_dout),
    .ioctl_din     (ioctl_din),
    .sel           ((ioctl_index[7:0] == NVRAM_INDEX) && nvram_profile_active),
    .nvram_wr      (nvram_wr),
    .nvram_addr    (nvram_addr),
    .nvram_din     (nvram_din),
    .nvram_dout    (nvram_dout)
);

wire [31:0] joystick_0, joystick_1, joystick_2;
wire [15:0] joy_l_analog_0, joy_l_analog_1;
wire        hps_direct_video;

// WIDE=1: ioctl_dout is 16 bits/write (rtl/mem/mcr68_rom_loader.sv's own
// header documents this exact assumption -- "the live MiSTer wrapper uses
// hps_io WIDE=1... advances ioctl_addr by two") and matches
// mra/Xenophobe.mra's `interleave output="16"` tag on the maincpu/sndcpu
// blocks, whose tool-assembled 16-bit stream this transports two bytes at
// a time. gfx1 (not interleaved) still streams byte-for-byte under WIDE=1;
// production gfx2 is internally row-packed by mcr68_rom_loader.sv after the
// same external stream arrives, without changing the MRA/ROM byte order.
hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .buttons(buttons),
    .status(status),
    // Hide aspect-ratio controls when sys_top is in raw/direct-video mode,
    // where the scaler cannot apply them.  The direct-video bit is the same
    // HPS cfg[10] decoded by sys_top.  Mask bit 1 previously hid the CRT
    // Adjust amount knobs (H1); no H1-prefixed option remains, so it is 0.
    .status_menumask({15'd0, hps_direct_video}),
    .status_in(128'd0),
    .status_set(1'b0),

    .forced_scandoubler(),
    .direct_video(hps_direct_video),
    .gamma_bus(gamma_bus),
    // This single-SDRAM core does not consume the framework's optional
    // capacity telemetry; leave the output explicitly unconnected.
    .sdram_sz(),

    // No NVRAM on Xenophobe (AGENTS.md: "No protection chip and no NVRAM
    // on Xenophobe") -- Arch Rivals' 4B battery-backed work-RAM byte is the
    // one title this upload/download path is live for, gated entirely by
    // whether the loaded .mra declares an index-9 <nvram> tag; see
    // NVRAM_INDEX above and rtl/mem/mcr68_nvram_bridge.sv.
    .ioctl_download(ioctl_download),
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(periodic_upload_req),
    .ioctl_upload_index(NVRAM_INDEX),
    .ioctl_wr(ioctl_wr),
    .ioctl_rd(ioctl_rd),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_din(ioctl_din),
    .ioctl_index(ioctl_index),
    .ioctl_wait(ioctl_wait),

    .joystick_0(joystick_0),
    .joystick_1(joystick_1),
    .joystick_2(joystick_2),
    .joystick_3(),
    .joystick_4(),
    .joystick_5(),
    // Left analog sticks for players 1/2: the Williams 49-way titles
    // (archrivl, pigskin) need them.
    // Signed 8-bit halves: x = [7:0], y = [15:8]. A pad with no analog stick
    // reports 0, which quantises to grid centre, so wiring them is safe
    // unconditionally and needs no OSD toggle
    // (doc/rtl_inputs_multigame.md section 3).
    .joystick_l_analog_0(joy_l_analog_0), .joystick_l_analog_1(joy_l_analog_1), .joystick_l_analog_2(),
    .joystick_l_analog_3(), .joystick_l_analog_4(), .joystick_l_analog_5(),
    .joystick_r_analog_0(), .joystick_r_analog_1(), .joystick_r_analog_2(),
    .joystick_r_analog_3(), .joystick_r_analog_4(), .joystick_r_analog_5(),
    .joystick_0_rumble(16'd0), .joystick_1_rumble(16'd0),
    .joystick_2_rumble(16'd0), .joystick_3_rumble(16'd0),
    .joystick_4_rumble(16'd0), .joystick_5_rumble(16'd0),

    .paddle_0(), .paddle_1(), .paddle_2(), .paddle_3(), .paddle_4(), .paddle_5(),
    .spinner_0(), .spinner_1(), .spinner_2(), .spinner_3(), .spinner_4(), .spinner_5(),

    .ps2_kbd_clk_out(), .ps2_kbd_data_out(),
    .ps2_kbd_clk_in(1'b0), .ps2_kbd_data_in(1'b0),
    .ps2_kbd_led_status(3'b000), .ps2_kbd_led_use(3'b000),
    .ps2_mouse_clk_out(), .ps2_mouse_data_out(),
    .ps2_mouse_clk_in(1'b0), .ps2_mouse_data_in(1'b0),
    .ps2_key(), .ps2_mouse(), .ps2_mouse_ext(),

    .video_rotated(1'b0),
    .new_vmode(1'b0),

    .info_req(1'b0), .info(8'd0),

    .img_mounted(), .img_readonly(), .img_size(),
    .sd_lba('{32'd0}), .sd_blk_cnt('{6'd0}),
    .sd_rd(1'b0), .sd_wr(1'b0), .sd_ack(),
    .sd_buff_addr(), .sd_buff_dout(), .sd_buff_din('{16'd0}), .sd_buff_wr(),
    .ioctl_file_ext(),

    .RTC(), .TIMESTAMP(), .uart_mode(), .uart_speed(),
    .EXT_BUS()
);

//============================================================================
// Input mapping. This block used to hand-build Xenophobe's in0_pins/in1_pins/
// dsw_pins directly, which was correct for exactly one of the four titles the
// core now runs. It now normalises the pad into game-agnostic ACTIVE-HIGH
// controls and hands them to rtl/inputs/mcr68_input_frontend.sv, which owns
// the per-title bit placement (mcr68_input_map.sv), the Williams 49-way
// translate49 encoding (mcr68_joy49.sv).
//
// Evidence and per-bit citations: doc/rtl_inputs_multigame.md,
// doc/rtl_inputs_wiring.md.
//============================================================================
// Per-controller controls, normalised to ACTIVE HIGH (1 = pressed) -- that is
// the convention rtl/inputs/mcr68_input_map.sv takes. All per-title bit
// placement, polarity and the 49-way translate49 encoding now
// live in the RTL, so this block no longer hand-builds any port word.
//
// Blasted has no native START line. Its host Start field is an explicit alias
// of that player's join chute. The cabinet COIN1/COIN2 numbering is opposite
// its P1/P2 control bundles, so the Blasted adapter crosses only those lines.
// SERVICE1 is the separate service-credit pushbutton; PORT_SERVICE is the
// maintained TEST slide switch. Arch Rivals and Pigskin have real START lines.
logic [2:0] ctl_coin;
logic [1:0] ctl_start;
logic       ctl_service1, ctl_service_dip, ctl_tilt;

wire [2:0] blasted_coin;
wire       blasted_tilt;
wire       blasted_service_credit;

mcr68_blasted_controls u_blasted_controls (
    .osd_tilt       (status[33]),
    .joystick_0     (joystick_0[8:5]),
    .joystick_1     (joystick_1[8:5]),
    .joystick_2     (joystick_2[8:7]),
    .coin           (blasted_coin),
    .tilt           (blasted_tilt),
    .service_credit (blasted_service_credit)
);

wire arch_diagnostic_push = joystick_0[10] | joystick_1[10] | joystick_2[10];
wire arch_diagnostic_switch;
mcr68_maintained_switch u_arch_diagnostic_switch (
    .clk      (clk_sys),
    .rst      (poweron_rst),
    .active   (game_sel == 3'd3),
    .push     (arch_diagnostic_push),
    .force_on (status[32]),
    .level    (arch_diagnostic_switch)
);

always_comb begin
    ctl_coin       = 3'b000;
    ctl_start      = 2'b00;
    ctl_service1   = 1'b0;
    ctl_service_dip= status[32];
    ctl_tilt       = status[33];
    case (game_sel)
        3'd0: begin // Xenophobe: three actions, Coin, Tilt, Service Credit.
            ctl_coin = {joystick_2[7], joystick_1[7], joystick_0[7]};
            ctl_tilt = status[33] | joystick_0[8] | joystick_1[8] | joystick_2[8];
            ctl_service1    = joystick_0[9] | joystick_1[9] | joystick_2[9];
            ctl_service_dip = status[32];
        end
        3'd1: begin // Blasted: Fire, Start alias, Coin, Tilt, Service Credit.
            ctl_coin        = blasted_coin;
            ctl_tilt        = blasted_tilt;
            ctl_service1    = blasted_service_credit;
            ctl_service_dip = status[32];
        end
        3'd3: begin // Arch Rivals: actions, 1 Player, Coin Chute 1, operator controls.
            ctl_coin  = {joystick_2[7], joystick_1[7], joystick_0[7]};
            ctl_start = {joystick_1[6], joystick_0[6]};
            ctl_tilt  = status[33] | joystick_0[8] | joystick_1[8] | joystick_2[8];
            ctl_service1    = joystick_0[9] | joystick_1[9] | joystick_2[9];
            ctl_service_dip = arch_diagnostic_switch;
        end
        3'd4: begin // Pigskin: actions, Start, Coin, Tilt, Service Credit.
            ctl_coin  = {joystick_2[8], joystick_1[8], joystick_0[8]};
            ctl_start = {joystick_1[7], joystick_0[7]};
            ctl_service1    = joystick_0[10] | joystick_1[10] | joystick_2[10];
            ctl_service_dip = status[32];
            ctl_tilt        = status[33] | joystick_0[9] | joystick_1[9] | joystick_2[9];
        end
        default: begin end
    endcase
end

// OSD pause. Freezes CPU/PTM/493/watchdog inside the board; the native raster
// keeps scanning the unchanged video/sprite/palette RAM, so the image remains.
wire pause_game = status[34];

// MiSTer joystick_N bit convention: [0]=Right,[1]=Left,[2]=Down,[3]=Up,
// [4..]=fire1.. in the MRA's <buttons names="..."> order (the CONF_STR J1
// list is only a fallback). Every title's button list in tools/gen_mra.py is
// MAME's BUTTON1..BUTTONn order, so fire(k) == IPT_BUTTONk and
// joystick_N[3+k] is that player's BUTTONk.
//
wire [7:0] ctl_btn1 = {joystick_0[10:4], 1'b0};
wire [7:0] ctl_btn2 = {joystick_1[10:4], 1'b0};
wire [7:0] ctl_btn3 = {joystick_2[10:4], 1'b0};

// ---- analog -----------------------------------------------------------
// 49-way sticks (archrivl, pigskin): signed axes straight through.
wire signed [7:0] an_x1 = joy_l_analog_0[7:0];
wire signed [7:0] an_y1 = joy_l_analog_0[15:8];
wire signed [7:0] an_x2 = joy_l_analog_1[7:0];
wire signed [7:0] an_y2 = joy_l_analog_1[15:8];

// DIP low byte, in the polarity the CPU reads. The MRA-driven receiver keeps
// the DSW map title-specific; mcr68_input_map remains a pure port-word
// composer and deliberately has no per-title DIP knowledge.
wire [7:0] ctl_dsw;

mcr68_dip_config u_dip_config (
    .clk            (clk_sys),
    .poweron_rst    (poweron_rst),
    .game           (game_sel),
    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_index    (ioctl_index),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .dsw            (ctl_dsw)
);

// ---- per-title port-word composition ----------------------------------
// rtl/inputs/mcr68_input_frontend.sv = mcr68_input_map (per-title IN0/IN1/DSW
// assembly and 49-way sticks).
wire [15:0] in0_pins, in1_pins, dsw_pins;

wire signed [15:0] core_audio_out;

mcr68_input_frontend u_input_frontend (
    .clk         (clk_sys),
    .rst         (core_reset),
    .game        (game_sel),
    .coin        (ctl_coin),
    .start_btn   (ctl_start),
    .tilt        (ctl_tilt),
    .service1    (ctl_service1),
    .service_dip (ctl_service_dip),
    .joy1        (joystick_0[3:0]),
    .joy2        (joystick_1[3:0]),
    .joy3        (joystick_2[3:0]),
    .btn1        (ctl_btn1[7:1]),
    .btn2        (ctl_btn2[7:1]),
    .btn3        (ctl_btn3[7:1]),
    .an_x1       (an_x1),
    .an_y1       (an_y1),
    .an_x2       (an_x2),
    .an_y2       (an_y2),
    .dsw_in      (ctl_dsw),
    .in0_word    (in0_pins),
    .in1_word    (in1_pins),
    .dsw_word    (dsw_pins)
);

//============================================================================
// SDRAM ROM subsystem (Phase 5 integration point, this task): mcr68_sdram
// (physical controller) + mcr68_rom_loader (hps_io ioctl -> SDRAM write) +
// mcr68_rom_fabric (per-client SDRAM read adapter). See each file's own
// header in rtl/mem/ for the full port contracts -- reconciled together
// with mcr68_main_board.sv's new SDRAM_ROM parameter in this same pass
// All four downloaded regions have live consumers: main and sound CPU ROM
// ports, the preloaded decoded tile-row cache, and on-demand sprite rows.
//
// Clock domain: clk_ram is tied to clk_sys here (a single-clock design) --
// no additional clock domain or CDC is introduced. mcr68_sdram.sv's own
// REFRESH_CYCLES default (700) assumed a ~96.6 MHz clk_ram; overridden to
// 350 below for clk_sys's 50 MHz (7.8us/row average-refresh budget *
// 50 MHz = 390 cycles; 350 keeps the same conservative safety margin
// below budget as the donor's own 700-at-96.6MHz choice).
//
// SDRAM_CLK is forwarded inverted for a half-cycle pin margin and is covered
// by Arcade-MCR68.sdc. Real-hardware display/audio/input verification remains
// required for this clock-output change.
//============================================================================
wire clk_ram = clk_sys;
// Forward the memory clock on the opposite phase. This supplies the SDRAM
// pin-level half-cycle margin without altering the vendored MiSTer PLL.
assign SDRAM_CLK = clk_sdram_pll;

wire         sdram_ready;
wire         rom_wr_req, rom_wr_ack;
wire [25:1]  rom_wr_addr;
wire [15:0]  rom_wr_data;
wire [1:0]   rom_wr_be;
wire         rom_loaded;

mcr68_rom_loader #(
    .PACK_GFX2     (1'b1)
) u_rom_loader (
    .clk            (clk_ram),
    // PLL-lock only -- NOT `reset`. Main sets status[0]=1 and holds the core
    // reset for the entire ROM download, and `reset` carries
    // RESET|status[0]|buttons[1]; wired here it held the loader in reset
    // while the download streamed, discarding every byte. Same hardware
    // root-cause session as the ioctl_wait deadlock (2026-08-14): the
    // download path must live in the PLL-lock domain, not the core-reset
    // domain. Matches the proven Y Board pattern (dl_reset from ~pll_locked
    // only).
    .rst            (!clk_video_locked),
    .game           (game_sel),             // static config; see cfg_game_byte above
    .mem_ready      (sdram_ready),
    .ioctl_download (ioctl_download),
    .ioctl_index    (ioctl_index[7:0]),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr[24:0]),
    .ioctl_dout     (ioctl_dout),
    .ioctl_wait     (ioctl_wait),
    .wr_req         (rom_wr_req),
    .wr_addr        (rom_wr_addr),
    .wr_data        (rom_wr_data),
    .wr_be          (rom_wr_be),
    .wr_ack         (rom_wr_ack),
    .rom_loaded     (rom_loaded)
);

// mcr68_main_board's mainrom_* port is wired live to the fabric's `main`
// client below (same clk_ram/clk_sys domain -- no CDC needed).
//
// 2026-08-26: the three CPU program-ROM clients (main 68000, Sounds Good
// 68000, Williams bg 6809) now go through per-CPU direct-mapped caches
// (rtl/mem/mcr68_rom_cache.sv) before reaching the fabric.  Without them,
// every ROM bus cycle on hardware paid the full SDRAM round trip and both
// 68000s ran far below nominal speed -- slow/warbling music, and Xenophobe's
// boot RAM test outrunning the 8-vblank watchdog (permanent reset-loop black
// screen).  A cache hit answers in 2 clk, restoring the zero-wait cadence
// every Verilator/MAME-diff harness already models.  cpu_* nets are the
// board-side (cached) legs; fab_* remain the fabric-side legs.
wire        cpu_main_req, cpu_main_ack;
wire [16:0] cpu_main_addr;
wire [15:0] cpu_main_data;
wire        cpu_snd_req, cpu_snd_ack;
wire [16:0] cpu_snd_addr;
wire [15:0] cpu_snd_data;
wire        cpu_bg_req, cpu_bg_ack;
wire [18:0] cpu_bg_addr;
wire [7:0]  cpu_bg_data;

wire        fab_main_req, fab_main_ack;
wire [16:0] fab_main_addr;
wire [15:0] fab_main_data;
wire        fab_snd_req, fab_snd_ack;
wire [16:0] fab_snd_addr;
wire [15:0] fab_snd_data;
wire        fab_gfx1_req, fab_gfx1_ack;
wire [16:0] fab_gfx1_addr;
wire [7:0]  fab_gfx1_data;
wire        fab_gfx2_req, fab_gfx2_ack;
wire [18:0] fab_gfx2_addr;
wire [7:0]  fab_gfx2_data;
wire        fab_gfx2_word_req, fab_gfx2_word_ack;
wire [18:0] fab_gfx2_word_addr;
wire [15:0] fab_gfx2_word_data;
wire        fab_gfx2_burst_req, fab_gfx2_burst_ack;
wire [18:0] fab_gfx2_burst_addr;
wire [31:0] fab_gfx2_burst_data;
wire        fab_gfx2_row_req, fab_gfx2_row_ack;
wire [18:0] fab_gfx2_row_addr;
wire [127:0] fab_gfx2_row_data;
// bg client: Williams S11/S11C background-sound-board bg:cpu ROM, wired
// straight through from u_mcr68_main_board's bgrom_* ports (already masked
// there by prof_rt.snd_williams_bg -- see mcr68_main_board.sv) to the
// fabric's new `bg` client (shares p1/SND_BASE with `snd` -- see
// rtl/mem/mcr68_rom_fabric.sv's "BG CLIENT ADDED" header note). No
// additional masking needed at this level.
// bgrom_addr on u_mcr68_main_board is [18:0] (19 bits) -- the REAL bg:cpu
// address range is 512K (4-bit bank register x 32KiB pages), one bit
// narrower than mcr68_rom_loader.sv's staged 576K region; see
// rtl/mem/mcr68_rom_fabric.sv's "BG CLIENT ADDED" header note.
wire        fab_bg_req, fab_bg_ack;
wire [18:0] fab_bg_addr;
wire [7:0]  fab_bg_data;

wire        sdr_p0_req, sdr_p0_ack, sdr_p1_req, sdr_p1_ack;
wire        sdr_p2_req, sdr_p2_ack, sdr_p3_req, sdr_p3_ack;
wire [25:1] sdr_p0_addr, sdr_p1_addr, sdr_p2_addr, sdr_p3_addr;
wire [15:0] sdr_p0_data, sdr_p1_data, sdr_p2_data, sdr_p3_data;
wire        sdr_p3_burst_req, sdr_p3_burst_ack;
wire [25:1] sdr_p3_burst_addr;
wire [31:0] sdr_p3_burst_data;
wire        sdr_p3_row_req, sdr_p3_row_ack;
wire [25:1] sdr_p3_row_addr;
wire [127:0] sdr_p3_row_data;

// Per-CPU program-ROM caches (see the header of rtl/mem/mcr68_rom_cache.sv
// for the hardware root-cause).  Flushed while the core is held in reset --
// which covers every ROM download and profile change -- so a stale line can
// never survive a new image.
mcr68_rom_cache #(.AW(17), .DW(16), .ENTRIES_LOG2(13)) u_mainrom_cache (
    .clk    (clk_ram),
    .rst    (core_reset),
    .c_req  (cpu_main_req),
    .c_addr (cpu_main_addr),
    .c_data (cpu_main_data),
    .c_ack  (cpu_main_ack),
    .m_req  (fab_main_req),
    .m_addr (fab_main_addr),
    .m_data (fab_main_data),
    .m_ack  (fab_main_ack)
);

mcr68_rom_cache #(.AW(17), .DW(16), .ENTRIES_LOG2(13)) u_sndrom_cache (
    .clk    (clk_ram),
    .rst    (core_reset),
    .c_req  (cpu_snd_req),
    .c_addr (cpu_snd_addr),
    .c_data (cpu_snd_data),
    .c_ack  (cpu_snd_ack),
    .m_req  (fab_snd_req),
    .m_addr (fab_snd_addr),
    .m_data (fab_snd_data),
    .m_ack  (fab_snd_ack)
);

mcr68_rom_cache #(.AW(19), .DW(8), .ENTRIES_LOG2(13)) u_bgrom_cache (
    .clk    (clk_ram),
    .rst    (core_reset),
    .c_req  (cpu_bg_req),
    .c_addr (cpu_bg_addr),
    .c_data (cpu_bg_data),
    .c_ack  (cpu_bg_ack),
    .m_req  (fab_bg_req),
    .m_addr (fab_bg_addr),
    .m_data (fab_bg_data),
    .m_ack  (fab_bg_ack)
);

mcr68_rom_fabric #(
    .USE_GFX2_ROW (1'b1)
) u_rom_fabric (
    .clk        (clk_ram),
    .rst        (reset),

    .main_req   (fab_main_req),
    .main_addr  (fab_main_addr),
    .main_data  (fab_main_data),
    .main_ack   (fab_main_ack),

    .snd_req    (fab_snd_req),  .snd_addr (fab_snd_addr),
    .snd_data   (fab_snd_data), .snd_ack  (fab_snd_ack),
    .gfx1_req   (fab_gfx1_req), .gfx1_addr(fab_gfx1_addr),
    .gfx1_data  (fab_gfx1_data),.gfx1_ack (fab_gfx1_ack),
    .gfx2_req   (fab_gfx2_req), .gfx2_addr(fab_gfx2_addr),
    .gfx2_data  (fab_gfx2_data),.gfx2_ack (fab_gfx2_ack),
    .gfx2_word_req   (fab_gfx2_word_req), .gfx2_word_addr(fab_gfx2_word_addr),
    .gfx2_word_data  (fab_gfx2_word_data),.gfx2_word_ack (fab_gfx2_word_ack),
    .gfx2_burst_req  (fab_gfx2_burst_req), .gfx2_burst_addr(fab_gfx2_burst_addr),
    .gfx2_burst_data (fab_gfx2_burst_data),.gfx2_burst_ack (fab_gfx2_burst_ack),
    .gfx2_row_req    (fab_gfx2_row_req), .gfx2_row_addr(fab_gfx2_row_addr),
    .gfx2_row_data   (fab_gfx2_row_data),.gfx2_row_ack (fab_gfx2_row_ack),
    .bg_req     (fab_bg_req),   .bg_addr  (fab_bg_addr),
    .bg_data    (fab_bg_data),  .bg_ack   (fab_bg_ack),

    .p0_req (sdr_p0_req), .p0_addr (sdr_p0_addr), .p0_data (sdr_p0_data), .p0_ack (sdr_p0_ack),
    .p1_req (sdr_p1_req), .p1_addr (sdr_p1_addr), .p1_data (sdr_p1_data), .p1_ack (sdr_p1_ack),
    .p2_req (sdr_p2_req), .p2_addr (sdr_p2_addr), .p2_data (sdr_p2_data), .p2_ack (sdr_p2_ack),
    .p3_req (sdr_p3_req), .p3_addr (sdr_p3_addr), .p3_data (sdr_p3_data), .p3_ack (sdr_p3_ack),
    .p3_burst_req (sdr_p3_burst_req), .p3_burst_addr (sdr_p3_burst_addr),
    .p3_burst_data (sdr_p3_burst_data), .p3_burst_ack (sdr_p3_burst_ack),
    .p3_row_req (sdr_p3_row_req), .p3_row_addr (sdr_p3_row_addr),
    .p3_row_data (sdr_p3_row_data), .p3_row_ack (sdr_p3_row_ack)
);

wire [GFX1_CODE_W-1:0] gfx1_code;
wire [2:0]  gfx1_row;
wire [1:0]  gfx1_pair;
wire [3:0]  gfx1_pen0, gfx1_pen1;
wire [GFX2_CODE_W-1:0] gfx2_code;
wire [4:0]  gfx2_row;
wire        gfx2_req, gfx2_ack;
wire [127:0] gfx2_pens;

// gfx1_small: true when the ACTIVE title's real gfx1 region is the 64K size
// (GFX_64K in rtl/mcr68_game_pkg.sv's profile table -- Xenophobe/Blasted)
// rather than the 128K elaborated union (Arch Rivals/Pigskin).
// Selects where u_gfx_sdram's 12d/upper-bitplane half begins; see that
// module's gfx1_plane_base comment. Written as a direct case on game_sel
// (NOT `mcr68_profile(game_sel).gfx1_size`) deliberately: field-selecting a
// packed-struct function-call result is Verilator-legal but Quartus-17-
// illegal (see rtl/mcr68_game_pkg.sv's accessor-wrapper comments for the
// same rule applied there).
wire gfx1_small = (game_sel == 3'd0) || (game_sel == 3'd1);
// Xenophobe is the only active profile whose gfx2 region is 256 KiB. The
// shared production fetcher is elaborated at the 512 KiB union width, so it
// needs this runtime geometry bit to preserve the real 9-bit code and 18-bit
// plane/code/row address packing for Xenophobe.
wire gfx2_small = (game_sel == 3'd0);

mcr68_gfx_rom_sdram #(
    // Must match the main board's GAME_STATIC elaboration, or the HARDWARE gfx
    // path stays Xenophobe-sized while the sim path widens -- which is exactly
    // why an earlier measurement under-reported block RAM.
    .GFX1_BYTES (mcr68_gfx1_bytes(GAME_ELAB)),
    .GFX2_BYTES (mcr68_gfx2_bytes(GAME_ELAB)),
    .USE_GFX2_BURST (1'b1),
    .USE_GFX2_ROW_BURST (1'b1)
) u_gfx_sdram (
    .clk(clk_sys), .rst(reset), .load_enable(rom_loaded), .gfx1_ready(gfx1_cache_ready),
    .gfx1_small(gfx1_small),
    .gfx2_small(gfx2_small),
    .gfx1_code(gfx1_code), .gfx1_row(gfx1_row), .gfx1_pair(gfx1_pair),
    .gfx1_pen0(gfx1_pen0), .gfx1_pen1(gfx1_pen1),
    .gfx2_code(gfx2_code), .gfx2_row(gfx2_row), .gfx2_req(gfx2_req),
    .gfx2_ack(gfx2_ack), .gfx2_pens(gfx2_pens),
    .fab_gfx1_req(fab_gfx1_req), .fab_gfx1_addr(fab_gfx1_addr),
    .fab_gfx1_data(fab_gfx1_data), .fab_gfx1_ack(fab_gfx1_ack),
    .fab_gfx2_req(fab_gfx2_req), .fab_gfx2_addr(fab_gfx2_addr),
    .fab_gfx2_data(fab_gfx2_data), .fab_gfx2_ack(fab_gfx2_ack),
    .fab_gfx2_word_req(fab_gfx2_word_req), .fab_gfx2_word_addr(fab_gfx2_word_addr),
    .fab_gfx2_word_data(fab_gfx2_word_data), .fab_gfx2_word_ack(fab_gfx2_word_ack),
    .fab_gfx2_burst_req(fab_gfx2_burst_req), .fab_gfx2_burst_addr(fab_gfx2_burst_addr),
    .fab_gfx2_burst_data(fab_gfx2_burst_data), .fab_gfx2_burst_ack(fab_gfx2_burst_ack),
    .fab_gfx2_row_req(fab_gfx2_row_req), .fab_gfx2_row_addr(fab_gfx2_row_addr),
    .fab_gfx2_row_data(fab_gfx2_row_data), .fab_gfx2_row_ack(fab_gfx2_row_ack)
);

mcr68_sdram #(
    .REFRESH_CYCLES(350),  // see clock-domain note above -- 50 MHz clk_ram
    .P3_ROW_ENABLE(1'b1)
) u_sdram (
    .clk        (clk_ram),
    // PLL-lock only -- NOT `reset`. `init` is level-held and restarts the
    // ~1.3 ms init sequence; with `reset` here (which carries
    // RESET|status[0]|buttons[1]|poweron_rst, all actively driven by Main
    // around core load), `ready` could never rise, `mem_ready` stayed 0, and
    // the old idle-asserting ioctl_wait deadlocked the first SPI word.
    // Init must run once at PLL lock and then survive every core reset.
    .init       (!clk_video_locked),
    .ready      (sdram_ready),

    .SDRAM_DQ   (SDRAM_DQ),
    .SDRAM_A    (SDRAM_A),
    .SDRAM_BA   (SDRAM_BA),
    .SDRAM_DQML (SDRAM_DQML),
    .SDRAM_DQMH (SDRAM_DQMH),
    .SDRAM_nCS  (SDRAM_nCS),
    .SDRAM_nCAS (SDRAM_nCAS),
    .SDRAM_nRAS (SDRAM_nRAS),
    .SDRAM_nWE  (SDRAM_nWE),
    .SDRAM_CKE  (SDRAM_CKE),

    .wr_req  (rom_wr_req),  .wr_addr (rom_wr_addr), .wr_din (rom_wr_data),
    .wr_be   (rom_wr_be),   .wr_ack  (rom_wr_ack),

    .p0_req (sdr_p0_req), .p0_addr (sdr_p0_addr), .p0_dout (sdr_p0_data), .p0_ack (sdr_p0_ack),
    .p1_req (sdr_p1_req), .p1_addr (sdr_p1_addr), .p1_dout (sdr_p1_data), .p1_ack (sdr_p1_ack),
    .p2_req (sdr_p2_req), .p2_addr (sdr_p2_addr), .p2_dout (sdr_p2_data), .p2_ack (sdr_p2_ack),
    .p3_req (sdr_p3_req), .p3_addr (sdr_p3_addr), .p3_dout (sdr_p3_data), .p3_ack (sdr_p3_ack),
    .p3_burst_req (sdr_p3_burst_req), .p3_burst_addr (sdr_p3_burst_addr),
    .p3_burst_dout (sdr_p3_burst_data), .p3_burst_ack (sdr_p3_burst_ack),
    .p3_row_req (sdr_p3_row_req), .p3_row_addr (sdr_p3_row_addr),
    .p3_row_dout (sdr_p3_row_data), .p3_row_ack (sdr_p3_row_ack)
);

//============================================================================
// Game core -- rtl/mcr68_main_board.sv, real synthesis target
// (SDRAM_ROM=1): main/sound CPU ROMs and graphics ROMs come from the shared
// SDRAM fabric. Work/video/aux/sprite/palette RAM and sound RAM use the
// synthesizable production storage modules selected by the board's
// SDRAM_ROM generate paths. The host-file parameters below are intentionally
// empty because they belong only to the standalone simulation harnesses.
//
// The three existing Verilator sim harnesses (sim/tb_mcr68_headless.sv,
// tb_mcr68_visual.sv, tb_mcr68_sound_headless.sv) instantiate
// mcr68_main_board directly, WITHOUT this module or the SDRAM_ROM
// parameter, so none of the above affects them -- verified by rebuilding
// these harnesses are separate from this production wrapper and are not a
// substitute for Quartus or MiSTer hardware validation.
//============================================================================
wire        core_video_ce_dot;
wire        core_video_hblank, core_video_vblank;
wire        core_video_hsync, core_video_vsync;
wire  [7:0] core_video_r, core_video_g, core_video_b;
wire  [8:0] core_video_x, core_video_y;
wire  [5:0] core_video_index;

mcr68_main_board #(
    .MAINCPU_ROM_FILE (""),           // unused when SDRAM_ROM=1, see comment above
    .GFX1_ROM_FILE    (""),           // unused when SDRAM_ROM=1
    .GFX2_ROM_FILE    (""),           // unused when SDRAM_ROM=1
    .SNDCPU_ROM_FILE  (""),           // unused when SDRAM_ROM=1
    // Elaborate the UNION of all four titles' graphics sizes so one bitstream
    // can run any of them: gfx1 'h20000 (archrivl/pigskin) and gfx2 'h80000
    // (everything except Xenophobe). GAME_PIGSKIN carries both maxima.
    // Region sizes and port widths are elaboration-time and cannot follow the
    // runtime `game` input; only address decode and I/O do.
    .GAME_STATIC      (GAME_ELAB),
    .CLK_HZ           (50_000_000),   // == clk_sys, see "Clock generation" above
    .CPU_HZ           (7_723_800),    // mcr68.cpp:1192-1222, unchanged from module default
    // Hardware-output profile: the PCB's separate 20 MHz video oscillator
    // supports an inferred 10 MHz dot cadence.  At 50 MHz this is an exact
    // divide-by-five, avoiding the 5/6-clock pixel-width modulation produced
    // by the MAME-compatible 9.984 MHz NCO rate.  Simulation defaults remain
    // 9.984 MHz for the pinned 30.000 Hz differential lane.
    .DOT_CLK_HZ       (10_000_000),
    // H_TOTAL/V_TOTAL: read directly off the Arch Rivals schematic (manual
    // 16-4001-K-101, sheet 7 timebase HALs) -- net names `634~`/`317~` name
    // the horizontal total, `511` the vertical total (511+1=512), matching
    // this same "68000 Video Game Board A084-91871-G000/M051-00114-G166"
    // shared across Xenophobe/Blasted/Pigskin/Arch Rivals. KNOWN for Arch
    // Rivals; INFERRED (not independently schematic-verified yet) for the
    // other three titles that share this identical board design. At the
    // 10 MHz dot clock above this raster runs 15.7729 kHz horizontal /
    // 30.807 Hz vertical -- see docs/ARCHRIVALS_PCB_RTL_PLAN.md P0-1.
    // Superseded from the 640x520/"unchanged from module default" MAME-
    // compatible raster this profile carried before that schematic study.
    .H_TOTAL          (634),
    .V_TOTAL          (512),
    .WDOG_LIMIT       (8),            // mcr68.cpp:1225, unchanged from module default
    .IRQ1_OFFSET_ECLKS(256 + 16),     // mcr68.cpp:1859, unchanged from module default (dead when USE_SCANLINE_493=1 below)
    // PCB-accurate "493" strobe (same schematic sheet): the frame interrupt
    // is the decoded scanline 493 itself, not an E-clock countdown timed to
    // assume a specific frame period. Ties irq1 directly to the raster
    // above instead of to E_CLOCKS_PER_FRAME's frame-period assumption --
    // see rtl/mcr68_io.sv's own header and docs/ARCHRIVALS_PCB_RTL_PLAN.md
    // P0-2.
    .USE_SCANLINE_493 (1'b1),
    .IRQ493_LINE      (493),
    .WDOG_RESET_CYCLES(16),           // unchanged from module default
    .SDRAM_ROM        (1'b1)          // real synthesis target -- see mcr68_main_board.sv header
) u_mcr68_main_board (
    .pause            (pause_game),
    .clk               (clk_sys),
    .rst               (core_reset),

    // Runtime title select. SystemVerilog has no default for an input port --
    // leaving this unconnected elaborates to 'z, it does NOT default to 0
    // (mcr68_main_board.sv's own port comment says so explicitly).
    .game              (game_sel),

    .in0_pins          (in0_pins),
    .in1_pins          (in1_pins),
    .dsw_pins          (dsw_pins),

    // Board-side ROM legs now terminate at the per-CPU caches above, not the
    // fabric directly.
    .mainrom_req       (cpu_main_req),
    .mainrom_addr      (cpu_main_addr),
    .mainrom_data      (cpu_main_data),
    .mainrom_ack       (cpu_main_ack),
    .sndrom_req        (cpu_snd_req),
    .sndrom_addr       (cpu_snd_addr),
    .sndrom_data       (cpu_snd_data),
    .sndrom_ack        (cpu_snd_ack),
    .bgrom_req         (cpu_bg_req),
    .bgrom_addr        (cpu_bg_addr),
    .bgrom_data        (cpu_bg_data),
    .bgrom_ack         (cpu_bg_ack),
    .ext_gfx1_code     (gfx1_code),
    .ext_gfx1_row      (gfx1_row),
    .ext_gfx1_pair     (gfx1_pair),
    .ext_gfx1_pen0     (gfx1_pen0),
    .ext_gfx1_pen1     (gfx1_pen1),
    .ext_gfx2_code     (gfx2_code),
    .ext_gfx2_row      (gfx2_row),
    .ext_gfx2_req      (gfx2_req),
    .ext_gfx2_ack      (gfx2_ack),
    .ext_gfx2_pens     (gfx2_pens),

    .video_ce_dot      (core_video_ce_dot),
    .video_hblank_o    (core_video_hblank),
    .video_vblank_o    (core_video_vblank),
    .video_hsync_o     (core_video_hsync),
    .video_vsync_o     (core_video_vsync),
    .video_pixel_x_o   (core_video_x),
    .video_pixel_y_o   (core_video_y),
    .video_r           (core_video_r),
    .video_g           (core_video_g),
    .video_b           (core_video_b),
    // Named dbg_* by history, but both are production signals: the palette
    // index feeds the scanout packer and dbg_audio_out is the core's only
    // audio source.
    .dbg_palette_rd_addr(core_video_index),
    .dbg_audio_out     (core_audio_out),

    .nvram_wr          (nvram_wr),
    .nvram_addr        (nvram_addr),
    .nvram_din         (nvram_din),
    .nvram_dout        (nvram_dout)
);
//============================================================================

// Video output. Keep the native game renderer at 512x480 and publish only
// completed frames through the packed three-bank scanout. The game renderer
// remains 634 dots x 512 lines at 10 MHz; presentation is fixed at twice that
// dot cadence, approximately 31.55 kHz H / 61.61 Hz V.
// The third bank keeps producer, completed and displayed frame ownership
// disjoint at any relative phase, so a completed game frame is never
// discarded while waiting for the presentation vblank.
// The diagnostic raster below remains independent of this game path.
//============================================================================
wire scan_ce, scan_hblank, scan_vblank, scan_hsync, scan_vsync;
wire [7:0] scan_r, scan_g, scan_b;

// Presentation cadence. Default (status[16]=0) is unchanged: each completed
// 30.807 Hz game frame is presented TWICE at 61.613 Hz.
//
// This is re-exposed as an OSD toggle because frame doubling is the only
// remaining core-side mechanism that can soften the picture on a real panel
// while every single-frame capture stays pixel-perfect: if the two
// presentations of one game frame are not bit-identical, the display
// alternates between two images at 61.6 Hz and the eye integrates that into
// a doubled/blurred edge. A screenshot samples one presentation and looks
// clean. Selecting Native 30.8Hz presents each frame once and removes the
// mechanism entirely -- if the softness disappears (at the cost of a 30.8 Hz
// refresh), the doubling path is the cause; if it does not change, the
// softening is downstream of the core's video tap.
wire present_x2_request = ~status[16];
(* preserve *) reg [2:0] present_x2_sync = 3'b111;
always @(posedge clk_video_pll) begin
    if (!clk_video_locked)
        present_x2_sync <= 3'b111;
    else
        present_x2_sync <= {present_x2_sync[1:0], present_x2_request};
end
wire present_x2_video_request = present_x2_sync[2];
wire present_x2_video_active;

mcr68_video_scanout #(
	.VIDEO_CLK_HZ  (100_000_000),
	.VIDEO_DOT_HZ  (10_000_000),
	.H_TOTAL       (634),
	.V_TOTAL       (512),
	.H_ACTIVE      (512),
	.V_ACTIVE      (480)
) u_video_scanout (
	.game_clk      (clk_sys),
	.video_clk     (clk_video_pll),
	.rst           (core_reset),
	.DDRAM_CLK     (DDRAM_CLK),
	.DDRAM_BUSY    (DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR    (DDRAM_ADDR),
	.DDRAM_DOUT    (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD      (DDRAM_RD),
	.DDRAM_DIN     (DDRAM_DIN),
	.DDRAM_BE      (DDRAM_BE),
	.DDRAM_WE      (DDRAM_WE),
	.game_enable   (!core_reset),
    .game_ce       (core_video_ce_dot),
    .game_y        (core_video_y),
    .game_hblank   (core_video_hblank),
    .game_vblank   (core_video_vblank),
    .game_index    (core_video_index),
    .game_rgb      ({core_video_r[7:5], core_video_g[7:5], core_video_b[7:5]}),
    .present_x2    (present_x2_video_request),
    .direct_video  (hps_direct_video),
    .present_x2_active(present_x2_video_active),
	// Only consumer was the removed CRT Adjust read-rate accumulator.
	.pixel_x2_active(),
    .out_ce        (scan_ce),
    .out_hblank    (scan_hblank),
    .out_vblank    (scan_vblank),
    .out_hsync     (scan_hsync),
    .out_vsync     (scan_vsync),
    .out_r         (scan_r),
    .out_g         (scan_g),
    .out_b         (scan_b)
);

// Feed the native game raster to arcade_video. This internal bus stays 9 bits
// because three bits per channel is the board's true palette depth (xRBG_333)
// and carrying it narrow is lossless. It is expanded to the full 8 bits per
// channel at the arcade_video boundary -- see the av_r8/av_g8/av_b8 block --
// so video_mixer's lossy HALF_DEPTH path is not used.
wire        av_ce_pix = scan_ce;
wire        av_hblank = scan_hblank;
wire        av_vblank = scan_vblank;
wire        av_hsync  = scan_hsync;
wire        av_vsync  = scan_vsync;
wire [8:0]  av_rgb    = {scan_r[7:5], scan_g[7:5], scan_b[7:5]};

// Keep the scanout-to-framework presentation boundary explicit. Without this
// stage, h_count can feed the line-word mux and palette lookup in the same
// 100 MHz cycle that arcade_video captures RGB_fix. Preserve every member of
// the bundle so Quartus cannot merge the boundary back into RGB_fix; CE,
// blanking, sync and RGB advance together by one video clock.
(* preserve *) logic       av_ce_pix_r, av_hblank_r, av_vblank_r;
(* preserve *) logic       av_hsync_r, av_vsync_r;
(* preserve *) logic [8:0] av_rgb_r;
always_ff @(posedge clk_video_pll) begin
    if (!clk_video_locked) begin
        av_ce_pix_r <= 1'b0;
        av_hblank_r <= 1'b1;
        av_vblank_r <= 1'b1;
        av_hsync_r  <= 1'b0;
        av_vsync_r  <= 1'b0;
        av_rgb_r    <= 9'd0;
    end else begin
        av_ce_pix_r <= av_ce_pix;
        av_hblank_r <= av_hblank;
        av_vblank_r <= av_vblank;
        av_hsync_r  <= av_hsync;
        av_vsync_r  <= av_vsync;
        av_rgb_r    <= av_rgb;
    end
end

//============================================================================
// CRT Adjust REMOVED 2026-09-12.
//
// A core-side `crt_adjust` geometry stage used to sit here between the
// registered presentation boundary (av_*_r) and arcade_video. It was removed
// rather than repaired: the module is structurally wrong for this core's
// raster. Its ping-pong line buffer is AW=10 -> 512 samples per bank (upstream
// default HTOTAL=384), but it was fed the OUTPUT pixel CE, which is 634
// samples/line on Direct Video and 1268 on the scaler path, so every line's
// tail overwrote its own head and the hb0/hb1 blanking marks were wrong. Its
// read-period base (crt_base_quarters) also ignored the Video Rate option, so
// Native 15 kHz compressed the image into the left half. Audit 2026-09-11
// findings V-01/V-02.
//
// Nothing downstream of av_*_r changed: arcade_video is now driven directly
// from the registered boundary, which is exactly what the CRT-Adjust-Off path
// already did.
//============================================================================

// -----------------------------------------------------------------------------
// 3-bit -> 8-bit channel expansion, done HERE instead of inside arcade_video.
//
// MEASURED 2026-08-31 from a MiSTer native capture: the core was emitting the
// channel levels
//     0, 34, 68, 102, 153, 187, 221, 255
// where this board's resistor ladder (Arch Rivals manual 16-4001-K-101 sheet
// 19: 2K/1K/510R into emitter followers, linear binary weights) and MAME's
// pal3bit both give
//     0, 36, 73, 109, 146, 182, 219, 255
// The 4th step was 51 instead of 34 and every midtone was wrong.
//
// Cause is the framework path, not the renderer. sys/arcade_video.v's DW==9
// branch builds the CORRECT 8-bit value R = {v,v,v[2:1]}, then passes only
// R[7:4] -- which is {v, v[2]} -- to video_mixer, whose `GAMMA && HALF_DEPTH`
// branch expands 4 bits back to 8 as {R,R}, i.e. x17. The result is
// 17 * {v,v[2]} = 0,34,68,102,153,187,221,255. Two bits per channel are
// discarded on the way through.
//
// sys/ stays vendored and unmodified (same rule as the scandoubler removal
// above). Instead the core expands to 8 bits itself and instantiates
// arcade_video with DW=24, which sets video_mixer's HALF_DEPTH to 0 and keeps
// all eight bits. No resource cost: HALF_DEPTH_SD is already 0 because
// GAMMA=1, so the (pruned) scandoubler line store was 8-bit wide either way.
wire [7:0] av_r8 = {av_rgb_r[8:6], av_rgb_r[8:6], av_rgb_r[8:7]};
wire [7:0] av_g8 = {av_rgb_r[5:3], av_rgb_r[5:3], av_rgb_r[5:4]};
wire [7:0] av_b8 = {av_rgb_r[2:0], av_rgb_r[2:0], av_rgb_r[2:1]};
// HDMI_BLACKOUT is an ENABLE for ascal's resolution-change black frames, not a
// continuous blank (sys/ascal.vhd `swblack`): it does nothing while the input
// resolution is stable. Kept enabled so a Video Rate / Direct Video change is
// covered; with CRT Adjust removed no other stage alters the input geometry at
// runtime.
assign hdmi_blackout_en = 1'b1;

assign video_field_out = 1'b0;

// The scanout owns the progressive/native presentation cadence and
// status[12:10] remains unused.

wire [7:0] av_vga_r, av_vga_g, av_vga_b;
wire av_vga_hs, av_vga_vs, av_vga_de, av_ce_out;
wire av_de_osd = av_vga_de;

// WIDTH is 1024 for the scaler path: the scanout publishes each source pixel
// twice so ascal's horizontal scale ratio lands on exactly 1.0 and its
// always-on horizontal polyphase filter degenerates to a unity tap. Direct
// Video deliberately retains the native 512-pixel cadence, because sys_top
// transmits every CLK_VIDEO sample on that path.
arcade_video #(.WIDTH(1024), .DW(24)) arcade_video
(
    .clk_video(clk_video_pll),
    .ce_pix   (av_ce_pix_r),

    .RGB_in({av_r8, av_g8, av_b8}),
    .HBlank(av_hblank_r),
    .VBlank(av_vblank_r),
    .HSync (av_hsync_r),
    .VSync (av_vsync_r),

    .CLK_VIDEO(),  // top-level CLK_VIDEO is the same clk_video_pll domain
    .CE_PIXEL (av_ce_out),
    .VGA_R(av_vga_r), .VGA_G(av_vga_g), .VGA_B(av_vga_b),
    .VGA_HS(av_vga_hs), .VGA_VS(av_vga_vs), .VGA_DE(av_vga_de), .VGA_SL(VGA_SL),

    // SCANDOUBLER REMOVED. Both inputs are hard constants so
    // arcade_video's `wire scandoubler = fx || forced_scandoubler` folds to 0
    // and Quartus prunes the whole scandoubler/Hq2x path. This is done here,
    // in the CORE, rather than by editing sys/video_mixer.sv -- the framework
    // is not modified.
    //
    // WHY: every failing setup path in the fitted design was inside
    // video_mixer|scandoubler|Hq2x|Blend (df_rule[0]/f[20] -> i30[*]) on the
    // 100 MHz clk_video_pll domain -- worst-case setup slack -0.891 ns, total
    // negative slack -23.932 ns. No path in this core's own RTL was failing.
    // Removing the scandoubler is a deliberate FEATURE REMOVAL requested by
    // the maintainer, not a timing workaround chosen by the build: the
    // alternative was retuning clk_video_pll (100 MHz is far above the ~40 MHz
    // arcade_video requires for a 9.984 MHz pixel clock).
    // Consequence: no scanline/HQ2x effects on the analog VGA path, and the
    // "Scandoubler Fx" OSD entry has been removed with it.
    .fx(3'd0),
    .forced_scandoubler(1'b0),
    .gamma_bus(gamma_bus)
);

// Original = native 512x480 pixel-exact; Full Screen/[ARC1]/[ARC2] per the
// standard MiSTer aspect-ratio option convention (matches NARC/Y Board).
wire [1:0] ar = status[9:8];

// Scale option ordering, and WHY "HV Integer" is index 0 (the power-on/
// fresh-CFG default) rather than "Normal".
//
// This board is a 512x480 raster on a 4:3 monitor, i.e. a 1.25 pixel aspect.
// On a 1920x1080 output that forces a NON-INTEGER horizontal scale and there
// is no arrangement of the core's own raster that avoids it:
//
//   vertical   1080 / 480 = 2.25 -> integer 2x  -> 960 lines (clean)
//   horizontal 4:3 of 960        = 1280         -> 1280 / 512 = 2.5x
//
// 2.5x means every game pixel is rendered 2 or 3 output pixels wide in an
// alternating 2,3,2,3 pattern. With a nearest-neighbour scaler filter that
// reads as uneven/"wobbly" pixels; with an interpolating filter it reads as
// soft. Either way it is the dominant sharpness artifact on this core, and
// it is NOT a rendering defect -- the core's own 512x480 output is
// pixel-identical to MAME (measured 2026-08-31: MiSTer native capture vs
// MAME 0.289 snap, same horizontal transition density, 25440 vs 25307).
// It is simply far more visible on the detail-dense titles (Arch Rivals /
// Pigskin / Blasted carry ~2.7x the horizontal transition count of
// Xenophobe's attract screen), which is why it was reported as a per-title
// problem when the video path has no per-title logic at all.
//
// The previous menu made "Normal" (fractional) the default and offered
// "Integer", which is video_freak's V-INTEGER mode -- vertical only. Because
// MiSTer.ini's own vscale_mode=1 already applies vertical integer scaling,
// selecting it changed nothing, which is exactly why "integer scaling" was
// (reasonably) ruled out as the cause. Only video_freak SCALE=4/3 make the
// HORIZONTAL factor integer.
//
//   idx 0  HV Integer   SCALE=4 -> 1024x960 on 1080p, exact 2x2, crisp.
//                                 Square pixels: ~20% narrower than 4:3.
//   idx 1  Normal       SCALE=0 -> 1280x960, true 4:3, 2.5x horizontal.
//   idx 2  V-Integer    SCALE=1 -> vertical integer only (old "Integer").
//   idx 3  HV Integer+  SCALE=3 -> 1536x960, exact 3x2, crisp.
//                                 ~20% wider than 4:3, fills more screen.
wire [2:0] scale_mode = (status[15:14] == 2'd0) ? 3'd4 :
                        (status[15:14] == 2'd1) ? 3'd0 :
                        (status[15:14] == 2'd2) ? 3'd1 : 3'd3;
wire [11:0] base_arx = (!ar) ? 12'd4 : {11'd0, ar - 1'd1};
wire [11:0] base_ary = (!ar) ? 12'd3 : 12'd0;

video_freak u_video_freak (
    .CLK_VIDEO(clk_video_pll), .CE_PIXEL(av_ce_out), .VGA_VS(av_vga_vs),
    .VGA_DE_IN(av_de_osd), .VGA_DE(VGA_DE),
    .ARX(base_arx), .ARY(base_ary), .SCALE(scale_mode),
    .CROP_SIZE(12'd0), .CROP_OFF(5'd0),
    .HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
    .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY)
);

assign CE_PIXEL = av_ce_out;
assign VGA_R = av_vga_r;
assign VGA_G = av_vga_g;
assign VGA_B = av_vga_b;
assign VGA_HS = av_vga_hs;
assign VGA_VS = av_vga_vs;

//============================================================================
// Audio output -- driven live by mcr68_main_board's dbg_audio_out (see
// instantiation above; signed [15:0], clk_sys domain, 48 kHz cadence per
// mcr68_main_board.sv's SAMPLE_HZ=48_000).
//
// Bundle each changed 48 kHz sample with a toggle. The sample is stable for
// about 20.8 us, so it safely spans the toggle synchronizer into CLK_AUDIO.
//============================================================================
reg signed [15:0] audio_source_hold = 16'sd0;
reg signed [15:0] audio_source_prev = 16'sd0;
reg audio_toggle = 1'b0;
always_ff @(posedge clk_sys) begin
    if (reset) begin
        audio_source_hold <= 16'sd0;
        audio_source_prev <= 16'sd0;
        audio_toggle      <= 1'b0;
    end else begin
        audio_source_prev <= core_audio_out;
        if (core_audio_out != audio_source_prev) begin
            audio_source_hold <= core_audio_out;
            audio_toggle      <= ~audio_toggle;
        end
    end
end

reg [2:0] audio_toggle_a = 3'b000;
reg signed [15:0] audio_cdc_out = 16'sd0;
reg [1:0] audio_reset_sr = 2'b11;
always_ff @(posedge CLK_AUDIO or posedge reset) begin
    if (reset) audio_reset_sr <= 2'b11;
    else       audio_reset_sr <= {audio_reset_sr[0], 1'b0};
end
wire audio_reset = audio_reset_sr[1];

always_ff @(posedge CLK_AUDIO) begin
    if (audio_reset) begin
        audio_toggle_a <= 3'b000;
        audio_cdc_out  <= 16'sd0;
    end else begin
        audio_toggle_a <= {audio_toggle_a[1:0], audio_toggle};
        if (audio_toggle_a[2] ^ audio_toggle_a[1])
            audio_cdc_out <= audio_source_hold;
    end
end

// Held silent while core_reset is asserted (ROM download / power-on /
// OSD reset), same convention NARC uses, so no download-time click/pop
// reaches the DAC. Mono DAC source -> both channels identical.
wire [15:0] audio_out_muted = core_reset ? 16'h0000 : audio_cdc_out;
assign AUDIO_L = audio_out_muted;
assign AUDIO_R = audio_out_muted;

endmodule
