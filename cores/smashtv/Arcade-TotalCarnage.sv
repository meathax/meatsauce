//============================================================================
//  Total Carnage (Midway Y-Unit, ADPCM) for MiSTer -- emu top-level wrapper.
//
//  Same shared core (smashtv_core, built with TOTCARN=1) as the Smash T.V. top,
//  but for Total Carnage: 512 KB program at 0xFFC00000, the 0x01C00060 security
//  chip, and the Williams ADPCM sound board (williams_adpcm: MC6809E + YM2151 +
//  OKI MSM6295 + AD7524 DAC) in place of the CVSD board. ROMs load via ioctl ->
//  SDRAM (prog word 0, GFX word 0x40000, sound-CPU 0x500000, OKI 0x540000).
//
//  Framework structure adapted from the Sega System 32 core / the Smash TV top.
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
assign AUDIO_L = snd_audio_l;         // Williams ADPCM sound board (below)
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
`define BUILD_DATE "TotalCarnage"
`endif

localparam CONF_STR = {
    "TotalCarnage;;",
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

smashtv_rom_loader #(.TOTCARN(1'b1)) loader (
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
// Board-side sound-ROM ports (6809 CPU ROM + OKI sample ROM) and the single
// arbitrated SDRAM sound channel they share.
wire        snd_rom_req, snd_rom_ack; wire [24:1] snd_rom_addr; wire [15:0] snd_rom_dout;
wire        oki_rom_req, oki_rom_ack; wire [24:1] oki_rom_addr; wire [15:0] oki_rom_dout;
wire        sdr_snd_req, sdr_snd_ack; wire [24:1] sdr_snd_addr; wire [15:0] sdr_snd_dout;

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
    .snd_req(sdr_snd_req), .snd_addr(sdr_snd_addr), .snd_dout(sdr_snd_dout), .snd_ack(sdr_snd_ack)
);

// Shared sound SDRAM channel arbiter: the 6809 CPU-ROM fetch takes priority (it
// wait-states the 6809); the OKI sample fetch tolerates a stall (jt6295 holds
// rom_ok low). A registered owner routes ack/dout back to the right requester.
reg snd_inflight = 1'b0, snd_owner_oki = 1'b0;
wire snd_start = (snd_rom_req | oki_rom_req) & ~snd_inflight;
always @(posedge clk_sys) begin
    if (reset) snd_inflight <= 1'b0;
    else begin
        if (snd_start)                  begin snd_inflight <= 1'b1; snd_owner_oki <= ~snd_rom_req; end
        if (snd_inflight & sdr_snd_ack) snd_inflight <= 1'b0;
    end
end
assign sdr_snd_req  = snd_inflight;
assign sdr_snd_addr = snd_owner_oki ? oki_rom_addr : snd_rom_addr;
assign snd_rom_dout = sdr_snd_dout;
assign oki_rom_dout = sdr_snd_dout;
assign snd_rom_ack  = sdr_snd_ack & snd_inflight & ~snd_owner_oki;
assign oki_rom_ack  = sdr_snd_ack & snd_inflight &  snd_owner_oki;

// core program-ROM burst port (18-bit word addr) -> SDRAM word address
wire        core_prog_req; wire [17:0] core_prog_addr;
assign prog_req    = core_prog_req;
assign prog_addr_w = {6'd0, core_prog_addr};   // 512 KB program image at SDRAM word 0
// core GFX read port (already a full SDRAM word address from the core adapter)
wire        core_gfx_req; wire [24:1] core_gfx_addr;
assign gfx_req    = core_gfx_req;
assign gfx_addr_w = core_gfx_addr;

////////////////////////   INPUTS   ////////////////////////
// Total Carnage input words (MAME williams/midyunit.cpp INPUT_PORTS(totcarn)),
// all active-low. Twin-stick: left stick = move, right stick (4 buttons) = fire,
// 2 players. MiSTer joystick: [0]=Right [1]=Left [2]=Down [3]=Up (move); J1
// buttons [4..7] = Fire Up/Down/Left/Right; [8]=Start [9]=Coin.
//
// IN0: P1 move[3:0]/fire[7:4], P2 move[11:8]/fire[15:12].
function automatic [7:0] tc_player(input [31:0] j);
    tc_player = { j[7], j[6], j[5], j[4],      // fire R,L,D,U (bits 7..4)
                  j[0], j[1], j[2], j[3] };    // move R,L,D,U (bits 3..0)
endfunction
wire snd_int_state;   // ADPCM sound IRQ state (from the sound board, below)
wire [15:0] in0 = ~{ tc_player(joystick_1), tc_player(joystick_0) };
// IN1: coin1/2, start1, tilt, service, start2, service1, bill, [vfreeze], coin3,
// [unused 0x3c00], adpcm_irq (b14, IPT_CUSTOM active-low = ~sound_int_state).
wire [15:0] in1 = ~{ 1'b0, snd_int_state, 4'b0,
    joystick_2[9],                 // b9 coin3
    1'b0,                          // b8 video-freeze (unused)
    1'b0, 1'b0,                    // b7 bill, b6 service1
    joystick_1[8],                 // b5 start2
    1'b0,                          // b4 service switch
    1'b0,                          // b3 tilt
    joystick_0[8],                 // b2 start1
    joystick_1[9],                 // b1 coin2
    joystick_0[9] };               // b0 coin1
wire [15:0] in2    = 16'hffff;     // totcarn IN2 unused
// DSW defaults (MAME totcarn): Coinage-Source=Dipswitch(bit6=0), rest = 0xFFBF.
wire [15:0] in_dsw = 16'hffbf;

////////////////////////   GAME CORE   ////////////////////////
wire [7:0] r8, g8, b8; wire hs, vs, hbl, vbl, core_ce;

smashtv_core #(.TOTCARN(1'b1),
               .EXTERNAL_PROG(1'b1), .EXTERNAL_GFX(1'b1), .EXTERNAL_MAIN(1'b1),
               .GFX_WORDS(262144),
               // pace the CPU to the real 34010's ~1.56M instr/s (~15 clks per
               // instruction at 24.162 MHz) so game speed matches the arcade
               .CPU_PACE_CLKS(15)) core (
    .clk(clk_sys), .rst(reset), .video_rst(video_reset), .ce_pix(ce_pix),
    .pause(status[6]),                 // OSD "Pause" -> freeze game, keep video
    // Total Carnage: 6bpp, inline security chip (TOTCARN param). game_id/cfg
    // fixed (this is a dedicated TOTCARN=1 build, no MRA config header).
    .game_id(8'd0), .cfg_4bpp(1'b0), .cfg_has_prot(1'b1),
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

////////////////////////   SOUND BOARD (Williams ADPCM)   ////////////////////////
// The main TMS34010 writes 0x01E00000 (adpcm_sound_w): data[8]=1 runs the 6809
// (=0 holds it in reset), data[9]=0 asserts the command IRQ, data[7:0]=command.
// The core forwards data[9:0] as snd_cmd_w; the board decodes reset/IRQ/latch
// itself (no external soft-reset needed). The 6809 program ROM (SDRAM 0x500000)
// and OKI samples (SDRAM 0x540000) read via the shared, arbitrated snd channel.
// snd_int_state feeds IN1 bit 0x4000 (adpcm_irq_state_r). Audio is signed 16-bit.
wire  [9:0] snd_cmd_w;  wire snd_cmd_stb_w;
wire signed [15:0] snd_audio_l, snd_audio_r;
williams_adpcm #(.CLK_SYS_HZ(24_162_000),   // HALVED clk_sys -> E-clock + YM/OKI cen
                 .EXTERNAL_SND_ROM(1), .SND_WORD_BASE(24'h500000),
                 .EXTERNAL_OKI_ROM(1), .OKI_WORD_BASE(24'h540000)) sndbrd (
    .clk(clk_sys), .rst(reset),
    .cmd(snd_cmd_w), .cmd_stb(snd_cmd_stb_w),
    .talkback(), .snd_int_state(snd_int_state),
    .audio_l(snd_audio_l), .audio_r(snd_audio_r),
    .snd_rom_req(snd_rom_req), .snd_rom_addr(snd_rom_addr),
    .snd_rom_dout(snd_rom_dout), .snd_rom_ack(snd_rom_ack),
    .oki_rom_req(oki_rom_req), .oki_rom_addr(oki_rom_addr),
    .oki_rom_dout(oki_rom_dout), .oki_rom_ack(oki_rom_ack),
    .dbg_run(snd_dbg_run), .dbg_stall(snd_dbg_stall)
);
wire snd_dbg_run, snd_dbg_stall;
wire snd_soft_rst = reset;   // sound-board reset line (for the SMASHTV_DEBUG_SND overlay)
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
