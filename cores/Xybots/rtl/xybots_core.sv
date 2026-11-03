`timescale 1ns/1ps
//============================================================================
//  Xybots (Atari Games, 1987) — the game logic top.  Arcade-Xybots.sv is the
//  MiSTer wrapper above this file (OSD, HPS, arcade_video, audio); everything
//  the arcade board itself did lives here and below.
//
//  The five blocks, and the SP-313 schematic sheets each one models:
//
//    xybots_mem       sheet 3 ROMs + the MiSTer download path + SDRAM
//    xybots_main_bus  sheet 2 — 68000, decode, DTACK, IRQ, watchdog,
//                     SLAPSTIC, EEPROM + NVRAM, inputs, video RAM, colour RAM
//    xybots_video     sheets 4/5/7/8/9 — SYNGEN, the VRAM address multiplex,
//                     alphanumerics, playfield, priority, GPC, CRAM, DACs
//    xybots_mo        sheets 5/6/8 — the motion-object engine.  It is a
//                     SIBLING of xybots_video, not its child: both are
//                     instantiated here and they exchange scram_d, the SYNGEN
//                     taps and the three line-buffer nibbles.
//    xybots_jsa       sheets 11-14 — the whole JSA I audio PCB (no POKEY, no
//                     TMS5220), YM2151 via jt51
//
//  ---- clocking ------------------------------------------------------------
//
//  ONE clock domain, clk_sys = 57.272727 MHz = 4 x the SP-313 sheet-4 crystal
//  (14.318181 MHz), with integer clock enables and no fractional enables
//  anywhere.  This works because the JSA I sound crystal (3.579545 MHz) is
//  EXACTLY the video crystal / 4, so every rate on both boards divides clk_sys:
//
//     ce_14m  = clk_sys / 4   = 14.318181 MHz   SYNGEN master (sheet 4)
//     ce_7m   = clk_sys / 8   =  7.159091 MHz   VIDCLK pixel AND the 68000
//     ce_ym   = clk_sys / 16  =  3.579545 MHz   YM2151 (JSA I)
//     ce_6502 = clk_sys / 32  =  1.789772 MHz   JSA I 6502
//
//  All four are decodes of ONE free-running 5-bit counter, so each slower
//  enable is a strict subset of every faster one (a ce_6502 pulse is always
//  also a ce_ym, ce_7m and ce_14m pulse).  That is what lets the SDC treat the
//  whole core as a single clk_sys domain with multicycle exceptions per
//  CE-gated block, and it is why no CDC exists inside the game logic.  The two
//  crystals are independent on the real PCB set; exact-frequency integer
//  enables are the best available model, and the sound-command mailbox is the
//  only observable crossing point.
//
//  The ce_7m phase convention: the clk_sys cycle in which `ce_7m` is high is
//  the LAST cycle of SYNGEN count `h`, because the counter increments on that
//  cycle's clock edge.  So during it `h` still names the count whose pixel is
//  being produced — xybots_syngen, xybots_video and xybots_mo all take this one
//  wire and all read it that way.
//
//  ---- OSD pause -----------------------------------------------------------
//
//  Not a board feature: MiSTer freezes the game while the OSD is open.  The
//  video side (SYNGEN, the layer and MO pipelines, the SDRAM graphics path)
//  keeps running, so the frozen picture stays on screen and the OSD, which
//  sys_top draws over the core's own video timing, still has a raster to sit
//  on.  Everything the game can observe is frozen instead: ce_7m to the main
//  board (68000, DTACK, slapstic), ce_ym/ce_6502 to the JSA board (6502,
//  YM2151, periodic IRQ, filter), plus `paused` into xybots_main_bus for the
//  three things video or raw clk_sys would still move (watchdog, VIRQ preset,
//  X2804 write timer).  Audio falls silent by itself, because the YM2151 and
//  the filter hold their last sample.
//
//  The pause starts and ends only at the /VBLANK assertion edge.  A frame is
//  263 x 456 x 8 = 959 424 clk_sys, a multiple of 32, so that edge falls on
//  the same `ce_cnt` phase every frame, and a pause is always a whole number
//  of frames long.  The game therefore resumes on exactly the raster line,
//  pixel and enable phase it stopped on.  Apart from the wall-clock gap, the
//  machine cannot tell it was paused.
//
//  ---- reset structure -----------------------------------------------------
//
//    init_reset   ~pll_locked ONLY.  Reaches xybots_mem (SDRAM init + loader)
//                 and nothing else.  A game reset here would drop SDRAM_CKE in
//                 the middle of a download, a known failure mode in sibling
//                 cores.
//    sys_reset    reset | ~rom_loaded | an index-2 NVRAM download.  The "board
//                 is not ready" reset: video, the motion-object engine, the JSA
//                 board, and the main bus's own init_reset/por.  Holding the
//                 game off until the ROMs are in BRAM/SDRAM is what stops the
//                 68000 executing FF FF; holding it over the index-2 transfer
//                 makes the EEPROM restore atomic with respect to the CPU.
//    cpu_reset    sys_reset | watchdog_reset — formed INSIDE xybots_main_bus,
//                 because the sheet-2 /RESET net reaches only the 68000's
//                 RESET/HALT pins and (on sheet 3) the EEPROM unlock latch and
//                 its /OE gate.  The watchdog does NOT reset the video side,
//                 the slapstic or the sound board; the sound board has its own
//                 path (/AUDRES -> SCOM /RESREQ), which is `snd_reset`.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//============================================================================

module xybots_core #(
	// 1 selects MAME's IRGB_4444 transfer instead of the sheet-9 resistor
	// ladder, bit-exactly.  It exists so a simulation can be compared against
	// MAME's rendered bitmap; the core itself uses the schematic curve and
	// there is deliberately no OSD option for it.
	parameter bit DAC_MAME_COMPAT = 1'b0
)(
	input  logic        clk_sys,        // 57.272727 MHz
	input  logic        reset,          // active-high system reset

	// SDRAM/loader init reset — MUST be ~pll_locked ONLY, never the game reset.
	// The game reset can pulse DURING the ROM download; if the SDRAM controller
	// sees it, SDRAM_CKE drops and it re-enters its 200 us init mid-download and
	// the loader's writes are lost — a known failure mode in sibling cores.
	input  logic        init_reset,

	// MiSTer pause request (the OSD is open and the option is on).  Level,
	// asynchronous to the frame; see "OSD pause" below.
	input  logic        pause,

	// ---- HPS ioctl ROM download (index 0) ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	output logic        ioctl_wait,

	// ---- NVRAM (X2804 EEPROM) save-back to HPS (index 2) ----
	input  logic        ioctl_upload,
	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din,

	// ---- controls ----
	// `panel` is the /SW word at 0x806100 in its SCHEMATIC bit order but with
	// ACTIVE-HIGH "pressed" sense; xybots_inputs (18F/21E LS244) inverts it:
	//   [15] P1 UP  [14] P1 DOWN  [13] P1 LEFT  [12] P1 RIGHT
	//   [11] P1 TURN L  [10] P1 TURN R  [9] P1 FIRE  [8] P1 START
	//   [ 7] P2 UP  [ 6] P2 DOWN  [ 5] P2 LEFT  [ 4] P2 RIGHT
	//   [ 3] P2 TURN L  [ 2] P2 TURN R  [1] P2 FIRE  [0] P2 START
	// self_test is the JSA board's SW1, which fans out to /RDIO bit 7 AND over
	// JSCOM-1 to the main board's /SYSIN D8 — one switch, two readers.
	// Coins live on the JSA board and are SWAPPED on Xybots (MAME
	// set_swapped_coins(true)); the swap is inside xybots_jsa_io.
	input  logic [15:0] panel,
	input  logic        self_test,
	input  logic        coin1,
	input  logic        coin2,

	// ---- video out (single clk_sys domain, qualified by ce_pix) ----
	// 8 bits per channel: CRAM is I:R:G:B 4:4:4:4 (sheet 9), but the INTENSITY
	// bit means the sheet-9 resistor-ladder DAC produces more than 16 levels
	// per channel, so the core's output bus is 8-bit and arcade_video is
	// instantiated with DW=24.
	output logic        ce_pix,
	output logic  [7:0] vga_r, vga_g, vga_b,
	output logic        hsync, vsync, hblank, vblank,

	// ---- audio ----
	output logic signed [15:0] aud_l, aud_r,

	// ---- SDRAM chip ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

	// ===================== clock enables =====================
	// One free-running /32 counter; every enable is a decode of it, so the
	// slower enables are subsets of the faster ones (see the header).  The
	// counter is NOT reset — the PCB's SYNGEN/JSA dividers free-run too, and
	// holding it in reset would make the phase relationship depend on when
	// reset released.
	// No reset and no initialiser: Quartus powers `ce_cnt` up at 0, and a
	// simulator built with --x-initial 0 does the same, so the enable PHASE is
	// identical in both.  The absolute phase inside the /32 counter does not
	// matter to the design; only the subset relationship above does.
	logic [4:0] ce_cnt;
	always_ff @(posedge clk_sys) ce_cnt <= ce_cnt + 5'd1;

	wire ce_14m  = (ce_cnt[1:0] == 2'd0);   // 14.318181 MHz
	wire ce_7m   = (ce_cnt[2:0] == 3'd0);   //  7.159091 MHz  (pixel + 68000)
	wire ce_ym   = (ce_cnt[3:0] == 4'd0);   //  3.579545 MHz
	wire ce_6502 = (ce_cnt      == 5'd0);   //  1.789772 MHz

	// ===================== resets =====================
	// `rom_loaded` latches at the END of the index-0 download (and only index 0
	// — xybots_rom_loader qualifies it), so the 68000 cannot execute FF FF out
	// of an unwritten program ROM.  The MiSTer NVRAM restore is a SEPARATE
	// index-2 transfer that arrives just afterwards; it writes the X2804 array,
	// so the 68000 is held for its duration too and the restored image is in
	// place before the boot reads a single EEPROM block, instead of landing
	// under a CPU that is already in its RAM test.  The board's /RESET does not
	// erase the cell array, on the PCB or here, so nothing is lost by holding
	// it.  `xybots_eeprom_2804`'s power-up erase also keys off this window:
	// `init_reset` high is "an image is streaming in", and its release is where
	// the erase-or-keep decision is taken.
	logic rom_loaded;
	wire  nvram_download = ioctl_download & (ioctl_index == 16'd2);
	wire  sys_reset      = reset | ~rom_loaded | nvram_download;

	// =====================================================================
	//  Memory subsystem — ROMs, the index-0 download, the SDRAM
	// =====================================================================
	logic [16:0] prog_a;
	logic        prog_slap_sel;
	logic  [1:0] prog_slap_bank;
	logic [15:0] prog_data;

	logic [12:0] char_addr;
	logic  [7:0] char_data;

	logic        sndrom_wr;
	logic [15:0] sndrom_addr;
	logic  [7:0] sndrom_data;

	logic        eeprom_img_wr;
	logic  [8:0] eeprom_img_addr;
	logic  [7:0] eeprom_img_data;

	logic        mo_req, mo_valid;
	logic [18:2] mo_addr;
	logic [31:0] mo_data;
	logic        pf_req, pf_valid;
	logic [17:2] pf_addr;
	logic [31:0] pf_data;

	xybots_mem u_mem (
		.clk            (clk_sys),
		.init_reset     (init_reset),      // ~pll_locked ONLY

		.ioctl_download (ioctl_download),
		.ioctl_wr       (ioctl_wr),
		.ioctl_addr     (ioctl_addr),
		.ioctl_dout     (ioctl_dout),
		.ioctl_index    (ioctl_index),
		.ioctl_wait     (ioctl_wait),      // straight through to hps_io
		.rom_loaded     (rom_loaded),

		.prog_a         (prog_a),
		.prog_slap_sel  (prog_slap_sel),
		.prog_slap_bank (prog_slap_bank),
		.prog_data      (prog_data),

		.char_addr      (char_addr),
		.char_data      (char_data),

		.sndrom_wr      (sndrom_wr),
		.sndrom_addr    (sndrom_addr),
		.sndrom_data    (sndrom_data),

		.eeprom_img_wr  (eeprom_img_wr),
		.eeprom_img_addr(eeprom_img_addr),
		.eeprom_img_data(eeprom_img_data),

		.mo_req         (mo_req),   .mo_addr (mo_addr),
		.mo_valid       (mo_valid), .mo_data (mo_data),
		.pf_req         (pf_req),   .pf_addr (pf_addr),
		.pf_valid       (pf_valid), .pf_data (pf_data),

		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_CKE(SDRAM_CKE),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_nWE(SDRAM_nWE)
	);

	// =====================================================================
	//  Video and the motion-object engine
	// =====================================================================
	// They are SIBLINGS, not parent and child: xybots_video owns the sheet-5
	// VRAM address multiplexer and exports the shared read data `scram_d` plus
	// the SYNGEN taps; xybots_mo consumes those, drives its own SDRAM sprite
	// client, and hands back the three line-buffer nibbles.
	logic [12:0] vram_vaddr;
	logic [15:0] vram_vdata;
	logic  [9:0] cram_vaddr;
	logic [15:0] cram_vdata;
	logic [15:0] scram_d;

	logic  [3:0] lb_pix, lb_col, lb_pri;
	logic [12:0] mo_vaddr;
	logic  [8:0] mo_hpos;
	logic        mo_fetch_late, pf_late;

	logic        virq, vrac2, h256, virq_gate;
	logic  [1:0] vrac;
	logic  [8:0] h, hpos_out;
	logic  [7:0] v;
	logic        vid_hblank, vid_vblank;

	logic h_2hd1h, h_2hd1h_n, h_4hd1h, h_4hd1h_n, h_4hd2h, h_4hd2h_n;
	logic h1_n, h2_n, h4_n, v1_n, v1d8h, v1d8h_n;
	logic mohr_n, mohld0_n, mohld1_n, mohr0_n, mohr1_n, dclk, rclk;

	logic [7:0] vid_r, vid_g, vid_b;

	xybots_video #(
		.DAC_MAME_COMPAT (DAC_MAME_COMPAT),
		.MO_PIPE_ADJ     (0)                 // this engine needs no re-timing
	) u_video (
		.clk(clk_sys), .ce_7m(ce_7m), .ce_14m(ce_14m), .reset(sys_reset),

		.vram_vaddr(vram_vaddr), .vram_vdata(vram_vdata),
		.cram_vaddr(cram_vaddr), .cram_vdata(cram_vdata),
		.char_addr (char_addr),  .char_data (char_data),

		.pf_req(pf_req), .pf_addr(pf_addr), .pf_valid(pf_valid), .pf_data(pf_data),

		.lb_pix(lb_pix), .lb_col(lb_col), .lb_pri(lb_pri),
		.scram_d(scram_d),

		// All three layers on, hardwired: the layer enables are a debug hook
		// for simulation only and no OSD option drives them.
		.dbg_layer_en(3'b111),

		.virq(virq), .vrac(vrac), .vrac2(vrac2),
		.h(h), .v(v), .h256(h256),
		.hblank(vid_hblank), .vblank(vid_vblank), .virq_gate(virq_gate),

		.h_2hd1h(h_2hd1h), .h_2hd1h_n(h_2hd1h_n),
		.h_4hd1h(h_4hd1h), .h_4hd1h_n(h_4hd1h_n),
		.h_4hd2h(h_4hd2h), .h_4hd2h_n(h_4hd2h_n),
		.h1_n(h1_n), .h2_n(h2_n), .h4_n(h4_n),
		.v1_n(v1_n), .v1d8h(v1d8h), .v1d8h_n(v1d8h_n),
		.mohr_n(mohr_n), .mohld0_n(mohld0_n), .mohld1_n(mohld1_n),
		.mohr0_n(mohr0_n), .mohr1_n(mohr1_n),
		.dclk(dclk), .rclk(rclk),

		.red(vid_r), .green(vid_g), .blue(vid_b),
		.hsync(hsync), .vsync(vsync),
		.hblank_out(hblank), .vblank_out(vblank),
		.ce_pix(ce_pix),

		.pf_late(pf_late), .hpos_out(hpos_out)
	);

	xybots_mo u_mo (
		.clk(clk_sys), .reset(sys_reset), .ce_7m(ce_7m),

		.h(h), .v(v), .vblank(vid_vblank),
		.h_2hd1h(h_2hd1h), .h_4hd2h_n(h_4hd2h_n), .v1d8h(v1d8h),
		.mohld0_n(mohld0_n), .mohld1_n(mohld1_n),
		.mohr0_n(mohr0_n), .mohr1_n(mohr1_n),

		// mo_vaddr is connected for observation only — xybots_video owns the
		// VRAM port and drives the identical address during the MO phase.
		.vram_vaddr(mo_vaddr),
		.scram_d(scram_d),

		.mo_req(mo_req), .mo_addr(mo_addr), .mo_valid(mo_valid), .mo_data(mo_data),

		.lb_pix(lb_pix), .lb_col(lb_col), .lb_pri(lb_pri), .mo_hpos(mo_hpos),
		.fetch_late(mo_fetch_late)
	);

`ifdef XYBOTS_BRINGUP_DEBUG
	// ---- bring-up test pattern, NOT built for release ----------------------
	// Define XYBOTS_BRINGUP_DEBUG to replace the game's picture with the
	// colour-bar/box pattern.  It exercises the PLL, the raster and the whole
	// MiSTer video chain independently of the ROMs, which is worth having when
	// a board comes up black.  A debug path stays in the tree behind a define
	// and the define is left undefined for every release build.
	// `frame_start` is tied low here, so the pattern's box stays where it
	// starts; the bars, the border and the grey ramp are what this mode is for.
	logic [3:0] tp_r, tp_g, tp_b;
	xybots_testpat u_testpat (
		.clk(clk_sys), .reset(sys_reset), .ce(ce_7m),
		.h_count(hpos_out), .v_count({1'b0, v}),
		.hblank(hblank), .vblank(vblank), .frame_start(1'b0),
		.r(tp_r), .g(tp_g), .b(tp_b));
	assign vga_r = {tp_r, tp_r};
	assign vga_g = {tp_g, tp_g};
	assign vga_b = {tp_b, tp_b};
	// The game's own picture is still generated (and still fetches tiles and
	// sprites out of the SDRAM) — it just does not reach the pin.  That is what
	// makes this a bring-up mode rather than a different design.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_vid = &{1'b0, vid_r, vid_g, vid_b, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */
`else
	assign vga_r = vid_r;
	assign vga_g = vid_g;
	assign vga_b = vid_b;
`endif

	// =====================================================================
	//  OSD pause (see the header)
	// =====================================================================
	// Reset forces `paused` low: fx68k needs its enables running to take a
	// reset, and the ROM download (which itself opens the OSD) runs under
	// sys_reset.  After release the pause re-engages on the next /VBLANK edge
	// if the OSD is still open.
	logic vblank_q, paused;
	always_ff @(posedge clk_sys) begin
		vblank_q <= vid_vblank;
		if (sys_reset)                     paused <= 1'b0;
		else if (vid_vblank && !vblank_q)  paused <= pause;
	end

	wire ce_7m_game   = ce_7m   & ~paused;   // main board: 68000 and bus
	wire ce_ym_game   = ce_ym   & ~paused;   // JSA board: YM2151, periodic IRQ
	wire ce_6502_game = ce_6502 & ~paused;   // JSA board: 6502, filter

	// =====================================================================
	//  Main board — SP-313 sheet 2
	// =====================================================================
	logic        snd_cmd_wr, snd_resp_rd, snd_reset;
	logic  [7:0] snd_cmd_data, snd_resp_data;
	logic        snd_irq, snd_m2s_ready;

	logic [23:1] cpu_a;
	logic [15:0] cpu_dout, cpu_din;
	logic        cpu_as, cpu_uds_n, cpu_lds_n, cpu_rw, cpu_dtack;
	logic  [2:0] cpu_fc, ipl;
	logic  [1:0] slap_bank;
	logic        watchdog_reset, reset_net;

	xybots_main_bus #(.CLK_HZ(57_272_727)) u_main (
		.clk(clk_sys), .ce_7m(ce_7m_game), .paused(paused),
		// sys_reset, NOT init_reset: the 68000 must be held while the ROMs
		// stream in, and the watchdog must be parked at POR until then.
		.init_reset(sys_reset), .por(sys_reset),

		.vrac(vrac), .vrac2(vrac2), .v(v[2:0]),
		.hblank(vid_hblank), .vblank(vid_vblank), .h256(h256),
		.virq(virq),                       // UNDELAYED board net, not a pixel

		.prog_a(prog_a), .prog_slap_sel(prog_slap_sel),
		.prog_slap_bank(prog_slap_bank), .prog_data(prog_data),

		// The X2804 restore comes in over ioctl index 2 (and the index-0 tail)
		// through xybots_nvram_io, INSIDE this module.  xybots_mem's
		// `eeprom_img_*` is the alternative hook for a core that does not
		// instantiate it — wire ONE of the two, never both.
		.eeprom_img_wr(1'b0), .eeprom_img_addr(9'd0), .eeprom_img_data(8'd0),

		.vram_vaddr(vram_vaddr), .vram_vdata(vram_vdata),
		.cram_vaddr(cram_vaddr), .cram_vdata(cram_vdata),

		.panel(panel), .self_test(self_test), .swb(4'b0000),

		.snd_cmd_wr(snd_cmd_wr), .snd_cmd_data(snd_cmd_data),
		.snd_resp_rd(snd_resp_rd), .snd_reset(snd_reset),
		.snd_resp_data(snd_resp_data), .snd_irq(snd_irq),
		.snd_m2s_ready(snd_m2s_ready),

		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_index(ioctl_index), .ioctl_upload(ioctl_upload),
		.ioctl_upload_req(ioctl_upload_req),
		.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din),

		.cpu_a(cpu_a), .cpu_dout(cpu_dout), .cpu_as(cpu_as),
		.cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n), .cpu_rw(cpu_rw),
		.cpu_dtack(cpu_dtack), .cpu_fc(cpu_fc), .cpu_din(cpu_din),
		.slap_bank(slap_bank), .watchdog_reset(watchdog_reset),
		.reset_net(reset_net), .ipl(ipl)
	);

	// =====================================================================
	//  JSA I audio PCB — SP-313 sheets 11-14
	// =====================================================================
	// The watchdog does NOT reach this board; its only reset paths are
	// power-up and /AUDRES -> SCOM /RESREQ (`snd_reset`).
	logic coin_ctr1, coin_ctr2;

	xybots_jsa #(.SWAP_COINS(1'b1)) u_jsa (
		.clk(clk_sys), .reset(sys_reset),
		.ce_6502(ce_6502_game), .ce_ym(ce_ym_game),

		.rom_wr(sndrom_wr), .rom_wr_addr(sndrom_addr), .rom_wr_data(sndrom_data),

		.main_cmd_wr(snd_cmd_wr), .main_cmd_data(snd_cmd_data),
		.main_resp_rd(snd_resp_rd), .main_sndrst_wr(snd_reset),
		.main_resp_data(snd_resp_data), .main_irq(snd_irq),
		.main_to_sound_ready(snd_m2s_ready),

		.coin1(coin1), .coin2(coin2), .coin3(1'b0), .coin4(1'b0),
		.self_test(self_test),
		.coin_ctr1(coin_ctr1), .coin_ctr2(coin_ctr2),

		.lpf_bypass(1'b0),                 // the sheet-13 filter is the hardware
		.aud_left(aud_l), .aud_right(aud_r)
	);

	// =====================================================================
	//  Observation-only nets
	// =====================================================================
	// Everything below is either a board net with no consumer in a MiSTer core
	// (the coin counter solenoids), a SYNGEN tap only one of the two video
	// siblings needs, or a diagnostic output nothing reads.  Collecting them in
	// one reader keeps the Verilator lint meaningful instead of blanket-
	// disabled, and gives Quartus exactly one 10036 to report.
	// `hpos_out` is listed here because the release build has no consumer for
	// it; under XYBOTS_BRINGUP_DEBUG it drives the test pattern's h_count.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_core = &{1'b0,
		coin_ctr1, coin_ctr2,
		eeprom_img_wr, eeprom_img_addr, eeprom_img_data,
		mo_vaddr, mo_hpos, mo_fetch_late, pf_late, hpos_out,
		virq_gate, mohr_n, dclk, rclk,
		h_2hd1h_n, h_4hd1h, h_4hd1h_n, h_4hd2h,
		h1_n, h2_n, h4_n, v1_n, v1d8h_n,
		cpu_a, cpu_dout, cpu_din, cpu_as, cpu_uds_n, cpu_lds_n, cpu_rw,
		cpu_dtack, cpu_fc, ipl, slap_bank, watchdog_reset, reset_net,
		1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
