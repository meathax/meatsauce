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
wire [15:0] joystick_l_analog_0;
wire [15:0] joystick_l_analog_1;
wire [15:0] joystick_l_analog_2;
wire [15:0] joystick_r_analog_0;
wire  [7:0] paddle_0;
wire  [8:0] spinner_0;
wire        core_hs, core_vs;
wire        mode_416_active;
wire [24:0] ps2_mouse;
// The single universal RBF accepts every supported single-screen System 32
// descriptor. Runtime fields select the real V25 path for GA2/Arabian Fight;
// all other supported sets retain the standard-board peripherals and HLEs.
always @(*) begin
    active_board = board_desc;
`ifdef S32_PROFILE_STANDARD
    active_board.multi32          = 1'b0;
    // The universal image contains the real V25 QIP; descriptor bits select
    // it for GA2/Arabian Fight and retain HLE behavior for other variants.
    active_board.has_v25          = board_desc.has_v25;
    active_board.v25_table        = board_desc.v25_table;
`endif
end

// The current MRA descriptor inventory uses these three descriptor features
// only for Slip Stream, Rad Mobile, and Rad Rally respectively.
wire driving_controls_visible = active_board.digital_steering ||
                                 (active_board.digital_profile == DIGITAL_RADM) ||
                                 active_board.comm_link_hle;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
// s32_video changes the native horizontal size at a frame boundary.  Keep
// ascal's resolution-switch blackout enabled so scaled HDMI gets clean
// remeasurement frames; direct video and analog output do not use this gate.
assign HDMI_BLACKOUT = 1'b1;
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
`ifndef S32_SYSTEM32_ONLY
    "O[6],Screen (Multi32),A,B;",
`endif
    "O[7],Service Mode,Off,On;",
    // These controls are meaningful only on the three driving descriptors.
    "h3O[40:39],P1 Steering,Analog Stick,Paddle,Spinner,Spinner Reverse;",
    "h3O[42:41],Steering Sensitivity,Normal,Low,High;",
    // Analog sticks/USB lightguns remain the default positional source;
    // GunCon SNAC is an additional opt-in source for either player.
    "h0O[31:30],P1 Gun Input,Stick/USB Gun/Sinden,SNAC Port 1;",
    "h0o[1:0],P2 Gun Input,Stick/USB Gun/Sinden,SNAC Port 2;",
    // JTFRAME-compatible generic lightgun presentation controls.  status[8]
    // intentionally follows the MiSTer/JTFRAME Sinden-border convention;
    // status[9] is already the established CRT Adjust option in this core.
    "h0O[8],Sinden Borders,Off,On;",
    "h0O[34],Gun Crosshair,Off,On;",
    "h0O[37:36],Gun Sensitivity,Normal,High,Low,Lowest;",
    "h2O[35],Invert Trackball Y,Off,On;",
    // status[29] is RESERVED and intentionally unused.  It used to select
    // "V60 Fetch,Fast,PCB (Reset)"; the Fast instruction-fetch transport has
    // been removed and the core always uses the PCB fetch path.  The bit is
    // left allocated rather than reclaimed so every later option
    // (Scale = status[28:27], etc.) keeps its existing meaning for users with
    // saved settings.
    "-;",
    "O[9],CRT Adjust,Off,On;",
    "H1O[14:10],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H1O[21:15],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H1O[26:22],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "O[28:27],Scale,Normal,V-Integer,HV-Integer;",
    "-;",
    "R[0],Reset;",
    "J1,B1,B2,B3,B4,B5,B6,Start,Coin,Test,Service;",
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
// clk_ram, not clk_sys: the 320-wide dot clock is 7.5 clk_sys periods, so a
// uniform CE_PIXEL only exists in the 96.6 MHz domain (15 clocks per pixel;
// 416 mode is 12).  See s32_video_retime.sv (direct-video column-tearing fix).
assign CLK_VIDEO = clk_ram;

// Keep every game subsystem reset until a complete index-0 ROM transfer has
// drained into SDRAM. The loader itself is reset only by PLL startup so soft
// reset and NVRAM transfers do not forget that ROM is already resident.
wire video_reset = RESET | status[0] | buttons[1] | ~pll_locked;
wire reset = video_reset | ioctl_download | ~rom_loaded | ~sdram_ready_sys;

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
// Every MRA exposes Pause after Service, which is joystick bit 14. Either
// player's mapped control freezes the game while video continues scanning.
// Keep the NCOs running behind these gates so release cannot accumulate a
// burst of missed enables; s32_core also synchronizes the level into clk_v25.
wire pause = joystick_0[14] | joystick_1[14];
wire ce_cpu_run = ce_cpu & ~pause;
wire ce_z80_run = ce_z80 & ~pause;
wire ce_fm_run = ce_fm & ~pause;
wire ce_pcm_run = ce_pcm & ~pause;
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
wire [15:0] cpu_ce_inc = active_board.has_v25
                         ? (active_board.v25_table ? 16'd32768 : 16'd21848)
                         : (is_multi32 ? 16'd27127 : 16'd21848);
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
    .is_multi32(is_multi32), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm)
);

///////////////////////////////   HPS IO   ////////////////////////////////////

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),

    .buttons(buttons),
    .status(status),
    // H1/H2/H3 controls remain hidden until their descriptor/runtime gate.
    .status_menumask({12'd0, driving_controls_visible,
                      (active_board.prot_sel == PROT_SONIC), ~status[9],
                      active_board.gun_aim}),

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
    .joystick_r_analog_0(joystick_r_analog_0),
    .paddle_0(paddle_0),
    .paddle_1(),
    .spinner_0(spinner_0),
    .spinner_1(),
    .ps2_mouse(ps2_mouse)
);

// hps_io toggles ps2_mouse[24] for each host report.  Decode that toggle once
// in the clk_sys domain so the P1 generic lightgun and Sonic trackball see a
// one-clock event.  P2 deliberately receives no mouse stream because MiSTer
// exposes one shared PS/2 mouse packet path.
reg ps2_mouse_event_d;
wire ps2_mouse_strobe = ps2_mouse[24] ^ ps2_mouse_event_d;
// JTFRAME's MiSTer target sign-extends the PS/2 report with flags[4]/[5]
// before its `cv` helper converts the 9-bit packet to an 8-bit two's-
// complement delta (an arithmetic one-bit scale reduction).  Preserve that
// exact packet interpretation instead of treating the raw byte's bit 7 as a
// standalone sign.
wire signed [8:0] ps2_mouse_dx9 = $signed({ps2_mouse[4], ps2_mouse[15:8]});
wire signed [8:0] ps2_mouse_dy9 = $signed({ps2_mouse[5], ps2_mouse[23:16]});
wire signed [8:0] ps2_mouse_dx_jt9 = ps2_mouse_dx9 >>> 1;
wire signed [8:0] ps2_mouse_dy_jt9 = ps2_mouse_dy9 >>> 1;
wire        [7:0] ps2_mouse_dx_jt = ps2_mouse_dx_jt9[7:0];
wire        [7:0] ps2_mouse_dy_jt = ps2_mouse_dy_jt9[7:0];
always @(posedge clk_sys) begin
    ps2_mouse_event_d <= ps2_mouse[24];
end

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
wire        v25_wr;
wire [15:0] v25_waddr;
wire  [7:0] v25_wdata;
wire        eep_wr;
wire  [5:0] eep_waddr;
wire [15:0] eep_wdata;

s32_rom_loader #(.WIDE(1), .CLEAR_RF_WAVE(1)) loader (
    .clk(clk_sys), .rst(~pll_locked),
    .mem_ready(sdram_ready_sys),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index[7:0]),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .board_desc(board_desc),
    .sdr_wr_req(sw_req), .sdr_wr_addr(sw_addr), .sdr_wr_din(sw_din),
    .sdr_wr_be(sw_be), .sdr_wr_ack(sw_ack),
    .v25_wr(v25_wr), .v25_waddr(v25_waddr), .v25_wdata(v25_wdata),
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
wire        fbw_start, fbw_valid, fbw_end, fbw_shadow, fbw_busy;
wire        fbe_req, fbe_ack, fbr_req, fbr_ack;
wire  [1:0] fbw_buf, fbe_buf, fbr_buf;
wire  [8:0] fbw_x, fbr_x;
wire  [7:0] fbw_y, fbe_y, fbr_y;
wire [15:0] fbw_pix, fbr_pix;
s32_fb_if fb (
    .clk(clk_ram), .rst(reset),
    .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
    .wr_start(fbw_start), .wr_buf(fbw_buf), .wr_x(fbw_x), .wr_y(fbw_y),
    .wr_valid(fbw_valid), .wr_pix(fbw_pix), .wr_end(fbw_end),
    .wr_shadow(fbw_shadow), .wr_busy(fbw_busy),
    .er_req(fbe_req), .er_buf(fbe_buf), .er_y(fbe_y), .er_ack(fbe_ack),
    .rd_req(fbr_req), .rd_buf(fbr_buf), .rd_y(fbr_y), .rd_ack(fbr_ack),
    .rd_x(fbr_x), .rd_pix(fbr_pix)
);

//////////////////////////////   INPUTS   /////////////////////////////////////
// MiSTer logical joystick bits are directions [3:0], six arcade buttons
// [9:4], Start [10], Coin [11].  GA2's 315-5296 player ports follow MAME:
// {left,right,up,down,unused,button3,button2,button1}, active low.
function automatic [7:0] p_dig(input [31:0] j);
    p_dig = ~{j[1], j[0], j[3], j[2], 1'b0, j[6], j[5], j[4]};
endfunction
wire [7:0] p1a_dig = p_dig(joystick_0);
// Air Rescue's documented main-board port keeps only P1 BUTTON1/2.
// The reduced profile has no local P2 port or start inputs.
wire arescue_inputs = (active_board.prot_sel == PROT_ARESCUE) &&
                      active_board.dual_pcb;
wire [7:0] arescue_p1a = {6'h3f, p1a_dig[1:0]};
wire [7:0] arescue_p2a = 8'hff;
// Rad Mobile leaves raw player-port bit 0 unused and places its two cabinet
// switches, Light and Wiper, on bits 1/2.  Drive them from B3/B4 rather than
// B1/B2: B1/B2 are the shared digital accelerator/brake fallbacks that feed
// the MSM6253 channels for every driving cabinet, so sourcing Light/Wiper from
// them made one button do two unrelated things at once.  Rad Mobile now offers
// the same assignable Accelerate/Brake pair as Rad Rally and Slip Stream.
wire [7:0] radm_p1a = {p1a_dig[7:3], ~joystick_0[7],
                        ~joystick_0[6], 1'b1};
wire [7:0] p2a_dig = p_dig(joystick_1);

// Generic JTFRAME-compatible gun sources.  MiSTer's joystick direction bits
// are {right,left,down,up} in the HPS word; the adapter consumes JTFRAME's
// {down,up,left,right} game_joy order.  The source is instantiated for both
// players even though the shared PS/2 packet stream is assigned to P1.
wire [8:0] lightgun_width  = mode_416_active ? 9'd416 : 9'd320;
wire [8:0] lightgun_height = 9'd224;
wire [3:0] lightgun_joy_p1 = {joystick_0[2], joystick_0[3],
                               joystick_0[1], joystick_0[0]};
wire [3:0] lightgun_joy_p2 = {joystick_1[2], joystick_1[3],
                               joystick_1[1], joystick_1[0]};
wire [3:0] lightgun_joy_p3 = {joystick_2[2], joystick_2[3],
                               joystick_2[1], joystick_2[0]};
wire [8:0] generic_gun_p1_x, generic_gun_p1_y;
wire [8:0] generic_gun_p2_x, generic_gun_p2_y;
wire [7:0] generic_adc_p1_x, generic_adc_p1_y;
wire [7:0] generic_adc_p2_x, generic_adc_p2_y;
wire       generic_gun_p1_strobe, generic_gun_p2_strobe;

s32_lightgun #(.DEFAULT_WIDTH(320), .DEFAULT_HEIGHT(224)) generic_lightgun_p1 (
    .clk          (clk_sys),
    .rst          (reset),
    .vs           (core_vs),
    .screen_width (lightgun_width),
    .screen_height(lightgun_height),
    .rotate       (2'b00),
    .sensitivity  (status[37:36]),
    .joyana       (joystick_l_analog_0),
    .joy_dir      (lightgun_joy_p1),
    .mouse_dx     (ps2_mouse_dx_jt),
    .mouse_dy     (ps2_mouse_dy_jt),
    .mouse_strobe (ps2_mouse_strobe),
    .gun_x        (generic_gun_p1_x),
    .gun_y        (generic_gun_p1_y),
    .adc_x        (generic_adc_p1_x),
    .adc_y        (generic_adc_p1_y),
    .gun_strobe   (generic_gun_p1_strobe)
);

s32_lightgun #(.DEFAULT_WIDTH(320), .DEFAULT_HEIGHT(224)) generic_lightgun_p2 (
    .clk          (clk_sys),
    .rst          (reset),
    .vs           (core_vs),
    .screen_width (lightgun_width),
    .screen_height(lightgun_height),
    .rotate       (2'b00),
    .sensitivity  (status[37:36]),
    .joyana       (joystick_l_analog_1),
    .joy_dir      (lightgun_joy_p2),
    .mouse_dx     (8'd0),
    .mouse_dy     (8'd0),
    .mouse_strobe (1'b0),
    .gun_x        (generic_gun_p2_x),
    .gun_y        (generic_gun_p2_y),
    .adc_x        (generic_adc_p2_x),
    .adc_y        (generic_adc_p2_y),
    .gun_strobe   (generic_gun_p2_strobe)
);
// Rad Rally and Slip Stream expose a single cabinet Gear Change toggle, not a
// momentary switch or four-position encoding.  Keep this semantic independent
// from Rad Rally's separate EPR-14084 communication-board selector.
reg radr_gear = 1'b0;
reg radr_gear_btn_d = 1'b0;
always @(posedge clk_sys) begin
    if (reset || !active_board.gear_toggle) begin
        radr_gear <= 1'b0;
        radr_gear_btn_d <= joystick_0[6];
    end
    else begin
        radr_gear_btn_d <= joystick_0[6];
        if (joystick_0[6] && !radr_gear_btn_d)
            radr_gear <= ~radr_gear;
    end
end
// Only bit 0 is wired on these cabinets.  Passing B3 through on bit 2 also
// presents the Gear Change press as a second game input.
wire [7:0] gear_toggle_p1a = {7'h7f, ~radr_gear};
// Dark Edge leaves raw player-port bit 0 unused and places its first two
// buttons on bits 1/2.  Adapt MiSTer's logical B1/B2 here; the remaining
// three buttons are on the PPI below.  Select from the existing descriptor so
// this remains a shared universal-profile implementation, not a game build.
wire [7:0] darkedge_p1a = {p1a_dig[7:4], 1'b1,
                           ~joystick_0[5], ~joystick_0[4], 1'b1};
wire [7:0] darkedge_p2a = {p2a_dig[7:4], 1'b1,
                           ~joystick_1[5], ~joystick_1[4], 1'b1};

// The System11 Point Blank 2 transport is a Jurassic Park-only option.
// Alien 3 is identified by the gun descriptor's distinct coin_swap cabinet
// wiring and must remain a pure analog-stick/USB-lightgun path: SNAC polling,
// coordinate overrides, buttons, coins, and USER_OUT activity are all held
// inactive for that title regardless of saved OSD status bits.
wire gun_snac_supported = active_board.gun_aim && !active_board.coin_swap;
wire p1_snac_mode = gun_snac_supported && (status[31:30] == 2'b01);
wire p2_snac_mode = gun_snac_supported && (status[33:32] == 2'b01);
wire snac_enabled = p1_snac_mode | p2_snac_mode;
wire snac_select1_n, snac_select2_n, snac_command, snac_serial_clk;
wire snac_p1_connected, snac_p2_connected;
wire snac_p1_sample_valid, snac_p2_sample_valid;
wire [7:0] snac_p1_device_id, snac_p2_device_id;
wire [15:0] snac_p1_buttons, snac_p2_buttons;
wire [8:0] snac_p1_raw_x, snac_p1_raw_y, snac_p2_raw_x, snac_p2_raw_y;
wire snac_p1_gun_aim_valid, snac_p2_gun_aim_valid;
wire [9:0] snac_p1_gun_x, snac_p2_gun_x;
wire [7:0] snac_p1_gun_y, snac_p2_gun_y;
// Match the donor's GunCon identification gate: a valid PSX response is not
// enough to claim a positional gun until the returned device ID is 0x63.
// Button routing intentionally uses this gate, not optical-coordinate range;
// a real gun can report an off-screen aim while its trigger/Cross remain live.
wire snac_p1_gun = p1_snac_mode && snac_p1_connected &&
                   (snac_p1_device_id == 8'h63);
wire snac_p2_gun = p2_snac_mode && snac_p2_connected &&
                   (snac_p2_device_id == 8'h63);

s32_guncon_snac guncon_snac (
    .clk(clk_sys), .rst(reset),
    .enable_p1(p1_snac_mode), .enable_p2(p2_snac_mode),
    .frame_sync(VGA_VS),
    .data_in(USER_IN[4]), .ack_in(USER_IN[3]),
    .select1_n(snac_select1_n), .select2_n(snac_select2_n),
    .command(snac_command), .serial_clk(snac_serial_clk),
    .p1_connected(snac_p1_connected), .p2_connected(snac_p2_connected),
    .p1_sample_valid(snac_p1_sample_valid),
    .p2_sample_valid(snac_p2_sample_valid),
    .p1_device_id(snac_p1_device_id), .p2_device_id(snac_p2_device_id),
    .p1_buttons(snac_p1_buttons), .p2_buttons(snac_p2_buttons),
    .p1_raw_x(snac_p1_raw_x), .p1_raw_y(snac_p1_raw_y),
    .p2_raw_x(snac_p2_raw_x), .p2_raw_y(snac_p2_raw_y),
    .p1_gun_aim_valid(snac_p1_gun_aim_valid),
    .p2_gun_aim_valid(snac_p2_gun_aim_valid),
    .p1_gun_x(snac_p1_gun_x), .p2_gun_x(snac_p2_gun_x),
    .p1_gun_y(snac_p1_gun_y), .p2_gun_y(snac_p2_gun_y)
);

// USER_OUT follows the standard GunCon SNAC wiring used by the donor:
// bit0=P2 select, bit1=P1 select, bit2=COMMAND, bit5=serial clock, and bit6
//=composite sync. CSYNC is asserted only after a connected GunCon is
// identified, matching the Point Blank 2 integration; a generic SNAC device
// on an accidentally selected port sees the idle-high line. Keep the bus
// idle-high unless SNAC is explicitly selected.
assign USER_OUT = snac_enabled ?
                  {(snac_p1_gun || snac_p2_gun) ? ~(VGA_HS ^ VGA_VS) : 1'b1,
                   snac_serial_clk, 2'b11, snac_command,
                   snac_select1_n, snac_select2_n} : 7'h7f;

wire [7:0] host_gun_p1_x = generic_adc_p1_x;
wire [7:0] host_gun_p1_y = generic_adc_p1_y;
wire [7:0] host_gun_p2_x = generic_adc_p2_x;
wire [7:0] host_gun_p2_y = generic_adc_p2_y;
// Alien 3 and Jurassic Park share the generic JTFRAME-compatible absolute
// host path.  GunCon SNAC retains its independent calibrated-coordinate
// override and remains descriptor-gated to Jurassic Park.
wire [7:0] gun_adc_p1_x = (p1_snac_mode && snac_p1_gun_aim_valid)
                           ? snac_p1_gun_x[9:2] : host_gun_p1_x;
wire [7:0] gun_adc_p1_y = (p1_snac_mode && snac_p1_gun_aim_valid)
                           ? snac_p1_gun_y : host_gun_p1_y;
wire [7:0] gun_adc_p2_x = (p2_snac_mode && snac_p2_gun_aim_valid)
                           ? snac_p2_gun_x[9:2] : host_gun_p2_x;
wire [7:0] gun_adc_p2_y = (p2_snac_mode && snac_p2_gun_aim_valid)
                           ? snac_p2_gun_y : host_gun_p2_y;
wire jpark_gun_gain_enable = active_board.gun_aim && !active_board.coin_swap;
wire [7:0] game_gun_p1_x, game_gun_p1_y;
wire [7:0] game_gun_p2_x, game_gun_p2_y;
s32_jpark_gun_gain jpark_gun_gain (
    .enable  (jpark_gun_gain_enable),
    .p1_x_in (gun_adc_p1_x), .p1_y_in (gun_adc_p1_y),
    .p2_x_in (gun_adc_p2_x), .p2_y_in (gun_adc_p2_y),
    .p1_x_out(game_gun_p1_x), .p1_y_out(game_gun_p1_y),
    .p2_x_out(game_gun_p2_x), .p2_y_out(game_gun_p2_y)
);
wire gun_snac_trigger_p1 = snac_p1_gun && snac_p1_buttons[13];
wire gun_snac_trigger_p2 = snac_p2_gun && snac_p2_buttons[13];
wire gun_snac_button2_p1 = snac_p1_gun && snac_p1_buttons[12];
wire gun_snac_button2_p2 = snac_p2_gun && snac_p2_buttons[12];
wire gun_snac_coin_p1 = snac_p1_gun && snac_p1_buttons[14];
wire gun_snac_coin_p2 = snac_p2_gun && snac_p2_buttons[14];

// The shared HPS mouse's left button is the generic USB-lightgun trigger.
// Once a valid GunCon is identified its trigger remains authoritative; a
// selected-but-disconnected SNAC port still falls back to the host path.
wire generic_mouse_trigger_p1 = active_board.gun_aim &&
                                !snac_p1_gun && ps2_mouse[0];

// Convert the normalized GunCon coordinate to the same native raster space as
// the generic adapter for the optional core-side crosshair.
function automatic [8:0] lightgun_adc_to_screen(
    input [7:0] adc,
    input [8:0] dimension
);
    reg [16:0] product;
    begin
        product = adc * dimension;
        lightgun_adc_to_screen = product[16:8];
    end
endfunction

wire [8:0] display_gun_p1_x =
    (p1_snac_mode && snac_p1_gun_aim_valid)
      ? lightgun_adc_to_screen(snac_p1_gun_x[9:2], lightgun_width)
      : generic_gun_p1_x;
wire [8:0] display_gun_p1_y =
    (p1_snac_mode && snac_p1_gun_aim_valid)
      ? lightgun_adc_to_screen(snac_p1_gun_y, lightgun_height)
      : generic_gun_p1_y;
wire [8:0] display_gun_p2_x =
    (p2_snac_mode && snac_p2_gun_aim_valid)
      ? lightgun_adc_to_screen(snac_p2_gun_x[9:2], lightgun_width)
      : generic_gun_p2_x;
wire [8:0] display_gun_p2_y =
    (p2_snac_mode && snac_p2_gun_aim_valid)
      ? lightgun_adc_to_screen(snac_p2_gun_y, lightgun_height)
      : generic_gun_p2_y;

// GunCon trigger is the same active-low P1_A bit used by MRA button A. Keep
// ordinary MiSTer A/B controls additive when SNAC is connected. Alien3's
// second live P1_A/P2_A bit is the gun's attached Button, so GunCon A (the
// donor's Start-side auxiliary button) is mapped there for that descriptor.
// Alien3 cabinet Start is still retained as the trigger alias from its special
// coin/trigger wiring; Jurassic Park does not use that alias.
wire gun_p1_button1 = p1a_dig[0] & ~(snac_p1_gun && gun_snac_trigger_p1)
                                  & ~generic_mouse_trigger_p1;
wire gun_p2_button1 = p2a_dig[0] & ~(snac_p2_gun && gun_snac_trigger_p2);
wire gun_p1_button2 = p1a_dig[1] & ~(snac_p1_gun && gun_snac_button2_p1);
wire gun_p2_button2 = p2a_dig[1] & ~(snac_p2_gun && gun_snac_button2_p2);
wire [7:0] gun_p1a = {p1a_dig[7:2], gun_p1_button2, gun_p1_button1};
wire [7:0] gun_p2a = {p2a_dig[7:2], gun_p2_button2, gun_p2_button1};
// MAME's Alien3 P1_A/P2_A masks leave only BUTTON1/2 (the trigger and the
// second cabinet button) connected; direction and BUTTON3 bits are physically
// unused. Start remains a convenience alias for the trigger bit.
wire [7:0] alien3_p1a = {6'h3f, gun_p1a[1], gun_p1a[0] & ~joystick_0[10]};
wire [7:0] alien3_p2a = {6'h3f, gun_p2a[1], gun_p2a[0] & ~joystick_1[10]};
// Jurassic Park's port mask leaves only BUTTON1 (Shoot) connected.
wire [7:0] jpark_p1a = {7'h7f, gun_p1a[0]};
wire [7:0] jpark_p2a = {7'h7f, gun_p2a[0]};
wire [7:0] core_p1a = arescue_inputs ? arescue_p1a :
                       active_board.gun_aim ?
                       (active_board.coin_swap ? alien3_p1a : jpark_p1a) :
                       (active_board.prot_sel == PROT_DARKEDGE) ? darkedge_p1a :
                       active_board.gear_toggle ? gear_toggle_p1a :
                       (active_board.digital_profile == DIGITAL_RADM) ? radm_p1a :
                       p1a_dig;
wire [7:0] core_p2a = arescue_inputs ? arescue_p2a :
                       active_board.gun_aim ?
                       (active_board.coin_swap ? alien3_p2a : jpark_p2a) :
                       (active_board.prot_sel == PROT_DARKEDGE) ? darkedge_p2a :
                       p2a_dig;

wire [7:0] adc_ch [0:7];
// MiSTer reports each analog-stick axis as signed -128..+127. Split the right
// stick's vertical axis into independent, released-at-zero pedals: up is
// accelerator and down is brake. Saturating magnitude 127/128 to 255 lets
// both directions reach the cabinet ADC endpoint without a multiplier.
wire [7:0] driving_wheel;
wire [7:0] driving_accel;
wire [7:0] driving_brake;
wire       wheel_load_ch0;
wire [1:0] driving_wheel_source = driving_controls_visible
                                 ? status[40:39] : 2'd0;
wire [1:0] driving_steering_sensitivity = driving_controls_visible
                                         ? status[42:41] : 2'd0;
s32_driving_controls driving_controls (
    .clk(clk_sys),
    .rst(reset),
    .wheel_sample(wheel_load_ch0),
    .capture_wheel((active_board.digital_profile == DIGITAL_RADM) ||
                   active_board.digital_steering),
    .left_x(joystick_l_analog_0[7:0]),
    .paddle(paddle_0),
    .spinner(spinner_0),
    .mouse(ps2_mouse),
    .wheel_source(driving_wheel_source),
    .steering_sensitivity(driving_steering_sensitivity),
    .right_y(joystick_r_analog_0[15:8]),
    .digital_accel(joystick_0[4]),
    .digital_brake(joystick_0[5]),
    .digital_left(joystick_0[1]),
    .digital_right(joystick_0[0]),
    .wheel(driving_wheel),
    .accel(driving_accel),
    .brake(driving_brake)
);
// Driving cabinets wire the wheel, accelerator, and brake to the first three
// MSM6253 channels. MiSTer's left-stick X is the wheel; right-stick up/down
// are the analog pedals, with A/B as full-scale digital fallbacks. The driving
// OSD selects the absolute paddle or relative spinner/mouse source; Rad Mobile
// and descriptor-selected Slip Stream profiles also map the MiSTer left/right
// D-pad bits to full-scale wheel endpoints. The MSM6253 samples the live value
// on its accepted channel-load write.
wire analog_all_ff = active_board.analog_profile == ANALOG_ALL_FF;
// MAME marks Air Rescue ANALOG1 PORT_REVERSE, ANALOG2 normal, and
// ANALOG3 centered. Its flight stick is P1's left analog stick: X is the
// low byte and Y the high byte of joystick_l_analog_0. Keep this source direct
// for the Air Rescue ADC path; the shared positional-gun adapter remains for
// gun titles. The complement preserves the documented X polarity.
wire [7:0] arescue_stick_x = joystick_l_analog_0[7:0] + 8'h80;
wire [7:0] arescue_stick_y = joystick_l_analog_0[15:8] + 8'h80;
wire [7:0] arescue_analog_z = joystick_r_analog_0[15:8] + 8'h80;
assign adc_ch[0] = analog_all_ff ? 8'hff :
                   arescue_inputs ? ~arescue_stick_x :
                   active_board.gun_aim ? game_gun_p1_x : driving_wheel;
assign adc_ch[1] = analog_all_ff ? 8'hff :
                   arescue_inputs ? arescue_stick_y :
                   active_board.gun_aim ? game_gun_p1_y : driving_accel;
assign adc_ch[2] = analog_all_ff ? 8'hff :
                   arescue_inputs ? arescue_analog_z :
                   active_board.gun_aim ? game_gun_p2_x : driving_brake;
assign adc_ch[3] = active_board.gun_aim ? game_gun_p2_y : 8'hff;
assign adc_ch[4] = 8'h80;
assign adc_ch[5] = 8'h80;
assign adc_ch[6] = 8'h80;
assign adc_ch[7] = 8'h80;
// MAME system32_generic: port C is unused; port E/SERVICE12 is
// {unknown[7:6], start2, start1, coin2, coin1, test, service}, active low.
// Test = the OSD "Service Mode" toggle OR the mappable Test button (j12);
// Service (coin-service credit) = the mappable Service button (j13).
wire [7:0] portc = 8'hff;
wire test_btn = status[7] | joystick_0[12] | joystick_1[12];
wire svc_btn  = joystick_0[13] | joystick_1[13];
wire [7:0] svc12_generic = ~{
                      2'b00,
                      joystick_1[10] | (snac_p2_gun && snac_p2_buttons[12]),
                      joystick_0[10] | (snac_p1_gun && snac_p1_buttons[12]),
                      joystick_1[11] | gun_snac_coin_p2,
                      joystick_0[11] | gun_snac_coin_p1,
                      test_btn, svc_btn};
// Alien3 routes only the two cabinet coin switches through SERVICE12: the
// generic Start fields are physically absent on that gun cabinet. SNAC
// GunCon B/Cross is the second coin source, matching the Point Blank donor.
wire [7:0] svc12_alien3 = ~{
                     2'b00, 2'b00,
                     joystick_0[11] | gun_snac_coin_p1,
                     joystick_1[11] | gun_snac_coin_p2,
                     test_btn, svc_btn};
// Air Rescue leaves START1/START2 physically unused; only the two coin
// inputs and the service/test lines remain in SERVICE12.
wire [7:0] svc12_arescue = ~{
                      2'b00, 2'b00,
                      joystick_1[11], joystick_0[11],
                      test_btn, svc_btn};
wire [7:0] svc12 = arescue_inputs ? svc12_arescue :
                   active_board.coin_swap ? svc12_alien3 : svc12_generic;
// Port F/SERVICE34: bits 3:0 = DIP SW1:1-4 (Off), bit4 = PCB Push SW1
// (Service), bit5 = PCB Push SW2 (Test), bit6 unknown; bit7 is replaced by the
// EEPROM DO line inside s32_core.  Some games poll the PCB push switches
// rather than the cabinet Test line, so drive them from the same buttons —
// physically equivalent to pressing the matching switch on the board.
// Air Rescue masks SERVICE34 bits 4/5 as unused; EEPROM DO is inserted by s32_core.
wire [7:0] svc34_arescue = 8'hff;
wire [7:0] svc34 = arescue_inputs ? svc34_arescue :
                   ~{2'b00, test_btn, svc_btn, 4'b0000};
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
wire [7:0] ga2_ppi_pc = ~{4'b0, joystick_0[11], joystick_1[11],
                          joystick_3[10], joystick_2[10]};
// Burning Rival and Dark Edge use the physical i8255 differently from GA2:
// A/C are pulled high and B carries the upper action buttons.  Their first
// three action buttons remain on the descriptor-selected player A ports.
wire [7:0] brival_ppi_pb = {~joystick_0[9], 1'b1,
                            ~joystick_0[7], ~joystick_0[8], 1'b1,
                            ~joystick_1[9], ~joystick_1[8], ~joystick_1[7]};
wire [7:0] darkedge_ppi_pb = {~joystick_0[8], 1'b1,
                              ~joystick_0[6], ~joystick_0[7], 1'b1,
                              ~joystick_1[8], ~joystick_1[7], ~joystick_1[6]};
wire brival_inputs = active_board.prot_sel == PROT_BRIVAL;
wire darkedge_inputs = active_board.prot_sel == PROT_DARKEDGE;
wire [7:0] core_ppi_pa = (brival_inputs || darkedge_inputs) ? 8'hff :
                          p_dig(joystick_2);
    wire [7:0] core_ppi_pb = brival_inputs ? brival_ppi_pb :
                              darkedge_inputs ? darkedge_ppi_pb : p_dig(joystick_3);
    wire [7:0] core_ppi_pc = (brival_inputs || darkedge_inputs) ? 8'hff :
                              ga2_ppi_pc;
    wire trackball_y_invert = (active_board.prot_sel == PROT_SONIC) && status[35];

//////////////////////////////   CORE   ///////////////////////////////////////
wire [23:0] rgb_a, rgb_b;
wire ce_pix_core, core_hb, core_vb;
wire signed [15:0] aud_l, aud_r;
s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram),
`ifdef S32_UNIVERSAL
    .clk_v25(clk_v25),
`endif
    .rst(reset), .video_rst(video_reset),
    .board(active_board),
    .ce_cpu(ce_cpu_run), .ce_z80(ce_z80_run),
    .ce_fm(ce_fm_run), .ce_pcm(ce_pcm_run),
    .pause(pause),
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
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y), .fb_er_ack(fbe_ack),
    .fb_rd_req(fbr_req), .fb_rd_buf(fbr_buf),
    .fb_rd_y(fbr_y), .fb_rd_ack(fbr_ack),
    .fb_rd_x(fbr_x), .fb_rd_pix(fbr_pix),
    .v25_prg_wr(v25_wr), .v25_prg_waddr(v25_waddr), .v25_prg_wdata(v25_wdata),
    .eep_ld_wr(eep_wr), .eep_ld_addr(eep_waddr), .eep_ld_data(eep_wdata),
    .eep_rd_data(eep_rd_data), .eep_rd_addr(eep_rd_addr),
    .eep_upload(eep_upload), .eep_modified(eep_modified),
    .in_p1a(core_p1a), .in_p2a(core_p2a),
    .in_portc(portc), .in_svc12(svc12), .in_svc34(svc34),
    .in_p1b(p_dig(joystick_2)), .in_p2b(p_dig(joystick_3)),
    .in_portc_b(8'hff), .in_svc12_b(8'hff), .in_svc34_b(8'hff),
    .adc_ch(adc_ch),
    .track_p1_x(joystick_l_analog_0[7:0]), .track_p1_y(joystick_l_analog_0[15:8]),
    .track_p2_x(joystick_l_analog_1[7:0]), .track_p2_y(joystick_l_analog_1[15:8]),
    .track_p3_x(joystick_l_analog_2[7:0]), .track_p3_y(joystick_l_analog_2[15:8]),
    .track_p1_dir(lightgun_joy_p1), .track_p2_dir(lightgun_joy_p2),
    .track_p3_dir(lightgun_joy_p3),
    .track_mouse_dx(ps2_mouse_dx9), .track_mouse_dy(ps2_mouse_dy9),
    .track_mouse_strobe(ps2_mouse_strobe),
    .trackball_y_invert(trackball_y_invert),
    .ppi_pa(core_ppi_pa), .ppi_pb(core_ppi_pb), .ppi_pc(core_ppi_pc),
    .rgb_a(rgb_a), .rgb_b(rgb_b),
    .ce_pix(ce_pix_core),
    .hs(core_hs), .vs(core_vs), .hb(core_hb), .vb(core_vb),
    .mode_416_active(mode_416_active),
    .audio_l(aud_l), .audio_r(aud_r),
    .out_lamps(),
    .wheel_load_ch0(wheel_load_ch0)
);

// Do not leave a held DAC sample audible while the game clocks are frozen.
assign AUDIO_L = pause ? 16'sd0 : aud_l;
assign AUDIO_R = pause ? 16'sd0 : aud_r;

//////////////////////////////   VIDEO   //////////////////////////////////////
`ifdef S32_SYSTEM32_ONLY
wire [23:0] game_rgb = rgb_a;
`else
wire [23:0] game_rgb = status[6] ? rgb_b : rgb_a;
`endif
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
wire [11:0] aspect_arx = (aspect == 0) ? 12'd4 : {10'd0, (aspect - 1'd1)};
wire [11:0] aspect_ary = (aspect == 0) ? 12'd3 : 12'd0;

// Keep the framework's integer-scaling size calculation available through the
// OSD while retaining the direct native RGB/sync/DE/CE path below.  SCALE=0 is
// normal output, 1 is vertical integer scaling, and 2 is horizontal+vertical
// integer scaling.
wire [2:0] scale_mode = (HDMI_WIDTH != 12'd0 && HDMI_HEIGHT != 12'd0)
                      ? {1'b0, status[28:27]} : 3'd0;
wire scale_de_unused;
video_freak s32_video_freak (
    .CLK_VIDEO (clk_sys),
    .CE_PIXEL  (ce_pix_core),
    .VGA_VS    (core_vs),
    .HDMI_WIDTH(HDMI_WIDTH),
    .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE    (scale_de_unused),
    .VIDEO_ARX (VIDEO_ARX),
    .VIDEO_ARY (VIDEO_ARY),
    .VGA_DE_IN(~(core_hb | core_vb)),
    .ARX       (aspect_arx),
    .ARY       (aspect_ary),
    .CROP_SIZE (12'd0),
    .CROP_OFF  (5'd0),
    .SCALE     (scale_mode)
);

//////////////////////////// CRT ADJUST /////////////////////////////////////
// Core-side integration of rmonic79/MiSTer-CRT-Adjust. The feature is gated
// off when the framework HDMI scaler or CRT scandoubler is active: this keeps
// the native CE cadence at the shared output boundary in those modes, where a
// stretched read cadence can otherwise create a malformed HDMI raster.
wire              crt_on     = status[9];
wire signed [4:0] crt_hsize  = $signed(status[14:10]);
wire        [6:0] crt_hpos   = status[21:15];
wire signed [5:0] crt_vshift = $signed(status[26:22]);
wire hdmi_output_active = (HDMI_WIDTH != 12'd0) || (HDMI_HEIGHT != 12'd0);
wire crt_adjust_active = crt_on && !hdmi_output_active
                       && (scandoubler_fx == 3'd0);

// System 32's active window is line-anchored at x=0. HSync-shift mode avoids
// moving the content out of the line buffer at the extreme H-Position values.
// The OSD list has 97 ordinal choices: 0..48, then -48..-1. Decode that
// ordinal explicitly; it is not a native 7-bit two's-complement field. The
// module is sized for the 416-wide total; in 320-wide mode its 512-sample
// HSync shifter needs the 512-410 total-line correction for negative offsets.
wire signed [8:0] crt_hpos_native = (crt_hpos <= 7'd48)
    ? $signed({2'b00, crt_hpos})
    : $signed({2'b00, crt_hpos}) - 9'sd97;
wire signed [8:0] crt_hpos_module = (!mode_416_active && crt_hpos_native[8])
    ? crt_hpos_native - 9'sd102 : crt_hpos_native;

wire [7:0] crt_r, crt_g, crt_b;
wire crt_hs, crt_vs, crt_hb, crt_vb, crt_hs_ref;

// clk_sys/pixel is 6 clocks (24 quarter-cycles) in 416 mode and 7.5 clocks
// (30 quarter-cycles on average) in 320 mode. The quarter-cycle read period
// preserves native width at hsize=0 and gives fine, uniform H-Size steps.
reg [7:0] crt_rd_acc;
reg crt_hs_ref_d;
wire [7:0] crt_base_period = mode_416_active ? 8'd24 : 8'd30;
wire [7:0] crt_rd_period = crt_base_period + {{3{crt_hsize[4]}}, crt_hsize};
wire crt_rd_tick = (crt_rd_acc + 8'd4) >= {1'b0, crt_rd_period};
wire crt_hs_ref_rise = crt_hs_ref & ~crt_hs_ref_d;
always @(posedge clk_sys) begin
    if (video_reset) begin
        crt_rd_acc   <= 8'd0;
        crt_hs_ref_d <= 1'b0;
    end
    else begin
        crt_hs_ref_d <= crt_hs_ref;
        if (crt_hs_ref_rise)
            crt_rd_acc <= 8'd0;
        else if (crt_rd_tick)
            crt_rd_acc <= crt_rd_acc + 8'd4 - {1'b0, crt_rd_period};
        else
            crt_rd_acc <= crt_rd_acc + 8'd4;
    end
end
wire crt_rd_ce = crt_adjust_active ? crt_rd_tick : ce_pix_core;

crt_adjust #(
    .VTOTAL   (262),
    .HTOTAL   (512),
    .HPOS_MODE(0),
    .AW        (10)
) u_crt_adjust (
    .clk       (clk_sys),
    .pxl_cen   (ce_pix_core),
    .pxl2_cen  (crt_rd_ce),
    .active    (crt_adjust_active),
    .hsize     (crt_hsize),
    .hoffset   (crt_hpos_module),
    .voffset   (crt_vshift),
    .r_in      (game_rgb[23:16]),
    .g_in      (game_rgb[15:8]),
    .b_in      (game_rgb[7:0]),
    .hs_in     (core_hs),
    .vs_in     (core_vs),
    .hb_in     (core_hb | core_vb),
    .vb_in     (core_vb),
    .r_out     (crt_r),
    .g_out     (crt_g),
    .b_out     (crt_b),
    .hs_out    (crt_hs),
    .vs_out    (crt_vs),
    .hb_out    (crt_hb),
    .vb_out    (crt_vb),
    .hs_ref_out(crt_hs_ref)
);

// Anchor the downstream OSD to the native active-region rising edge. If the
// OSD DE followed the shifted/stretched window, H-Position would move the OSD
// together with the game image.
reg crt_hs_in_d, crt_native_active_d, crt_str_active_d;
reg crt_vblank_1l, crt_de_osd;
wire crt_hs_in_rise = core_hs & ~crt_hs_in_d;
wire crt_native_active = ~(core_hb | crt_vblank_1l);
wire crt_native_rise = crt_native_active & ~crt_native_active_d;
wire crt_str_active = ~crt_hb;
wire crt_str_fall = crt_str_active_d & ~crt_str_active;
always @(posedge clk_sys) begin
    if (video_reset) begin
        crt_hs_in_d         <= 1'b0;
        crt_native_active_d <= 1'b0;
        crt_str_active_d    <= 1'b0;
        crt_vblank_1l       <= 1'b0;
        crt_de_osd          <= 1'b0;
    end
    else begin
        crt_hs_in_d <= core_hs;
        if (crt_hs_in_rise)
            crt_vblank_1l <= core_vb;
        if (ce_pix_core)
            crt_native_active_d <= crt_native_active;
        if (crt_rd_ce)
            crt_str_active_d <= crt_str_active;
        if (crt_native_rise)
            crt_de_osd <= 1'b1;
        else if (crt_str_fall)
            crt_de_osd <= 1'b0;
    end
end

// Generic JTFRAME-compatible crosshair/border decoration.  The framework's
// ascal.vhd has no gun-border port in this repository revision, so keep the
// native video timing untouched and decorate only the RGB stream.  CRT Adjust
// can change the output geometry independently of the native gun coordinates;
// suppress the crosshair in that optional mode rather than presenting a
// silently misregistered sight.  The native (default) path is exact.
wire [23:0] video_rgb_pre = crt_adjust_active ? {crt_r, crt_g, crt_b} : game_rgb;
wire        video_ce_pre  = crt_adjust_active ? crt_rd_ce : ce_pix_core;
wire        video_hs_pre  = crt_adjust_active ? crt_hs : core_hs;
wire        video_vs_pre  = crt_adjust_active ? crt_vs : core_vs;
wire        video_de_pre  = crt_adjust_active ? crt_de_osd : ~(core_hb | core_vb);
wire [23:0] video_rgb_overlay;
wire [8:0]  lightgun_raster_x, lightgun_raster_y;
s32_lightgun_overlay #(.BORDER_WIDTH(4)) lightgun_overlay (
    .clk          (clk_sys),
    .rst          (video_reset),
    .pxl_cen      (video_ce_pre),
    .hs           (video_hs_pre),
    .vs           (video_vs_pre),
    .de           (video_de_pre),
    .screen_width (lightgun_width),
    .screen_height(lightgun_height),
    .gun1_x       (display_gun_p1_x),
    .gun1_y       (display_gun_p1_y),
    .gun2_x       (display_gun_p2_x),
    .gun2_y       (display_gun_p2_y),
    .gun1_en      (active_board.gun_aim),
    .gun2_en      (active_board.gun_aim),
    .border_en    (active_board.gun_aim && status[8]),
    // status[9] is CRT Adjust in this core, so status[34] is the explicit
    // crosshair control while retaining the JTFRAME status[8] border meaning.
    .crosshair_en (active_board.gun_aim && status[34] && !crt_adjust_active),
    .rgb_in       (video_rgb_pre),
    .rgb_out      (video_rgb_overlay),
    .raster_x     (lightgun_raster_x),
    .raster_y     (lightgun_raster_y)
);

// Re-sample the finished clk_sys-domain stream onto the uniform clk_ram pixel
// grid (CLK_VIDEO = clk_ram).  The native fractional CE alternates 8/7 clk_sys
// per pixel in 320-wide mode; direct video transmits that jitter and a
// fixed-stride sampler (RetroTink 4K DV) turns it into tile-column tearing
// during scroll.  CRT Adjust keeps its intentionally fractional stretch
// cadence via the bypass path.
wire        final_ce = crt_adjust_active ? crt_rd_ce : ce_pix_core;
wire        final_hs = crt_adjust_active ? crt_hs : core_hs;
wire        final_vs = crt_adjust_active ? crt_vs : core_vs;
wire        final_de = crt_adjust_active ? crt_de_osd : ~(core_hb | core_vb);
// Close the real 48.3-to-96.6 MHz output path before the fast retimer.  The
// lightgun decorator is combinational by design; register the complete stream
// together so RGB cannot arrive a cycle apart from its raster controls.
reg [23:0] retime_rgb_src;
reg        retime_ce_src, retime_hs_src, retime_vs_src, retime_de_src;
always @(posedge clk_sys) begin
    if (video_reset) begin
        retime_rgb_src <= 24'h000000;
        retime_ce_src  <= 1'b0;
        retime_hs_src  <= 1'b0;
        retime_vs_src  <= 1'b0;
        retime_de_src  <= 1'b0;
    end
    else begin
        retime_rgb_src <= video_rgb_overlay;
        retime_ce_src  <= final_ce;
        retime_hs_src  <= final_hs;
        retime_vs_src  <= final_vs;
        retime_de_src  <= final_de;
    end
end
wire        rt_ce, rt_hs, rt_vs, rt_de;
wire [23:0] rt_rgb;
s32_video_retime video_retime (
    .clk     (clk_ram),
    .rst     (video_reset),
    .mode_416(mode_416_active),
    .bypass  (crt_adjust_active),
    .raw_ce  (retime_ce_src),
    .raw_rgb (retime_rgb_src),
    .raw_hs  (retime_hs_src),
    .raw_vs  (retime_vs_src),
    .raw_de  (retime_de_src),
    .ce      (rt_ce),
    .rgb     (rt_rgb),
    .hs      (rt_hs),
    .vs      (rt_vs),
    .de      (rt_de)
);

assign CE_PIXEL = rt_ce;
assign VGA_R  = rt_rgb[23:16];
assign VGA_G  = rt_rgb[15:8];
assign VGA_B  = rt_rgb[7:0];
assign VGA_HS = rt_hs;
assign VGA_VS = rt_vs;
assign VGA_DE = rt_de;

endmodule
