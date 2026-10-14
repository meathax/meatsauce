//============================================================================
//  Arcade: Sega System 32 / Multi 32 for MiSTer  (emu top)
//  DESIGN.md §9 — framework integration.
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

    // DDR3
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

    // SDRAM
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

    input         CLK_AUDIO,   // 24.576 MHz
    inout   [3:0] ADC_BUS,

    // SD-SPI
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

// unused framework peripherals
assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

import s32_pkg::*;

// Declare the descriptor before it is referenced by the clock-enable logic.
// Quartus 17 otherwise parses board_desc.multi32 as a hierarchical name.
board_desc_t board_desc;
board_desc_t active_board;

// Declare framework/HPS signals before configuration, LED, reset, and clock
// logic uses them. This keeps Quartus 17 and ModelSim 10.5 on the same parse.
wire        rom_loaded;
wire  [1:0] buttons;
wire [63:0] status;
wire        ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout, ioctl_din;
wire        eep_upload, eep_modified;
wire  [5:0] eep_rd_addr;
wire [15:0] eep_rd_data;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3, joystick_4, joystick_5;
wire [15:0] joystick_0_rumble, joystick_1_rumble;
wire [15:0] joystick_l_analog_0;
wire [15:0] joystick_l_analog_1;
wire [15:0] joystick_l_analog_2;
wire [15:0] joystick_l_analog_3;
wire [15:0] joystick_l_analog_4;
wire [15:0] joystick_l_analog_5;
wire [15:0] joystick_r_analog_0;
wire [15:0] joystick_r_analog_1;
wire  [7:0] paddle_0;
wire  [7:0] paddle_1;
wire  [8:0] spinner_0;
wire  [8:0] spinner_1;
wire        core_hs, core_vs;
wire        mode_416_active;
wire  [1:0] core_steering_motors;
wire [24:0] ps2_mouse;
// This RBF contains the common Sega System Multi 32 (837-8676) hardware used
// by the supported Multi 32 titles.  The descriptor is committed by the ROM
// loader after all region downloads and selects only small board/profile
// differences; the dual 315-5296 I/O, dual 315-5388/5242 video, V70, and
// shared MultiPCM architecture stay common to every title.
always @(*) begin
    // Keep old all-zero descriptors usable while the descriptor-only boot
    // commit is in flight.  A production descriptor with multi32=1 is then
    // consumed verbatim, including title-specific I/O flags.
    if (board_desc.multi32) begin
        active_board = board_desc;
    end
    else begin
        active_board = '0;
        active_board.multi32           = 1'b1;
        active_board.has_adc           = 1'b1;
        active_board.analog_profile    = ANALOG_DRIVING;
        active_board.sprite_bank_valid = 1'b1;
        active_board.sprite_bank_mask  = 2'b11;
        active_board.digital_profile   = DIGITAL_GENERIC;
        active_board.game_profile      = MULTI32_OUTRUNNERS;
    end
end

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;
// Lit until the index-0 ROM stream has fully drained to SDRAM.
assign LED_USER = ~rom_loaded;
assign LED_POWER = 0;
assign LED_DISK = 0;
assign BUTTONS = 0;

//////////////////////////////////   CONF   ///////////////////////////////////
// BUILD_DATE is normally provided by sys/build_id.tcl -> build_id.v. Guard it
// so the core still compiles cleanly if that define is absent.
`ifndef BUILD_DATE
`define BUILD_DATE "SegaS32"
`endif

localparam CONF_STR = {
    "S32;;",
    "-;",
    "O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "O[6],Screen (Multi32),A,B;",
    "O[38],Splitscreen,Off,On;",
    "O[7],Service Mode,Off,On;",
    "-;",
    "O[40:39],P1 Steering,Analog Wheel,Paddle,Spinner,Spinner Reverse;",
    "O[42:41],P2 Steering,Analog Wheel,Paddle,Spinner,Spinner Reverse;",
    "h0P2,Rumble;",
    "h0P2O[43],Rumble,On,Off;",
    "h0P2O[45:44],Rumble Strength,Low,Medium,High;",
    // status[8], status[30:34], status[36:37] were the lightgun/GunCon SNAC
    // options (Sinden Borders, Gun Crosshair, Gun Sensitivity, P1/P2 Gun
    // Input) -- OutRunners has no positional-gun cabinet. Left unallocated
    // rather than reclaimed, matching the status[29] convention below.
    // status[43] = OutRunners rumble enable; status[45:44] = rumble strength.
    // status[29] is RESERVED and intentionally unused.  It used to select
    // "V60 Fetch,Fast,PCB (Reset)"; the Fast instruction-fetch transport has
    // been removed and the core always uses the PCB fetch path.  The bit is
    // left allocated rather than reclaimed so every later option
    // (Scale = status[28:27], etc.) keeps its existing meaning for users with
    // saved settings.
    "-;",
    "O[28:27],Scale,Normal,V-Integer,HV-Integer;",
    "-;",
    "R[0],Reset;",
    // B1/B2 = shift up/down, B3 = DJ/music, B4/B5 = track <</>>,
    // B6/B7 = dedicated digital Accelerate/Brake (previously aliased onto
    // B1/B2, which made shifting also floor the pedal). Bit layout:
    // 4..10 = B1..B7, 11 = Start, 12 = Coin, 13 = Test, 14 = Service.
    "J1,B1,B2,B3,B4,B5,B6,B7,Start,Coin,Test,Service;",
    "V,v",`BUILD_DATE
};

////////////////////////////   CLOCKS/PLL   ///////////////////////////////////
wire clk_sys, clk_ram, clk_v25, pll_locked;
wire sdram_ready;
reg  sdram_ready_meta, sdram_ready_sys;
pll pll (
    .refclk_clk(CLK_50M),
    .reset_reset(1'b0),
    .outclk0_clk(clk_ram),    // 96.634615 MHz
    .outclk1_clk(clk_sys),    // 48.317307 MHz
    .outclk2_clk(SDRAM_CLK),  // 96.634615 MHz, 180 deg: centred SDRAM interface
    .outclk3_clk(clk_v25),    // 24.158653 MHz (clk_sys/2): s80x86 compute domain
    .locked_export(pll_locked)
);
assign DDRAM_CLK = clk_ram;
assign CLK_VIDEO = clk_sys;

// Keep every game subsystem reset until a complete index-0 ROM transfer has
// drained into SDRAM. The loader itself is reset only by PLL startup so soft
// reset and NVRAM transfers do not forget that ROM is already resident.
wire video_reset = RESET | status[0] | buttons[1] | ~pll_locked;
wire reset = video_reset | ioctl_download | ~rom_loaded | ~sdram_ready_sys;

// Hide the OutRunners rumble page unless the committed descriptor selects that
// title. h0 means hide when menu-mask bit 0 is clear.
wire [15:0] status_menumask;
assign status_menumask = {15'd0, (active_board.game_profile == MULTI32_OUTRUNNERS)};

// The PCB exposes a binary steering-wheel shaker request. Translate it to
// MiSTer's large-rumble channel; these magnitudes are controller policy, not
// claims about the original cabinet driver's analogue amplitude.
localparam [7:0] OUTRUNNERS_RUMBLE_LOW    = 8'h40;
localparam [7:0] OUTRUNNERS_RUMBLE_MEDIUM = 8'h80;
localparam [7:0] OUTRUNNERS_RUMBLE_HIGH   = 8'hff;
wire outrunners_rumble_active = ~reset &&
                                 (active_board.game_profile == MULTI32_OUTRUNNERS);
wire outrunners_rumble_enabled = outrunners_rumble_active && ~status[43];
wire [7:0] outrunners_rumble_magnitude =
    (status[45:44] == 2'd0) ? OUTRUNNERS_RUMBLE_LOW :
    (status[45:44] == 2'd1) ? OUTRUNNERS_RUMBLE_MEDIUM :
    (status[45:44] == 2'd2) ? OUTRUNNERS_RUMBLE_HIGH : 8'h00;
wire [15:0] outrunners_rumble_value = {outrunners_rumble_magnitude, 8'h00};
assign joystick_0_rumble = (outrunners_rumble_enabled && core_steering_motors[0])
                          ? outrunners_rumble_value : 16'h0000;
assign joystick_1_rumble = (outrunners_rumble_enabled && core_steering_motors[1])
                          ? outrunners_rumble_value : 16'h0000;

// Synchronise the controller-ready level from clk_ram before it gates the
// loader and the game logic in clk_sys.
always @(posedge clk_sys) begin
    if (!pll_locked) begin
        sdram_ready_meta <= 1'b0;
        sdram_ready_sys  <= 1'b0;
    end
    else begin
        sdram_ready_meta <= sdram_ready;
        sdram_ready_sys  <= sdram_ready_meta;
    end
end

// fractional clock enables (DESIGN.md §3.3)
reg ce_cpu;
wire ce_z80, ce_fm, ce_pcm;
reg [15:0] acc_cpu;
wire is_multi32 = active_board.multi32;
// CPU Turbo is retired in the universal profile: s32.sdc's V60 register-
// to-register multicycle relaxation now applies unconditionally, and that
// relaxation is only sound with fixed, single-cycle-safe CE spacing (no
// back-to-back clk_sys edges) for every game, not just the two V25 titles --
// see s32.sdc's s32_game_fixed_ce comment. Every board therefore runs at a
// fixed cadence with no runtime multiplier; see the derivation below for why
// that cadence is now clk_sys/2 on every System 32 board rather than only on
// arabfgt/ga2.
// 2026-08-14: the bus cadence now tracks the execute cadence on every System 32
// board, not just the two V25 titles.
//
// s32_v60_exec_cadence (rtl/s32_core.sv:7-28) deliberately advances the V60
// microsequencer at clk_sys/2 = 24.159 MHz to model the overlap of the real
// V60's decode/EA/execute units, because the RTL sequencer is serial where the
// silicon is pipelined.  The external bus adapter, however, was left at the
// PCB's literal 16.108 MHz.  That pairing is not self-consistent: every memory
// access then costs 1.5x more relative to execution than it does on real
// hardware, and ~38% of V60 cycles are operand-memory cycles.  Dark Edge is the
// worst case precisely because it took the 21848 branch, while arabfgt/ga2 have
// shipped the consistent 32768 pairing all along (originally added to fix
// Arabian Fight's attract-loop overrun -- the same underlying deficit).
//
// 32768/65536 * 48.317307 MHz = exactly clk_sys/2, so the bus advances in step
// with the sequencer.  This is a model-consistency fix, not a turbo: the
// alternative consistent choice (both sides at 16.108 MHz) was measured to make
// Dark Edge's gameplay countdown advance every 70 frames against MAME's 35.
//
// Multi 32's V70 keeps its own 20 MHz constant; it is out of production scope.
//
// SDC note: s32.sdc's V60 register-to-register -setup 2 exception depends on
// v60_exec_ce alternating clk_sys phases, NOT on cpu_ce_inc.  32768 also yields
// a strictly alternating enable, so no back-to-back clk_sys edge is created on
// either the exec or the bus side and the exception remains sound.
//
// 2026-08-14 -- REVERTED to the per-board rates above.  The uniform 32768
// pairing argued for above is a source-level consistency argument; it was
// contradicted by real hardware.  Raising the external bus to clk_sys/2 on the
// boards that had been running the PCB's literal 16.108 MHz black-screened
// Golden Axe: The Revenge of Death Adder, Spider-Man and Rad Rally, all three
// of which ran correctly on the preceding RBF.  Arabian Fight, the one board
// whose rate did NOT change, kept working; Dark Edge, Holosseum and Slip
// Stream tolerated the higher rate, so the raise is necessary-but-not-
// sufficient for the failure and the load-sensitive titles are the ones it
// breaks (Rad Rally survives its attract loop and dies once gameplay starts).
//
// 21848 is the documented board fact (s32_pkg::PCB_V60_CE_INC, PCB_OSC_HZ/2 =
// 16.108 MHz); 32768 overclocks the external bus by 50%.  Observed hardware
// behaviour outranks the model-consistency argument, and preserving the
// hardware-visible cadence is the standing rule.  The Dark Edge countdown
// deficit that motivated the change is real but must be fixed without
// overclocking the bus -- it is a separate, still-open item.
// No V25 on this board (OutRunners is unprotected); the bus runs at the
// Multi 32 V70 rate, 40 MHz / 2 = 20 MHz (16'd27127/65536 x 48.317307 MHz).
wire [15:0] cpu_ce_inc = 16'd27127;
always @(posedge clk_sys) begin
    logic [16:0] s;
    if (reset) begin
        ce_cpu <= 1'b0;
        acc_cpu <= 16'd0;
    end
    else begin
        // cpu: 16.107950/48.317307 (V60, the PCB's literal bus rate) on every
        //      board except Arabian Fight, which keeps 24.158654/48.317307
        //      (= clk_sys/2) for its attract-loop overrun;
        //      20/48.317307 (V70, Multi 32 only)
        s = acc_cpu + {1'b0, cpu_ce_inc};  // base increment * turbo mult (capped)
        ce_cpu <= s[16];
        acc_cpu <= s[15:0];
    end
end

s32_audio_ce audio_ce(
    .clk(clk_sys), .reset(reset), .pll_locked(pll_locked),
    .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm)
);

///////////////////////////////   HPS IO   ////////////////////////////////////

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),

    .buttons(buttons),
    .status(status),
    .status_menumask(status_menumask),

    .ioctl_download(ioctl_download),
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(eep_modified),
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
    .joystick_3(joystick_3),
    .joystick_4(joystick_4),
    .joystick_5(joystick_5),
    .joystick_l_analog_0(joystick_l_analog_0),
    .joystick_l_analog_1(joystick_l_analog_1),
    .joystick_l_analog_2(joystick_l_analog_2),
    .joystick_l_analog_3(joystick_l_analog_3),
    .joystick_l_analog_4(joystick_l_analog_4),
    .joystick_l_analog_5(joystick_l_analog_5),
    .joystick_r_analog_0(joystick_r_analog_0),
    .joystick_r_analog_1(joystick_r_analog_1),
    .joystick_0_rumble(joystick_0_rumble),
    .joystick_1_rumble(joystick_1_rumble),
    .paddle_0(paddle_0),
    .paddle_1(paddle_1),
    .spinner_0(spinner_0),
    .spinner_1(spinner_1),
    .ps2_mouse(ps2_mouse)
);

// No lightgun on this board: the PS/2 mouse decode chain that fed it
// (ps2_mouse_strobe/dx_jt/dy_jt) was removed. ps2_mouse itself stays
// connected to hps_io since that port always exists on the framework side.

// MiSTer MRA NVRAM is a byte stream at index 3. Convert the EEPROM's
// 64x16 little-endian shadow into that stream for save uploads.
s32_eeprom_nvram_if #(.WIDE(1)) eep_nvram_if (
    .ioctl_upload(ioctl_upload), .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr), .eep_rd_data(eep_rd_data),
    .eep_upload(eep_upload), .eep_rd_addr(eep_rd_addr),
    .ioctl_din(ioctl_din)
);

////////////////////////////   ROM LOADING   //////////////////////////////////
wire        sw_req, sw_ack;
wire [24:1] sw_addr;
wire [15:0] sw_din;
wire  [1:0] sw_be;
wire        wave_sw_req, wave_sw_ack;
wire [24:1] wave_sw_addr;
wire [15:0] wave_sw_din;
wire  [1:0] wave_sw_be;
wire        mem_sw_req, mem_sw_ack;
wire [24:1] mem_sw_addr;
wire [15:0] mem_sw_din;
wire  [1:0] mem_sw_be;
wire        eep_wr;
wire  [5:0] eep_waddr;
wire [15:0] eep_wdata;

// CLEAR_RF_WAVE=0: this board has no RF5C68, so the MultiPCM aperture holds
// real sample ROM. The 2026-08-14 revert (see rtl/audio/s32_soundsys.sv) also
// means this repository never actually used the wave-RAM SDRAM aperture the
// clear was written for; zeroing it here would corrupt the first 64 KiB of
// genuine MultiPCM sample data before every game boot.
s32_rom_loader #(.WIDE(1), .CLEAR_RF_WAVE(0)) loader (
    .clk(clk_sys), .rst(~pll_locked),
    .mem_ready(sdram_ready_sys),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index[7:0]),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .board_desc(board_desc),
    .sdr_wr_req(sw_req), .sdr_wr_addr(sw_addr), .sdr_wr_din(sw_din),
    .sdr_wr_be(sw_be), .sdr_wr_ack(sw_ack),
    .eep_wr(eep_wr), .eep_waddr(eep_waddr), .eep_wdata(eep_wdata),
    .eep_loaded(), .rom_loaded(rom_loaded)
);

s32_sdram_write_mux2 sdram_write_mux (
    .clk(clk_sys), .rst(~pll_locked),
    .c0_req(sw_req), .c0_addr(sw_addr), .c0_data(sw_din), .c0_be(sw_be),
    .c0_ack(sw_ack),
    .c1_req(wave_sw_req), .c1_addr(wave_sw_addr),
    .c1_data(wave_sw_din), .c1_be(wave_sw_be), .c1_ack(wave_sw_ack),
    .d_req(mem_sw_req), .d_addr(mem_sw_addr), .d_data(mem_sw_din),
    .d_be(mem_sw_be), .d_ack(mem_sw_ack)
);

/////////////////////////////////   SDRAM   ///////////////////////////////////
wire        p0_req, p0_burst, p0_ack, p1_req, p1_ack, p2_req, p2_ack, p3_req, p3_ack, p4_req, p4_ack, p5_req, p5_ack;
wire        core_p1_req, core_p2_req;
wire [24:1] p0_addr, p3_addr, p4_addr;
wire [24:3] p1_addr, p5_addr;
wire [24:4] p2_addr;
wire [24:3] core_p1_addr;
wire [24:4] core_p2_addr;
wire [15:0] p3_dout, p4_dout;
wire [63:0] p0_dout, p1_dout, p5_dout;
wire[127:0] p2_dout;

assign p1_req  = core_p1_req;
assign p1_addr = core_p1_addr;
assign p2_req  = core_p2_req;
assign p2_addr = core_p2_addr;
sdram sdram (
    .clk(clk_ram), .init(~pll_locked), .ready(sdram_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(mem_sw_req), .wr_addr(mem_sw_addr), .wr_din(mem_sw_din),
    .wr_be(mem_sw_be), .wr_ack(mem_sw_ack),
    .p0_req(p0_req), .p0_burst(p0_burst), .p0_addr(p0_addr),
    .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

////////////////////////////   FRAMEBUFFER   //////////////////////////////////
wire        fbw_start, fbw_valid, fbw_end, fbw_shadow, fbw_busy, fbw_can_start;
wire        fbe_req, fbe_ack, fbr_req, fbr_ack, fbr2_req, fbr2_ack;
wire  [1:0] fbw_buf, fbe_buf, fbr_buf, fbr2_buf;
wire  [8:0] fbw_x, fbr_x;
wire  [7:0] fbw_y, fbe_y, fbr_y, fbr2_y;
wire [15:0] fbw_pix, fbr_pix, fbr2_pix;
s32_fb_if fb (
    .clk(clk_ram), .rst(reset),
    .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
    .wr_start(fbw_start), .wr_buf(fbw_buf), .wr_x(fbw_x), .wr_y(fbw_y),
    .wr_valid(fbw_valid), .wr_pix(fbw_pix), .wr_end(fbw_end),
    .wr_shadow(fbw_shadow), .wr_busy(fbw_busy), .wr_can_start(fbw_can_start),
    .er_req(fbe_req), .er_buf(fbe_buf), .er_y(fbe_y), .er_ack(fbe_ack),
    .rd_req(fbr_req), .rd_buf(fbr_buf), .rd_y(fbr_y), .rd_ack(fbr_ack),
    .rd_x(fbr_x), .rd_pix(fbr_pix),
    .rd2_req(fbr2_req), .rd2_buf(fbr2_buf), .rd2_y(fbr2_y),
    .rd2_ack(fbr2_ack), .rd2_pix(fbr2_pix)
);

//////////////////////////////   INPUTS   /////////////////////////////////////
// MiSTer logical joystick bits are directions [3:0], six arcade buttons
// [9:4], Start [10], Coin [11].  GA2's 315-5296 player ports follow MAME:
// {left,right,up,down,unused,button3,button2,button1}, active low.
function automatic [7:0] p_dig(input [31:0] j);
    p_dig = ~{j[1], j[0], j[3], j[2], 1'b0, j[6], j[5], j[4]};
endfunction
// Hard Dunk's four action buttons occupy the low nibble of each 315-5296
// player port; directions remain in bits 4..7.  Keep this separate from the
// three-button generic mapping so unused input bits never become a phantom
// action on a different title.
function automatic [7:0] p_dig4(input [31:0] j);
    p_dig4 = ~{j[1], j[0], j[3], j[2], j[7], j[6], j[5], j[4]};
endfunction
// Title Fight has two independent sticks per player.  MiSTer exposes each
// stick as signed X/Y bytes (X=[7:0], Y=[15:8]); retain the digital d-pad as a
// fallback for keyboard/joypad users and assert only the corresponding
// active-low direction bit.  The 24-count dead zone is below the MAME
// joystick's normal digital threshold and avoids centre jitter.
function automatic [7:0] title_stick(input [31:0] j, input [15:0] a);
    reg signed [7:0] x;
    reg signed [7:0] y;
    reg [7:0] p;
    begin
        x = a[7:0];
        y = a[15:8];
        p = 8'hff;
        if ((x < -8'sd24) || j[1]) p[7] = 1'b0;
        if ((x >  8'sd24) || j[0]) p[6] = 1'b0;
        if ((y < -8'sd24) || j[3]) p[5] = 1'b0;
        if ((y >  8'sd24) || j[2]) p[4] = 1'b0;
        title_stick = p;
    end
endfunction
// Title Fight's right-hand stick can be driven by the MiSTer right analog
// axis or by four independently assignable action buttons. The left-hand
// stick continues to use the physical D-pad as its digital fallback.
function automatic [7:0] title_right_stick(input [31:0] j, input [15:0] a);
    reg signed [7:0] x;
    reg signed [7:0] y;
    reg [7:0] p;
    begin
        x = a[7:0];
        y = a[15:8];
        p = 8'hff;
        if ((x < -8'sd24) || j[4]) p[7] = 1'b0; // Right stick left / B1
        if ((x >  8'sd24) || j[5]) p[6] = 1'b0; // Right stick right / B2
        if ((y < -8'sd24) || j[6]) p[5] = 1'b0; // Right stick up / B3
        if ((y >  8'sd24) || j[7]) p[4] = 1'b0; // Right stick down / B4
        title_right_stick = p;
    end
endfunction
wire [7:0] p1a_dig = p_dig(joystick_0);
// Rad Mobile leaves raw player-port bit 0 unused and places its two cabinet
// switches, Light and Wiper, on bits 1/2.  Drive them from B3/B4 rather than
// B1/B2: B1/B2 are the shared digital accelerator/brake fallbacks that feed
// the MSM6253 channels for every driving cabinet, so sourcing Light/Wiper from
// them made one button do two unrelated things at once.  Rad Mobile now offers
// the same assignable Accelerate/Brake pair as Rad Rally and Slip Stream.
wire [7:0] p2a_dig = p_dig(joystick_1);

// No lightgun, GunCon SNAC, or positional-gun cabinet on this board: those
// were System-32-only peripherals (Alien 3, Jurassic Park). USER_IN/USER_OUT
// are free for a future comm-board link. gun_aim/coin_swap are hardcoded 0 in
// active_board above, so every branch that used to key off them is gone too.
assign USER_OUT = 7'h7f;

wire [7:0] title_p1_left  = title_stick(joystick_0, joystick_l_analog_0);
wire [7:0] title_p1_right = title_right_stick(joystick_0, joystick_r_analog_0);
wire [7:0] title_p2_left  = title_stick(joystick_1, joystick_l_analog_1);
wire [7:0] title_p2_right = title_right_stick(joystick_1, joystick_r_analog_1);

// Hard Dunk is the six-player Multi 32 board: the first two players use the
// primary 5296, players 4/5 use the second 5296, and players 3/6 arrive on
// the 8255 PPI's A/B ports.  p_dig4 matches the MAME byte layout exactly:
// buttons 1..4 occupy bits 0..3 and the 8-way directions occupy bits 4..7.
function automatic [7:0] hard_dig4(input [31:0] j, input [15:0] a);
    reg signed [7:0] x;
    reg signed [7:0] y;
    reg [7:0] p;
    begin
        x = a[7:0];
        y = a[15:8];
        p = p_dig4(j);
        if ((x < -8'sd24) || j[1]) p[7] = 1'b0;
        if ((x >  8'sd24) || j[0]) p[6] = 1'b0;
        if ((y < -8'sd24) || j[3]) p[5] = 1'b0;
        if ((y >  8'sd24) || j[2]) p[4] = 1'b0;
        hard_dig4 = p;
    end
endfunction
wire [7:0] hard_p1a = hard_dig4(joystick_0, joystick_l_analog_0);
wire [7:0] hard_p2a = hard_dig4(joystick_1, joystick_l_analog_1);
wire [7:0] hard_p3a = hard_dig4(joystick_2, joystick_l_analog_2);
wire [7:0] hard_p4a = hard_dig4(joystick_3, joystick_l_analog_3);
wire [7:0] hard_p5a = hard_dig4(joystick_4, joystick_l_analog_4);
wire [7:0] hard_p6a = hard_dig4(joystick_5, joystick_l_analog_5);
// The Multi 32 board exposes players 4/5 on the second 5296 and
// players 3/6 on the 8255; keep the game-player numbering explicit.
wire [7:0] hard_p1b = hard_p4a;
wire [7:0] hard_p2b = hard_p5a;
wire [7:0] hard_ppi_pa = hard_p3a;
wire [7:0] hard_ppi_pb = hard_p6a;
// Hard Dunk's EXTRA3 PPI bits are START3 (bit 0) and START6 (bit 1)
// The J1 contract places START at bit 11 and COIN at bit 12.
wire [7:0] hard_ppi_pc = ~{6'b000000, joystick_5[11], joystick_2[11]};

// Stadium Cross exposes one three-button control group per Multi 32 I/O
// board.  MAME's Attack and Brake inputs are active low while Wheelie is
// active high; map them to MiSTer's A/B/X buttons without touching the
// unused port bits.  The normal (non-link) sets still have independent P1
// analog wheel/pedal channels on both boards.
function automatic [7:0] scross_ctrl(input [31:0] j, input [15:0] left_a);
    reg [7:0] p;
    reg signed [8:0] y;
    reg handle_forward;
    reg handle_back;
    begin
        p = 8'hff;
        y = $signed({left_a[15], left_a[15:8]});
        handle_forward = (y < -9'sd24) || j[3] || j[8];
        handle_back = (y > 9'sd24) || j[2] || j[9];
        p[0] = ~j[4]; // Attack (BUTTON1, active low)
        p[1] = (j[5] || handle_back) && !handle_forward; // Wheelie sensor
        p[2] = ~j[6]; // Brake (BUTTON3, active low)
        // Stadium Cross uses a centered HANDLE VR and a separate WHEELIE
        // sensor; the service manual documents no independent forward/back
        // switches. Left-stick Y and the named digital pitch controls feed
        // that sensor state, with rearward pull asserting WHEELIE.
        scross_ctrl = p;
    end
endfunction
wire [7:0] scross_p1a = scross_ctrl(joystick_0, joystick_l_analog_0);
wire [7:0] scross_p1b = scross_ctrl(joystick_1, joystick_l_analog_1);
// Stadium Cross has three cabinet buttons in MAME (Attack/Wheelie/Brake),
// while MiSTer also exposes an assignable digital accelerator and the two
// handlebar pitch buttons above.  D-pad up/down are pitch fallbacks, not
// pedal inputs; the analog pedal remains on the right-stick Y axis.
wire stadium_cross = active_board.game_profile == MULTI32_STADIUM_CROSS;
wire p1_digital_accel = stadium_cross
                      ? joystick_0[7]
                      : joystick_0[9];
wire p1_digital_brake = stadium_cross
                      ? 1'b0
                      : joystick_0[10];
wire p2_digital_accel = stadium_cross
                      ? joystick_1[7]
                      : joystick_1[9];
wire p2_digital_brake = stadium_cross
                      ? 1'b0
                      : joystick_1[10];
wire [7:0] core_p1a = (active_board.game_profile == MULTI32_TITLE_FIGHT) ?
                      title_p1_left :
                      (active_board.game_profile == MULTI32_STADIUM_CROSS) ?
                      scross_p1a :
                      (active_board.game_profile == MULTI32_HARD_DUNK) ?
                      hard_p1a : p1a_dig;
// OutRunners routes PLAYER 1's music keys through the P2_A port (MAME
// INPUT_PORTS_START(orunners): P2_A bit0 = P1 DJ/music, bit1 = P1 track <<,
// bit2 = P1 track >>). Feeding p2a_dig (the second player's shift buttons)
// here left all three music keys dead in the service menu's INPUT TEST and
// in-game. Player 2's own controls live on the second I/O chip: P1_B carries
// P2 shift up/down and P2_B carries P2's music keys (wired at the s32_core
// instantiation below).
wire [7:0] core_p2a = (active_board.game_profile == MULTI32_TITLE_FIGHT) ?
                      title_p1_right :
                      (active_board.game_profile == MULTI32_STADIUM_CROSS) ?
                      8'hff :
                      (active_board.game_profile == MULTI32_HARD_DUNK) ?
                      hard_p2a :
                      {5'h1f, ~joystick_0[8], ~joystick_0[7], ~joystick_0[6]};
wire [7:0] core_p1b = (active_board.game_profile == MULTI32_TITLE_FIGHT) ?
                      title_p2_left :
                      (active_board.game_profile == MULTI32_STADIUM_CROSS) ?
                      scross_p1b :
                      (active_board.game_profile == MULTI32_HARD_DUNK) ?
                      hard_p1b : p_dig(joystick_1);
wire [7:0] core_p2b = (active_board.game_profile == MULTI32_TITLE_FIGHT) ?
                      title_p2_right :
                      (active_board.game_profile == MULTI32_STADIUM_CROSS) ?
                      8'hff :
                      (active_board.game_profile == MULTI32_HARD_DUNK) ?
                      hard_p2b :
                      {5'h1f, ~joystick_1[8], ~joystick_1[7], ~joystick_1[6]};

wire [7:0] adc_ch [0:7];
// MiSTer reports each analog-stick axis as signed -128..+127. Split the right
// stick's vertical axis into independent, released-at-zero pedals: up is
// accelerator and down is brake. Stadium Cross uses the left-stick Y axis for
// handlebar pitch in scross_ctrl above; its physical pedals remain on right Y.
wire [7:0] driving_wheel;
wire [7:0] driving_accel;
wire [7:0] driving_brake;
wire       adc0_load;
s32_driving_controls driving_controls (
    .clk(clk_sys),
    .rst(reset),
    .capture_wheel(1'b0),
    .wheel_sample(1'b0),
    .left_x(joystick_l_analog_0[7:0]),
    .paddle(paddle_0),
    .spinner(spinner_0),
    .mouse(ps2_mouse),
    .wheel_source(status[40:39]),
    .right_y(joystick_r_analog_0[15:8]),
    // Dedicated digital pedal fallbacks. OutRunners uses MRA buttons 6/7
    // (joystick bits 9/10); Stadium Cross retains only its named B4
    // accelerator fallback. D-pad up/down belong to handlebar pitch.
    .digital_accel(p1_digital_accel),
    .digital_brake(p1_digital_brake),
    .digital_left(joystick_0[1]),
    .digital_right(joystick_0[0]),
    .wheel(driving_wheel),
    .accel(driving_accel),
    .brake(driving_brake)
);
// OutRunners is a two-cockpit cabinet: P2 gets its own wheel/pedal set on
// the second joystick's analog axes, read through the ADC's bank-1 slots
// (segas32.cpp in2_analog_read/in3_analog_read select
// m_analog_ports[bank*4+2/3] -- see the s32_msm6253 comment in s32_core.sv).
// adc0_load (the wheel-sample strobe) is RadM-specific and P1-only; P2's
// wheel follows the deadzoned stick directly like P1's does when RadM
// capture is not active.
wire [7:0] driving_wheel_p2;
wire [7:0] driving_accel_p2;
wire [7:0] driving_brake_p2;
s32_driving_controls driving_controls_p2 (
    .clk(clk_sys),
    .rst(reset),
    .capture_wheel(1'b0),
    .wheel_sample(1'b0),
    .left_x(joystick_l_analog_1[7:0]),
    .paddle(paddle_1),
    .spinner(spinner_1),
    .mouse(25'd0),
    .wheel_source(status[42:41]),
    .right_y(joystick_r_analog_1[15:8]),
    .digital_accel(p2_digital_accel),
    .digital_brake(p2_digital_brake),
    .digital_left(joystick_1[1]),
    .digital_right(joystick_1[0]),
    .wheel(driving_wheel_p2),
    .accel(driving_accel_p2),
    .brake(driving_brake_p2)
);
// Driving cabinets wire the wheel, accelerator, and brake to the MSM6253
// channels. Each wheel can use MiSTer's analog X, absolute paddle, or relative
// spinner interface; right-stick up/down are the analog pedals, with A/B as
// full-scale digital fallbacks. The default analog path remains direct.
// Channel layout matches MAME's fixed ANALOG1/2 + banked ANALOG3/4 (bank 0)
// and ANALOG7/8 (bank 1) -- see the s32_msm6253 instantiation comment.
assign adc_ch[0] = stadium_cross ? ~driving_wheel : driving_wheel;
assign adc_ch[1] = driving_accel;      // ANALOG2: P1 accel/pedal (fixed)
assign adc_ch[2] = stadium_cross ? ~driving_wheel_p2 : driving_brake;
assign adc_ch[3] = stadium_cross ? driving_accel_p2 : driving_wheel_p2;
assign adc_ch[4] = 8'h80;              // unused: an0/an1 never read bank 1
assign adc_ch[5] = 8'h80;              // unused: an0/an1 never read bank 1
assign adc_ch[6] = stadium_cross ? 8'h80 : driving_accel_p2;
assign adc_ch[7] = stadium_cross ? 8'h80 : driving_brake_p2;
// MAME system32_generic: port C is unused; port E/SERVICE12 is
// {unknown[7:6], start2, start1, coin2, coin1, test, service}, active low.
// Test = the OSD "Service Mode" toggle OR the local cockpit's mappable Test
// button (j13). Service (coin-service credit) is likewise local to each
// cockpit's Service button (j14). Keep the OSD toggle global, but never OR
// the two physical control panels together: the two 315-5296 chips have
// independent service menus on the real Multi 32 board.
wire [7:0] portc = 8'hff;
wire test_btn_a = status[7] | joystick_0[13];
wire svc_btn_a  = joystick_0[14];
wire test_btn_b = status[7] | joystick_1[13];
wire svc_btn_b  = joystick_1[14];
wire [7:0] svc12 = ~{
                      2'b00,
                      joystick_1[11],
                      joystick_0[11],
                      joystick_1[12],
                      joystick_0[12],
                      test_btn_a, svc_btn_a};
// Multi32_GENERIC leaves SERVICE12_A bit 3 unused. Hard Dunk keeps the
// primary board's coin1 on bit 2 while retaining starts 1/2 on bits 4/5.
wire [7:0] hard_svc12 = ~{2'b00, joystick_1[11], joystick_0[11],
                          1'b0, joystick_0[12], test_btn_a, svc_btn_a};
// Port F/SERVICE34: bits 3:0 = DIP SW1:1-4 (Off), bit4 = PCB Push SW1
// (Service), bit5 = PCB Push SW2 (Test), bit6 unknown; bit7 is replaced by the
// EEPROM DO line inside s32_core.  Some games poll the PCB push switches
// rather than the cabinet Test line, so drive them from the same buttons —
// physically equivalent to pressing the matching switch on the board.
wire [7:0] svc34 = ~{2'b00, test_btn_a, svc_btn_a, 4'b0000};
// Board B (screen B, joystick_1's own board) gets its own service/test pair,
// coin and start. Its second coin door/start lane is not wired on OutRunners.
wire [7:0] svc12_b = ~{2'b00, 1'b0, joystick_1[11], 1'b0, joystick_1[12],
                        test_btn_b, svc_btn_b};
// Title Fight's second Multi 32 I/O chip exposes starts 3/4 on bits 4/5 and
// keeps the generic board-B service/test/coin lanes.
wire [7:0] title_svc12_b = ~{2'b00, joystick_3[11], joystick_2[11],
                             1'b0, joystick_1[12], test_btn_b, svc_btn_b};
// Hard Dunk's second 5296 carries starts 4/5 on bits 4/5; its generic
// service/test/coin2 lanes remain on bits 0/1/2.
wire [7:0] hard_svc12_b = ~{2'b00, joystick_4[11], joystick_3[11],
                            1'b0, joystick_1[12], test_btn_b, svc_btn_b};
wire [7:0] svc34_b = ~{2'b00, test_btn_b, svc_btn_b, 4'b0000};
wire [7:0] core_svc12 = (active_board.game_profile == MULTI32_HARD_DUNK) ?
                        hard_svc12 : svc12;
wire [7:0] core_svc12_b = (active_board.game_profile == MULTI32_TITLE_FIGHT) ?
                          title_svc12_b :
                          (active_board.game_profile == MULTI32_HARD_DUNK) ?
                          hard_svc12_b : svc12_b;
// GA2's 4-player i8255 port C is MAME EXTRA3 (ppi.in_pc_callback -> "EXTRA3").
// Base sets: bit0=Start3, bit1=Start4, bits[7:2] unused. The US sets (ga2u,
// spidmanu, arabfgtu) instead read COIN1 on bit3 (0x08) and COIN2 on bit2
// (0x04) here (PORT_MODIFY EXTRA3). IO-11/12: additively drive those two bits
// from the same P1/P2 coin buttons that feed SERVICE12 coin1/coin2, so US sets
// register their primary coins. Safe for every non-US set because they mark
// EXTRA3 bits 2/3 IPT_UNUSED. NOTE (unverified on hardware): on a US set the
// coin button now also pulses SERVICE12 (read there as COIN3/COIN4), so if that
// game credits COIN3/4 as well as COIN1/2 a single press could double-count;
// eliminating that needs a board-descriptor US flag, deferred by choice.
wire [7:0] ga2_ppi_pc = ~{4'b0, joystick_0[12], joystick_1[12],
                          joystick_3[11], joystick_2[11]};
// Burning Rival and Dark Edge use the physical i8255 differently from GA2:
// A/C are pulled high and B carries the upper action buttons.  Their first
// three action buttons remain on the descriptor-selected player A ports.
wire [7:0] brival_ppi_pb = {~joystick_0[9], 1'b1,
                            ~joystick_0[7], ~joystick_0[8], 1'b1,
                            ~joystick_1[9], ~joystick_1[8], ~joystick_1[7]};
wire [7:0] darkedge_ppi_pb = {~joystick_0[8], 1'b1,
                              ~joystick_0[6], ~joystick_0[7], 1'b1,
                              ~joystick_1[8], ~joystick_1[7], ~joystick_1[6]};
wire brival_inputs = 1'b0;  // Burning Rival protection removed -- other-game hardware
wire darkedge_inputs = 1'b0;  // Dark Edge protection removed -- other-game hardware
wire [7:0] core_ppi_pa = (active_board.game_profile == MULTI32_HARD_DUNK) ?
                          hard_ppi_pa :
                          ((brival_inputs || darkedge_inputs) ? 8'hff :
                           p_dig(joystick_2));
wire [7:0] core_ppi_pb = (active_board.game_profile == MULTI32_HARD_DUNK) ?
                          hard_ppi_pb :
                          (brival_inputs ? brival_ppi_pb :
                           darkedge_inputs ? darkedge_ppi_pb : p_dig(joystick_3));
wire [7:0] core_ppi_pc = (active_board.game_profile == MULTI32_HARD_DUNK) ?
                          hard_ppi_pc :
                          ((brival_inputs || darkedge_inputs) ? 8'hff :
                           ga2_ppi_pc);

//////////////////////////////   CORE   ///////////////////////////////////////
wire [23:0] rgb_a, rgb_b;
wire ce_pix_core, core_hb, core_vb;
wire [8:0] core_hcnt;   // native raster X, for the splitscreen composer below
wire signed [15:0] aud_l, aud_r;
s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram),
    .rst(reset), .video_rst(video_reset),
    .board(active_board),
    .screen_sel(status[6]),
    .ce_cpu(ce_cpu), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm),
    // The production profile has no debug/screenshot pause control. Keep the
    // core port constant so standalone verification benches can still test
    // V25 pause semantics without carrying the menu logic into an RBF.
    .pause(1'b0),
    // Wide V60 instruction fetch is hardwired on.  Keeping prefetches on the
    // dedicated ROM-cache path preserves the p1 tile-renderer deadline in
    // dense road scenes; routing them through the ce_cpu-gated 16-bit path
    // multiplied p0 SDRAM traffic and regressed Slip Stream draw distance.
    // The physical V60 data/I/O cadence remains the PCB rate; no OSD option is
    // exposed and status bit 29 stays reserved.
    .fast_v60(1'b1),
    .sdr_p0_req(p0_req), .sdr_p0_burst(p0_burst), .sdr_p0_addr(p0_addr),
    .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(core_p1_req), .sdr_p1_addr(core_p1_addr), .sdr_p1_dout(p1_dout),
    .sdr_p1_ack(p1_ack),
    .sdr_p2_req(core_p2_req), .sdr_p2_addr(core_p2_addr), .sdr_p2_dout(p2_dout),
    .sdr_p2_ack(p2_ack),
    .sdr_p3_req(p3_req), .sdr_p3_addr(p3_addr), .sdr_p3_dout(p3_dout), .sdr_p3_ack(p3_ack),
    .sdr_p4_req(p4_req), .sdr_p4_addr(p4_addr), .sdr_p4_dout(p4_dout), .sdr_p4_ack(p4_ack),
    .sdr_wave_wr_req(wave_sw_req), .sdr_wave_wr_addr(wave_sw_addr),
    .sdr_wave_wr_data(wave_sw_din), .sdr_wave_wr_be(wave_sw_be),
    .sdr_wave_wr_ack(wave_sw_ack),
    .sdr_p5_req(p5_req), .sdr_p5_addr(p5_addr), .sdr_p5_dout(p5_dout), .sdr_p5_ack(p5_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(fbw_buf), .fb_wr_x(fbw_x), .fb_wr_y(fbw_y),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_wr_busy(fbw_busy),
    .fb_wr_can_start(fbw_can_start),
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y), .fb_er_ack(fbe_ack),
    .fb_rd_req(fbr_req), .fb_rd_buf(fbr_buf),
    .fb_rd_y(fbr_y), .fb_rd_ack(fbr_ack),
    .fb_rd_x(fbr_x), .fb_rd_pix(fbr_pix),
    .fb_rd2_req(fbr2_req), .fb_rd2_buf(fbr2_buf),
    .fb_rd2_y(fbr2_y), .fb_rd2_ack(fbr2_ack), .fb_rd2_pix(fbr2_pix),
    .v25_prg_wr(1'b0), .v25_prg_waddr(16'd0), .v25_prg_wdata(8'd0),
    .eep_ld_wr(eep_wr), .eep_ld_addr(eep_waddr), .eep_ld_data(eep_wdata),
    .eep_rd_data(eep_rd_data), .eep_rd_addr(eep_rd_addr),
    .eep_upload(eep_upload), .eep_modified(eep_modified),
    .in_p1a(core_p1a), .in_p2a(core_p2a),
    .in_portc(portc), .in_svc12(core_svc12), .in_svc34(svc34),
    // Second cockpit (Player 2, joystick_1): P1_B bits 1:0 = P2 shift
    // up/down, P2_B bits 2:0 = P2 DJ/music + track <</>> (MAME
    // INPUT_PORTS_START(orunners) P1_B/P2_B).
    .in_p1b(core_p1b), .in_p2b(core_p2b),
    .in_portc_b(8'hff), .in_svc12_b(core_svc12_b), .in_svc34_b(svc34_b),
    .adc_ch(adc_ch),
    .ppi_pa(core_ppi_pa), .ppi_pb(core_ppi_pb), .ppi_pc(core_ppi_pc),
    .adc0_load(adc0_load),
    .rgb_a(rgb_a), .rgb_b(rgb_b),
    .ce_pix(ce_pix_core),
    .hs(core_hs), .vs(core_vs), .hb(core_hb), .vb(core_vb),
    .hcnt_o(core_hcnt), .vcnt_o(),
    .mode_416_active(mode_416_active),
    .audio_l(aud_l), .audio_r(aud_r),
    .out_lamps(),
    .out_steering_motors(core_steering_motors)
);

wire splitscreen_en = status[38];
s32_monitor_audio_route monitor_audio_route (
    .monitor_a(aud_l), .monitor_b(aud_r),
    .screen_sel(status[6]), .splitscreen(splitscreen_en),
    .audio_l(AUDIO_L), .audio_r(AUDIO_R)
);

//////////////////////////////   VIDEO   //////////////////////////////////////
wire [23:0] game_rgb = status[6] ? rgb_b : rgb_a;

// Splitscreen composer: mix0/mix1 already render both screens every native
// frame (see s32_core.sv fb_rd2_* comment) -- this places them side by side
// on a doubled-width output raster instead of the single-screen A/B toggle
// above. Bypassed entirely (comp_* unused) when splitscreen_en is low.
wire [23:0] comp_rgb;
wire        comp_ce_pix, comp_hs, comp_vs, comp_hb, comp_vb;
s32_splitscreen_composer u_splitscreen (
    .clk(clk_sys), .rst(video_reset), .mode_416_active(mode_416_active),
    .rgb_a(rgb_a), .rgb_b(rgb_b),
    .hcnt(core_hcnt),
    .ce_pix_native(ce_pix_core),
    .vblank_native(core_vb),
    .vsync_native(core_vs),
    .rgb_out(comp_rgb), .ce_pix_out(comp_ce_pix),
    .hsync_out(comp_hs), .vsync_out(comp_vs),
    .hblank_out(comp_hb), .vblank_out(comp_vb)
);

// disp_* is the signal set every downstream video stage should use: the
// composed dual-screen raster when Splitscreen is on, native single-screen
// timing otherwise.
wire [23:0] disp_rgb    = splitscreen_en ? comp_rgb    : game_rgb;
wire        disp_ce_pix = splitscreen_en ? comp_ce_pix : ce_pix_core;
wire        disp_hs     = splitscreen_en ? comp_hs     : core_hs;
wire        disp_vs     = splitscreen_en ? comp_vs     : core_vs;
wire        disp_hb     = splitscreen_en ? comp_hb     : core_hb;
wire        disp_vb     = splitscreen_en ? comp_vb     : core_vb;

wire [2:0] scandoubler_fx = status[5:3];
// Scandoubler Fx is a 3-bit field (None/CRT 25/50/75). VGA_SL takes the two
// low bits directly so None=0 and CRT 25/50/75 map to 1/2/3.
wire [2:0] scanline_level = scandoubler_fx;   // None=0, CRT 25/50/75 = 1/2/3
assign VGA_SL = scanline_level[1:0];

// Original = the 4:3 arcade monitor (MAME's default for both 320- and 416-wide
// System 32 modes); the old 13:7 square-pixel ratio stretched holo's 320 mode.
// Full Screen fills; [ARC1]/[ARC2] emit the framework custom-aspect encoding
// (ARY=0, ARX = menu index) instead of acting as 16:9 (audit R20 PF-2).
wire [1:0] aspect = status[2:1];
// Two 4:3 screens side by side is ~8:3 in the Original setting, but split
// mode still honours Full Screen and the framework's ARC1/ARC2 encodings.
// ARY=0 with ARX=1/2 is decoded by sys_top as ARC1/ARC2; 0:0 is Full Screen.
wire [11:0] aspect_arx = splitscreen_en
                       ? ((aspect == 0) ? 12'd8 :
                          (aspect == 1) ? 12'd0 : {10'd0, (aspect - 1'd1)})
                       : (aspect == 0) ? 12'd4 : {10'd0, (aspect - 1'd1)};
wire [11:0] aspect_ary = splitscreen_en ? ((aspect == 0) ? 12'd3 : 12'd0) :
                          (aspect == 0) ? 12'd3 : 12'd0;

// Keep the framework's integer-scaling size calculation available through the
// OSD while retaining the direct native RGB/sync/DE/CE path below.  SCALE=0 is
// normal output, 1 is vertical integer scaling, and 2 is horizontal+vertical
// integer scaling.
wire [2:0] scale_mode = (HDMI_WIDTH != 12'd0 && HDMI_HEIGHT != 12'd0)
                      ? {1'b0, status[28:27]} : 3'd0;
wire scale_de_unused;
video_freak s32_video_freak (
    .CLK_VIDEO (clk_sys),
    .CE_PIXEL  (disp_ce_pix),
    .VGA_VS    (disp_vs),
    .HDMI_WIDTH(HDMI_WIDTH),
    .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE    (scale_de_unused),
    .VIDEO_ARX (VIDEO_ARX),
    .VIDEO_ARY (VIDEO_ARY),
    .VGA_DE_IN(~(disp_hb | disp_vb)),
    .ARX       (aspect_arx),
    .ARY       (aspect_ary),
    .CROP_SIZE (12'd0),
    .CROP_OFF  (5'd0),
    .SCALE     (scale_mode)
);

// OutRunners uses the native game raster directly. CRT geometry adjustment
// is intentionally not part of this single-board production image.
assign CE_PIXEL = disp_ce_pix;
assign VGA_R  = disp_rgb[23:16];
assign VGA_G  = disp_rgb[15:8];
assign VGA_B  = disp_rgb[7:0];
assign VGA_HS = disp_hs;
assign VGA_VS = disp_vs;
assign VGA_DE = ~(disp_hb | disp_vb);

endmodule
