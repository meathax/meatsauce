//============================================================================
//  Sega System 32 / Multi 32 — board top (DESIGN.md §3.1)
//  Wires: V60 + bus decode (Appendix A), video pipeline, sound subsystem,
//  I/O chips, interrupt controller, protection modules, SDRAM/DDR3.
//============================================================================

import s32_pkg::*;

// Keep the V60 execution cadence as a separately testable hardware contract.
// The external BCU remains on ce_cpu (the PCB's 16.108 MHz bus cadence), while
// this enable advances the serial RTL microsequencer at clk_sys/2 to model the
// overlap of the real V60's decode/EA/execute units.  In a captured pre-fix
// Dark Edge build, running both sides from ce_cpu made its displayed gameplay
// countdown advance every 70 frames instead of MAME's measured 35-frame writes
// to 0x20a112 at PC 0x087080, consistent with alternate VBlank work coalescing.
module s32_v60_exec_cadence (
    input  wire clk,
    input  wire rst,
    input  wire pause,
    output wire ce
);
reg phase;
always @(posedge clk) begin
    if (rst || pause) phase <= 1'b0;
    else              phase <= ~phase;
end
assign ce = !pause && !phase;
endmodule

// The universal production revision uses the single-port synchronous V60
// cache. Keep this preprocessing choice local to this compilation unit.
// Fixed CE spacing (no CPU Turbo in any supported game) is common to all
// boards.
//
// The V25 MCU and its rtl/prot/ / rtl/cpu/v25/ sources were removed: they are
// exclusive to Golden Axe: Revenge of Death Adder / Arabian Fight's
// standard-board revision, which this repository no longer builds.

`ifdef S32_GAME_ONLY_STD
`define S32_AREA_ROM_CACHE
`elsif S32_GAME_ONLY
`define S32_AREA_ROM_CACHE
`endif

module s32_core #(
`ifdef S32_SYSTEM32_ONLY
    // The SegaS32 Quartus revision sets this macro so Cyclone V only pays for
    // hardware present on a single-screen System 32 board.  A future Multi 32
    // revision leaves the macro unset (or explicitly overrides the parameter).
    parameter SYSTEM32_ONLY = 1'b1
`else
    parameter SYSTEM32_ONLY = 1'b0
`endif
) (
    input             clk_sys,      // 48.317307 MHz
    input             clk_ram,      // 96.634615 MHz
    input             rst,
    // Keep CRT timing alive while game logic is held in ROM-load reset.
    input             video_rst,

    input  board_desc_t board,
    // MiSTer status[6]: which Multi 32 screen currently drives the physical
    // output. Selects which DDR3 sprite buffer half is fetched for scanout.
    input              screen_sel,

    // clock enables (from fractional CE generators in emu top)
    input             ce_cpu,       // 16.108 / 20 MHz physical V60/V70 bus
    input             ce_z80,       // 8.054 / 8.0
    input             ce_fm,
    input             ce_pcm,       // 12.5 / 10.0
    // OSD pause: the emu top zeroes ce_cpu/ce_z80/ce_pcm; the real V25 has
    // its own clk_v25-domain CE generator, so it must be told separately or
    // it keeps running against a frozen V60 (mailbox tear on ga2/arabfgt).
    input             pause,
    // Wide instruction-fetch enable, stable from reset in the production top.
    // Selects the ROM icache's dedicated 8-byte fetch port for V60 prefetch;
    // the physical V60 data/I-O bus remains on ce_cpu.  Removing this in the
    // 2026-08-14 profile merge routed every prefetch through the shared
    // ce-gated 16-bit adapter, multiplying V60 p0 SDRAM traffic and starving
    // the tile renderer's p1 port on its ~10% scanline-budget margin
    // (measured: arabfgt water rows 51-53 dropped to the stale line buffer on
    // 19/448 captured frames).  Restored 2026-08-14.
    input             fast_v60,
    // SDRAM ports (to sdram.sv in emu top)
    output            sdr_p0_req,
    output            sdr_p0_burst,
    output     [24:1] sdr_p0_addr,
    input      [63:0] sdr_p0_dout,
    input             sdr_p0_ack,
    output            sdr_p1_req,
    output     [24:3] sdr_p1_addr,
    input      [63:0] sdr_p1_dout,
    input             sdr_p1_ack,
    output            sdr_p2_req,
    output     [24:4] sdr_p2_addr,
    input     [127:0] sdr_p2_dout,
    input             sdr_p2_ack,
    output            sdr_p3_req,
    output     [24:1] sdr_p3_addr,
    input      [15:0] sdr_p3_dout,
    input             sdr_p3_ack,
    output            sdr_p4_req,
    output     [24:1] sdr_p4_addr,
    input      [15:0] sdr_p4_dout,
    input             sdr_p4_ack,
    // RF5C68 wave-RAM runtime writes share SDRAM's loader/write port in the
    // emu top. Reads use p4, whose MultiPCM region is unused by System 32.
    output            sdr_wave_wr_req,
    output     [24:1] sdr_wave_wr_addr,
    output     [15:0] sdr_wave_wr_data,
    output      [1:0] sdr_wave_wr_be,
    input             sdr_wave_wr_ack,
    output            sdr_p5_req,
    output     [24:3] sdr_p5_addr,
    input      [63:0] sdr_p5_dout,
    input             sdr_p5_ack,

    // DDR3 framebuffer service (s32_fb_if lives in emu top)
    output            fb_wr_start,
    output      [1:0] fb_wr_buf,
    output      [8:0] fb_wr_x,
    output      [7:0] fb_wr_y,
    output            fb_wr_valid,
    output     [15:0] fb_wr_pix,
    output            fb_wr_end,
    output            fb_wr_shadow,   // run RMWs dest &= 0x7fff (V-10)
    input             fb_wr_busy,     // fb_if run(s) still queued/flushing
    input             fb_wr_can_start, // fb_if capture context free for new row
    output            fb_er_req,
    output      [1:0] fb_er_buf,
    output      [7:0] fb_er_y,
    input             fb_er_ack,
    output            fb_rd_req,
    output      [1:0] fb_rd_buf,
    output      [7:0] fb_rd_y,
    input             fb_rd_ack,
    output      [8:0] fb_rd_x,
    input      [15:0] fb_rd_pix,
    // Screen B independent scanout lane (Multi32 simultaneous split display).
    output            fb_rd2_req,
    output      [1:0] fb_rd2_buf,
    output      [7:0] fb_rd2_y,
    input             fb_rd2_ack,
    input      [15:0] fb_rd2_pix,

    // V25 program load
    input             v25_prg_wr,
    input      [15:0] v25_prg_waddr,
    input       [7:0] v25_prg_wdata,

    // EEPROM NVRAM load/save
    input             eep_ld_wr,
    input       [5:0] eep_ld_addr,
    input      [15:0] eep_ld_data,
    output     [15:0] eep_rd_data,
    input       [5:0] eep_rd_addr,
    input             eep_upload,
    output            eep_modified,

    // inputs (already mapped per game class by emu top)
    input       [7:0] in_p1a, in_p2a, in_portc, in_svc12, in_svc34,
    input       [7:0] in_p1b, in_p2b, in_portc_b, in_svc12_b, in_svc34_b,
    input       [7:0] adc_ch [0:7],
    input       [7:0] ppi_pa, ppi_pb, ppi_pc,
    output            adc0_load,

    // video out (screen A; screen B via second mixer on M32)
    output     [23:0] rgb_a,
    output     [23:0] rgb_b,
    output            ce_pix,
    output            hs, vs, hb, vb,
    output      [8:0] hcnt_o, vcnt_o,   // native raster position, for the
                                         // top-level splitscreen composer
    output            mode_416_active,

    output signed [15:0] audio_l,
    output signed [15:0] audio_r,
    output      [7:0] out_lamps,
    output      [1:0] out_steering_motors
);

// The production profile is one resource shape shared by all supported
// Multi 32 descriptors.  S32_GAME_ONLY_STD implies GAME_ONLY, retaining the
// ROM-cache/resource optimisation without compiling a separate game image.
`ifdef S32_UNIVERSAL
localparam GAME_ONLY     = 1'b1;
localparam GAME_ONLY_STD = 1'b1;
`elsif S32_GAME_ONLY_STD
localparam GAME_ONLY     = 1'b1;
localparam GAME_ONLY_STD = 1'b1;
`elsif S32_GAME_ONLY
localparam GAME_ONLY     = 1'b1;
localparam GAME_ONLY_STD = 1'b0;
`else
localparam GAME_ONLY     = 1'b0;
localparam GAME_ONLY_STD = 1'b0;
`endif

// All production titles use the Sega System Multi 32 dual-video shape.  Small
// board peripherals and title-specific conventions remain descriptor
// selected; keeping the common Multi 32 datapath build-time constant avoids a
// second copy of the video/RAM architecture.
wire       cfg_multi32           = 1'b1;
wire       cfg_has_adc           = board.has_adc;
wire       cfg_has_ppi           = board.has_ppi;
wire       cfg_has_motor_hle     = 1'b0;
wire       cfg_sprite_bank_valid = board.sprite_bank_valid;
wire [1:0] cfg_sprite_bank_mask  = board.sprite_bank_mask;
wire       cfg_flip_y            = board.flip_y;
// A System32-only bitstream must not enter a Multi 32 runtime configuration if
// it is accidentally paired with a Multi 32 MRA.  The universal source build
// retains the descriptor-selected path when SYSTEM32_ONLY is false.  GAME_ONLY
// the production profile is a dedicated single-screen System 32 build by definition, so it
// force the System 32 configuration even if a QSF sets a game macro without
// S32_SYSTEM32_ONLY (previously that mismatch left is_multi32 following the
// descriptor while optional hardware it implies was compiled out).
// The production image is intentionally Multi 32-only.  SYSTEM32_ONLY remains
// available to the standalone System 32 verification profile, while GAME_ONLY
// no longer changes the runtime board class.
wire is_multi32 = SYSTEM32_ONLY ? 1'b0 : cfg_multi32;

// ---------------------------------------------------------------------------
// CPU + bus adapter
// ---------------------------------------------------------------------------
wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;
wire        wr_stb;

wire        irq_n;
wire [7:0]  irq_vector;

// dedicated wide instruction-fetch port (FAST_IFETCH): the prefetch reads whole
// 8-byte ROM icache lines here at clk_sys latency, bypassing the ce-gated 16-bit
// data adapter that otherwise bottlenecks fetch bandwidth.  RESTORED 2026-08-14:
// the profile merge removed this transport, which multiplied V60 p0 SDRAM
// transactions and starved the tile renderer's p1 port (see the fast_v60 port
// comment above for the measured arabfgt evidence).
wire        if_req;
wire [23:0] if_addr;                 // frontier byte address (low 3 bits = intra-line
                                    // offset used to pre-align the returned line)
`ifdef S32_AREA_ROM_CACHE
wire [63:0] if_data;
wire        if_served;
`else
// The general fallback cache is data-only; without a wide-port server the
// V60 must never issue if_ requests, so FAST_IFETCH is forced off below and
// these are inert constants rather than undriven regs.
wire [63:0] if_data   = 64'd0;
wire        if_served = 1'b0;
`endif
                                    // held while a fetch result is presented
wire        if_ack = if_served;     // held (not pulsed) so the ce-gated CPU never
                                    // misses it between its enable ticks

// Compile the wide-fetch transport into production. fast_v60 selects it at
// runtime only after reset; the fallback (non-area-cache) configuration has no
// wide-port server, so it hard-disables the capability.
`ifndef FAST_IFETCH_EN
 `ifdef S32_AREA_ROM_CACHE
  `define FAST_IFETCH_EN 1'b1
 `else
  `define FAST_IFETCH_EN 1'b0
 `endif
`endif
// The PCB clocks the V60 at 16.108 MHz, but the processor overlaps its
// decode/EA/execute units while the external BCU continues to issue minimum
// three-clock bus cycles.  Our single-FSM implementation has no independent
// pipeline stages, so advancing its internal microsequencer at clk_sys/2
// models that overlap without shortening the physical bus cadence below.
// The fixed alternating CE also preserves s32.sdc's two-cycle V60 timing
// contract: no V60 register can update on adjacent clk_sys edges.
wire v60_exec_ce;
s32_v60_exec_cadence v60_cadence (
    .clk(clk_sys), .rst(rst), .pause(pause), .ce(v60_exec_ce)
);

// IS_V70=1: the real chip is a NEC D70632R-20 (V70), confirmed by physical
// board marking and MAME device config, not a V60. The only functional
// effect today is the processor ID register (PIR = 0x7000, not 0x6000) --
// s32_v60_bus's external bus stays 16-bit regardless of this parameter (see
// that file's header); OutRunners has been verified booting on that 16-bit
// adapter, so a true 32-bit V70 bus is deferred pending evidence it's needed.
s32_v60 #(.START_PC(32'hFFFFFFF0), .FAST_IFETCH(`FAST_IFETCH_EN), .IS_V70(1'b1)) v60 (   // MAME reset PC (audit R20 V60-21)
    .clk(clk_sys), .ce(v60_exec_ce), .rst(rst),
    .fast_ifetch(fast_v60),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_ack(),
    .nmi_n(1'b1)
);


s32_v60_bus vbus (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

// ---------------------------------------------------------------------------
// address decode (Appendix A) — 24-bit space
// ---------------------------------------------------------------------------
wire [23:0] A = {m_addr, 1'b0};
wire sel_rom    = (A < 24'h200000);
wire sel_wram   = (A[23:20] == 4'h2);
wire sel_vram   = (A[23:20] == 4'h3);
wire sel_sprram = (A[23:20] == 4'h4);
wire sel_sprctl = (A[23:20] == 4'h5);
wire sel_shared = (A[23:20] == 4'h7);
wire sel_comm   = (A[23:16] == 8'h80);
// MAME's regular System 32 map exposes the communication-board CN and FG
// flip-flop registers at 0x801000/0x801002.  They are byte registers, not
// open-bus locations: reset reads 0xFE from both, CN stores bit 0, and FG
// stores bit 0 only while CN is enabled (s32comm.cpp).
wire sel_comm_cn  = sel_comm && (A[15:1] == 15'h0800);
wire sel_comm_fg  = sel_comm && (A[15:1] == 15'h0801);
wire sel_dual   = (A[23:16] == 8'h81);
wire sel_prot_a = (A[23:20] == 4'hA);
wire sel_v25    = sel_prot_a && (A[19:12] == 8'h00); // 0xA00000-A00FFF
// MAME's I/O mirrors ignore A19:A7 (System 32) or A18:A7 (Multi 32).
// A6:A5 remain decoded: 00 selects the 5296 and A6 selects expansion I/O.
wire io0_area   = (A[23:20] == 4'hC) && (!is_multi32 || !A[19]);
wire sel_io0    = io0_area && (A[6:5] == 2'b00);
wire sel_ioex   = io0_area && A[6];
wire sel_io1    = is_multi32 && (A[23:20] == 4'hC) && A[19] &&
                  (A[6:5] == 2'b00);
wire sel_intc   = (A[23:20] == 4'hD) && !A[19];
wire sel_rand   = (A[23:20] == 4'hD) &&  A[19];
wire sel_romhi  = (A[23:20] == 4'hF);

// Palette/mixer windows are mirrored through bits 19:17 (System 32) or
// 18:17 (Multi 32); A16 alone distinguishes palette RAM from mixer regs.
wire pal_area   = (A[23:20] == 4'h6);
wire is_pal0    = pal_area && !A[16] && (!is_multi32 || !A[19]);
wire is_mix0    = pal_area &&  A[16] && (!is_multi32 || !A[19]);
wire is_pal1    = is_multi32 && pal_area && A[19] && !A[16];
wire is_mix1    = is_multi32 && pal_area && A[19] &&  A[16];

// ---------------------------------------------------------------------------
// work RAM — dual port (CPU + protection)
//
// System 32 has 64 KiB (32K x 16); Multi 32 has 128 KiB (64K x 16).  Keeping
// the depth elaboration-time constant lets Quartus remove 64 M10Ks from the
// SegaS32 revision instead of retaining the runtime-selectable maximum.
// ---------------------------------------------------------------------------
localparam integer WRAM_ADDR_WIDTH = SYSTEM32_ONLY ? 15 : 16;
localparam integer WRAM_WORDS      = SYSTEM32_ONLY ? 32768 : 65536;
wire [15:0] wram_q;
wire [WRAM_ADDR_WIDTH-1:0] wram_a = SYSTEM32_ONLY ? A[15:1] :
                                    (is_multi32 ? A[16:1] : {1'b0, A[15:1]});

// Work RAM's second port existed only for the standard-board protection
// responders (Dark Edge / J.League / Burning Rival HLE) and the V25 mailbox.
// OutRunners uses neither -- MAME's init_orunners() installs no protection --
// so port B is tied inactive rather than carried as dead arbitration logic.
s32_big_dpram #(
    .ADDR_WIDTH(WRAM_ADDR_WIDTH), .NUM_WORDS(WRAM_WORDS)
) work_ram (
    .clock_a(clk_sys), .address_a(wram_a),
    .data_a(m_wdata), .byteena_a(m_be),
    .wren_a(m_req && m_we && sel_wram), .q_a(wram_q),
    .clock_b(clk_sys), .address_b('0),
    .data_b(16'h0000), .byteena_b(2'b00),
    .wren_b(1'b0), .q_b()
);


// ---------------------------------------------------------------------------
// video subsystem
// ---------------------------------------------------------------------------
wire [15:0] vram_cpu_q, vram_vid_q;
wire        io0_cnt1, io0_cnt2;
wire        io1_cnt1;              // Multi 32 screen-B display enable (io1 CNT1)
wire [15:0] vid_vaddr;
wire [15:0] r1ff00, r1ff02, r1ff04, r1ff06, r1ff5c, r1ff5e;
wire [15:0] r1ff88, r1ff8a, r1ff8c, r1ff8e;
wire [15:0] w_scrollfracx [0:1];
wire [15:0] w_scrollfracy [0:1];
wire [15:0] w_scrollx [0:3];
wire [15:0] w_scrolly [0:3];
wire [15:0] w_offsx [0:3];
wire [15:0] w_offsy [0:3];
wire [15:0] w_pages [0:7];
wire [15:0] w_zoomx [0:1];
wire [15:0] w_zoomy [0:1];
wire [15:0] w_clips [0:19];

s32_vram vram (
    .clk(clk_sys), .vid_clk(clk_ram),
    .cpu_we(m_req && m_we && sel_vram),
    .cpu_addr(A[16:1]),
    .cpu_wdata(m_wdata), .cpu_be(m_be), .cpu_rdata(vram_cpu_q),
    .vid_addr(vid_vaddr), .vid_rdata(vram_vid_q),
    .reg_1ff00(r1ff00), .reg_1ff02(r1ff02), .reg_1ff04(r1ff04),
    .reg_1ff06(r1ff06),
    .reg_scrollfracx(w_scrollfracx), .reg_scrollfracy(w_scrollfracy),
    .reg_scrollx(w_scrollx), .reg_scrolly(w_scrolly),
    .reg_offsx(w_offsx), .reg_offsy(w_offsy),
    .reg_pages(w_pages), .reg_zoomx(w_zoomx), .reg_zoomy(w_zoomy),
    .reg_1ff5c(r1ff5c), .reg_1ff5e(r1ff5e), .reg_clips(w_clips),
    .reg_1ff88(r1ff88), .reg_1ff8a(r1ff8a), .reg_1ff8c(r1ff8c),
    .reg_1ff8e(r1ff8e)
);

// sprite RAM: CPU port + engine port
wire [15:0] sprram_q, sprlist_q;
wire [15:0] slist_addr;
s32_big_dpram #(
    .ADDR_WIDTH(16), .NUM_WORDS(65536), .MIXED_RDW_MODE("DONT_CARE"),
    .PORT_B_READ_ONLY(1'b1)
) sprite_ram (
    .clock_a(clk_sys), .address_a(A[16:1]),
    .data_a(m_wdata), .byteena_a(m_be),
    .wren_a(m_req && m_we && sel_sprram), .q_a(sprram_q),
    .clock_b(clk_ram), .address_b(slist_addr),
    .data_b(16'h0000), .byteena_b(2'b00),
    .wren_b(1'b0), .q_b(sprlist_q)
);


// CRT timing
wire mode_416;
wire vbl_start, vbl_end;
wire [8:0] hcnt, vcnt;
s32_video crt (
    .clk(clk_sys), .rst(video_rst), .mode_416(mode_416),
    .mode_active(mode_416_active),
    .ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt),
    .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
    .vblank_start(vbl_start), .vblank_end(vbl_end)
);
assign hcnt_o = hcnt;
assign vcnt_o = vcnt;

// tilemap engine (clk_ram domain; registers quasi-static)
wire        tm_lb_we;
wire [2:0]  tm_lb_layer;
wire [8:0]  tm_lb_x;
wire [13:0] tm_lb_pix;
wire        line_start_r;
wire [8:0]  render_line;
wire        tm_lb_bank;
wire        tm_line_done;
wire        tm_line_busy;
wire [7:0]  io0_ph;
// Snapshot of CPU-domain video controls used for one complete rendered line.
// These registers are captured at the line-start boundary below.
reg        tm_mode_416;
reg  [7:0] tm_ext_tilebank;
reg [15:0] tm_r1ff00, tm_r1ff02, tm_r1ff04, tm_r1ff06;
reg [15:0] tm_r1ff5c, tm_r1ff5e, tm_r1ff88, tm_r1ff8a, tm_r1ff8c, tm_r1ff8e;
reg [15:0] tm_scrollfracx [0:1], tm_scrollfracy [0:1];
reg [15:0] tm_scrollx [0:3], tm_scrolly [0:3];
reg [15:0] tm_offsx [0:3], tm_offsy [0:3];
reg [15:0] tm_pages [0:7];
reg [15:0] tm_zoomx [0:1], tm_zoomy [0:1];
reg [15:0] tm_clips [0:19];
reg [15:0] tm_clips_cdc [0:19];
reg [15:0] tm_r1ff5c_cdc;
// The tile renderer snapshots controls for the line in the opposite parity
// bank.  The mixer must use the matching snapshot for the line currently
// being scanned; using tilemap.layer_off directly lets a mid-frame register
// write gate the previous line with the next line's state.
reg  [5:0] tm_layer_off_bank0, tm_layer_off_bank1;
reg  [8:0] mix_disp_x_cdc;
reg [15:0] mix_bg_ctrl;
integer tm_init_i;
integer tm_cap_i;
integer tm_cdc_i;
initial begin
    tm_mode_416 = 1'b1;
    tm_ext_tilebank = 8'b0;
    tm_r1ff00 = 16'h8000;
    tm_r1ff02 = 0; tm_r1ff04 = 0; tm_r1ff06 = 0;
    tm_r1ff5c = 0; tm_r1ff5c_cdc = 0; tm_r1ff5e = 0;
    mix_bg_ctrl = 0;
    tm_r1ff88 = 0; tm_r1ff8a = 0; tm_r1ff8c = 0; tm_r1ff8e = 0;
    for (tm_init_i = 0; tm_init_i < 4; tm_init_i = tm_init_i + 1) begin
        tm_scrollx[tm_init_i] = 0; tm_scrolly[tm_init_i] = 0;
        tm_offsx[tm_init_i] = 0; tm_offsy[tm_init_i] = 0;
    end
    for (tm_init_i = 0; tm_init_i < 8; tm_init_i = tm_init_i + 1) tm_pages[tm_init_i] = 0;
    for (tm_init_i = 0; tm_init_i < 2; tm_init_i = tm_init_i + 1) begin
        tm_scrollfracx[tm_init_i] = 0; tm_scrollfracy[tm_init_i] = 0;
        tm_zoomx[tm_init_i] = 16'h0200; tm_zoomy[tm_init_i] = 16'h0200; // neutral 1.0 zoom default
    end
    for (tm_init_i = 0; tm_init_i < 20; tm_init_i = tm_init_i + 1) begin
        tm_clips[tm_init_i] = 0;
        tm_clips_cdc[tm_init_i] = 0;
    end
    tm_layer_off_bank0 = 6'b111111;
    tm_layer_off_bank1 = 6'b111111;
    mix_disp_x_cdc = 0;
end

// clk_sys is a phase-related divide-by-two of clk_ram. Capture CPU/video
// controls on clk_ram's falling edge so the following rising-edge consumers
// have a full half-cycle of setup/hold margin.
always @(negedge clk_ram) begin
    // These are sampling registers, not architectural state. They have
    // explicit power-up values and are overwritten on every falling edge, so
    // a reset mux only creates a long status[0] -> inverted-clk_ram half-cycle
    // path across all 329 bits.
    mix_disp_x_cdc <= hcnt;
    tm_r1ff5c_cdc <= r1ff5c;
    for (tm_cdc_i = 0; tm_cdc_i < 20; tm_cdc_i = tm_cdc_i + 1)
        tm_clips_cdc[tm_cdc_i] <= w_clips[tm_cdc_i];
end

// Launch at the start of the preceding scanline.  This gives the renderer a
// complete line period to fill the opposite parity buffer; the former hblank
// launch left only 90-96 pixel periods and routinely missed its deadline when
// SDRAM was contended by the V25.  ce_pix/hcnt are held for multiple clk_ram
// edges, so the scheduler performs the required event qualification.
wire tm_line_boundary = ce_pix && (hcnt == 9'd0);
wire [8:0] tm_next_line = (vcnt == 9'd261) ? 9'd0 : vcnt + 1'd1;
// Only kick the renderer for the visible lines 0-223 (tm_next_line ranges over
// 0..261; vcnt 261 pre-renders line 0).  Rendering the 38 vblank lines filled
// never-displayed parity banks and burned ~15% of frame SDRAM p1 bandwidth the
// V60/V25/sprite clients contend for (audit R20 TM-5).  The backdrop snapshot
// below keeps the ungated boundary so per-line line-color still updates.
wire tm_render_kick = tm_line_boundary && (tm_next_line <= 9'd223);
// Holosseum is mounted with ORIENTATION_FLIP_Y.  Keep timing and line-buffer
// parity in visible-screen order, but render the vertically mirrored source
// scanline into that bank.
wire [8:0] tm_source_line = (cfg_flip_y && render_line <= 9'd223)
                          ? (9'd223 - render_line) : render_line;
s32_tile_line_scheduler tile_line_scheduler (
    .clk(clk_ram), .rst(rst),
    .line_kick(tm_render_kick), .next_line(tm_next_line),
    .line_done(tm_line_done), .line_start(line_start_r),
    .render_line(render_line), .lb_bank(tm_lb_bank), .busy(tm_line_busy)
);

always @(posedge clk_ram) begin
    // The backdrop is generated by the mixer for the line currently being
    // scanned, while the tile renderer snapshots controls for the following
    // line.  Keep a separate current-line copy of VRAM $1FF5E so a mid-frame
    // write cannot tear one backdrop scanline or lead it by one line.
    if (rst)
        mix_bg_ctrl <= 16'h0000;
    else if (tm_line_boundary)
        mix_bg_ctrl <= r1ff5e;

    if (line_start_r) begin
        // Snapshot the CPU-domain register file once per line. The renderer
        // observes only this stable copy until line_done.  A missed boundary
        // cannot mutate the in-flight line, bank, or control state.
        tm_mode_416 <= mode_416_active;
        tm_ext_tilebank <= io0_ph;
        tm_r1ff00 <= r1ff00; tm_r1ff02 <= r1ff02;
        tm_r1ff04 <= r1ff04; tm_r1ff06 <= r1ff06;
        tm_r1ff5c <= tm_r1ff5c_cdc; tm_r1ff5e <= r1ff5e;
        tm_r1ff88 <= r1ff88; tm_r1ff8a <= r1ff8a;
        tm_r1ff8c <= r1ff8c; tm_r1ff8e <= r1ff8e;
        if (tm_lb_bank)
            tm_layer_off_bank1 <= {
                r1ff02[5] | r1ff8e[5],
                r1ff02[3] | r1ff8e[4] | r1ff00[13],
                r1ff02[2] | r1ff8e[3] | r1ff00[12],
                r1ff02[1] | r1ff8e[2],
                r1ff02[0] | r1ff8e[1],
                r1ff02[4] | r1ff8e[0]
            };
        else
            tm_layer_off_bank0 <= {
            r1ff02[5] | r1ff8e[5],
            r1ff02[3] | r1ff8e[4] | r1ff00[13],
            r1ff02[2] | r1ff8e[3] | r1ff00[12],
            r1ff02[1] | r1ff8e[2],
            r1ff02[0] | r1ff8e[1],
            r1ff02[4] | r1ff8e[0]
            };
        for (tm_cap_i = 0; tm_cap_i < 8; tm_cap_i = tm_cap_i + 1)
            tm_pages[tm_cap_i] <= w_pages[tm_cap_i];
        for (tm_cap_i = 0; tm_cap_i < 20; tm_cap_i = tm_cap_i + 1)
            tm_clips[tm_cap_i] <= tm_clips_cdc[tm_cap_i];
    end

    // Whole-layer scroll, zoom and centre are frame quantities, not per-line
    // ones: the 315-5387 exposes rowscroll/rowselect tables ($1FF04) precisely
    // so software can vary scroll per scanline, which would be redundant if
    // the scroll registers themselves took effect mid-frame.  Capturing them
    // per line let a mid-frame update land between the integer ($1FF16) and
    // fractional ($1FF14) halves of one scroll value, so the scanlines drawn
    // in between mixed an old fraction with a new integer and rendered the
    // layer at the wrong source Y.  Snapshot once at vblank instead.
    if (vbl_start) begin
        for (tm_cap_i = 0; tm_cap_i < 4; tm_cap_i = tm_cap_i + 1) begin
            tm_scrollx[tm_cap_i] <= w_scrollx[tm_cap_i];
            tm_scrolly[tm_cap_i] <= w_scrolly[tm_cap_i];
            tm_offsx[tm_cap_i] <= w_offsx[tm_cap_i];
            tm_offsy[tm_cap_i] <= w_offsy[tm_cap_i];
        end
        for (tm_cap_i = 0; tm_cap_i < 2; tm_cap_i = tm_cap_i + 1) begin
            tm_scrollfracx[tm_cap_i] <= w_scrollfracx[tm_cap_i];
            tm_scrollfracy[tm_cap_i] <= w_scrollfracy[tm_cap_i];
            tm_zoomx[tm_cap_i] <= w_zoomx[tm_cap_i];
            tm_zoomy[tm_cap_i] <= w_zoomy[tm_cap_i];
        end
    end
end

wire [5:0] tm_layer_off;
wire [5:0] tm_layer_off_disp = vcnt[0] ? tm_layer_off_bank1 : tm_layer_off_bank0;
wire [21:3] tile_rom_addr;
s32_tilemap tilemap (
    .clk(clk_ram), .rst(rst),
    .line(tm_source_line), .line_start(line_start_r), .line_done(tm_line_done),
    .mode_416(tm_mode_416), .is_multi32(is_multi32), .ext_tilebank(tm_ext_tilebank), .layer_off_o(tm_layer_off),
    .r1ff00(tm_r1ff00), .r1ff02(tm_r1ff02), .r1ff04(tm_r1ff04), .r1ff06(tm_r1ff06),
    .r1ff5c(tm_r1ff5c), .r1ff5e(tm_r1ff5e),
    .r1ff88(tm_r1ff88), .r1ff8a(tm_r1ff8a), .r1ff8c(tm_r1ff8c), .r1ff8e(tm_r1ff8e),
    .scrollfracx(tm_scrollfracx), .scrollfracy(tm_scrollfracy),
    .scrollx(tm_scrollx), .scrolly(tm_scrolly),
    .offsx(tm_offsx), .offsy(tm_offsy),
    .pages(tm_pages), .zoomx(tm_zoomx), .zoomy(tm_zoomy), .clips(tm_clips),
    .vram_addr(vid_vaddr), .vram_rdata(vram_vid_q),
    .tile_req(sdr_p1_req), .tile_addr(tile_rom_addr),
    .tile_data(sdr_p1_dout), .tile_ack(sdr_p1_ack),
    .lb_we(tm_lb_we), .lb_layer(tm_lb_layer), .lb_x(tm_lb_x), .lb_pix(tm_lb_pix)
);
// The 4 MB tile region begins at the non-power-of-two-aligned 0x600000.
// Concatenating only the high address bits placed reads at 0x400000 and would
// fetch sound ROM on hardware; add the renderer's region-local row address.
assign sdr_p1_addr = SDR_TILES_BASE[24:3] + {3'b000, tile_rom_addr};

// sprite engine
wire [7:0] sprctl_q;
wire [1:0] disp_buf;
wire [1:0] spr_scan_buf;
s32_sprite #(
    .VERIFY_SROM(1'b0)
) sprite (
    .clk(clk_ram), .rst(rst), .is_multi32(is_multi32),
    .screen_sel(screen_sel),
    .verify_srom(1'b0),  // V25-only sprite-ROM cross-check; no V25 on OutRunners
    // Old MRAs predate bank metadata and therefore retain the original
    // four-bank address space. New descriptors mirror 4/8 MiB ROMs exactly.
    .srom_bank_mask(cfg_sprite_bank_valid ? cfg_sprite_bank_mask : 2'b11),
    // Logical swap/render remains 50 us after vblank end. Completed physical
    // frames publish at vblank start so scanout never sees an in-flight buffer.
    .present(vbl_start), .vblank(vbl_end),
    .ctl_we(wr_stb && m_we && sel_sprctl && m_be[0]),
    .ctl_addr(A[3:1]), .ctl_wdata(m_wdata[7:0]),
    .ctl_rdata(sprctl_q), .ctl_raddr(A[3:1]),
    .slist_addr(slist_addr), .slist_data(sprlist_q),
    .srom_req(sdr_p2_req), .srom_addr(sdr_p2_addr[23:4]),
    .srom_data(sdr_p2_dout), .srom_ack(sdr_p2_ack),
    .fb_wr_start(fb_wr_start), .fb_wr_buf(fb_wr_buf), .fb_wr_x(fb_wr_x),
    .fb_wr_y(fb_wr_y), .fb_wr_valid(fb_wr_valid), .fb_wr_pix(fb_wr_pix),
    .fb_wr_end(fb_wr_end),
    .fb_wr_shadow(fb_wr_shadow), .fb_busy(fb_wr_busy),
    .fb_can_start(fb_wr_can_start),
    .fb_er_req(fb_er_req), .fb_er_buf(fb_er_buf), .fb_er_y(fb_er_y),
    .fb_er_ack(fb_er_ack),
    .disp_buf(disp_buf), .scan_buf(spr_scan_buf)
);
assign sdr_p2_addr[24] = 1'b1;   // sprites region base 0x1000000

// TM-1: CRT/tilemap screen-width authority is VRAM $1FF00 bit 15, matching
// MAME screen_update_system32 / multi32_update, which set the visible area to
// 52*8 (416) when that bit is set and 40*8 (320) otherwise.  The sprite engine
// keeps its own width bit (ctl_latched[6][0]) for sprite-side clipping, exactly
// MAME's split (games program both consistently).  $1FF00 powers up 0x8000
// (bit 15 = 1 => 416), preserving the prior power-on default.
assign mode_416 = r1ff00[15];

// Sprite line prefetch for mixer. Hold the request and its address until the
// DDR service acknowledges it; a one-cycle pulse was lost whenever an erase
// or sprite write occupied the framebuffer engine. The framebuffer interface
// now fills an inactive ping-pong line bank, so launch near the start of the
// preceding line and give the line-buffer fetch almost a whole scanline.
reg       fb_rd_req_r;
reg [1:0] fb_rd_buf_r;
reg [7:0] fb_rd_y_r;
reg       fb_rd2_req_r;
reg [1:0] fb_rd2_buf_r;
reg [7:0] fb_rd2_y_r;
// Prefetch only lines that will actually display: kicks during vcnt 0-222
// fetch lines 1-223 and vcnt 261 fetches next frame's line 0.  The former
// ungated kick also ran through the 37 vblank lines, fetching nonexistent
// buffer rows 224-255 and wasting ~14% of the DDR line-read bandwidth (same
// rationale as the TM-5 tilemap vblank suppression).
wire fb_rd_kick = ce_pix && hcnt == 9'd16 &&
                  (vcnt < 9'd223 || vcnt == 9'd261);
wire [7:0] fb_next_y = (vcnt == 9'd261) ? (cfg_flip_y ? 8'd223 : 8'd0) :
                           (cfg_flip_y ? (8'd222 - vcnt[7:0])
                                       : (vcnt[7:0] + 8'd1));
// Both scanout lanes are fixed to their own monitor's physical buffer
// (bit1 = monitor 0/1, bit0 = the shared double-buffer flip -- one SWAP
// command flips both monitors together). Declared before first use: ModelSim
// vlog rejects a forward reference to a net inside a procedural block.
//
// R_SWAP publishes scan_buf only after the prior hidden pass has completed.
// Both monitors share its A/B selector; bit 1 selects the physical monitor.
wire [1:0] spr_scan_buf_a = {1'b0, spr_scan_buf[0]};
wire [1:0] spr_scan_buf_b = {1'b1, spr_scan_buf[0]};

`ifdef SIMULATION
always @(posedge clk_ram) begin
    if (!rst && is_multi32) begin
        if (fb_er_req && (fb_er_buf[0] == spr_scan_buf[0]))
            $fatal(1, "Multi32 sprite erase aliased displayed bank");
        if ((fb_wr_start || fb_wr_valid) &&
            (fb_wr_buf[0] == spr_scan_buf[0]))
            $fatal(1, "Multi32 sprite write aliased displayed bank");
    end
end
`endif
always @(posedge clk_ram) begin
    if (rst) begin
        fb_rd_req_r <= 1'b0;
        fb_rd_buf_r <= 2'd0;
        fb_rd_y_r   <= 8'd0;
    end
    else begin
        if (fb_rd_req_r) begin
            if (fb_rd_ack) fb_rd_req_r <= 1'b0;
        end
        else if (!fb_rd_ack && fb_rd_kick) begin
            fb_rd_req_r <= 1'b1;
            // Ordinary System 32 A/B scanout. Physical selectors change only
            // when a complete field is published, so the fetch cannot observe
            // an in-flight render. Lane A is fixed to monitor 0 (spr_scan_buf_a
            // below), independent of status[6]/screen_sel, so both scanout
            // lanes stay correct simultaneously for splitscreen -- screen_sel
            // now only selects the final display mux, not which sprite data
            // is fetched.
            fb_rd_buf_r <= spr_scan_buf_a;
            // CRT lines are 0..261. Truncating line 261 before adding produced
            // line 6 instead of the next frame's line 0. Shared with lane B's
            // identical mux below via fb_next_y.
            fb_rd_y_r <= fb_next_y;
        end
    end
end
assign fb_rd_req = fb_rd_req_r;
assign fb_rd_buf = fb_rd_buf_r;
assign fb_rd_y   = fb_rd_y_r;
assign fb_rd_x   = hcnt;

always @(posedge clk_ram) begin
    if (rst) begin
        fb_rd2_req_r <= 1'b0;
        fb_rd2_buf_r <= 2'd0;
        fb_rd2_y_r   <= 8'd0;
    end
    else begin
        if (fb_rd2_req_r) begin
            if (fb_rd2_ack) fb_rd2_req_r <= 1'b0;
        end
        else if (!fb_rd2_ack && fb_rd_kick) begin
            fb_rd2_req_r <= 1'b1;
            fb_rd2_buf_r <= spr_scan_buf_b;
            fb_rd2_y_r <= fb_next_y;
        end
    end
end
assign fb_rd2_req = fb_rd2_req_r;
assign fb_rd2_buf = fb_rd2_buf_r;
assign fb_rd2_y   = fb_rd2_y_r;

// mixers + palettes
// mix0 (screen A) reads lane A's fetched line; mix1 (screen B) reads its own
// independent lane B fetch (fb_rd2_*, above). Both lanes fetch every frame
// regardless of which screen is currently displayed -- required so the
// side-by-side splitscreen composer can show both simultaneously.
wire [15:0] fb_rd_pix_b = fb_rd2_pix;
`ifdef S32_UNIVERSAL_DISABLED
`define S32_MIX_PIX_PIPE
`elsif S32_GAME_ONLY_STD
`define S32_MIX_PIX_PIPE
`elsif S32_GAME_ONLY
`define S32_MIX_PIX_PIPE
`endif
`ifdef S32_MIX_PIX_PIPE
`undef S32_MIX_PIX_PIPE
// The fetched sprite line lives in the top-level framebuffer M10K while the
// mixer is placed with the palette/video logic.  Stage both the sprite pixel
// and its display-X marker once in this universal profile. The mixer
// still snapshots them together, one clock later within the same 12+ clock
// pixel period, but the long M10K-to-priority-bank route is split at a
// freely placeable register.
reg [15:0] fb_rd_pix_mix_pipe;
reg  [8:0] mix_disp_x_pipe;
always @(posedge clk_ram) begin
    fb_rd_pix_mix_pipe <= fb_rd_pix;
    mix_disp_x_pipe    <= mix_disp_x_cdc;
end
wire [15:0] fb_rd_pix_mix = fb_rd_pix_mix_pipe;
wire  [8:0] mix_disp_x    = mix_disp_x_pipe;
`else
wire [15:0] fb_rd_pix_mix = fb_rd_pix;
wire  [8:0] mix_disp_x    = mix_disp_x_cdc;
`endif
wire [15:0] pal0_cpu_q, pal1_cpu_q;
wire [13:0] mix0_pal_addr, mix1_pal_addr;
wire [15:0] mix0_pal_q, mix1_pal_q;
wire [15:0] mix0_q, mix1_q;
wire [15:0] mix0_r4e, mix1_r4e;
wire [13:0] mix_px_text, mix_px_nbg0, mix_px_nbg1;
wire [13:0] mix_px_nbg2, mix_px_nbg3, mix_px_bmp;

// Both current screen mixers consume the same tilemap-renderer stream.  Share
// the twelve physical parity/layer RAM banks and fan out their registered
// pixels; the mixers retain independent registers, palettes and RGB pipelines.
s32_linebuf shared_lbuf (
    .clk(clk_ram),
    .lb_we(tm_lb_we), .lb_layer(tm_lb_layer), .lb_wx(tm_lb_x),
    .lb_wpix(tm_lb_pix), .lb_bank(tm_lb_bank),
    .rd_x(hcnt), .rd_bank(vcnt[0]),
    .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
    .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
    .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp)
);

s32_palette pal0 (
    .clk(clk_sys), .mix_clk(clk_ram),
    .cpu_we(m_req && m_we && is_pal0),
    .cpu_addr(A[15:1]), .cpu_wdata(m_wdata), .cpu_be(m_be),
    .cpu_rdata(pal0_cpu_q), .mixer_r4e(mix0_r4e),
    .mix_addr(mix0_pal_addr), .mix_data(mix0_pal_q)
);

s32_mixer mix0 (
    .clk(clk_ram), .rst(rst),
    .reg_we(wr_stb && m_we && is_mix0),
    .reg_addr(A[6:1]), .reg_wdata(m_wdata), .reg_be(m_be),
    .reg_rdata(mix0_q), .reg_raddr(A[6:1]), .reg_r4e(mix0_r4e),
    .disp_x(mix_disp_x), .disp_y(vcnt), .disp_active(~hb & ~vb),
    .frame_latch(vbl_start),
    .display_en(io0_cnt1), .flip_y(cfg_flip_y), .layer_off(tm_layer_off_disp), .bg_ctrl(mix_bg_ctrl),
    .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
    .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
    .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp),
    .spr_pix(fb_rd_pix_mix),
    .pal_addr(mix0_pal_addr), .pal_data(mix0_pal_q),
    .rgb(rgb_a)
);

generate
    if (SYSTEM32_ONLY) begin : g_system32_only_video
        // 0x680000/0x690000 are Multi 32-only windows, so System 32 reads
        // continue through the normal open-bus default in the CPU read mux.
        // Mirror A onto the unused output to keep the top-level screen selector
        // harmless for single-screen MRAs.
        assign pal1_cpu_q     = 16'hffff;
        assign mix1_q         = 16'hffff;
        assign mix1_r4e       = 16'h0000;
        assign mix1_pal_addr  = 14'h0000;
        assign mix1_pal_q     = 16'h0000;
        assign rgb_b          = rgb_a;
    end
    else begin : g_multi32_video
        // B7: Multi 32 second screen — palette bank 1 (0x680000) + mixer 1
        // (0x690000).  This branch remains available to a future Multi 32 QSF.
        s32_palette pal1 (
            .clk(clk_sys), .mix_clk(clk_ram),
            .cpu_we(m_req && m_we && is_pal1),
            .cpu_addr(A[15:1]), .cpu_wdata(m_wdata), .cpu_be(m_be),
            .cpu_rdata(pal1_cpu_q), .mixer_r4e(mix1_r4e),
            .mix_addr(mix1_pal_addr), .mix_data(mix1_pal_q)
        );
        s32_mixer mix1 (
            .clk(clk_ram), .rst(rst),
            .reg_we(wr_stb && m_we && is_mix1),
            .reg_addr(A[6:1]), .reg_wdata(m_wdata), .reg_be(m_be),
            .reg_rdata(mix1_q), .reg_raddr(A[6:1]), .reg_r4e(mix1_r4e),
            .disp_x(mix_disp_x), .disp_y(vcnt), .disp_active(~hb & ~vb),
            .frame_latch(vbl_start),
            .display_en(io1_cnt1), .flip_y(cfg_flip_y), .layer_off(tm_layer_off_disp), .bg_ctrl(mix_bg_ctrl),
            .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
            .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
            .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp),
            .spr_pix(fb_rd_pix_b),
            .pal_addr(mix1_pal_addr), .pal_data(mix1_pal_q),
            .rgb(rgb_b)
        );
    end
endgenerate

// ---------------------------------------------------------------------------
// sound subsystem
// ---------------------------------------------------------------------------
wire        snd_doorbell, snd_to_v60;
wire [15:0] sh_rdata;
wire [23:0] zrom_ba;
wire [21:0] mpcm_ba;
wire        mpcm_req_i;
wire        wave_rd_req_i;
wire [15:0] wave_rd_addr_i;
wire        wave_wr_req_i;
wire [15:0] wave_wr_addr_i;
wire  [7:0] wave_wr_data_i;

s32_soundsys #(.SYSTEM32_ONLY(SYSTEM32_ONLY)) sound (
    .clk(clk_sys), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm),
    .rst(rst),
    .z80_reset(~io0_cnt2),
    .is_multi32(is_multi32),
    .game_profile(board.game_profile),
    .sh_cs(m_req && sel_shared),
    .sh_we(m_we && sel_shared),
    .sh_addr(A[12:1]), .sh_be(m_be), .sh_wdata(m_wdata), .sh_rdata(sh_rdata),
    .v60_doorbell(snd_doorbell),
    .irq_to_v60(snd_to_v60),
    .zrom_req(sdr_p3_req), .zrom_addr(zrom_ba),
    .zrom_data(sdr_p3_dout), .zrom_ack(sdr_p3_ack),
    .mpcm_req(mpcm_req_i), .mpcm_addr(mpcm_ba),
    // Select the addressed byte from the 16-bit SDRAM word.  The MultiPCM ROM
    // bus is byte-wide; the old code always took the even lane, corrupting
    // every odd sample/descriptor byte (audit R20 AU-2).  mpcm_ba is held
    // stable by the MultiPCM engine until its req/ack completes.
    .mpcm_data(mpcm_ba[0] ? sdr_p4_dout[15:8] : sdr_p4_dout[7:0]),
    .mpcm_ack(sdr_p4_ack),
    .wave_rd_req(wave_rd_req_i), .wave_rd_addr(wave_rd_addr_i),
    .wave_rd_data(sdr_p4_dout), .wave_rd_ack(sdr_p4_ack),
    .wave_wr_req(wave_wr_req_i), .wave_wr_addr(wave_wr_addr_i),
    .wave_wr_data(wave_wr_data_i), .wave_wr_ack(sdr_wave_wr_ack),
    .audio_l(audio_l), .audio_r(audio_r)
);
// B1: SDRAM address hookup for sound ports — add region bases so fetches
// land in the soundcpu / multipcm regions instead of address 0.
assign sdr_p3_addr = SDR_SOUNDCPU_BASE[24:1] + {1'b0, zrom_ba[23:1]};
assign sdr_p4_req = SYSTEM32_ONLY ? wave_rd_req_i : mpcm_req_i;
assign sdr_p4_addr = SDR_MULTIPCM_BASE[24:1] +
                     (SYSTEM32_ONLY ? {9'b000000000, wave_rd_addr_i[15:1]} :
                                      {3'b000, mpcm_ba[21:1]});
assign sdr_wave_wr_req  = SYSTEM32_ONLY && wave_wr_req_i;
assign sdr_wave_wr_addr = SDR_MULTIPCM_BASE[24:1] +
                          {9'b000000000, wave_wr_addr_i[15:1]};
assign sdr_wave_wr_data = wave_wr_addr_i[0] ? {~wave_wr_data_i, 8'h00}
                                             : {8'h00, ~wave_wr_data_i};
assign sdr_wave_wr_be   = wave_wr_addr_i[0] ? 2'b10 : 2'b01;

// ---------------------------------------------------------------------------
// IO-7: s32comm share RAM (0x800000-0x800fff).  The regular-PCB machine config
// instantiates S32COMM (MAME segas32_regular_state::device_add_mconfig), so
// this window behaves as byte-wide RAM even with no link partner: a game that
// writes then reads the share area must read its own data back, not open bus.
// Only D[7:0] is mapped (MAME maps 0x800000-0x800fff share_r/w with
// umask16 0x00ff); the cn/fg link registers at 0x801000/2 retain their
// disconnected-link status semantics, and the rest of the 0x80xxxx page
// reads link-not-connected (0xFFFF).
// ---------------------------------------------------------------------------
wire       sel_comm_ram = sel_comm && (A[15:12] == 4'h0);
`ifdef S32_UNIVERSAL_DISABLED
wire [7:0]  comm_q = 8'h00;
wire        comm_cn = 1'b0;
wire        comm_fg = 1'b0;
`else
reg [7:0]  comm_ram [0:2047];
reg [7:0]  comm_q;
reg        comm_cn;
reg        comm_fg;
integer    comm_init_i;
initial begin
    // Power-up default only (not a per-cycle synchronous reset -- comm_ram
    // is deliberately not touched by `if (rst)` below), matching M10K/MLAB
    // initial-contents semantics. A game reading share RAM before ever
    // writing it must read 0x00, not X or open bus.
    for (comm_init_i = 0; comm_init_i < 2048; comm_init_i = comm_init_i + 1)
        comm_ram[comm_init_i] = 8'h00;
end

wire       comm_cpu_we    = m_req && m_we && sel_comm_ram && m_be[0];

always @(posedge clk_sys) begin
    if (comm_cpu_we) comm_ram[A[11:1]] <= m_wdata[7:0];
    comm_q <= comm_ram[A[11:1]];
end

always @(posedge clk_sys) begin
    if (rst) begin
        comm_cn <= 1'b0;
        comm_fg <= 1'b0;
    end
    else begin
        if (m_req && m_we && sel_comm_cn && m_be[0]) begin
            comm_cn <= m_wdata[0];
            // MAME's s32comm cn_w(0) invokes device_reset(), clearing FG too.
            if (!m_wdata[0]) comm_fg <= 1'b0;
        end
        if (m_req && m_we && sel_comm_fg && m_be[0] && comm_cn)
            comm_fg <= m_wdata[0];
    end
end
`endif

// ---------------------------------------------------------------------------
// I/O chips + EEPROM
// ---------------------------------------------------------------------------
wire [7:0] io0_q, io1_q;
wire [7:0] io0_pc, io0_pd, io0_pg, io0_dir, io1_pd, io1_ph;
// No Rad Mobile moving-controller mailbox on this board (cfg_has_motor_hle is
// always 0); s32_radm_motor_mailbox was removed.
wire [7:0] io0_pc_in = in_portc;
wire       eep_do;

s32_io5296 io0 (
    .clk(clk_sys), .rst(rst),
    .cs(m_req && sel_io0 && m_be[0]), .we(m_we),
    .addr(A[5:1]), .wdata(m_wdata[7:0]), .rdata(io0_q),
    .in_pa(in_p1a), .in_pb(in_p2a),
    .in_pc(io0_pc_in),                         // RadM: bidirectional moving-board bus
    .in_pe(in_svc12),
    // MAME wires DO to bit 7 of BOTH SERVICE34_A and SERVICE34_B on Multi 32
    // (segas32.cpp INPUT_PORTS_START(system32_generic)'s SERVICE34_A base
    // definition is inherited unmodified by multi32_generic, and
    // SERVICE34_B carries its own identical do_read bit) -- not io1 only.
    .in_pf({eep_do, in_svc34[6:0]}),
    .out_pc(io0_pc), .out_pd(io0_pd), .out_pg(io0_pg), .out_ph(io0_ph),
    .dir_out(io0_dir),
    .cnt0(), .cnt1(io0_cnt1), .cnt2(io0_cnt2)
);
assign out_lamps = io0_pd;
assign out_steering_motors = {io1_pd[4], io0_pd[4]};

s32_io5296 io1 (
    .clk(clk_sys), .rst(rst),
    .cs(m_req && sel_io1 && m_be[0]), .we(m_we),
    .addr(A[5:1]), .wdata(m_wdata[7:0]), .rdata(io1_q),
    .in_pa(in_p1b), .in_pb(in_p2b), .in_pc(in_portc_b),
    // Multi 32 EEPROM DO is read on the SECOND I/O chip's SERVICE34_B bit 7
    // (MAME io_chip_1.in_pf = SERVICE34_B, do_read on bit 7); previously io1 got
    // constant 0xff there, so Multi 32 NVRAM boot never converged (audit R23-F1).
    .in_pe(in_svc12_b), .in_pf({eep_do, in_svc34_b[6:0]}),
    .out_pc(), .out_pd(io1_pd), .out_pg(), .out_ph(io1_ph), .dir_out(),
    // cnt1 = screen-B display enable (MAME io_chip_1 out_cnt1 -> display_enable_w<1>).
    .cnt0(), .cnt1(io1_cnt1), .cnt2()
);

// EEPROM wiring: Multi 32 reads it on io1 port H.
wire [7:0] eep_src = io1_ph;
s32_eeprom93c46 eeprom (
    .clk(clk_sys), .rst(rst),
    .di(eep_src[7]), .cs(eep_src[5]), .sk(eep_src[6]), .dout(eep_do),
    .ld_wr(eep_ld_wr), .ld_addr(eep_ld_addr), .ld_data(eep_ld_data),
    .rd_data(eep_rd_data), .rd_addr(eep_rd_addr),
    .upload(eep_upload), .modified(eep_modified)
);

// extended IO: ADC / PPI
wire adc_bit;
wire sel_adc   = sel_ioex && (A[5:3] == 3'b010) && cfg_has_adc;
wire sel_ppi   = sel_ioex && (A[5:3] == 3'b100) && cfg_has_ppi;
assign adc0_load = wr_stb && sel_adc && m_be[0] && m_we &&
                   (A[2:1] == 2'd0);
generate
    if (GAME_ONLY && !GAME_ONLY_STD) begin : g_no_adc
        // Only the real-V25 dedicated shape has no ADC board. The standard
        // dedicated shape retains the ADC because Slip Stream selects it via
        // the runtime board descriptor; non-analog games do not select it.
        assign adc_bit = 1'b1;
    end
    else begin : g_extended_analog
        // Power up at bank 0 to match MAME device_start (m_analog_bank = 0);
        // System 32 analog games never write 0xC00060 so it would otherwise
        // stay X in simulation and undefined at cold boot (audit R20 IO-15).
        reg [2:0] analog_bank = 3'd0;
        s32_msm6253 adc (
            .clk(clk_sys), .rst(rst),
            // The core holds m_req across the registered read wait.  Pulse
            // the converter only when that transaction is accepted: rmux
            // first captures the current D7, then this one-shot advances the
            // serial shifter.  Driving CS from raw m_req shifted 0x80 to 0x00
            // one cycle before rmux sampled it, so Slip Stream saw its neutral
            // wheel as full-left.
            .cs(wr_stb && sel_adc && m_be[0]), // 0xC00050-57
            .we(m_we), .addr(A[2:1]),
            .dout_bit(adc_bit),
            // MAME wires only ADC channels 2/3 through the 4053 bank mux
            // (sega_multi32_analog_state::in2_analog_read/in3_analog_read,
            // m_analog_ports[bank*4+2/3]); channels 0/1 are fixed to
            // ANALOG1/ANALOG2 (adc.set_input_tag<0/1>) regardless of bank.
            // adc_ch[0..3] = bank0's ANALOG1-4, adc_ch[4..7] = bank1's
            // ANALOG5-8 slots (OutRunners populates ANALOG7/8 there, not
            // ANALOG5/6 -- see the adc_ch assignment in Arcade-SegaSystem32.sv).
            .an0(adc_ch[0]), .an1(adc_ch[1]),
            .an2(adc_ch[{analog_bank[0], 2'd2}]), .an3(adc_ch[{analog_bank[0], 2'd3}])
        );
        always @(posedge clk_sys)
            if (m_req && m_we && sel_ioex && m_be[0] && is_multi32 &&
                A[5:0] == 6'h20)
                analog_bank <= m_wdata[2:0];   // 0xC00060 analog_bank_w

    end
endgenerate

// Multi 32 six-player boards map an 8255A at 0xC00060-0xC00067.  The
// descriptor gates the chip select, so the universal image retains one small
// PPI for Hard Dunk without changing the OutRunners/Title Fight map.
wire [7:0] ppi_q;
s32_i8255 ppi (
    .clk(clk_sys), .rst(rst),
    .cs(m_req && sel_ppi && m_be[0]), .we(m_we),
    .addr(A[2:1]), .wdata(m_wdata[7:0]), .rdata(ppi_q),
    .in_pa(ppi_pa), .in_pb(ppi_pb), .in_pc(ppi_pc)
);

// ---------------------------------------------------------------------------
// interrupt controller
// ---------------------------------------------------------------------------
wire [7:0] intc_q;
s32_intc intc (
    .clk(clk_sys), .rst(rst), .is_multi32(is_multi32),
    .cs(wr_stb && sel_intc), .we(m_we),
    .addr(A[3:1]), .be(m_be), .wdata(m_wdata), .rdata(intc_q),
    .vblank_start(vbl_start), .vblank_end(vbl_end),
    .sound_irq(snd_to_v60),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_taken(1'b0),
    .z80_doorbell(snd_doorbell)
);

// ---------------------------------------------------------------------------
// protection / V25 -- removed.  OutRunners is unprotected hardware (MAME's
// init_orunners() installs no protection responder) and Multi 32 has no V25
// MCU (that chip is exclusive to Golden Axe: Revenge of Death Adder /
// Arabian Fight's standard-board revision).  SDRAM port 5 (the V25 program
// fetch port) is tied permanently idle rather than removed from the module
// interface, so the top-level SDRAM arbiter and s32_core instantiation in
// Arcade-SegaSystem32.sv need no port-list changes.
// ---------------------------------------------------------------------------
wire        br_trap      = 1'b0;
wire [15:0] br_trap_q    = 16'hffff;
wire [7:0]  v25_q        = 8'h00;
assign sdr_p5_req  = 1'b0;
assign sdr_p5_addr = '0;


// V60 ROM fetch via SDRAM p0, through a small I/D cache (perf):
//   Production profiles use 64 lines x 8 bytes direct-mapped. Hit = 1
//   clk_sys; a miss uses one aligned four-beat p0 burst. Reset (including ROM
//   download) invalidates the complete cache.
// ---------------------------------------------------------------------------
`ifdef S32_AREA_ROM_CACHE
wire        rom_req_r;
wire        rom_burst_r;
wire [23:1] rom_addr_r;
`else
reg        rom_req_r;
reg        rom_burst_r;
reg [23:1] rom_addr_r;
`endif
// Transaction-acked flag (the read-mux ack register below).  Forward-declared
// here so the icache lookup can suppress re-arming a completed ROM read while
// the V60 bus still holds m_req; the driving logic lives in the read-mux block.
reg        ack_r;
assign sdr_p0_req   = rom_req_r;
assign sdr_p0_burst = rom_burst_r;
assign sdr_p0_addr  = {2'b00, rom_addr_r[21:1]};

`ifdef S32_AREA_ROM_CACHE
// Dedicated-game area cache. The generic asynchronous cache below provides a
// one-clk_sys hit, but its two variable-index read paths flatten 2,464 cache
// bits into registers and very wide muxes in Quartus 17. This implementation
// gives the dedicated profile one arbitrated synchronous lookup port. The
// extra raw clock of lookup latency remains inside the fixed V60 CE interval.
wire        rom_ready;
wire [15:0] rom_word_r;
// No protection subsystem shares this cache's ROM-fetch port anymore (the
// J.League protection table read client was removed); tie its request side
// permanently idle. prot_data/prot_ack are cache outputs and stay unused.
wire        prot_rom_req  = 1'b0;
wire [20:0] prot_rom_addr = 21'd0;
wire [15:0] prot_rom_data;
wire        prot_rom_ack;
s32_ga_rom_cache ga_rom_cache (
    .clk(clk_sys),
    .rst(rst),
    .invalidate(1'b0),
    // Wide instruction-fetch client (V60 prefetch).  The F0-window mirror maps
    // onto the first megabyte exactly as the data port does below.
    .if_req(if_req),
    .if_line_addr((if_addr[23:20] == 4'hf)
                  ? {1'b0, if_addr[19:3]} : if_addr[20:3]),
    .if_offset(if_addr[2:0]),
    .if_data(if_data),
    .if_ack(if_served),
    .data_req(m_req && !m_we && (sel_rom || sel_romhi) && !ack_r),
    .data_addr(sel_romhi ? {1'b0, A[19:0]} : A[20:0]),
    .data_data(rom_word_r),
    .data_ack(rom_ready),
    .prot_req(prot_rom_req),
    .prot_addr(prot_rom_addr),
    .prot_data(prot_rom_data),
    .prot_ack(prot_rom_ack),
    .rom_req(rom_req_r),
    .rom_burst(rom_burst_r),
    .rom_addr(rom_addr_r),
    .rom_data(sdr_p0_dout),
    .rom_ack(sdr_p0_ack)
);
`else
wire [15:0] prot_rom_data = 16'hffff;
wire        prot_rom_ack = 1'b0;
// Non-production/general fallback.  Its original 32-line geometry is retained
// deliberately: every production profile selects s32_ga_rom_cache above, and
// the measured 64-line conflict win/resource evidence applies to that flat,
// synchronous MLAB implementation.  Address coverage remains exact here:
// index byte bits [7:3] plus tag bits [20:8] cover every line-address bit.
reg  [63:0] icache_data [0:31];
reg  [12:0] icache_tag  [0:31];      // addr[20:8]
reg  [31:0] icache_valid;

// MAME: map(0xf00000, 0xffffff).rom().region("maincpu", 0) — the top window
// mirrors the FIRST megabyte (the V60 reset stub at 0xFFFFF0 lives at
// maincpu offset 0xFFFF0). A[20:0] would fetch reset code from the wrong
// megabyte — found by real-ROM inspection (ga2: JMP $00100506 sits at
// 0x0FFFF0, data at 0x1FFFF0).
wire [20:0] rom_byte_a = sel_romhi ? {1'b0, A[19:0]} : A[20:0];
wire [4:0]  ic_line    = rom_byte_a[7:3];
wire [12:0] ic_tag     = rom_byte_a[20:8];
wire        ic_hit     = icache_valid[ic_line] && (icache_tag[ic_line] == ic_tag);
wire [63:0] ic_ldata   = icache_data[ic_line];
wire [15:0] ic_word    = ic_ldata[{rom_byte_a[2:1], 4'b0000} +: 16];

// There is no separate instruction-fetch client: V60 prefetches arrive here as
// ordinary ROM reads on the shared bus, through the same ic_hit lookup as data.

reg         rom_filling;
reg         rom_ready;               // pulses when requested word available
reg  [15:0] rom_word_r;
// latched fill target: the live A can change mid-fill, so the fill FSM uses its
// own latched line rather than the current bus address.
reg  [4:0]  fill_line;
reg  [12:0] fill_tag;
reg  [1:0]  fill_dsel;               // data-read word select (byte_a[2:1])

always @(posedge clk_sys) begin
    if (rst) begin
        rom_req_r <= 0; rom_burst_r <= 0; rom_filling <= 0; rom_ready <= 0;
        icache_valid <= 32'h0;
    end
    else begin
        rom_req_r <= 0;
        rom_burst_r <= 0;
        rom_ready <= 0;

        if (rom_filling) begin
            if (sdr_p0_ack) begin
                // p0 returns the complete aligned cache line atomically.  This
                // removes three arbitration/ACT/tRCD/CAS round trips per miss
                // without exposing a partial cache line to either CPU client.
                icache_data[fill_line]  <= sdr_p0_dout;
                rom_filling             <= 1'b0;
                icache_tag[fill_line]   <= fill_tag;
                icache_valid[fill_line] <= 1'b1;
                case (fill_dsel)
                    2'd0: rom_word_r <= sdr_p0_dout[15:0];
                    2'd1: rom_word_r <= sdr_p0_dout[31:16];
                    2'd2: rom_word_r <= sdr_p0_dout[47:32];
                    default: rom_word_r <= sdr_p0_dout[63:48];
                endcase
                rom_ready <= 1'b1;
            end
        end
        // ROM read (rare: constants/tables in ROM).  See !ack_r note above.
        else if (m_req && !m_we && (sel_rom || sel_romhi) && !rom_ready && !ack_r) begin
            if (ic_hit) begin
                rom_word_r <= ic_word;
                rom_ready  <= 1'b1;
            end
            else begin
                rom_filling  <= 1'b1;
                fill_line    <= ic_line;
                fill_tag     <= ic_tag;
                fill_dsel    <= rom_byte_a[2:1];
                rom_req_r    <= 1'b1;
                rom_burst_r  <= 1'b1;
                rom_addr_r   <= {3'b000, rom_byte_a[20:3], 2'b00};
            end
        end
    end
end
`endif

// ---------------------------------------------------------------------------
// CPU read mux + ack
// ---------------------------------------------------------------------------
reg [15:0] rmux;
assign m_rdata = rmux;
assign m_ack   = ack_r;   // ack_r declared with the ROM fetch regs above

// Random source for 0xD80000.  MAME returns machine().rand() (full-width,
// uncorrelated).  A 32-bit xorshift advanced every clk_sys — not just on the
// CPU clock-enable — plus a per-read fold decorrelates reads only a few CPU
// cycles apart, which a 1-bit-per-CPU-clock LFSR did not (audit R20 IO-13).
reg [31:0] rng = 32'h1357_9BDF;
always @(posedge clk_sys) begin
    logic [31:0] rx;
    rx  = rng ^ (rng << 13);
    rx  = rx  ^ (rx  >> 17);
    rng <= rx ^ (rx << 5);
end
wire [15:0] rng_read = rng[31:16] ^ rng[15:0];

reg ack_d;
reg rd_wait;   // BRAM/register reads: one dead cycle so the registered q
               // (wram_q, v25 rdata, io rdata, ...) reflects THIS address.
               // Without it rmux latches the previous access's data — the q
               // registers update on the same edge the ack mux samples them.
assign wr_stb = ack_r & ~ack_d;   // one-shot per transaction (for side-effect regs)
always @(posedge clk_sys) begin
    ack_d <= ack_r;
    if (!m_req) begin ack_r <= 0; rd_wait <= 0; end
    else if (!ack_r) begin
        if (sel_rom || sel_romhi) begin
            if (m_we) ack_r <= 1'b1;   // writes to ROM: ack + discard
            else if (rom_ready) begin rmux <= rom_word_r; ack_r <= 1'b1; end
        end
        else if (!m_we && !rd_wait) rd_wait <= 1'b1;
        else begin
            rd_wait <= 1'b0;
            ack_r <= 1'b1;   // BRAM/regs
            casez (1'b1)
                br_trap:      rmux <= br_trap_q;
                sel_wram:     rmux <= wram_q;
                sel_vram:    rmux <= vram_cpu_q;
                sel_sprram:  rmux <= sprram_q;
                sel_sprctl:  rmux <= {8'hff, sprctl_q};
                is_pal0:     rmux <= pal0_cpu_q;
                is_mix0:     rmux <= mix0_q;
                is_pal1:     rmux <= pal1_cpu_q;   // B7: Multi 32 screen B
                is_mix1:     rmux <= mix1_q;
                sel_shared:  rmux <= sh_rdata;
                // IO-7: share RAM reads its own byte back (D[15:8] open bus).
                // MAME s32comm returns 0xFE | CN for CN and 0xFE | FG for FG
                // with the unconnected ZFG held low; only the rest of 0x80xxxx
                // remains open bus. No link-partner timer or publication HLE
                // is present in the OutRunners image.
                sel_comm:    begin
                                if (sel_comm_ram)
                                    rmux <= {8'hff, comm_q};
                                else if (sel_comm_cn)
                                    rmux <= {8'hff, 8'hfe | {7'b0, comm_cn}};
                                else if (sel_comm_fg)
                                    rmux <= {8'hff, 8'hfe | {7'b0, comm_fg}};
                                else
                                    rmux <= 16'hffff;
                             end
                // Open-bus outside the comm RAM (A[15]=0) and the 4-byte id
                // window (A[15] && A[14:2]==0); the module holds stale rdata
                // when neither chip-select fires (audit R20 IO-10a).
                sel_dual:    rmux <= 16'hffff;
                // 0xA00000-0xAFFFFF (V25/protection window) is open-bus:
                // OutRunners has neither (MAME leaves this range unmapped,
                // audit R20 PF-7).
                sel_v25:     rmux <= 16'hffff;
                sel_prot_a:  rmux <= 16'hffff;
                sel_io0:     rmux <= {8'hff, io0_q};
                sel_io1:     rmux <= {8'hff, io1_q};
                // MSM6253 serial output is wired to D7, not D0 (MAME
                // msm6253 d7_r); audit R20 IO-3.
                sel_ioex:    rmux <= sel_adc ? {8'hff, adc_bit, 7'h7f} :
                                     sel_ppi ? {8'hff, ppi_q} : 16'hffff;
                sel_intc:    rmux <= {8'hff, intc_q};
                sel_rand:    rmux <= rng_read;
                default:     rmux <= 16'hffff;
            endcase
        end
    end
end


endmodule

`ifdef S32_AREA_ROM_CACHE
`undef S32_AREA_ROM_CACHE
`endif
//============================================================================
// Main-ROM cache: 64 direct-mapped 8-byte lines.
//
// A single synchronous lookup port is sufficient because instruction fetches
// have priority and the V60 data bus holds a request until acknowledge. The
// whole line is committed after one four-beat SDRAM burst, avoiding partial
// writes so Quartus can implement {tag,data} as MLAB lanes. Valid bits stay
// outside the memory so reset/invalidation remains a one-cycle operation.
//============================================================================
module s32_ga_rom_cache #(
    // Six index bits retain 64 lines (512 bytes).  Keep this parameter for the
    // focused 32-vs-64 conflict benchmark; production uses the larger default.
    parameter integer INDEX_BITS = 6
) (
    input              clk,
    input              rst,
    input              invalidate,

    input              if_req,
    input       [20:3] if_line_addr,
    input        [2:0] if_offset,
    output reg  [63:0] if_data,
    output reg         if_ack,

    input              data_req,
    input       [20:0] data_addr,
    output reg  [15:0] data_data,
    output reg         data_ack,

    // J.League protection table reads share this cache/SDRAM client.
    input              prot_req,
    input       [20:0] prot_addr,
    output reg  [15:0] prot_data,
    output reg         prot_ack,

    output reg         rom_req,
    output reg         rom_burst,
    output reg  [23:1] rom_addr,
    input       [63:0] rom_data,
    input              rom_ack
);

localparam integer LINE_COUNT = 1 << INDEX_BITS;
localparam integer TAG_BITS = 18 - INDEX_BITS;
localparam integer CACHE_WIDTH = 64 + TAG_BITS;

// 64 x 76 = 4,864 bits in production. Keep this synchronous, full-line store
// in an M10K so it does not consume scarce memory ALMs. Validity remains
// separate to avoid a reset loop on the inferred memory.
(* ramstyle = "M10K, no_rw_check" *) reg [CACHE_WIDTH-1:0] cache_mem [0:LINE_COUNT-1];
reg [CACHE_WIDTH-1:0] cache_q;
reg [LINE_COUNT-1:0] cache_valid;

reg        lookup_pending;
reg        lookup_fetch;
reg        lookup_prot;
reg  [INDEX_BITS-1:0] lookup_index;
reg [TAG_BITS-1:0] lookup_tag;
reg [17:0] lookup_line_addr;
reg  [2:0] lookup_if_offset;
reg  [1:0] lookup_data_word;

reg        filling;
reg        fill_discard;
reg        fill_fetch;
reg        fill_prot;
reg  [INDEX_BITS-1:0] fill_index;
reg [TAG_BITS-1:0] fill_tag;
reg  [2:0] fill_if_offset;
reg  [1:0] fill_data_word;

wire choose_fetch = if_req && !if_ack;
wire choose_prot  = !choose_fetch && prot_req && !prot_ack;
wire choose_data  = !choose_fetch && !choose_prot && data_req && !data_ack;
wire launch_lookup = !lookup_pending && !filling &&
                     (choose_fetch || choose_prot || choose_data);
wire [INDEX_BITS-1:0] lookup_mem_addr = lookup_pending ? lookup_index :
    choose_fetch ? if_line_addr[INDEX_BITS+2:3]
                 : choose_prot ? prot_addr[INDEX_BITS+2:3]
                 : data_addr[INDEX_BITS+2:3];
wire [63:0] completed_line = rom_data;
wire cache_commit = filling && rom_ack &&
                    !fill_discard && !invalidate && !rst;
function automatic [15:0] select_word(
    input [63:0] line,
    input  [1:0] word_sel
);
begin
    case (word_sel)
        2'd0: select_word = line[15:0];
        2'd1: select_word = line[31:16];
        2'd2: select_word = line[47:32];
        default: select_word = line[63:48];
    endcase
end
endfunction

// Synchronous read plus one full-line write port. There is no asynchronous
// array read and no partial array write, the two shapes that flattened the old
// cache into ALMs in Quartus 17.
always @(posedge clk) begin
    cache_q <= cache_mem[lookup_mem_addr];
    if (cache_commit)
        cache_mem[fill_index] <= {fill_tag, completed_line};
end

always @(posedge clk) begin
    if (rst) begin
        cache_valid      <= '0;
        lookup_pending   <= 1'b0;
        lookup_fetch     <= 1'b0;
        lookup_prot      <= 1'b0;
        lookup_index     <= '0;
        lookup_tag       <= '0;
        lookup_line_addr <= 18'd0;
        lookup_if_offset <= 3'd0;
        lookup_data_word <= 2'd0;
        filling          <= 1'b0;
        fill_discard     <= 1'b0;
        fill_fetch       <= 1'b0;
        fill_prot        <= 1'b0;
        fill_index       <= '0;
        fill_tag         <= '0;
        fill_if_offset   <= 3'd0;
        fill_data_word   <= 2'd0;
        if_data          <= 64'd0;
        if_ack           <= 1'b0;
        data_data        <= 16'hffff;
        data_ack         <= 1'b0;
        prot_data        <= 16'hffff;
        prot_ack         <= 1'b0;
        rom_req          <= 1'b0;
        rom_burst        <= 1'b0;
        rom_addr         <= 23'd0;
    end
    else begin
        rom_req <= 1'b0;
        rom_burst <= 1'b0;
        if (!if_req)   if_ack   <= 1'b0;
        if (!data_req) data_ack <= 1'b0;
        if (!prot_req) prot_ack <= 1'b0;

        if (invalidate) begin
            cache_valid    <= '0;
            lookup_pending <= 1'b0;
            if_ack          <= 1'b0;
            data_ack        <= 1'b0;
            prot_ack        <= 1'b0;
            if (filling) begin
                if (rom_ack) begin
                    filling      <= 1'b0;
                    fill_discard <= 1'b0;
                end
                else begin
                    fill_discard <= 1'b1;
                end
            end
            else begin
                fill_discard <= 1'b0;
            end
        end
        else if (filling) begin
            if (rom_ack) begin
                if (fill_discard) begin
                    // Drain one response from an invalidated transaction and
                    // discard that complete line. A held requester retries.
                    filling      <= 1'b0;
                    fill_discard <= 1'b0;
                end
                else begin
                    cache_valid[fill_index] <= 1'b1;
                    filling <= 1'b0;
                    if (fill_fetch) begin
                        if_data <= completed_line >> {fill_if_offset, 3'b000};
                        if_ack  <= 1'b1;
                    end
                    else if (fill_prot) begin
                        prot_data <= select_word(completed_line, fill_data_word);
                        prot_ack  <= 1'b1;
                    end
                    else begin
                        data_data <= select_word(completed_line, fill_data_word);
                        data_ack  <= 1'b1;
                    end
                end
            end
        end
        else if (lookup_pending) begin
            lookup_pending <= 1'b0;
            if (cache_valid[lookup_index] &&
                cache_q[CACHE_WIDTH-1:64] == lookup_tag) begin
                if (lookup_fetch) begin
                    if_data <= cache_q[63:0] >> {lookup_if_offset, 3'b000};
                    if_ack  <= 1'b1;
                end
                else if (lookup_prot) begin
                    prot_data <= select_word(cache_q[63:0], lookup_data_word);
                    prot_ack  <= 1'b1;
                end
                else begin
                    data_data <= select_word(cache_q[63:0], lookup_data_word);
                    data_ack  <= 1'b1;
                end
            end
            else begin
                filling        <= 1'b1;
                fill_discard   <= 1'b0;
                fill_fetch     <= lookup_fetch;
                fill_prot      <= lookup_prot;
                fill_index     <= lookup_index;
                fill_tag       <= lookup_tag;
                fill_if_offset <= lookup_if_offset;
                fill_data_word <= lookup_data_word;
                rom_addr       <= {3'b000, lookup_line_addr, 2'b00};
                rom_req        <= 1'b1;
                rom_burst      <= 1'b1;
            end
        end
        else if (launch_lookup) begin
            lookup_pending <= 1'b1;
            lookup_fetch   <= choose_fetch;
            lookup_prot    <= choose_prot;
            if (choose_fetch) begin
                lookup_index     <= if_line_addr[INDEX_BITS+2:3];
                lookup_tag       <= if_line_addr[20:INDEX_BITS+3];
                lookup_line_addr <= if_line_addr;
                lookup_if_offset <= if_offset;
                lookup_data_word <= 2'd0;
            end
            else if (choose_prot) begin
                lookup_index     <= prot_addr[INDEX_BITS+2:3];
                lookup_tag       <= prot_addr[20:INDEX_BITS+3];
                lookup_line_addr <= prot_addr[20:3];
                lookup_if_offset <= 3'd0;
                lookup_data_word <= prot_addr[2:1];
            end
            else begin
                lookup_index     <= data_addr[INDEX_BITS+2:3];
                lookup_tag       <= data_addr[20:INDEX_BITS+3];
                lookup_line_addr <= data_addr[20:3];
                lookup_if_offset <= 3'd0;
                lookup_data_word <= data_addr[2:1];
            end
        end
    end
end

endmodule
