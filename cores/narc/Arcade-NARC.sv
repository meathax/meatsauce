//============================================================================
//  NARC (Williams Z-unit) for MiSTer -- emu top-level wrapper.
//
//  Assembles the parameterized Williams core with the MiSTer framework:
//  PLL, hps_io, ROM loader (ioctl -> SDRAM/GFX), the SDRAM controller (program
//  ROM), NARC dual-6809 sound board, and arcade_video.
//
//  Framework structure adapted from the Sega System 32 core.
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
    output  [1:0] VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,

    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,
    output        HDMI_BOB_DEINT,

    output        LED_USER,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,
    output  [1:0] BUTTONS,

    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

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

    input         CLK_AUDIO,
    inout   [3:0] ADC_BUS,

    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

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

wire reset;
wire rom_loaded, sound_rom_loaded;
wire signed [15:0] snd_audio_l, snd_audio_r;
// Do not let the sound CPUs execute against an empty or partially downloaded
// external ROM image. Release the board only after the indexed ROM stream has
// completed; this also makes the first ROM-cache fill deterministic.
wire sound_board_reset = reset || !sound_rom_loaded;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;
// Keep the MiSTer audio pins quiet while the game/sound board is reset, then
// pass the centered signed Williams mixer output immediately on release.
wire [15:0] snd_audio_l_out = sound_board_reset ? 16'h0000 : snd_audio_l;
wire [15:0] snd_audio_r_out = sound_board_reset ? 16'h0000 : snd_audio_r;
narc_audio_cdc snd_audio_cdc (
    .clk_sys(clk_sys), .clk_audio(CLK_AUDIO), .reset(sound_board_reset),
    .audio_l_in(snd_audio_l_out), .audio_r_in(snd_audio_r_out),
    .audio_l_out(AUDIO_L), .audio_r_out(AUDIO_R)
);
assign LED_USER = ioctl_download;
assign LED_POWER = 0;
assign LED_DISK = 0;
assign BUTTONS = 0;
assign DDRAM_CLK = clk_ram;
assign DDRAM_BURSTCNT = 0; assign DDRAM_ADDR = 0; assign DDRAM_RD = 0;
assign DDRAM_DIN = 0; assign DDRAM_BE = 0; assign DDRAM_WE = 0;
assign USER_OUT = '1;
assign UART_RTS = 0; assign UART_TXD = 0; assign UART_DTR = 0;
assign SD_SCK = 0; assign SD_MOSI = 0; assign SD_CS = 1;

// Pixel scaling, OSD-selectable. Applies to Aspect = Original only; Full Screen
// and the [ARC1]/[ARC2] entries are passed through untouched.
//
//   Integer 1:1 (default) -- report the core's NATIVE 512x400 as the display
//     aspect, so the display aspect equals the pixel-grid aspect and an integer
//     vertical scale forces an integer horizontal one: 400*2=800 -> 512*2=1024.
//     Every source pixel becomes exactly NxN output pixels; fonts are exact.
//     Geometry is ~4% narrower than the real tube (1.28 vs 1.333).
//
//   Normal 4:3 -- the geometrically authentic cabinet aspect. The real NARC
//     cabinet was a 4:3 CRT showing 512x400, so its pixels were genuinely NOT
//     square (PAR ~1.042) and 4:3 is what the hardware actually looked like.
//
// Why the option exists at all: with MiSTer.ini vscale_mode=1 (integer scale
// only) the vertical lands on a clean 400 -> 800 (2.000x), but honouring 4:3
// then forces the width to 1066, i.e. 512 -> 1066 = 2.082x. Not an integer, so
// most source columns become 2 output pixels and roughly every twelfth becomes
// 3. A one-pixel vertical stroke is then sometimes 2 wide and sometimes 3,
// which is why glyphs of the same font rendered inconsistently across a line
// and small text looked squashed. Measured from hardware captures: 1066x800.
//
// Authentic geometry and pixel-exact text are mutually exclusive here. The
// default favours legibility because that was the reported fault; switch to
// Normal 4:3 for the true tube shape at the cost of uneven pixel columns.
wire [1:0] ar = status[2:1];
wire       px_int = ~status[8];        // 0 = Integer 1:1 (default), 1 = Normal 4:3
assign VIDEO_ARX = (!ar) ? (px_int ? 13'd512 : 13'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (px_int ? 13'd400 : 13'd3) : 13'd0;

// Stamps the OSD version line with the date the RBF was produced. Without this
// include the `ifndef fallback always won and every build reported the same
// string, so an SD card gave no way to tell which bitstream was on it.
`include "build_id.v"
`ifndef BUILD_DATE
`define BUILD_DATE "NARC"
`endif

// Service Switch is the coin-door AUTO-UP/MANUAL-DOWN slide switch (game switch
// 21). NARC's operator menu is only reachable with it in MANUAL-DOWN and the
// Advance button pressed, so both have to be exposed or the whole bookkeeping /
// adjustment / diagnostic tree -- including the CMOS settings this core
// persists -- is unreachable. See reference/narc-main/NARC/NARC.ASM SWTAB.
localparam CONF_STR = {
    "NARC;;",
    "-;",
    "O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    // Only affects Aspect = Original. Integer reports the native 512x400 so both
    // axes scale by a whole number (pixel-exact text); Normal reports the
    // authentic 4:3 cabinet aspect, which forces a 2.082x horizontal scale and
    // makes one-pixel strokes alternate 2/3 output pixels wide.
    "O[8],Pixel Scaling,Integer 1:1,Normal 4:3;",
    // CRT Adjust (rmonic79/MiSTer-CRT-Adjust, rtl/video/crt_adjust.sv). All three
    // controls run through one always-on line buffer and every part of the engine
    // restarts on the same line reference, so the picture moves and resizes while
    // the CRT keeps its lock. This REPLACES an earlier sync-window shift here --
    // that approach is exactly what makes a real CRT drop sync when pushed far.
    // H1 hides the amounts until CRT Adjust is On; H must come before P.
    "O[17],CRT Adjust,Off,On;",
    // Sound-board diagnostic overlay, top-left quadrant with game passthrough.
    // Off = video passes through untouched. Compiled in permanently so one
    // bitstream serves both play and diagnosis.
    // O[9] was "Diag Overlay"; the overlay was removed once the explosion fault
    // it was built to chase was fixed. The bit is left UNUSED rather than
    // reassigned, so any saved narc.CFG with bit 9 set cannot silently turn on
    // some unrelated option.
    "H1O[22:18],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H1O[29:23],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H1O[34:30],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "O[5:3],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "O[6],Pause,Off,On;",
    "O[7],Service Switch,Auto Up,Manual Down;",
    "-;",
    "R[0],Reset;",
    "J1,Fire,Jump,Rocket Bomb,Crouch,Start,Coin,Advance,Hi Score Reset;",
    "V,v",`BUILD_DATE
};

////////////////////////   CLOCKS   ////////////////////////
wire clk_sys, clk_ram, pll_locked;
pll pll (
    .refclk_clk(CLK_50M),
    .reset_reset(1'b0),
    .outclk0_clk(clk_ram),    // 96.648 MHz  (SDRAM engine)
    .outclk1_clk(clk_sys),    // 24.162 MHz  (game core)
    .outclk2_clk(SDRAM_CLK),  // 96.648 MHz, 180 deg: centred SDRAM interface (s32 method)
    .locked_export(pll_locked)
);
// CLK_VIDEO / CE_PIXEL are driven by arcade_video below.

// Split reset like the proven Sega System 32 core: the video timing generator
// keeps running (emitting valid sync + a coloured boot screen) during ROM load,
// while the CPU / game logic is held in reset until the ROM is loaded. This keeps
// the HDMI signal alive during boot and makes the pixel path self-verifying.
wire video_reset, core_pause;
wire nvram_request, nvram_bus_grant, core_pause_ack;
narc_run_control run_control (
    .reset_ext(RESET), .reset_menu(status[0]), .reset_button(buttons[1]),
    .pll_locked(pll_locked), .ioctl_download(ioctl_download),
    .rom_loaded(rom_loaded), .nvram_active(nvram_request),
    .pause_menu(status[6]), .video_reset(video_reset),
    .game_reset(reset), .core_pause(core_pause)
);

// The Z-unit pixel stream is 16 MHz. Keeping the proven 24.162 MHz system clock
// preserves TMS34010 timing closure; a 2-of-3 enable produces 16.108 MHz.
reg [1:0] pdiv = 0; reg ce_pix = 0;
always @(posedge clk_sys) begin
    ce_pix <= (pdiv != 2'd2);
    if (pdiv == 2'd2) pdiv <= 0;
    else pdiv <= pdiv + 1'd1;
end

////////////////////////   HPS IO   ////////////////////////
wire  [1:0] buttons;
wire [63:0] status;
wire        ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout, ioctl_din;
wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;

hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .buttons(buttons),
    .status(status),
    // H1 in CONF_STR hides an option while menumask[1] is SET, so bit 1 is the
    // INVERSE of CRT Adjust: the three amounts appear only once it is On.
    // Without this the H1 entries would stay hidden permanently.
    .status_menumask({14'd0, ~status[17], 1'b0}),
    .forced_scandoubler(forced_scandoubler),
    .gamma_bus(gamma_bus),
    .ioctl_download(ioctl_download),
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(nvram_modified),
    .ioctl_upload_index(8'd3),
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
    .joystick_3(joystick_3)
);

////////////////////////   ROM LOAD   ////////////////////////
// Program, graphics, sound ROMs, and the persisted CMOS image stream to SDRAM.
wire        sw_req, sw_ack; wire [24:1] sw_addr; wire [15:0] sw_din; wire [1:0] sw_be;
wire        loader_wait, nvram_wait;

narc_rom_loader loader (
    .clk(clk_sys), .rst(~pll_locked),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index[7:0]),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(loader_wait),
    .sdr_wr_req(sw_req), .sdr_wr_addr(sw_addr), .sdr_wr_din(sw_din),
    .sdr_wr_be(sw_be), .sdr_wr_ack(sw_ack),
    .rom_loaded(rom_loaded), .sound_rom_loaded(sound_rom_loaded)
);

////////////////////////   SDRAM (one stick: all ROMs/main/CMOS)   ////////////
// FROZEN Wave-0 contract: single SDRAM module for program/GFX/main/CMOS/sound.
// Priority wr > snd > main > prog > gfx. VRAM = BRAM; sound work RAM = M10K.
// No DDRAM/second-stick path. Gate: sim/sdram_check/tb_sdram.
// clk_sys and clk_ram are 1:4 from the same PLL (phase-aligned), so the core's
// req/ack cross to the SDRAM clock by direct connection (as the prog channel
// already does) -- a clk_sys level is stable across two clk_ram edges.
wire        prog_req, prog_ack; wire [24:1] prog_addr_w; wire [47:0] prog_dout;
wire        gfx_req, gfx_ack;   wire [24:1] gfx_addr_w;  wire [95:0] gfx_dout;
wire        main_req, main_we, main_ack; wire [24:1] main_addr_w;
wire        core_main_req, core_main_we, core_main_ack; wire [24:1] core_main_addr;
wire [15:0] core_main_din; wire [1:0] core_main_be; wire [47:0] core_main_dout;
wire        nv_main_req, nv_main_ack; wire [24:1] nv_main_addr; wire [47:0] nv_main_dout;
wire [15:0] main_din_w; wire [1:0] main_be_w; wire [47:0] main_dout;
wire        snd_rom_req, snd_rom_ack; wire [24:1] snd_rom_addr; wire [15:0] snd_rom_dout;

// COLBITS=9 -- the 512/1024-column split the working core has always used.
//
// COLBITS=11 (2048-column, 64M x16) was tried on 2026-07-30 and produced a
// BLACK SCREEN on hardware, which is this design's signature for the core
// deadlocking on SDRAM data (see the ACK_HOLD note in rtl/mem/sdram.sv).
//
// Why it was wrong, and why simulation did not catch it: the COLBITS=11 gate
// (sim/sdram_check/tb_sdram_col11.sv) uses a chip model written to match the
// SAME assumption as the RTL -- that the fitted die has 2048 columns. That is
// circular. It proves the controller is self-consistent, not that the part
// agrees. If the die actually has 10 column bits, A[11] is a don't-care during
// a column command, so a[11] is DROPPED from the column while still being
// counted in the row: addresses differing only in a[11] alias onto each other
// and reads come back corrupt.
//
// Do not re-enable COLBITS=11 without the actual part number and its column
// count from the module's datasheet or markings. A behavioural model cannot
// answer this question.
sdram #(.COLBITS(9)) sdram (
    .clk(clk_ram), .init(~pll_locked), .ready(),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    // SDRAM_CLK is no longer a controller output -- it's driven directly by the
    // PLL's 180 deg phase tap above (s32 method: a clean generated clock the
    // SDC can reference, vs. the altddio_out DDR forwarding this replaces).
    .wr_req(sw_req), .wr_addr(sw_addr), .wr_din(sw_din), .wr_be(sw_be), .wr_ack(sw_ack),
    .prog_req(prog_req), .prog_addr(prog_addr_w), .prog_dout(prog_dout), .prog_ack(prog_ack),
    .gfx_req(gfx_req), .gfx_addr(gfx_addr_w), .gfx_dout(gfx_dout), .gfx_ack(gfx_ack),
    .main_req(main_req), .main_we(main_we), .main_addr(main_addr_w), .main_din(main_din_w),
    .main_be(main_be_w), .main_dout(main_dout), .main_ack(main_ack),
    .snd_req(snd_rom_req), .snd_addr(snd_rom_addr), .snd_dout(snd_rom_dout), .snd_ack(snd_rom_ack)
);

// core program-ROM burst port (18-bit word addr) -> SDRAM word address
wire        core_prog_req; wire [17:0] core_prog_addr;
assign prog_req    = core_prog_req;
assign prog_addr_w = {6'd0, core_prog_addr};   // program image at SDRAM word 0
// core GFX read port (already a full SDRAM word address from the core adapter)
wire        core_gfx_req; wire [24:1] core_gfx_addr;
assign gfx_req    = core_gfx_req;
assign gfx_addr_w = core_gfx_addr;

// A save request pauses the CPU at an instruction boundary, then the upload
// side owns the main SDRAM client. Reads return the persisted 16Kx16 CMOS image
// as a little-endian byte stream without resetting any game state.
wire nvram_active;
wire nvram_modified;
assign nvram_request = ioctl_upload && (ioctl_index == 16'd3);
assign ioctl_wait = loader_wait | nvram_wait |
                    (nvram_request && !nvram_bus_grant);

narc_nvram_arbiter nvram_arbiter (
    .clk(clk_sys), .rst(video_reset), .save_request(nvram_request),
    .core_quiescent(core_pause_ack), .nvram_grant(nvram_bus_grant)
);

assign main_req    = nvram_bus_grant ? nv_main_req  : core_main_req;
assign main_we     = nvram_bus_grant ? 1'b0         : core_main_we;
assign main_addr_w = nvram_bus_grant ? nv_main_addr : core_main_addr;
assign main_din_w  = nvram_bus_grant ? 16'h0000     : core_main_din;
assign main_be_w   = nvram_bus_grant ? 2'b11        : core_main_be;
assign core_main_dout = main_dout;
assign core_main_ack  = main_ack && !nvram_bus_grant;
assign nv_main_dout   = main_dout;
assign nv_main_ack    = main_ack && nvram_bus_grant;

narc_nvram_if nvram_if (
    .clk(clk_sys), .rst(video_reset),
    .ioctl_upload(ioctl_upload && nvram_bus_grant), .ioctl_index(ioctl_index),
    .ioctl_rd(ioctl_rd), .ioctl_addr(ioctl_addr),
    .ioctl_din(ioctl_din), .ioctl_wait(nvram_wait), .active(nvram_active),
    .main_req(nv_main_req), .main_we(), .main_addr(nv_main_addr),
    .main_din(), .main_be(), .main_dout(nv_main_dout), .main_ack(nv_main_ack)
);

// Hold the dirty request high through the complete upload. Clearing it when
// upload begins creates a second request edge after the game resumes and can
// trap MiSTer in a repeated "Saving"/CPU-pause loop.
// The upper bound is the END of the CMOS region: narc_rom_loader places it at
// CMOS_WORD_BASE 0x810000 and fills 0x4000 words (cmos_wcnt is [13:0]), so the
// region is 0x810000..0x813fff. This previously read 0x454000 -- a value BELOW
// the base, inside the GFX map -- which made the whole compare unsatisfiable,
// so no CMOS write was ever detected, nvram_modified never rose, and high
// scores/audits were never written back to disk.
wire core_cmos_write = core_main_req && core_main_we &&
                       core_main_addr >= 24'h810000 &&
                       core_main_addr <  24'h814000;
narc_nvram_dirty nvram_dirty (
    .clk(clk_sys), .rst(video_reset),
    .core_cmos_write(core_cmos_write),
    .restore_active(ioctl_download && (ioctl_index == 16'd3)),
    .upload_active(nvram_request), .osd_status(OSD_STATUS),
    .modified(nvram_modified)
);

////////////////////////   INPUTS   ////////////////////////
// NARC input words from MAME's Z-unit map. Cabinet controls are active-low;
// sound-board SYNC and talkback are active-high custom inputs.
wire [15:0] in0, in1, in2;
wire [7:0] snd_talkback;
wire [1:0] snd_audio_sync;
narc_inputs input_mapper (
    .joystick_0(joystick_0), .joystick_1(joystick_1),
    .joystick_2(joystick_2), .sound_sync(snd_audio_sync),
    .sound_talkback(snd_talkback), .service_manual(status[7]),
    .in0(in0), .in1(in1), .in2(in2)
);
wire [15:0] in_dsw = 16'hffff;

////////////////////////   GAME CORE   ////////////////////////
// One-stick DE10-Nano contract: every large ROM/RAM image lives in the single
// SDRAM module. INTERNAL BRAM arrays (prog/gfx/main/CMOS/sound ROM) must stay
// disabled here or the M10K budget (553) is blown before VRAM fits.
localparam bit NARC_EXT_PROG = 1'b1;
localparam bit NARC_EXT_GFX  = 1'b1;
localparam bit NARC_EXT_MAIN = 1'b1;
localparam bit NARC_EXT_CMOS = 1'b1;
localparam bit NARC_EXT_SND  = 1'b1;
generate
  if (!(NARC_EXT_PROG && NARC_EXT_GFX && NARC_EXT_MAIN && NARC_EXT_CMOS && NARC_EXT_SND))
    nonexistent_module_force_external_sdram_for_one_stick_fit u_fit_guard();
endgenerate

wire [7:0] r8, g8, b8; wire hs, vs, hbl, vbl, core_ce;

smashtv_core #(.EXTERNAL_PROG(NARC_EXT_PROG), .EXTERNAL_GFX(NARC_EXT_GFX),
               .EXTERNAL_MAIN(NARC_EXT_MAIN), .EXTERNAL_CMOS(NARC_EXT_CMOS),
               .ZUNIT_8BPP(1'b1),
               // INTERNAL gfxrom is generate-gated off; keep the array tiny so a
               // future EXTERNAL_GFX=0 mistake cannot elaborate a 256KB M10K hit.
               .GFX_WORDS(1),
               // Calibrated against MAME 0.288's 6 MHz-effective Z-unit:
               // INPUT_READY 884f vs 891f and INPLAY 1536f vs 1514f.
               .CPU_PACE_CLKS(4)) core (
    .clk(clk_sys), .rst(reset), .video_rst(video_reset), .ce_pix(ce_pix),
    .pause(core_pause && !nvram_request), // visual/menu pause
    .pause_immediate(core_pause && nvram_request), // transaction-safe save pause
    .game_id(8'd0), .cfg_4bpp(1'b0), .cfg_has_prot(1'b0),
    .in0(in0), .in1(in1), .in2(in2), .in_dsw(in_dsw), .in_unk0(16'hffff), .in_unk1(16'hffff),
    .ld_en(1'b0), .ld_region(2'd0), .ld_addr(24'd0), .ld_data(16'd0),   // ROMs load via SDRAM
    .prog_ext_req(core_prog_req), .prog_ext_addr(core_prog_addr),
    .prog_ext_w0(prog_dout[15:0]), .prog_ext_w1(prog_dout[31:16]),
    .prog_ext_w2(prog_dout[47:32]), .prog_ext_valid(prog_ack),
    .gfx_ext_req(core_gfx_req), .gfx_ext_addr(core_gfx_addr),
    .gfx_ext_dout(gfx_dout), .gfx_ext_ack(gfx_ack),
    .main_ext_req(core_main_req), .main_ext_we(core_main_we), .main_ext_addr(core_main_addr),
    .main_ext_din(core_main_din), .main_ext_be(core_main_be),
    .main_ext_dout(core_main_dout), .main_ext_ack(core_main_ack),
    .vga_r(r8), .vga_g(g8), .vga_b(b8),
    .vga_hs(hs), .vga_vs(vs), .vga_hb(hbl), .vga_vb(vbl), .vga_ce(core_ce),
    .snd_cmd(snd_cmd_w), .snd_cmd_stb(snd_cmd_stb_w), .dbg_pc(dbg_pc),
    .pause_ack(core_pause_ack)
);

////////////////////////   SOUND BOARD (NARC dual 6809E)   ////////////////////////
// The main TMS34010 writes the native 11-bit NARC command. Both sound ROM
// regions live in SDRAM at word base 0xC00000 behind the board's cache/arbiter;
// the slave image begins at +0x048000 words.
// Master work RAM uses eight M10Ks in two placeable banks; slave work RAM stays
// in MLAB. ROMs must remain EXTERNAL (NARC_EXT_SND) for M10K headroom.
wire [10:0] snd_cmd_w;  wire snd_cmd_stb_w;
wire snd_dbg_run, snd_dbg_stall;
wire [31:0] snd_dbg_rate, snd_dbg_state, snd_dbg_addr;
wire [7:0]  snd_dbg_act;
wire [3:0]  snd_dbg_ym;
// Replay the sound-region download bytes that land in each 6809's VECTOR PAGE
// ($FF00-$FFFF = image bytes 0x8ff00..0x8ffff) into the board's small
// bypass stores, so an interrupt vector fetch never evicts the handler it
// points at. Index-1 stream layout (narc_rom_loader): master image at
// 0x000000, slave image at 0x090000; both page bases are 256-byte aligned so
// ioctl_addr[7:0] is the offset directly. Same clk_sys domain as the loader —
// no CDC. Repeated strobes under ioctl_wait rewrite the same byte.
wire snd_uwin_stream = ioctl_download && ioctl_wr && (ioctl_index[7:0] == 8'd1);
wire snd_uwin_master = snd_uwin_stream &&
                       (ioctl_addr >= 27'h08c000) && (ioctl_addr < 27'h08e000);
wire snd_uwin_slave  = snd_uwin_stream &&
                       (ioctl_addr >= 27'h11c000) && (ioctl_addr < 27'h11e000);
narc_sound #(.CLK_SYS_HZ(24_162_000),
             .EXTERNAL_SND_ROM(NARC_EXT_SND), .SND_WORD_BASE(24'hC00000),
             .SND_ROM_SWAP_BYTES(1'b0), .YM_STATUS_BUSY_ACTIVE_HIGH(1'b1)) sndbrd (
    .clk(clk_sys), .rst(sound_board_reset),
    .cmd(snd_cmd_w), .cmd_stb(snd_cmd_stb_w), .snd_rst(reset),
    .talkback(snd_talkback), .audio_sync(snd_audio_sync),
    .audio_l(snd_audio_l), .audio_r(snd_audio_r),
    .snd_rom_req(snd_rom_req), .snd_rom_addr(snd_rom_addr),
    .snd_rom_dout(snd_rom_dout), .snd_rom_ack(snd_rom_ack),
    .uwin_wr(snd_uwin_master || snd_uwin_slave), .uwin_sel(snd_uwin_slave),
    .uwin_addr(ioctl_addr[12:0]), .uwin_data(ioctl_dout),
    .dbg_master_run(snd_dbg_run), .dbg_slave_run(), .dbg_stall(snd_dbg_stall),
    // Sound diagnostic taps -> narc_diag_overlay (see below). Pure outputs;
    // with DIAG_OVERLAY undefined nothing consumes them and synthesis removes
    // the counters entirely.
    .dbg_snd_rate(snd_dbg_rate), .dbg_snd_state(snd_dbg_state),
    .dbg_snd_addr(snd_dbg_addr), .dbg_snd_act(snd_dbg_act),
    .dbg_ym_flags(snd_dbg_ym)
);
// command-activity toggle: flips on every sound write the core issues
reg snd_dbg_cmdtgl;
always @(posedge clk_sys) begin
    if (reset) snd_dbg_cmdtgl <= 1'b0;
    else if (snd_cmd_stb_w) snd_dbg_cmdtgl <= ~snd_dbg_cmdtgl;
end
wire [31:0] dbg_pc;

////////////////////////   VIDEO OUT   ////////////////////////
// Boot indicator (like the Sega System 32 core): while the game core is held in
// reset the timing generator still runs, so fill the visible area with a solid
// colour. This proves the pixel path works independent of the CPU and shows how
// far boot got. blue = ROM downloading, red = waiting for ROM, else the game.
wire [23:0] rgb_boot = ioctl_download ? 24'h0000FF :
                       ~rom_loaded    ? 24'hFF0000 : 24'hFFFF00;
`ifdef SMASHTV_DEBUG_COLUMNS
// DIAGNOSTIC: ONE-PIXEL alternating vertical stripes, generated here in the top
// level from a counter clocked by ce_pix. It never touches VRAM, the palette or
// the port-B arbiter, so it isolates the output path from the frame-buffer path.
//
// It exists because the deployed core scans out every pixel column DOUBLED
// (native capture: 100.0% even-aligned column pairing over the whole frame),
// and that is NOT reproducible in simulation -- sim/vram_check/
// tb_z_column_doubling.sv measures 0.0% with the erase engine hammering.
//
// Stripe width, measured the same way as the hardware capture, discriminates:
//   1 px (pairing ~0%)   -> the output path preserves 512; the collapse is in
//                           the frame-buffer path, on silicon only.
//   2 px (pairing ~100%) -> the collapse is DOWNSTREAM of this mux, i.e. in
//                           sys/ or the HPS capture -> escalate, do not edit.
//
// Width is the right probe ONLY because the alternation is one pixel. An 8-px
// bar pattern cannot discriminate: dropping every other column and duplicating
// it preserves the apparent width of any feature wider than one pixel, so the
// pre-existing SMASHTV_DEBUG_PC bars below would look identical either way.
// FREE-RUNNING toggle on ce_pix -- deliberately NOT gated by hs or hbl.
//
// The first attempt reset this counter on `hs` and enabled it on `ce_pix &&
// !hbl`. That logic simulates correctly (sim/video_check/tb_debugcol_pattern.sv:
// 512 samples/line, 50/50 white/black, 0.0% adjacent-equal) yet produced a
// uniformly BLACK frame on hardware -- which is what a counter held permanently
// at zero looks like. Rather than keep theorising about why, this version
// depends on nothing but ce_pix, so neither a stuck hs nor a stuck hbl can pin
// it. If the screen is STILL black with this, the fault is downstream of this
// mux, not in the generator, and that is itself the answer.
//
// The per-line phase is free to walk (the line length in ce_pix ticks need not
// be even). That is fine: the measurement is stripe WIDTH within a row, which
// is unaffected by where a row starts.
reg dbgcol_stripe;
always @(posedge clk_sys) if (ce_pix) dbgcol_stripe <= ~dbgcol_stripe;
wire [23:0] rgb_out = reset ? rgb_boot
                            : (dbgcol_stripe ? 24'hFFFFFF : 24'h000000);
`elsif SMASHTV_DEBUG_PC
// DIAGNOSTIC: render the 34010 PC as 32 vertical bars (bit 31 leftmost), each 8
// pixels wide -- WHITE = 1, BLACK = 0. Pure full-on/off so it survives 12bpp +
// gamma; read the exact hung PC bit-for-bit from a screenshot. When the CPU is
// stuck the bar pattern is stable; when running the bars flicker.
reg [9:0] dbg_hcnt;
always @(posedge clk_sys) begin
    if (hs)                    dbg_hcnt <= 10'd0;
    else if (ce_pix && !hbl)   dbg_hcnt <= dbg_hcnt + 10'd1;
end
// Latch the PC once per frame (at vsync rising edge) so the bars are rock-stable
// and bit-exact readable (the live PC blurs its low bits at 24 MHz >> 8 MHz pixel).
// Sampling many frames shows whether the PC clusters (tight loop) or spreads (running).
reg vs_d;
reg [31:0] dbg_pc_lat;
always @(posedge clk_sys) begin
    vs_d <= vs;
    if (vs & ~vs_d) dbg_pc_lat <= dbg_pc;
end
wire [5:0] dbg_biti = dbg_hcnt[8:3];                       // bar index (0..); 8 px/bar
wire       dbg_bit  = (dbg_biti < 6'd32) ? dbg_pc_lat[31 - dbg_biti[4:0]] : 1'b0;
wire [23:0] rgb_dbg = dbg_bit ? 24'hFFFFFF : 24'h000000;
wire [23:0] rgb_out = reset ? rgb_boot : rgb_dbg;
`else
wire [23:0] rgb_out  = reset ? rgb_boot : {r8, g8, b8};
`endif

`ifdef SMASHTV_DEBUG_SND
// Sound diagnostic overlay: four 8x8 blocks at the top-left.
//   blk0 : soft-reset line   (RED = board held in reset, GREEN = running)
//   blk1 : command activity  (toggles WHITE/BLUE on every sound write)
//   blk2 : 6809 executing    (GREEN blinking ~0.5 Hz = alive; solid/dark = frozen)
//   blk3 : ROM wait-state    (RED = stalled right now; solid red = starved)
reg [9:0] sdbg_x; reg [3:0] sdbg_y; reg sdbg_hbl_d, sdbg_vs_d;
always @(posedge clk_sys) begin
    sdbg_hbl_d <= hbl; sdbg_vs_d <= vs;
    if (hbl && !sdbg_hbl_d) begin sdbg_x <= 0; if (sdbg_y != 4'hF) sdbg_y <= sdbg_y + 1'd1; end
    else if (ce_pix && !hbl) sdbg_x <= sdbg_x + 1'd1;
    if (vs && !sdbg_vs_d) sdbg_y <= 0;
end
wire sdbg_row = (sdbg_y < 4'd8);
wire [1:0] sdbg_blk = sdbg_x[4:3];
wire sdbg_area = sdbg_row && (sdbg_x < 10'd32);
reg [23:0] sdbg_rgb;
always @* begin
    case (sdbg_blk)
        2'd0: sdbg_rgb = reset         ? 24'hFF0000 : 24'h00FF00;
        2'd1: sdbg_rgb = snd_dbg_cmdtgl? 24'hFFFFFF : 24'h0000FF;
        2'd2: sdbg_rgb = snd_dbg_run   ? 24'h00FF00 : 24'h003000;
        default: sdbg_rgb = snd_dbg_stall ? 24'hFF0000 : 24'h301010;
    endcase
end
wire [23:0] rgb_out2 = sdbg_area ? sdbg_rgb : rgb_out;
`else
wire [23:0] rgb_out2 = rgb_out;
`endif

// HQ2x's four-pixel work buffer cost 26 M10Ks in the measured NARC fit.
// The core already supplies 512x400 to MiSTer's main scaler, so expose the
// useful simple/CRT modes and skip the internal fx=1 HQ2x encoding.
wire [2:0] fx_sel = status[5:3];
wire [2:0] fx = fx_sel ? (fx_sel + 3'd1) : 3'd0;
// Core generates a 2-of-3 synchronous pixel enable. CE_LEVEL prevents the
// generic video wrapper's clock-waveform heuristic from collapsing adjacent
// enabled pixels into one sample (which produced a stretched 256x400 stream).
// ---- optional on-screen sound diagnostic overlay --------------------------
// Enabled ONLY by building with -DDIAG_OVERLAY (see doc/DIAG_OVERLAY.md). With
// the macro undefined these wires collapse to the plain game video and the
// build is bit-identical to production, so this must never be committed with
// the macro set in Arcade-NARC.qsf.
//
// Purpose: chase the hardware fault where a big in-game explosion starts a loud
// tone that then plays over everything until reset. Simulation has not been
// able to trigger it (the scripted replay may never produce a large explosion),
// so this reads the sound board's state straight off the screen instead.
//
// The ACTIVITY grading is the point. A request line stuck asserted and one
// working normally look IDENTICAL as a level; graded by toggle they do not.
// REMOVED 2026-07-30 at the user's request. The overlay existed to chase the
// explosion fault from the screen because simulation could not reproduce it;
// that fault is now fixed (86c7c08) and confirmed on hardware, so the overlay
// has served its purpose and no longer earns its area or its OSD slot.
//
// rtl/diag/narc_diag_overlay.sv is KEPT in the tree. The sound diagnostic taps
// on narc_sound (dbg_snd_rate/state/addr/act) are also kept and simply left
// unconnected -- they are pure outputs, so synthesis prunes them and a build
// without the overlay is unaffected. Re-instantiating it is a paste job if a
// future fault needs reading off the screen again; see doc/DIAG_OVERLAY.md.
`ifdef NARC_SNDCMD_OVERLAY
// THROWAWAY DIAGNOSTIC -- never define this in Arcade-NARC.qsf.
//
// Reported against a real PCB 2026-07-31: stage 1 has no "brian driving music"
// (SOUND.YAM code 06 on MUSICHAN), money pickup has no "jing" (code 98), and
// dogs bark on the driving stage where the PCB has none. Every one of those
// sounds plays CORRECTLY, for its correct number, from the in-game sound
// diagnostic -- so the sound board, the YM, the CVSD and the sample banking are
// all fine, and sim/snd/tb_narc_music.sv agrees (the YM programs full voice
// registers and swings +-15968).
//
// That leaves the question of what the GAME asks for during gameplay, which no
// simulation here can answer: tb_narc_deep never reaches MAINLP (2 sound writes
// in 744 frames, then a pre-existing GFX assertion at tb_narc_deep.sv:106).
// The fault reproduces on the cab in seconds, so read it off the cab.
//
// Shows the last 8 sound-command BYTES, newest first, plus a write count.
// Release writes (0xFF00|code, both strobes high) are NOT recorded -- SNDSND
// issues one of those after every real command and they would otherwise fill
// the history with 0xFF.
//
// HOW TO READ IT, reaching stage 1:
//   06 appears        -> the game DOES ask for driving music; something between
//                        the port write and the board eats it.
//   06 never appears  -> the game never asks. Fault is in the game's own
//                        dispatch (SNDLD arbitration / the SNDPTR descriptor
//                        walk), not in the sound path.
//   wrong codes       -> e.g. 51 where the game means 11 (grunt -> dog bark).
//                        The bit pattern then names the corruption.
reg  [7:0]  sndhist [0:7];
reg  [15:0] sndhist_count;
reg         snd_music_seen, snd_code06_seen, snd_code07_seen, snd_code98_seen;
reg  [7:0]  snd_last_music;
integer     shi;
wire        snd_real_cmd  = snd_cmd_stb_w && snd_cmd_w[10] &&
                             (!snd_cmd_w[8] || !snd_cmd_w[9]);
// The active-low music strobe is represented by bits 9:8 == 00 after the
// TMS34010's 11-bit SOUND latch truncates FDxx to 11'h5xx. Keep a sticky record
// because the eight-entry history is quickly overwritten by gameplay effects.
wire        snd_music_cmd = snd_cmd_stb_w && snd_cmd_w[10] &&
                             (snd_cmd_w[9:8] == 2'b00);
always @(posedge clk_sys) begin
    if (reset) begin
        sndhist_count <= 16'd0;
        snd_music_seen <= 1'b0;
        snd_code06_seen <= 1'b0;
        snd_code07_seen <= 1'b0;
        snd_code98_seen <= 1'b0;
        snd_last_music <= 8'h00;
        for (shi = 0; shi < 8; shi = shi + 1) sndhist[shi] <= 8'h00;
    end else if (snd_real_cmd) begin
        for (shi = 7; shi > 0; shi = shi - 1) sndhist[shi] <= sndhist[shi-1];
        sndhist[0]    <= snd_cmd_w[7:0];
        sndhist_count <= sndhist_count + 16'd1;
    end
    if (!reset && snd_music_cmd) begin
        snd_music_seen <= 1'b1;
        snd_code06_seen <= snd_code06_seen || (snd_cmd_w[7:0] == 8'h06);
        snd_code07_seen <= snd_code07_seen || (snd_cmd_w[7:0] == 8'h07);
        snd_code98_seen <= snd_code98_seen || (snd_cmd_w[7:0] == 8'h98);
        snd_last_music <= snd_cmd_w[7:0];
    end
end

wire [7:0] dg_r, dg_g, dg_b;
wire       dg_hs, dg_vs, dg_hb, dg_vb;
narc_diag_overlay #(
    .DIAG_W(256), .DIAG_H(200), .SHRINK(1), .PIXW(4), .NROWS(4), .NLEDS(8)
) u_diag (
    .clk(clk_sys), .ce_pix(core_ce), .rst(video_reset),
    // Row 0 is the TOP row, so pack least-significant-first.
    .hex_rows({ {dbg_pc[31:16],
                 {snd_music_seen, snd_code06_seen, snd_code07_seen,
                  snd_code98_seen, snd_dbg_ym, snd_last_music}},      // row 3: music + YM/mix/IRQ flags + code
                {sndhist_count, 5'd0, snd_cmd_w},                  // row 2: count + last raw cmd
                {sndhist[7], sndhist[6], sndhist[5], sndhist[4]},  // row 1: older 4
                {sndhist[3], sndhist[2], sndhist[1], sndhist[0]} }),// row 0: newest 4
    .led_bits(snd_dbg_act),
    .led_is_activity(8'b0_111111_0),
    .status_bad(1'b0),
    .g_r(rgb_out2[23:16]), .g_g(rgb_out2[15:8]), .g_b(rgb_out2[7:0]),
    .g_hs(hs), .g_vs(vs), .g_hb(hbl), .g_vb(vbl),
    .vid_r(dg_r), .vid_g(dg_g), .vid_b(dg_b),
    .hsync(dg_hs), .vsync(dg_vs), .hblank(dg_hb), .vblank(dg_vb)
);
wire [7:0] ov_r  = dg_r;
wire [7:0] ov_g  = dg_g;
wire [7:0] ov_b  = dg_b;
wire       ov_hs = dg_hs;
wire       ov_vs = dg_vs;
wire       ov_hb = dg_hb;
wire       ov_vb = dg_vb;
`else
wire [7:0] ov_r  = rgb_out2[23:16];
wire [7:0] ov_g  = rgb_out2[15:8];
wire [7:0] ov_b  = rgb_out2[7:0];
wire       ov_hs = hs;
wire       ov_vs = vs;
wire       ov_hb = hbl;
wire       ov_vb = vbl;
`endif

// ---- CRT Adjust (rmonic79/MiSTer-CRT-Adjust, core-side variant) -----------
// rtl/video/crt_adjust.sv, vendored verbatim; licence at rtl/video/CRT_ADJUST_LICENSE.
// Core-side placement touches NO framework code, so it stays inside the
// MiSTer-devel rule against modifying sys/.
//
// It sits between the core's video output and arcade_video, so the adjusted
// stream also reaches the HDMI scaler. That is the documented trade for the
// core-side variant: treat this as an analog/CRT feature and leave CRT Adjust
// Off for an untouched HDMI image.
//
// READ RATE. The module reads one pixel every (base + hsize) sub-steps of
// clk_video, and the docs are explicit that base must be sized from the core's
// OWN ratio, never hardcoded. Their reference core is 96 MHz / 6 MHz = 16 whole
// cycles = 64 quarters. OURS IS DIFFERENT AND MUCH TIGHTER: clk_sys 24.162 MHz
// with a 16.108 MHz pixel is only 1.5 clk_sys per pixel. At their quarter
// granularity that is 6 sub-steps, and an hsize of -16 would go negative --
// unusable. So the granularity here is 1/32 of a clk_sys cycle instead:
//   base = 1.5 * 32 = 48 sub-steps, hsize -16..+15 -> period 32..63.
// One H-Size step is therefore ~1/48 = 2.1% (theirs is ~1.5%), and the full
// range is about 0.75x..1.5x. Verified only by construction -- see the caveat
// in the commit message; none of this has been simulated or fitted.
localparam int CRT_RD_BASE = 48;   // 1.5 clk_sys per pixel x 32 sub-steps

wire crt_on = status[17];

// H-Size: signed 5-bit, 0 = native.
wire signed [4:0] crt_hsize = $signed(status[22:18]);
// H-Position: 7-bit wrap-encoded. 0..48 = right, 79..127 = -49..-1 left.
wire  [6:0] crt_hpos_d = status[29:23];
wire signed [8:0] crt_hpos = (crt_hpos_d <= 7'd48)
    ? $signed({2'b0, crt_hpos_d})
    : $signed({2'b0, crt_hpos_d}) - 9'sd128;
// V-Shift: signed 5-bit, lines.
wire signed [5:0] crt_vshift = {{1{status[34]}}, $signed(status[34:30])};

// Read clock-enable. MUST reset on the rise of the module's hs_ref_out, never on
// the raw HSync -- that shared reference is what keeps the write side, the read
// counter and the read rate in phase, and resetting on raw HSync is precisely
// what desynced the older upstream scheme when shrinking.
wire crt_hs_ref;
reg  crt_hs_ref_d;
always @(posedge clk_sys) crt_hs_ref_d <= crt_hs_ref;
wire crt_hs_ref_rise = crt_hs_ref & ~crt_hs_ref_d;

wire [7:0] crt_rd_period = 8'(CRT_RD_BASE) + {{3{crt_hsize[4]}}, crt_hsize};
reg  [7:0] crt_rd_acc;
wire       crt_rd_tick = (crt_rd_acc + 8'd32) >= crt_rd_period;
always @(posedge clk_sys) begin
    if      (crt_hs_ref_rise) crt_rd_acc <= 8'd0;
    else if (crt_rd_tick)     crt_rd_acc <= crt_rd_acc + 8'd32 - crt_rd_period;
    else                      crt_rd_acc <= crt_rd_acc + 8'd32;
end
wire crt_rd_ce = crt_on ? crt_rd_tick : core_ce;

// HPOS_CONTENTSHIFT: NARC is 512 active in a 674-pixel line (76%), i.e. the
// wide/centred case the docs recommend it for; it also holds up while H-Size
// shrinks. SYNCSHIFT is for narrow, side-anchored games.
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb;
crt_adjust #(
    .VTOTAL   (433),             // NARC raster, matches VIDEO_VTOTAL
    .HTOTAL   (674),             // sizes the HSync shreg used by SYNCSHIFT
    .HPOS_MODE(1)                // 1 = CONTENTSHIFT
) u_crt_adjust (
    .clk      (clk_sys),
    .pxl_cen  (core_ce),         // write rate: the core's native pixel enable
    .pxl2_cen (crt_rd_ce),       // read rate: H-Size
    .active   (crt_on),
    .hsize    (crt_hsize),
    .hoffset  (crt_hpos),
    .voffset  (crt_vshift),
    .r_in     (ov_r), .g_in(ov_g), .b_in(ov_b),
    .hs_in    (ov_hs),           // NATIVE sync in; the module derives hs_ref_out
    .vs_in    (ov_vs),
    .hb_in    (ov_hb | ov_vb),   // combined blank for the horizontal edges
    .vb_in    (ov_vb),           // TRUE vertical blank -- keeps the OSD visible
    .r_out    (crt_r), .g_out(crt_g), .b_out(crt_b),
    .hs_out   (crt_hs), .vs_out(crt_vs),
    .hb_out   (crt_hb), .vb_out(crt_vb),
    .hs_ref_out(crt_hs_ref)
);

// Bypass cleanly when Off so a build with CRT Adjust unused is behaviourally
// identical to before this was added.
wire [7:0] av_r  = crt_on ? crt_r  : ov_r;
wire [7:0] av_g  = crt_on ? crt_g  : ov_g;
wire [7:0] av_b  = crt_on ? crt_b  : ov_b;
wire       av_hs = crt_on ? crt_hs : ov_hs;
wire       av_vs = crt_on ? crt_vs : ov_vs;
wire       av_hb = crt_on ? crt_hb : ov_hb;
wire       av_vb = crt_on ? crt_vb : ov_vb;

// GAMMA(0) IS LOAD-BEARING -- do not restore the default of 1.
//
// sys/gamma_corr.sv latches a pixel only on the RISING EDGE of ce_pix
// (`if(~old_ce & ce_pix)`) and has no CE_LEVEL parameter. Our ce_pix is a 2-of-3
// LEVEL: two adjacent asserted clocks are two DIFFERENT pixels. An edge detector
// sees one edge per three clocks, so it forwarded one pixel and dropped the
// other -- silently halving horizontal resolution to 256 columns while keeping
// the full 512-pixel width. Small font strokes merged; that was the "letters
// stuck together" fault.
//
// MEASURED: a 1-px alternating black/white pattern generated in this file (so
// downstream of all frame-buffer logic) is a perfect comb at the core output in
// simulation -- 512 samples/line, 10240 white / 10240 black, 0.0% adjacent-equal
// -- yet the hardware captured a frame of ONE colour, 204800/204800 px. Real
// game frames measured 100.0% even-aligned adjacent-column pairs identical.
//
// Nor is this fixable by making gamma_corr level-sensitive: it walks R, G and B
// through a single-port LUT over three following clocks, so it needs ~4 clk_vid
// per pixel and cannot accept two pixels in three clocks at all. GAMMA and
// CE_LEVEL are simply incompatible. Written up for upstream in
// doc/MISTER_GAMMA_CE_LEVEL_BUG.md.
//
// COST: the OSD gamma adjustment does nothing for this core. That is the whole
// price, and it buys back half the horizontal resolution.
arcade_video #(
    .WIDTH(512), .DW(24), .HQ2X(0), .LITE_RGB555(1), .CE_LEVEL(1), .GAMMA(0)
) arcade_video (
    .clk_video(clk_sys), .ce_pix(crt_rd_ce),
    .RGB_in({av_r, av_g, av_b}),
    .HBlank(av_hb), .VBlank(av_vb), .HSync(av_hs), .VSync(av_vs),
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
    .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE), .VGA_SL(VGA_SL),
    .fx(fx), .forced_scandoubler(forced_scandoubler), .gamma_bus(gamma_bus)
);

endmodule
