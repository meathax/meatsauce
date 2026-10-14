//============================================================================
//  Smash T.V. (Midway Y-Unit) for MiSTer -- emu top-level wrapper.
//
//  Assembles the verified game core (smashtv_core) with the MiSTer framework:
//  PLL, hps_io, ROM loader (ioctl -> SDRAM/GFX), the SDRAM controller (program
//  ROM), and arcade_video. First bring-up: program ROM in SDRAM; main RAM, VRAM
//  (12 bpp), GFX window, palette in block RAM. Sound is not yet wired.
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

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;
assign AUDIO_L = snd_audio_l;         // Williams CVSD sound board (below)
assign AUDIO_R = snd_audio_r;
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

// The cabinet is a 4:3 CRT: 410x256 anamorphic pixels fill the 4:3 tube
// (410:256 raw would be a wrong 1.6:1 stretch). OSD Aspect honors the
// standard MiSTer encoding: Original=4:3, then Full/ARC options.
wire [1:0] ar = status[2:1];
assign VIDEO_ARX = (!ar) ? 13'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 13'd3 : 13'd0;

`ifndef BUILD_DATE
`define BUILD_DATE "SmashTV"
`endif

localparam CONF_STR = {
    "SmashTV;;",
    "-;",
    "O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "O[6],Pause,Off,On;",
    "-;",
    "R[0],Reset;",
    "J1,Fire Up,Fire Down,Fire Left,Fire Right,Start,Coin;",
    "V,v",`BUILD_DATE
};

////////////////////////   CLOCKS   ////////////////////////
wire clk_sys, clk_ram, pll_locked, rom_loaded;
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
wire video_reset = RESET | status[0] | buttons[1] | ~pll_locked;
wire reset       = video_reset | ioctl_download | ~rom_loaded;

// 8 MHz pixel-clock enable from clk_sys/3 (24.162/3 ~= 8.05 MHz). clk_sys was
// halved from 48.324 to 24.162 MHz to close the TMS34010 decode->regfile path;
// the pixel clock is unchanged (was /6 from 48.324).
reg [1:0] pdiv; reg ce_pix;
always @(posedge clk_sys) begin
    ce_pix <= 1'b0;
    if (pdiv == 2'd2) begin pdiv <= 0; ce_pix <= 1'b1; end
    else pdiv <= pdiv + 1'd1;
end

////////////////////////   HPS IO   ////////////////////////
wire  [1:0] buttons;
wire [63:0] status;
wire        ioctl_download, ioctl_wr, ioctl_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;

hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .buttons(buttons),
    .status(status),
    .forced_scandoubler(forced_scandoubler),
    .gamma_bus(gamma_bus),
    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index),
    .ioctl_wait(ioctl_wait),
    .joystick_0(joystick_0),
    .joystick_1(joystick_1),
    .joystick_2(joystick_2),
    .joystick_3(joystick_3)
);

////////////////////////   ROM LOAD   ////////////////////////
// Program ROM and GFX ROM both stream to SDRAM (see smashtv_rom_loader).
wire        sw_req, sw_ack; wire [24:1] sw_addr; wire [15:0] sw_din; wire [1:0] sw_be;

// Per-game config latched from the MRA header (valid once rom_loaded).
wire [7:0] game_id;
wire       cfg_4bpp, cfg_has_prot, cfg_ctrl_trog;

smashtv_rom_loader loader (
    .clk(clk_sys), .rst(~pll_locked),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index[7:0]),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .sdr_wr_req(sw_req), .sdr_wr_addr(sw_addr), .sdr_wr_din(sw_din),
    .sdr_wr_be(sw_be), .sdr_wr_ack(sw_ack),
    .game_id(game_id), .cfg_4bpp(cfg_4bpp), .cfg_has_prot(cfg_has_prot),
    .cfg_ctrl_trog(cfg_ctrl_trog),
    .rom_loaded(rom_loaded)
);

////////////////////////   SDRAM (program ROM + GFX)   ////////////////////////
// clk_sys and clk_ram are 1:4 from the same PLL (phase-aligned), so the core's
// req/ack cross to the SDRAM clock by direct connection (as the prog channel
// already does) -- a clk_sys level is stable across two clk_ram edges.
wire        prog_req, prog_ack; wire [24:1] prog_addr_w; wire [47:0] prog_dout;
wire        gfx_req, gfx_ack;   wire [24:1] gfx_addr_w;  wire [95:0] gfx_dout;
wire        main_req, main_we, main_ack; wire [24:1] main_addr_w;
wire [15:0] main_din_w; wire [1:0] main_be_w; wire [47:0] main_dout;
wire        snd_rom_req, snd_rom_ack; wire [24:1] snd_rom_addr; wire [15:0] snd_rom_dout;

sdram sdram (
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
assign prog_addr_w = {7'd0, core_prog_addr};   // program image at SDRAM word 0
// core GFX read port (already a full SDRAM word address from the core adapter)
wire        core_gfx_req; wire [24:1] core_gfx_addr;
assign gfx_req    = core_gfx_req;
assign gfx_addr_w = core_gfx_addr;

////////////////////////   INPUTS   ////////////////////////
// Y-Unit input words (MAME williams/midyunit.cpp), all active-low. MiSTer
// joystick bits: [0]=Right [1]=Left [2]=Down [3]=Up, then J1 buttons [4],[5],...
// with [8]=Start [9]=Coin. The control scheme is per-game (cfg_ctrl_trog).
//
// --- Smash TV: dual-stick (move + fire as 4 buttons), 2 players ---
// IN0: P1 move[3:0], P1 fire[7:4], P2 move[11:8], P2 fire[15:12]
//   move/fire bit0=Up bit1=Down bit2=Left bit3=Right; J1 fire = buttons [4..7]
function automatic [7:0] stv_player(input [31:0] j);
    stv_player = { j[7], j[6], j[5], j[4],      // fire R,L,D,U
                   j[0], j[1], j[2], j[3] };    // move R,L,D,U -> bits 3..0
endfunction
wire [15:0] stv_in0 = ~{ stv_player(joystick_1), stv_player(joystick_0) };
wire [15:0] stv_in1 = ~{ 10'd0,
    1'b0, 1'b0, 1'b0, 1'b0,  // coin3/vfreeze/bill/service1
    joystick_1[8],           // start2
    1'b0, 1'b0,              // service / tilt
    joystick_0[8],           // start1
    joystick_1[9],           // coin2
    joystick_0[9] };         // coin1
wire [15:0] stv_in2 = 16'hffff;

// --- Trog: 4-way move + 1 punch, up to 4 players ---
// per-player 5-bit field {punch, R, L, D, U} -> bit4=punch bit3=R bit2=L bit1=D bit0=U
function automatic [4:0] trog_p(input [31:0] j);
    trog_p = { j[4], j[0], j[1], j[2], j[3] };  // punch, right, left, down, up
endfunction
wire [4:0] tp1 = trog_p(joystick_0);
wire [4:0] tp2 = trog_p(joystick_1);
wire [4:0] tp3 = trog_p(joystick_2);
wire [4:0] tp4 = trog_p(joystick_3);
// IN0: P1 move[3:0]/punch[4], P2 move[11:8]/punch[12]
wire [15:0] trog_in0 = ~{ 3'b0, tp2, 3'b0, tp1 };
// IN1: coin1/2, start1, tilt, test, start2, service1, bill, vfreeze, start3/4, P3 move+punch
wire [15:0] trog_in1 = ~{ tp3[4], tp3[3:0],       // b15 P3 punch, b14..b11 P3 R,L,D,U
    joystick_3[8], joystick_2[8],                 // b10 start4, b9 start3
    1'b0, 1'b0, 1'b0,                             // b8 vfreeze, b7 bill, b6 service1
    joystick_1[8],                                // b5 start2
    1'b0, 1'b0,                                   // b4 test, b3 tilt
    joystick_0[8],                                // b2 start1
    joystick_1[9], joystick_0[9] };               // b1 coin2, b0 coin1
// IN2: P4 move[3:0]/punch[4], coin3[5]
wire [15:0] trog_in2 = ~{ 10'b0, joystick_2[9], tp4 };

wire [15:0] in0 = cfg_ctrl_trog ? trog_in0 : stv_in0;
wire [15:0] in1 = cfg_ctrl_trog ? trog_in1 : stv_in1;
wire [15:0] in2 = cfg_ctrl_trog ? trog_in2 : stv_in2;
// DSW raw read (MAME defaults). Smash TV = all off = 0xFFFF. Trog = MAME
// trog defaults (Power-Up Test off -> bit 0x2000 clear) = 0xDFFF.
wire [15:0] in_dsw = cfg_ctrl_trog ? 16'hdfff : 16'hffff;

////////////////////////   GAME CORE   ////////////////////////
wire [7:0] r8, g8, b8; wire hs, vs, hbl, vbl, core_ce;

smashtv_core #(.EXTERNAL_PROG(1'b1), .EXTERNAL_GFX(1'b1), .EXTERNAL_MAIN(1'b1),
               .GFX_WORDS(262144),
               // pace the CPU to the real 34010's ~1.56M instr/s (~15 clks per
               // instruction at 24.162 MHz) so game speed matches the arcade
               .CPU_PACE_CLKS(15)) core (
    .clk(clk_sys), .rst(reset), .video_rst(video_reset), .ce_pix(ce_pix),
    .pause(status[6]),                 // OSD "Pause" -> freeze game, keep video
    .game_id(game_id), .cfg_4bpp(cfg_4bpp), .cfg_has_prot(cfg_has_prot),
    .in0(in0), .in1(in1), .in2(in2), .in_dsw(in_dsw), .in_unk0(16'hffff), .in_unk1(16'hffff),
    .ld_en(1'b0), .ld_region(2'd0), .ld_addr(24'd0), .ld_data(16'd0),   // ROMs load via SDRAM
    .prog_ext_req(core_prog_req), .prog_ext_addr(core_prog_addr),
    .prog_ext_w0(prog_dout[15:0]), .prog_ext_w1(prog_dout[31:16]),
    .prog_ext_w2(prog_dout[47:32]), .prog_ext_valid(prog_ack),
    .gfx_ext_req(core_gfx_req), .gfx_ext_addr(core_gfx_addr),
    .gfx_ext_dout(gfx_dout), .gfx_ext_ack(gfx_ack),
    .main_ext_req(main_req), .main_ext_we(main_we), .main_ext_addr(main_addr_w),
    .main_ext_din(main_din_w), .main_ext_be(main_be_w),
    .main_ext_dout(main_dout), .main_ext_ack(main_ack),
    .vga_r(r8), .vga_g(g8), .vga_b(b8),
    .vga_hs(hs), .vga_vs(vs), .vga_hb(hbl), .vga_vb(vbl), .vga_ce(core_ce),
    .snd_cmd(snd_cmd_w), .snd_cmd_stb(snd_cmd_stb_w), .dbg_pc(dbg_pc)
);

////////////////////////   SOUND BOARD (Williams CVSD)   ////////////////////////
// The main TMS34010 writes sound commands (0x01E00000); they latch here. The
// 6809 sound board's ROM lives in SDRAM (word base 0x500000), read via the
// wait-stated snd channel. Audio is signed 16-bit -> MiSTer AUDIO_L/R.
wire  [9:0] snd_cmd_w;  wire snd_cmd_stb_w;
wire signed [15:0] snd_audio_l, snd_audio_r;
// Y-Unit CVSD command mapping (MAME midyunit cvsd_sound_w):
//   reset_write(BIT(~data,8));  write((data & 0xff) | ((data & 0x200) >> 1));
// i.e. bit 8 LOW asserts the sound-board RESET (boot: 0xFE00 assert, 0x01FF
// release), and the PIA CB1 strobe is the ORIGINAL bit 9 (CB2 is always 0).
// Previously cmd[8]/cmd[9] went to CB1/CB2 raw and the soft reset was ignored
// -- the 6809 never restarted and command strobes were on the wrong bit: no
// sound at all on hardware.
reg snd_soft_rst = 1'b1;
always @(posedge clk_sys) begin
    if (reset)              snd_soft_rst <= 1'b1;
    else if (snd_cmd_stb_w) snd_soft_rst <= ~snd_cmd_w[8];
end
williams_cvsd #(.CLK_SYS_HZ(24_162_000),   // the HALVED clk_sys -- drives the E-clock
                                           // divider and the YM2151 cen accumulator
                .EXTERNAL_SND_ROM(1), .SND_WORD_BASE(24'h500000)) sndbrd (
    .clk(clk_sys), .rst(reset),
    .cmd({1'b0, snd_cmd_w[9], snd_cmd_w[7:0]}),
    .cmd_stb(snd_cmd_stb_w), .snd_rst(reset | snd_soft_rst),
    .talkback(),
    .audio_l(snd_audio_l), .audio_r(snd_audio_r),
    .snd_rom_req(snd_rom_req), .snd_rom_addr(snd_rom_addr),
    .snd_rom_dout(snd_rom_dout), .snd_rom_ack(snd_rom_ack),
    .dbg_run(snd_dbg_run), .dbg_stall(snd_dbg_stall)
);
wire snd_dbg_run, snd_dbg_stall;
// command-activity toggle: flips on every sound write the core issues
reg snd_dbg_cmdtgl;
always @(posedge clk_sys) if (snd_cmd_stb_w) snd_dbg_cmdtgl <= ~snd_dbg_cmdtgl;
wire [31:0] dbg_pc;

////////////////////////   VIDEO OUT   ////////////////////////
// Boot indicator (like the Sega System 32 core): while the game core is held in
// reset the timing generator still runs, so fill the visible area with a solid
// colour. This proves the pixel path works independent of the CPU and shows how
// far boot got. blue = ROM downloading, red = waiting for ROM, else the game.
wire [23:0] rgb_boot = ioctl_download ? 24'h0000FF :
                       ~rom_loaded    ? 24'hFF0000 : 24'hFFFF00;
`ifdef SMASHTV_DEBUG_PC
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
        2'd0: sdbg_rgb = snd_soft_rst  ? 24'hFF0000 : 24'h00FF00;
        2'd1: sdbg_rgb = snd_dbg_cmdtgl? 24'hFFFFFF : 24'h0000FF;
        2'd2: sdbg_rgb = snd_dbg_run   ? 24'h00FF00 : 24'h003000;
        default: sdbg_rgb = snd_dbg_stall ? 24'hFF0000 : 24'h301010;
    endcase
end
wire [23:0] rgb_out2 = sdbg_area ? sdbg_rgb : rgb_out;
`else
wire [23:0] rgb_out2 = rgb_out;
`endif

wire [2:0] fx = status[5:3];
arcade_video #(.WIDTH(410), .DW(24)) arcade_video (
    .clk_video(clk_sys), .ce_pix(ce_pix),
    .RGB_in(rgb_out2),
    .HBlank(hbl), .VBlank(vbl), .HSync(hs), .VSync(vs),
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
    .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE), .VGA_SL(VGA_SL),
    .fx(fx), .forced_scandoubler(forced_scandoubler), .gamma_bus(gamma_bus)
);

endmodule
