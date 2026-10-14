// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer top-level for the Sammy/Seta/Visco SSV core (Dyna Gear target).

`timescale 1ns/1ps

module emu (
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

    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,
    output        FB_FORCE_BLANK,

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

// SDR_AW: the SDRAM word-address width shared by the loader, the core and the
// controller. Taking it from the package rather than restating 24 here is the
// point -- the widths on this boundary are exactly where a silent truncation
// turns into "wrong ROM load offset" and a fake renderer bug.
import ssv_pkg::SDR_AW;

`ifndef BUILD_DATE
`define BUILD_DATE "SSV"
`endif

localparam CONF_STR = {
    "SSV;;",
    "-;",
    // Both entries below are properties of the HDMI scaler (sys/video_freak.sv
    // -> ascal), and sys_top forces HDMI_WIDTH/HDMI_HEIGHT to zero while Direct
    // Video is on (sys/sys_top.v:1804). Neither can do anything on a raw native
    // raster, so both are hidden behind the same H0 mask bit as Rotation rather
    // than being offered as controls that silently do nothing.
    "H0O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    // Maps to sys/video_freak.sv SCALE. The previous list named entry 1
    // "Integer (Horizontal)" and entry 3 "HV-Integer" and drove BOTH to SCALE=4,
    // so two of the four entries were the same mode under different names and
    // there was no way to reach the wider variant. Entries 0..2 keep the exact
    // SCALE values they had, so a saved setting still means what it did; only
    // entry 3 changes, from a duplicate of entry 1 to SCALE=3.
    "H0O[44:43],Scale,Normal,HV-Integer,V-Integer,HV-Integer+;",
    // Framebuffer-only rotation. Direct Video is a raw native raster path; a
    // vertical cabinet is rotated physically, while HDMI rotation uses DDRAM.
    "H0O[50:49],Rotation,Horizontal,Vertical (CW),Vertical (CCW),Horizontal (Flipped);",
    // Was labelled "Scandoubler Fx" while no scandoubler existed. HQ2x is
    // gone with arcade_video; the line doubler that replaced it does not
    // filter, so the list is the scanline levels only. Any non-None setting
    // turns the doubler on, which is the convention arcade_video used.
    "O[5:3],Video Fx,None,Scanlines 25%,Scanlines 50%,Scanlines 75%;",
    // Doubling on its own (31 kHz, no scanline mask) for VGA-rate displays and
    // scalers that want a progressive raster. Any Video Fx level still implies
    // it, so this only matters while Video Fx is None.
    "O[51],Line Doubler,Off,On;",
    "O[47:46],Stereo Mix,None,25%,50%,100%;",
    "O[6],Service Mode,Off,On;",
    // Opt-in: freezes the game CPU and ES5506 while the OSD is open. Off by
    // default. The video raster and audio clock keep running (see cpu_halt),
    // so HDMI sync is not disturbed the way retuning around a full pause was.
    "O[52],Pause when OSD open,Off,On;",
    // Default On: the option bit reads 0 until the user changes it, so the
    // enabled state is the first entry and the wire below is inverted.
    "H1O[48],Autosave Hiscores,On,Off;",
    // Flip Screen, Demo Sounds, Difficulty, Lives, Free Play, Health and both
    // coinage nibbles are DIP switches and live in the MRA's <switches> block.
    // The framework only renders that as an OSD page when CONF_STR carries the
    // "DIP;" token below -- without it the switches are parsed and delivered to
    // sw[] but have no menu entry, which is why the DIP page was missing.
    // status bits 8..23 are free as a result. Bits 24..40 are free too: they
    // held the CRT Adjust page, which has been removed.
    "-;",
    // Renders the MRA <switches> block as its own OSD page. Flip Screen lives
    // there; it is the board's own 180-degree flip, so it runs at native rate
    // and works on a 15 kHz CRT (unlike the framebuffer Rotation option above).
    "DIP;",
    "-;",
    "R[0],Reset;",
    // Six game buttons: SSV's P1/P2 ports carry B1-B3 and the
    // $500008 window carries B4-B6.
    "J1,Fire,Jump,Button 3,Button 4,Button 5,Button 6,Coin,Start,Service,Test;",
    "V,v",`BUILD_DATE
};

assign ADC_BUS = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
assign {SD_SCK, SD_MOSI, SD_CS} = 3'bZZZ;
assign VGA_F1 = 1'b0;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;
// swblack in sys/ascal.vhd. It is a level ENABLE, not a blanking control: the
// only thing it does is make ascal emit three black frames when the measured
// input resolution changes (sys/ascal.vhd:1996). This core changes input
// resolution more often than most -- Video Fx switches the line rate between
// 15 and 31 kHz, and the SSV games themselves resize the active area through
// the CRTC registers -- and with this tied low each of those switches puts the
// torn/garbage frames
// ascal produces while it re-measures straight on the HDMI output. Enabling it
// costs nothing while the resolution is stable.
assign HDMI_BLACKOUT = 1'b1;
assign HDMI_BOB_DEINT = 1'b0;
assign FB_FORCE_BLANK = 1'b0;
assign AUDIO_S = 1'b1;
// AUDIO_MIX is driven from the OSD at the bottom of this file.
assign LED_POWER = 2'b00;
// LED_DISK is driven below from the renderer overrun status.
assign BUTTONS = 2'b00;
// This core does not use the MiSTer User I/O port. Keep its open-drain
// outputs released while retaining the framework-required shell ports.
assign USER_OUT = 7'b1111111;

wire clk_sys, clk_ram, clk_aux, pll_locked;
wire pll_ready_sys, pll_ready_ram;
pll pll (
    .refclk_clk(CLK_50M), .reset_reset(1'b0),
    .outclk0_clk(clk_ram), .outclk1_clk(clk_sys),
    .outclk2_clk(SDRAM_CLK), .outclk3_clk(clk_aux),
    .locked_export(pll_locked)
);
assign CLK_VIDEO = clk_sys;
// Keep the established 2x system/DDR clock.  It is a platform clock, not a
// per-frame data signal: muxing it with screen_rotate's video clock creates a
// hardware clock mux and can make the HPS/HDMI path lose lock when rotation is
// changed or when FB_EN changes at a frame boundary.

wire [1:0] buttons;
wire [63:0] status;
wire ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;
wire [15:0] joystick_l_analog_0;
// Driven by hps_io, consumed by the video chain at the bottom of this file.
// There is no gamma_bus: gamma_corr went with arcade_video.
wire        forced_scandoubler;
wire        direct_video;
wire        video_rotated;

// High score save/load nets. The module itself is instantiated further down,
// next to ssv_core; these are declared here because hps_io and ssv_core both
// sit above it and both connect to them. See that instance for the mapping.
// 18 bits: $000000-$00ffff is the block-RAM main RAM and $010000-$03ffff is
// the SDRAM-backed extra work RAM that carries twineag2/ultrax score tables.
wire [17:0] hs_addr;
wire  [7:0] hs_data_to_ram, hs_data_from_ram;
wire        hs_ram_write, hs_configured, hs_ram_ready;
wire        hs_intent_read, hs_intent_write;
wire  [7:0] hs_data_to_hps;
wire        hs_upload, hs_upload_req;

// Descriptor-sized board NVRAM uses MiSTer persistence index 8. hps_io has a
// single upload request/index/data path, so requests from this bridge and the
// existing hiscore index-4 client are serialized below.
wire  [7:0] nv_data_to_hps;
wire        nv_upload_req, nv_ioctl_wait;
wire        nv_init_busy, nv_init_done;
wire        nvram_transfer;

logic hs_upload_req_q, nv_upload_req_q;
logic hs_upload_pending, nv_upload_pending;
logic [2:0] upload_arb_state;
logic       upload_req_to_hps;
logic [7:0] upload_index_to_hps;
localparam logic [2:0] UP_IDLE = 3'd0, UP_SIGNAL = 3'd1,
                       UP_WAIT = 3'd2, UP_ACTIVE = 3'd3,
                       UP_GAP = 3'd4;

always_ff @(posedge clk_sys) begin
    if (!pll_ready_sys) begin
        hs_upload_req_q    <= 1'b0;
        nv_upload_req_q    <= 1'b0;
        hs_upload_pending  <= 1'b0;
        nv_upload_pending  <= 1'b0;
        upload_arb_state   <= UP_IDLE;
        upload_req_to_hps  <= 1'b0;
        upload_index_to_hps <= 8'd4;
    end
    else begin
        hs_upload_req_q <= hs_upload_req;
        nv_upload_req_q <= nv_upload_req;
        upload_req_to_hps <= 1'b0;

        if (hs_upload_req && !hs_upload_req_q)
            hs_upload_pending <= 1'b1;
        if (nv_upload_req && !nv_upload_req_q)
            nv_upload_pending <= 1'b1;

        case (upload_arb_state)
            UP_IDLE: begin
                // Board NVRAM has priority, but an index-4 edge is retained.
                if (nv_upload_pending) begin
                    nv_upload_pending   <= 1'b0;
                    upload_index_to_hps <= 8'd8;
                    upload_req_to_hps   <= 1'b1;
                    upload_arb_state    <= UP_SIGNAL;
                end
                else if (hs_upload_pending) begin
                    hs_upload_pending   <= 1'b0;
                    upload_index_to_hps <= 8'd4;
                    upload_req_to_hps   <= 1'b1;
                    upload_arb_state    <= UP_SIGNAL;
                end
            end
            UP_SIGNAL: upload_arb_state <= UP_WAIT;
            UP_WAIT: begin
                // Keep the selected index stable until HPS starts that upload.
                if (ioctl_upload &&
                    (ioctl_index[7:0] == upload_index_to_hps))
                    upload_arb_state <= UP_ACTIVE;
            end
            UP_ACTIVE: begin
                if (!ioctl_upload)
                    upload_arb_state <= UP_GAP;
            end
            UP_GAP: upload_arb_state <= UP_IDLE;
            default: upload_arb_state <= UP_IDLE;
        endcase
    end
end

assign hs_upload = ioctl_upload && (ioctl_index[7:0] == 8'd4);
wire [7:0] ioctl_data_to_hps = (ioctl_index[7:0] == 8'd8)
                                ? nv_data_to_hps : hs_data_to_hps;

// SSV main RAM is 16-bit and the hiscore module speaks bytes. The board is
// little-endian (the loader packs LE and the golden CRC depends on it), so
// byte address N is the low half of word N>>1 when N is even.
wire [14:0] hs_word_addr = hs_addr[15:1];
wire [15:0] hs_word_din  = {hs_data_to_ram, hs_data_to_ram};
wire  [1:0] hs_word_be   = hs_addr[0] ? 2'b10 : 2'b01;
// An access above $00ffff belongs to the extra work RAM and must not disturb
// the aliased main-RAM word that the truncated address would otherwise hit.
wire        hs_ram_we    = hs_ram_write && !hs_ext_sel;
wire [15:0] hs_word_dout;
// The read side is registered inside the RAM, so the byte lane has to be
// selected with the address that produced the data, not the current one.
reg  hs_addr0_q;
always_ff @(posedge clk_sys) hs_addr0_q <= hs_addr[0];
wire [7:0] hs_main_from_ram = hs_addr0_q ? hs_word_dout[15:8]
                                         : hs_word_dout[7:0];

// Extra work RAM ($010000-$03ffff, twineag2/ultrax) lives in SDRAM, so it
// answers with wait states. hs_ram_ready is what stalls the hiscore module.
wire        hs_ext_sel, hs_ext_ready;
wire [7:0]  hs_ext_dout;
wire        hs_ext_rd_req, hs_ext_rd_ack;
wire [SDR_AW:3] hs_ext_rd_addr;
wire [63:0] hs_ext_rd_dout;
wire        hs_ext_wr_req, hs_ext_wr_ack;
wire [SDR_AW:1] hs_ext_wr_addr;
wire [15:0] hs_ext_wr_din;
wire  [1:0] hs_ext_wr_be;

reg hs_ext_sel_q;
always_ff @(posedge clk_sys) hs_ext_sel_q <= hs_ext_sel;
assign hs_data_from_ram = hs_ext_sel_q ? hs_ext_dout : hs_main_from_ram;
assign hs_ram_ready     = hs_ext_ready;

hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys), .HPS_BUS(HPS_BUS),
    .buttons(buttons), .status(status),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
    .ioctl_upload(ioctl_upload), .ioctl_rd(ioctl_rd),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
    // Hiscore index 4 and board NVRAM index 8 share the HPS upload channel.
    .ioctl_upload_req(upload_req_to_hps),
    .ioctl_upload_index(upload_index_to_hps),
    .ioctl_din(ioctl_data_to_hps),
    // H1 hides Autosave on an MRA that carries no hiscore.dat entry.
    // H0 hides the framebuffer Rotation menu while Direct Video is selected.
    // Direct Video carries the native raster and has no rotated framebuffer.
    .status_menumask({14'd0, ~hs_configured, direct_video}),
    .forced_scandoubler(forced_scandoubler),
    .direct_video(direct_video),
    .video_rotated(video_rotated),
    .joystick_0(joystick_0), .joystick_1(joystick_1),
    .joystick_2(joystick_2), .joystick_3(joystick_3)
    ,.joystick_l_analog_0(joystick_l_analog_0)
);

// V60 clock enable.
//
// CONFIRMED from a real STA-0001B photograph: the board's second crystal is
// **48.000 MHz**, and 48.000 / 3 = 16.000 MHz is the V60 clock. The accumulator
// below targets that from clk_sys.
//
// The two board clocks are independent, so their ratio is the observable
// quantity for gameplay/frame lock: 16 MHz / (42.954545 MHz / 6) = 704/315.
// SSV_CPU_INC=21701 against SSV_PIXEL_INC=9710 is within 3.7 ppm; the former
// 21702 value was 42.4 ppm fast relative to video and visibly accumulated an
// ES5506/frame-boundary phase error in current Dyna Gear lockstep evidence.
//
// The OSD is deliberately not part of the emulation pause path. MiSTer may
// retune or redraw video while the menu is open, so freezing the CPU here can
// disturb the frame/audio phase and make HDMI sync fragile. Keep only pauses
// required for data transfers and hiscore RAM transactions.
//
// hs_pause is the hiscore module asking for the CPU to be still while it
// reads or writes the score table. It is a registered output over there, so
// feeding game_pause straight back into its paused input is a handshake and
// not a combinational loop.
wire hs_pause;
wire game_pause;
// User-selected freeze while the OSD is up. Only the CPU/sound clock enable is
// gated, never the pixel or video-timing accumulators, so the raster stays
// locked and the scaler never sees a signal change.
wire user_pause = status[52] & OSD_STATUS;
wire cpu_halt   = game_pause | user_pause;

logic ce_cpu;
logic [15:0] cpu_acc;
always_ff @(posedge clk_sys) begin
    logic [16:0] sum;
    if (!pll_ready_sys || cpu_halt) begin
        ce_cpu <= 1'b0;
        if (!pll_ready_sys) cpu_acc <= 16'd0;
    end
    else begin
        sum = {1'b0, cpu_acc} + {1'b0, ssv_pkg::SSV_CPU_INC};
        ce_cpu <= sum[16];
        cpu_acc <= sum[15:0];
    end
end

wire sdram_ready;
wire sdram_ready_sys;
wire rom_loaded;
wire loader_reset, video_reset;
wire core_cold_reset, core_reset;
wire wdog_rst;

ssv_host_guard u_host_guard (
    .clk_sys(clk_sys), .clk_ram(clk_ram),
    .pll_locked_async(pll_locked),
    // RESET is an asynchronous shell input; status/buttons already originate
    // in clk_sys through hps_io and must retain their existing phase.
    .reset_async(RESET), .reset_request(status[0] | buttons[1]),
    .sdram_ready_async(sdram_ready),
    // The replay-extended download view, not the raw HPS one: during a DDR3
    // fast-load replay the guard must keep core_cold_reset held exactly as if
    // the ioctl stream were still running, or a game switch would release the
    // core between the real download falling and the first replayed byte
    // (rom_loaded is still high from the previous game at that point) and the
    // adaptor's core_cold_reset port gate would deadlock the load.
    .ioctl_download(loader_ioctl_download), .ioctl_upload(ioctl_upload),
    .ioctl_index(ioctl_index),
    .rom_loaded(rom_loaded),
    .nv_init_done(nv_init_done), .nv_init_busy(nv_init_busy),
    .hs_pause(hs_pause), .wdog_rst(wdog_rst),
    .pll_ready_sys(pll_ready_sys), .pll_ready_ram(pll_ready_ram),
    .sdram_ready_sys(sdram_ready_sys),
    .nvram_transfer(nvram_transfer), .game_pause(game_pause),
    .loader_reset(loader_reset), .video_reset(video_reset),
    .core_cold_reset(core_cold_reset), .core_reset(core_reset)
);

assign LED_USER = ~rom_loaded;

`ifdef SIMULATION
// Release builds contain no reset-cause state or diagnostic ports.  The
// simulation-only edge log makes an unsolicited reset distinguishable between
// watchdog, host persistence, media readiness, PLL and front-panel sources.
logic sim_video_reset_d, sim_core_reset_d, sim_wdog_rst_d;
wire [9:0] sim_reset_causes = {
    wdog_rst, ~nv_init_done, ~sdram_ready_sys, ~rom_loaded,
    nvram_transfer,
    ioctl_download && ((ioctl_index == 16'd0) || (ioctl_index == 16'd1)),
    ~pll_ready_sys, buttons[1], status[0], RESET
};
initial begin
    sim_video_reset_d = 1'b0;
    sim_core_reset_d  = 1'b0;
    sim_wdog_rst_d    = 1'b0;
end
always @(posedge clk_sys) begin
    if (video_reset !== sim_video_reset_d)
        $display("SSV_VIDEO_RESET_%s time=%0t causes=%b",
                 video_reset ? "ASSERT" : "RELEASE",
                 $time, sim_reset_causes);
    if (core_reset !== sim_core_reset_d)
        $display("SSV_CORE_RESET_%s time=%0t causes=%b",
                 core_reset ? "ASSERT" : "RELEASE",
                 $time, sim_reset_causes);
    if (wdog_rst !== sim_wdog_rst_d)
        $display("SSV_WDOG_RESET_%s time=%0t mode=%0d counter=%0d",
                 wdog_rst ? "ASSERT" : "RELEASE",
                 $time, game_cfg.wdog_mode, core.wdog_cycle_cnt);
    sim_video_reset_d <= video_reset;
    sim_core_reset_d  <= core_reset;
    sim_wdog_rst_d    <= wdog_rst;
end
`endif

wire ld_wr_req, ld_wr_ack;
wire ld_ioctl_wait;
wire [SDR_AW:1] ld_wr_addr;
wire [15:0] ld_wr_din;
wire [1:0] ld_wr_be;
wire st010_drom_we;
wire [10:0] st010_drom_wa;
wire [15:0] st010_drom_wd;

// Per-game configuration, parsed by the loader from the MRA's
// <rom index="1"> block. game_cfg is what the core actually runs on; there is
// no fallback to a compiled-in default, because a silent fallback turns a
// packaging mistake into a corrupt-graphics bug hunt. game_cfg_valid gates
// rom_loaded inside the loader, so a missing block shows up as LED_USER
// staying lit rather than as a broken picture.
ssv_pkg::ssv_cfg_t game_cfg;
wire               game_cfg_valid;
wire               game_cfg_commit;

// DDR3 fast-load adaptor for the index-0 ROM stream (see
// rtl/mem/ssv_ddr_rom_loader.sv). Dormant unless an MRA's index-0 <rom>
// carries address="0x30000000": with no address= attribute, Main streams
// data over ioctl as it always has, ddr_replay_active never asserts, and
// every wire below reduces to the original direct connection to `loader`.
// UNVERIFIED ON HARDWARE -- see docs/debug/DDR_FAST_ROM_LOAD_STATUS_20260820.md.
wire        ddr_replay_active, ddr_replay_wr;
wire [26:0] ddr_replay_addr;
wire  [7:0] ddr_replay_dout;
wire  [7:0] ddr_replay_index;
wire        ddr_replay_hold;
wire        ddr_ld_acquire, ddr_ld_rd;
wire  [7:0] ddr_ld_burstcnt;
wire [28:0] ddr_ld_addr;

ssv_ddr_rom_loader #(.DDR_BASE_BYTES(32'h3000_0000)) u_ddr_rom_loader (
    .clk(clk_sys), .reset(loader_reset), .core_cold_reset(core_cold_reset),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index[7:0]),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
    .loader_wait(ld_ioctl_wait),
    .replay_active(ddr_replay_active), .replay_wr(ddr_replay_wr),
    .replay_addr(ddr_replay_addr), .replay_dout(ddr_replay_dout),
    .replay_index(ddr_replay_index), .replay_hold(ddr_replay_hold),
    .ddr_acquire(ddr_ld_acquire), .ddr_burstcnt(ddr_ld_burstcnt),
    .ddr_addr(ddr_ld_addr), .ddr_rd(ddr_ld_rd), .ddr_busy(DDRAM_BUSY),
    .ddr_dout(DDRAM_DOUT), .ddr_dout_ready(DDRAM_DOUT_READY)
);

// With replay inactive every one of these equals the raw hps_io signal,
// unchanged. The index is muxed too -- this is not optional. In address mode
// Main's rom_finish() does a shmem_put and drops ioctl_download in
// milliseconds, then moves straight on to the next MRA element (every shipped
// SSV MRA has a trailing <nvram index="4">) while the replay is still
// streaming megabytes out of DDR3. ssv_rom_loader only accepts a byte while
// the index it sees is 0, so handing it the live HPS index mid-replay dropped
// the rest of the ROM on the floor: rom_loaded never asserted, core_cold_reset
// never released, black screen on every game. Found on hardware 2026-08-21;
// verif/tb_ssv_ddr_rom_loader.sv test 4 reproduces it (8 of 1035 bytes
// delivered with the index passed through raw).
wire        loader_ioctl_download = ioctl_download | ddr_replay_active;
wire        loader_ioctl_wr       = ddr_replay_active ? ddr_replay_wr   : ioctl_wr;
wire [26:0] loader_ioctl_addr     = ddr_replay_active ? ddr_replay_addr : ioctl_addr;
wire  [7:0] loader_ioctl_dout     = ddr_replay_active ? ddr_replay_dout : ioctl_dout;

ssv_rom_loader loader (
    .cfg(game_cfg), .cfg_valid(game_cfg_valid),
    .cfg_commit(game_cfg_commit),
    .clk(clk_sys), .rst(loader_reset), .mem_ready(sdram_ready_sys),
    .ioctl_download(loader_ioctl_download), .ioctl_index(ddr_replay_index),
    .ioctl_wr(loader_ioctl_wr), .ioctl_addr(loader_ioctl_addr),
    .ioctl_dout(loader_ioctl_dout), .ioctl_wait(ld_ioctl_wait),
    .sdr_wr_req(ld_wr_req), .sdr_wr_addr(ld_wr_addr),
    .sdr_wr_din(ld_wr_din), .sdr_wr_be(ld_wr_be),
    .sdr_wr_ack(ld_wr_ack), .rom_loaded(rom_loaded),
    .st010_drom_we(st010_drom_we),
    .st010_drom_wa(st010_drom_wa), .st010_drom_wd(st010_drom_wd)
);

// While cold-zeroing, descriptor bytes (index 1) must continue to flow, but
// index 0 and persisted index 8 are held until the exact-sized fill completes.
wire nv_init_ioctl_wait = (game_cfg_commit || nv_init_busy) &&
                          ioctl_download &&
                          ((ioctl_index == 16'd0) ||
                           (ioctl_index == 16'd8));
// ddr_replay_hold stalls Main's next transfer (typically the trailing
// <nvram index="4"> element) until the DDR3 replay has finished feeding the
// loader; without it those bytes would race the replay for the muxed bus.
assign ioctl_wait = ld_ioctl_wait | nv_ioctl_wait | nv_init_ioctl_wait |
                    ddr_replay_hold;

wire core_p0_req;
wire [SDR_AW:1] core_p0_addr;
wire p0_ack;
wire [15:0] p0_dout;
wire p0_req  = core_p0_req;
wire [SDR_AW:1] p0_addr = core_p0_addr;

// Graphics row fetch: one 128-bit p2 burst per 16-pixel tile row. p1 (64-bit,
// 4-word burst) serves the hiscore module's extra-work-RAM line fetches; that
// traffic exists only while the CPU is paused for a hiscore access.
wire p2_req, p2_ack;
wire [SDR_AW:4] p2_addr;
wire [127:0] p2_dout;
wire nv_p3_req, nv_p3_ack;
wire [SDR_AW:1] nv_p3_addr;
wire [15:0] nv_p3_dout;
wire p4_req, p4_ack;
wire [SDR_AW:1] p4_addr;
wire [15:0] p4_dout;
wire p5_req, p5_ack;
wire [SDR_AW:3] p5_addr;
wire [63:0] p5_dout;

wire core_wr_req, core_wr_ack;
wire [SDR_AW:1] core_wr_addr;
wire [15:0] core_wr_din;
wire [1:0] core_wr_be;
wire nv_wr_req, nv_wr_ack;
wire [SDR_AW:1] nv_wr_addr;
wire [15:0] nv_wr_din;
wire [1:0] nv_wr_be;
wire nv_modified;
wire sw_req, sw_ack;
wire [SDR_AW:1] sw_addr;
wire [15:0] sw_din;
wire [1:0] sw_be;
wire [1:0] nvram_size_mode = (game_cfg_valid && game_cfg.has_nvram)
                              ? game_cfg.nvram_mode : 2'd0;

ssv_nvram_bridge #(
    .SDR_AW(SDR_AW),
    .NVRAM_BASE(ssv_pkg::SDR_NVRAM_BASE)
) nvram_bridge (
    .clk(clk_sys), .rst(loader_reset),
    .nvram_size_mode(nvram_size_mode),
    .cfg_commit(game_cfg_commit),
    .init_busy(nv_init_busy), .init_done(nv_init_done),
    .modified(nv_modified), .dirty(),
    .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload),
    .ioctl_wr(ioctl_wr), .ioctl_rd(ioctl_rd),
    .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_din(nv_data_to_hps),
    .ioctl_wait(nv_ioctl_wait), .ioctl_upload_req(nv_upload_req),
    .sdr_ready(sdram_ready_sys),
    .sdr_wr_req(nv_wr_req), .sdr_wr_addr(nv_wr_addr),
    .sdr_wr_din(nv_wr_din), .sdr_wr_be(nv_wr_be),
    .sdr_wr_ack(nv_wr_ack),
    .sdr_rd_req(nv_p3_req), .sdr_rd_addr(nv_p3_addr),
    .sdr_rd_dout(nv_p3_dout), .sdr_rd_ack(nv_p3_ack)
);

ssv_hs_extram #(
    .SDR_AW(SDR_AW),
    .EXTRA_BASE(ssv_pkg::SDR_CPU_RAM_BASE),
    .CPU_BASE(18'h10000)
) hs_extram (
    .clk(clk_sys), .rst(loader_reset),
    // extra_ram_mode 2 is the $010000-$03ffff window; mode 1 is the $400000
    // window, which no hiscore.dat entry references.
    .enable(game_cfg_valid && (game_cfg.extra_ram_mode == 2'd2)),
    .hs_access(hs_intent_read | hs_intent_write),
    .hs_addr(hs_addr), .hs_write(hs_ram_write), .hs_din(hs_data_to_ram),
    .hs_dout(hs_ext_dout), .hs_ready(hs_ext_ready), .hs_sel(hs_ext_sel),
    .sdr_ready(sdram_ready_sys),
    .rd_req(hs_ext_rd_req), .rd_addr(hs_ext_rd_addr),
    .rd_dout(hs_ext_rd_dout), .rd_ack(hs_ext_rd_ack),
    .wr_req(hs_ext_wr_req), .wr_addr(hs_ext_wr_addr),
    .wr_din(hs_ext_wr_din), .wr_be(hs_ext_wr_be), .wr_ack(hs_ext_wr_ack)
);

wire loader_owns_write = ld_wr_req;
wire nvram_owns_write = !loader_owns_write && nv_wr_req;
// The CPU is paused for the duration of a hiscore restore, so taking the
// write port ahead of the core costs it nothing.
wire hs_ext_owns_write = !loader_owns_write && !nvram_owns_write &&
                         hs_ext_wr_req;

assign sw_req  = loader_owns_write ? ld_wr_req  :
                 nvram_owns_write  ? nv_wr_req  :
                 hs_ext_owns_write ? hs_ext_wr_req : core_wr_req;
assign sw_addr = loader_owns_write ? ld_wr_addr :
                 nvram_owns_write  ? nv_wr_addr :
                 hs_ext_owns_write ? hs_ext_wr_addr : core_wr_addr;
assign sw_din  = loader_owns_write ? ld_wr_din  :
                 nvram_owns_write  ? nv_wr_din  :
                 hs_ext_owns_write ? hs_ext_wr_din : core_wr_din;
assign sw_be   = loader_owns_write ? ld_wr_be   :
                 nvram_owns_write  ? nv_wr_be   :
                 hs_ext_owns_write ? hs_ext_wr_be : core_wr_be;
assign ld_wr_ack     = loader_owns_write ? sw_ack : 1'b0;
assign nv_wr_ack     = nvram_owns_write ? sw_ack : 1'b0;
assign hs_ext_wr_ack = hs_ext_owns_write ? sw_ack : 1'b0;
assign core_wr_ack   = (!loader_owns_write && !nvram_owns_write &&
                        !hs_ext_owns_write) ? sw_ack : 1'b0;

// Only a completed core write in the exact descriptor-selected physical
// NVRAM range marks persistence dirty. Loader/zero-fill/index-8 writes do not.
wire [SDR_AW:1] nvram_word_limit = ssv_pkg::SDR_NVRAM_BASE[SDR_AW:1] +
    ((nvram_size_mode == 2'd1) ? SDR_AW'(1024) :
     (nvram_size_mode == 2'd2) ? SDR_AW'(32768) : SDR_AW'(0));
assign nv_modified = core_wr_req && core_wr_ack &&
                     ((nvram_size_mode == 2'd1) ||
                      (nvram_size_mode == 2'd2)) &&
                     (core_wr_addr >= ssv_pkg::SDR_NVRAM_BASE[SDR_AW:1]) &&
                     (core_wr_addr < nvram_word_limit);

// The 128 MB module fitted on this board is TWO 32Mx16 devices, not one
// 64Mx16 part: SDRAM_nCS selects between them and DQML/DQMH are shorted to
// A11/A12. The controller encodes that contract and takes NO geometry
// parameters -- parameterising it is exactly how the wrong part came to be
// configured, which byte-masked every write through the A11 short and left
// device 1 without an MRS. See rtl/mem/sdram.sv and
// docs/issues/SDRAM_MODULE_CONTRACT.md; the failure is reproduced by
// verif/tb_ssv_sdram_module_contract.sv.
sdram sdram (
    .clk(clk_ram), .init(~pll_ready_ram), .ready(sdram_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(sw_req), .wr_addr(sw_addr), .wr_din(sw_din),
    .wr_be(sw_be), .wr_ack(sw_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(hs_ext_rd_req), .p1_addr(hs_ext_rd_addr),
    .p1_dout(hs_ext_rd_dout), .p1_ack(hs_ext_rd_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(nv_p3_req), .p3_addr(nv_p3_addr),
    .p3_dout(nv_p3_dout), .p3_ack(nv_p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

// MiSTer J1 order: Fire,Jump,B3,B4,B5,B6,Start,Coin,Service,Test
//                  joy[4]..joy[13]
// (the MRA's <buttons names=...> list must stay in this same order).
//
wire [31:0] joy_p1 = joystick_0;
wire [31:0] joy_p2 = joystick_1;
wire [31:0] joy_p3 = joystick_2;
wire [31:0] joy_p4 = joystick_3;

wire [15:0] p1_input_port;
wire [15:0] p2_input_port;
// Feeds ssv_core's UNUSED in_mahjong_rows port only -- the mahjong/Eagle Shot/
// Sexy Reaction/GDFS optional-I/O family is not in the universal profile, so
// this value is discarded inside the core. Kept in step with that port, which
// eight verif/ benches still bind by name; remove both together.
wire [23:0] mahjong_rows = {~joy_p4[9:4], ~joy_p3[9:4],
                            ~joy_p2[9:4], ~joy_p1[9:4]};
wire signed [7:0] analog_x = joystick_l_analog_0[7:0];
wire signed [7:0] analog_y = joystick_l_analog_0[15:8];
wire [11:0] optional_coord_x = 12'h800 + (12'($signed(analog_x)) <<< 3);
wire [11:0] optional_coord_y = 12'h800 + (12'($signed(analog_y)) <<< 3);
wire [7:0] optional_paddle = 8'h80 + 8'($signed(analog_x));

wire test_button = status[6] | joy_p1[13] | joy_p2[13];
// OSD assign-button prompt order for the standard 10-slot layout follows
// fixed joystick bits per slot position (4..13), not the MRA's <buttons>
// name text -- see docs/debug/... (2026-08-19 reorder). To get the desired
// on-screen prompt order Coin,Start,Service,Test, the CORE must read those
// functions from bits 10,11,12,13 in that same order; Start moved out of
// player_port() in ssv_input_ports.sv from bit 12 to bit 11 to match (grep
// that file for the companion change). Bit 12 was Start until this change --
// wiring service_button to a bit still read as Start elsewhere caused the
// 2026-08-19 Service/Start cross-firing bug; keep this comment in sync with
// player_port() if either side is touched again.
wire coin1_button = joy_p1[10];
wire coin2_button = joy_p2[10];
wire service_button = joy_p1[12] | joy_p2[12];
wire [15:0] system_port;
wire [15:0] extra_input_port;
wire core_frame_tick;

ssv_input_ports input_ports (
    .clk(clk_sys), .rst(core_cold_reset), .frame_tick(core_frame_tick),
    .joy_p1(joy_p1), .joy_p2(joy_p2),
    .input_layout(game_cfg.input_layout),
    .system_input_mode(game_cfg.system_input_mode),
    .extra_input_mode(game_cfg.extra_input_mode),
    .rapid_fire_b3_to_b1(game_cfg.rapid_fire_b3_to_b1),
    .rapid_fire_b1(game_cfg.rapid_fire_b1),
    .rapid_fire_b2(game_cfg.rapid_fire_b2),
    .test_button(test_button), .service_button(service_button),
    .coin1_button(coin1_button), .coin2_button(coin2_button),
    .p1_port(p1_input_port), .p2_port(p2_input_port),
    .system_port(system_port), .extra_port(extra_input_port)
);

// ---------------------------------------------------------------------------
// DIP switches, from the MRA.
//
// These used to be OSD options, each one hand-mapped to a DIP bit pattern --
// coinage in particular needed a 16-entry lookup, because the OSD list order
// and the board's nibble values have nothing to do with each other. The MRA
// expresses that directly (<dip ... ids=... values=...>) and the HPS sends the
// assembled bytes on ioctl index 254, so the core can take them verbatim.
//
// That removes the translation layer and, with it, the class of bug where the
// OSD says one thing and the board is told another. It also means a second SSV
// title only needs its own MRA, not RTL changes -- these bytes ARE what the
// game reads at $210002 and $210004.
//
// The reset default matches MAME's dynagear (FF / FD) so the core still comes
// up sanely if an MRA carries no <switches> block at all.
// ---------------------------------------------------------------------------
logic [7:0] sw [0:1];
initial begin
    sw[0] = 8'hff;  // DSW1: Coin A and Coin B both 1C/1C
    sw[1] = 8'hfd;  // DSW2: Flip Off, Demo On, Normal, 2 lives, Free Play Off,
                    //       4 Hearts
end
always_ff @(posedge clk_sys) begin
    if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[24:1])
        sw[ioctl_addr[0]] <= ioctl_dout;
end

wire [15:0] dsw1_port = {8'hff, sw[0]};
wire [15:0] dsw2_port = {8'hff, sw[1]};

wire [23:0] core_rgb;
wire core_ce, core_hs, core_vs, core_hb, core_vb;
wire core_ce_x2_unused;   // superseded by u_pixel_retime's x2 enable
wire renderer_overrun;
wire signed [15:0] core_audio_l, core_audio_r;
wire core_audio_tick;
wire signed [15:0] audio_cdc_l, audio_cdc_r;
wire audio_cdc_ready, audio_cdc_valid;

// DBG_AUDIO_OVERLAY=1 blacks out the game picture and shows the fullscreen
// ES5506 audio-debug screen instead (rtl/debug/ssv_audio_debug_overlay.sv;
// the game, inputs and audio keep running underneath). Left at its default
// 0 for this release build -- re-enable only for diagnostic captures.
ssv_core core (
    .cfg(game_cfg),
    .clk_sys(clk_sys), .rst(core_reset), .cold_rst(core_cold_reset),
    .ce_cpu(ce_cpu), .watchdog_hold(cpu_halt),
    .sdr_p0_req(core_p0_req), .sdr_p0_addr(core_p0_addr),
    .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p2_req(p2_req), .sdr_p2_addr(p2_addr),
    .sdr_p2_dout(p2_dout), .sdr_p2_ack(p2_ack),
    .sdr_wr_req(core_wr_req), .sdr_wr_addr(core_wr_addr),
    .sdr_wr_din(core_wr_din), .sdr_wr_be(core_wr_be),
    .sdr_wr_ack(core_wr_ack),
    .sdr_p5_req(p5_req), .sdr_p5_addr(p5_addr),
    .sdr_p5_dout(p5_dout), .sdr_p5_ack(p5_ack),
    .st010_drom_we(st010_drom_we), .st010_drom_wa(st010_drom_wa),
    .st010_drom_wd(st010_drom_wd),
    .sdr_p4_req(p4_req), .sdr_p4_addr(p4_addr),
    .sdr_p4_dout(p4_dout), .sdr_p4_ack(p4_ack),
    .in_dsw1(dsw1_port), .in_dsw2(dsw2_port),
    .in_p1(p1_input_port), .in_p2(p2_input_port),
    .in_system(system_port),
    .in_extra(extra_input_port),
    .in_mahjong_rows(mahjong_rows),
    .in_coord_x(optional_coord_x), .in_coord_y(optional_coord_y),
    .in_paddle(optional_paddle), .in_ball_switch(joy_p1[11]),
    .frame_tick(core_frame_tick),
    .hs_addr(hs_word_addr), .hs_din(hs_word_din), .hs_be(hs_word_be),
    .hs_we(hs_ram_we), .hs_dout(hs_word_dout),
    .rgb(core_rgb), .ce_pixel(core_ce), .ce_pix_x2(core_ce_x2_unused),
    .hs(core_hs), .vs(core_vs), .hb(core_hb), .vb(core_vb),
    .audio_l(core_audio_l), .audio_r(core_audio_r),
    .audio_tick(core_audio_tick),
    .wdog_rst(wdog_rst),
    .coin_lockout(), .renderer_overrun(renderer_overrun), .motor_output()
);

ssv_audio_cdc audio_cdc (
    .src_clk(clk_sys), .src_rst(RESET | core_reset),
    .src_valid(core_audio_tick), .src_l(core_audio_l), .src_r(core_audio_r),
    .src_ready(audio_cdc_ready),
    .dst_clk(CLK_AUDIO), .dst_rst(RESET | core_reset),
    .dst_l(audio_cdc_l), .dst_r(audio_cdc_r), .dst_valid(audio_cdc_valid)
);

// ---------------------------------------------------------------------------
// High score save/load (rtl/hiscore.v, alanswx / JimmyStones).
//
// The MRA carries the game's hiscore.dat entry on ioctl index 3; the saved
// dump is <MRA name>.nvm on index 4. The module walks the entry list, waits
// for the game to have initialised its table, then restores it -- and on OSD
// open it reads the table back and requests a save if anything changed.
//
// SSV main RAM is 16-bit and the module speaks bytes, so this converts. The
// board is little-endian (the loader packs LE and the golden CRC depends on
// it), so byte address N is the low half of word N>>1 when N is even.
// ---------------------------------------------------------------------------
hiscore #(
    // 18 bits covers SSV main RAM ($000000-$00ffff) plus the extra work RAM at
    // $010000-$03ffff that twineag2 and ultrax keep their score tables in.
    .HS_ADDRESSWIDTH(18),
    // 256 bytes of dump: Vasara 2 has the largest table at 235 bytes
    // (hiscore.dat vasara2: address $5302, length $eb).
    .HS_SCOREWIDTH(8),
    .CFG_ADDRESSWIDTH(4)
) u_hiscore (
    .clk(clk_sys),
    .reset(core_reset),
    .paused(cpu_halt),
    .autosave(~status[48]),
    // Opening the OSD is what triggers extraction of the table from game RAM,
    // and without it nothing is ever saved. It pauses the game CPU for the
    // length of the scan, which is why it is bound to the OSD rather than to
    // anything that happens during play.
    .OSD_STATUS(OSD_STATUS),

    .ioctl_upload(hs_upload),
    .ioctl_upload_req(hs_upload_req),
    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr[24:0]),
    .ioctl_index(ioctl_index[7:0]),

    .data_from_hps(ioctl_dout),
    .data_to_hps(hs_data_to_hps),
    .data_from_ram(hs_data_from_ram),
    .ram_ready(hs_ram_ready),
    .data_to_ram(hs_data_to_ram),
    .ram_address(hs_addr),
    .ram_write(hs_ram_write),
    .ram_intent_read(hs_intent_read),
    .ram_intent_write(hs_intent_write),
    .pause_cpu(hs_pause),
    .configured(hs_configured)
);

// The core's own raster is the only video source. The independent bring-up
// raster (ssv_diag_video) that used to sit alongside it has been removed: it
// was permanently disabled by a hardcoded localparam, so the mux below always
// selected the core and the second timing path was dead weight in every build.
//
// Everything downstream takes the raster through ssv_pixel_retime, which
// re-emits it with every active pixel exactly 7 clk_sys wide. The core's own
// enable alternates 7,7,7,6 in fixed screen columns, and Direct Video and the
// analog DAC both show that as narrow columns -- faint vertical seams the
// background scrolls through. See the module header.
wire [23:0] av_rgb;
wire av_hs, av_vs, av_hb, av_vb, av_ce, ce_pix_x2;
ssv_pixel_retime #(.W(27)) u_pixel_retime (
    .clk(clk_sys), .rst(video_reset),
    .ce_in(core_ce), .d_in({core_rgb, core_hs, core_vs, core_vb}),
    .hb_in(core_hb),
    .ce_out(av_ce), .ce_x2_out(ce_pix_x2),
    .d_out({av_rgb, av_hs, av_vs, av_vb}), .hb_out(av_hb)
);
wire [7:0] av_r = av_rgb[23:16];
wire [7:0] av_g = av_rgb[15:8];
wire [7:0] av_b = av_rgb[7:0];

// ---------------------------------------------------------------------------
// Video output.
//
// The chain is deliberately small: an optional 2x line doubler, then
// video_freak for the scaling modes and VGA_DE. What is NOT here matters as
// much as what is.
//
// sys/arcade_video.v was used briefly and removed. It reaches a scandoubler
// through video_mixer, and that scandoubler keeps its line storage inside
// Hq2x -- two input line buffers plus an output buffer four times the pixel
// width -- which is about nine M10K at this game's 336-pixel active width,
// with gamma_corr adding roughly four more. This design is at its block RAM
// ceiling and the fitter is at its memory ceiling, and neither the HQ2x filter
// nor a gamma curve earns that on an arcade board driving a CRT. Dropping
// arcade_video takes gamma with it, so there is no GAMMA parameter to set.
//
// sys_top applies VGA_SL before Direct Video leaves MiSTer. Suppress that mask
// on the raw path so an external 90-degree rotation cannot turn horizontal
// scanlines into vertical black bars; keep the line doubler independent.
// ---------------------------------------------------------------------------

wire       sd_on;
wire [1:0] rotation;
wire [1:0] aspect;
wire [1:0] scale_select;

ssv_video_mode_guard u_video_mode_guard (
    .clk(clk_sys), .rst(video_reset),
    .native_ce(av_ce), .native_hsync(av_hs), .native_vblank(av_vb),
    .sd_request(forced_scandoubler | status[51] | (|status[5:3])),
    .rotation_request(status[50:49]),
    .aspect_request(status[2:1]),
    .scale_request(status[44:43]),
    .sd_on(sd_on),
    .rotation(rotation), .aspect(aspect), .scale_select(scale_select)
);

// Any Fx selection implies doubling, the same rule arcade_video used. The
// request is committed by u_video_mode_guard at a VBlank line boundary.

// The doubler needs an enable at exactly twice the pixel rate and in phase
// with it. That now comes from ssv_pixel_retime, which marks each output pixel
// enable and the clock three after it, so the 2:1 ratio holds by construction.
//
// It used to be generated here by a SECOND accumulator restarted on the line
// reference, while the core's free-runs. verif/tb_ssv_scandoubler.sv measured
// that at a constant 907 ticks per line where exact doubling of a 454-pixel
// line needs 908 -- every doubled line was one pixel short. Do not reintroduce
// a local generator; the two accumulators cannot be kept in step.

wire [23:0] sd_rgb;
wire        sd_hs, sd_vs, sd_hb, sd_vb;

ssv_scandoubler u_scandoubler (
    .clk(clk_sys), .rst(video_reset),
    .ce_pix(av_ce), .ce_pix_x2(ce_pix_x2),
    .rgb_in({av_r, av_g, av_b}),
    .hs_in(av_hs), .vs_in(av_vs), .hb_in(av_hb), .vb_in(av_vb),
    .rgb_out(sd_rgb),
    .hs_out(sd_hs), .vs_out(sd_vs), .hb_out(sd_hb), .vb_out(sd_vb)
);

assign CE_PIXEL = sd_on ? ce_pix_x2 : av_ce;
assign VGA_R    = sd_on ? sd_rgb[23:16] : av_r;
assign VGA_G    = sd_on ? sd_rgb[15:8]  : av_g;
assign VGA_B    = sd_on ? sd_rgb[7:0]   : av_b;
assign VGA_HS   = sd_on ? sd_hs : av_hs;
assign VGA_VS   = sd_on ? sd_vs : av_vs;
// Gated by sd_on and suppressed for Direct Video. sys_top applies scanlines
// itself (sys/sys_top.v: scanlines #(0) VGA_scanlines) to whatever this core
// emits, on the analog, Direct Video and HDMI paths alike -- it has no idea
// whether the raster is doubled. u_video_mode_guard deliberately defers the
// doubler switch to the next VBlank line boundary, so between the OSD write and
// that commit the raster is still native while status[4:3] already asks for
// scanlines, and every second NATIVE line gets dimmed: a half-brightness comb
// over the picture rather than a scanline effect. One frame of it on a scaled
// HDMI display, and for the whole time the request is pending on a 15 kHz set.
assign VGA_SL   = (sd_on && !direct_video) ? status[4:3] : 2'd0;

wire vga_de_in = sd_on ? ~(sd_hb | sd_vb) : ~(av_hb | av_vb);
// Direct Video is the raw native raster. Its vertical-cabinet use case is a
// physically rotated CRT; DDRAM screen rotation is for the normal HDMI /
// framebuffer path only.
wire rotation_active = !direct_video &&
                       ((rotation == 2'd1) || (rotation == 2'd2));

// Follow the established MiSTer vertical-core contract: present the native
// cabinet aspect as 4:3 horizontally and 3:4 after framebuffer rotation.
wire [11:0] scale_aspect_x = (aspect == 0)
    ? (rotation_active ? 12'd3 : 12'd4)
    : {10'd0, aspect - 1'b1};
wire [11:0] scale_aspect_y = (aspect == 0)
    ? (rotation_active ? 12'd4 : 12'd3)
    : 12'd0;

// sys/video_freak.sv SCALE encoding (video_scale_int, the case at cnt==13):
//   0 normal, 1 V-integer, 2 HV-integer narrow, 3 HV-integer wide,
//   4 HV-integer best fit (picks narrow or wide by aspect error).
// Entries 0..2 hold the values the previous mapping gave them. Entry 3 was a
// second copy of entry 1 (both 3'd4) and is now the wide variant, which was
// otherwise unreachable from the OSD.
//
// SCALE is dead while Direct Video is on -- sys_top zeroes HDMI_WIDTH/HEIGHT
// there, and video_scale_int's first divide (HDMI_HEIGHT/vsize) then returns 0,
// which is its own "integer scaling is impossible" path back to the plain
// aspect. That is why the menu entry is hidden behind H0 above.
logic [2:0] scale_mode;
always_comb begin
    case (scale_select)
        2'd1: scale_mode = 3'd4;
        2'd2: scale_mode = 3'd1;
        2'd3: scale_mode = 3'd3;
        default: scale_mode = 3'd0;
    endcase
end
wire rotate_ddram_clk, rotate_ddram_we, rotate_ddram_rd;
wire [7:0] rotate_ddram_burstcnt;
wire [28:0] rotate_ddram_addr;
wire [63:0] rotate_ddram_din;
wire [7:0] rotate_ddram_be;

screen_rotate u_screen_rotate (
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
    .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de_in),
    .rotate_ccw(!direct_video && (rotation == 2'd2)),
    .no_rotate(direct_video || (rotation == 2'd0) || (rotation == 2'd3)),
    .flip(!direct_video && (rotation == 2'd3)),
    .video_rotated(video_rotated),
    .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH),
    .FB_HEIGHT(FB_HEIGHT), .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
    .FB_VBL(FB_VBL), .FB_LL(FB_LL),
    .DDRAM_CLK(rotate_ddram_clk), .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(rotate_ddram_burstcnt), .DDRAM_ADDR(rotate_ddram_addr),
    .DDRAM_DIN(rotate_ddram_din), .DDRAM_BE(rotate_ddram_be),
    .DDRAM_WE(rotate_ddram_we), .DDRAM_RD(rotate_ddram_rd)
);

// Keep the entire screen_rotate write bundle in its producer domain. Driving
// clk_ram here advertised unrelated sampling edges for clk_sys-owned payload.
//
// DDR3 port arbitration with the ROM-load adaptor (u_ddr_rom_loader above):
// ddr_ld_acquire is only ever asserted while core_cold_reset holds ssv_core's
// video timing -- and with it screen_rotate's write stream -- idle (see
// ssv_ddr_rom_loader.sv), so this reduces to the original direct
// screen_rotate wiring whenever a load isn't in flight. The adaptor is
// read-only -- it never drives DIN and DDRAM_WE is forced low while it owns
// the port so a stale screen_rotate write can never land during a load.
assign DDRAM_CLK      = rotate_ddram_clk;
assign DDRAM_BURSTCNT = ddr_ld_acquire ? ddr_ld_burstcnt : rotate_ddram_burstcnt;
assign DDRAM_ADDR     = ddr_ld_acquire ? ddr_ld_addr     : rotate_ddram_addr;
assign DDRAM_DIN      = rotate_ddram_din;
assign DDRAM_BE       = ddr_ld_acquire ? 8'hFF           : rotate_ddram_be;
assign DDRAM_WE       = ddr_ld_acquire ? 1'b0            : rotate_ddram_we;
assign DDRAM_RD       = ddr_ld_acquire ? ddr_ld_rd       : rotate_ddram_rd;

video_freak u_video_freak (
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
    .VGA_DE_IN(vga_de_in),
    .ARX(scale_aspect_x), .ARY(scale_aspect_y),
    .CROP_SIZE(12'd0), .CROP_OFF(5'd0),
    .SCALE(scale_mode)
);

// Mute only while a persistence transfer replaces game state (NVRAM
// upload/download, NVRAM init) or the user has frozen the game from the OSD. hs_pause is deliberately NOT part of it: the
// hiscore module raises it repeatedly during boot and on every OSD open, and
// the ES5506 is clocked from ce_cpu so a short pause just holds the last
// sample. Zeroing the output there produced audible ticks. The request comes
// from clk_sys, so it is synchronised into CLK_AUDIO before it gates the
// output, and the gate is registered so AUDIO_L/R never glitch.
wire audio_mute_sys = nvram_transfer | nv_init_busy | user_pause;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
reg [1:0] audio_mute_pipe = 2'b11;
reg signed [15:0] audio_out_l = 16'sd0, audio_out_r = 16'sd0;
always @(posedge CLK_AUDIO) begin
    audio_mute_pipe <= {audio_mute_pipe[0], audio_mute_sys};
    audio_out_l <= audio_mute_pipe[1] ? 16'sd0 : audio_cdc_l;
    audio_out_r <= audio_mute_pipe[1] ? 16'sd0 : audio_cdc_r;
end
assign AUDIO_L = audio_out_l;
assign AUDIO_R = audio_out_r;
assign AUDIO_MIX = status[47:46];

// {override, activity}: no override, so the disk LED shows MiSTer's real SD/
// storage activity. It used to be forced to the renderer-overrun flag, which
// flickered in busy scenes and hid genuine disk activity.
assign LED_DISK = 2'b00;

// DDRAM_BUSY, DDRAM_DOUT and DDRAM_DOUT_READY are now genuinely consumed by
// u_ddr_rom_loader above and must not be folded into this sink.
wire unused_inputs = &{1'b0, SD_MISO,
                       SD_CD, UART_CTS, UART_RXD, UART_DSR, USER_IN,
                       clk_aux};

endmodule
