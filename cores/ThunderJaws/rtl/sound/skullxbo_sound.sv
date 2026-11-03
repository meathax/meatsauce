`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones JSA Audio II board, A047184-02 (schematic 046487-01
//  rev D, JSA sheets 1-3), plus both ends of the SCOM sound link.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structural template: the Bad
//  Lands core's `badlands_sound.sv` and the Vindicators core's `vind_jsa.sv`
//  (both GPL-3.0).  Every device, bit map and equation is this board's.
//
//  Submodules:
//    skullxbo_scom        SCOM 120E (master, game PCB) + SCOM 3D (slave) and
//                         the four-wire cable
//    skullxbo_snd_decode  PAL16L8 136056-2101 at 2D + LS138 3F
//    skullxbo_snd_bus     6502A 1D (T65), 6264 2B, 27512 1B with its bank
//                         window, the periodic IRQ, the read mux, /RESET
//    skullxbo_snd_io      LS273 4D, LS174 3C, LS240 2F, the coin counters
//    skullxbo_ym          YM2151 3A (jt51) + YM3012 5A
//    skullxbo_oki         MSM6295 6D/E + its four 27512 sample ROMs
//    skullxbo_snd_filter  the 4066 volume ladder, the switched Sallen-Key
//                         filter, the TL084 OKI filter chain and the mixer
//
//  Clock enables (clk_sys = 57.272727 MHz):
//    ce_3m58 = /16   3.579545 MHz   YM2151, the LS393 IRQ chain
//    ce_1m79 = /32   1.789772 MHz   6502 (and O2 for the decode)
//    ce_1m19 = /48   1.193182 MHz   MSM6295
//    ce_14m, ce_7m                  unused: nothing on this board runs at
//                                   those rates.  The SCOM bit clock arrives
//                                   from the game board on `scom_ck`.
//  ce_1m79 must be a subset of ce_3m58 (jt51's cen / cen_p1 rule); the single
//  divider in skullxbo_core guarantees it.
//
//  Two resets:
//    * `por`: the board's own power-on reset.  It is the only reset the SCOM
//      link and the periodic-IRQ divider see.
//    * /SNDRES: SCOM 3D pin 16, asserted after the 68000 writes FF1800.
//      /RESET = POR AND /SNDRES drives the 6502, the LS273 4D and the LS174
//      3C, and nothing else.  The self test's sound board test relies on it.
//
//  Interface to the game board:
//    audwr_stb / audwr_data   68000 write to FF1400 -> the master SCOM
//    audrd_stb / audrd_data   68000 read of FF5001; reading it clears IRQ4
//    audres_stb               68000 write to FF1800 -> the master's /RESREQ
//    scom_ck                  /4H = 894.886 kHz from the game board
//    scom_full_n              /IPL2, active low: a response is waiting
//    audbusy_n                /AUDBUSY (status BD6), active low: the last
//                             command has not been taken yet
//    rom_wr / rom_addr / rom_data   the 64 KB sound ROM from the loader
//    oki_req / addr / ack / data    byte reads of the 256 KB sample ROM in
//                             SDRAM (see skullxbo_oki)
//    self_test                1 while the self-test switch is on
//    coin[3:0]                {J1-33, J1-31, J1-35, J1-36}, 1 = closed
//    cctr1 / cctr2 / cctr_wired_or   coin counters (see skullxbo_snd_io)
//    audio_l / audio_r        signed 16-bit.  The board is mono (one
//                             speaker output), so both carry the same signal.
//============================================================================

module skullxbo_sound
#(
	// Test only.  0 = the board's /RDIO byte; 1 = MAME's D6/D4 senses.
	parameter bit MAME_RDIO_POLARITY = 1'b0,
	// Test only.  1 = MAME's zero-latency mailbox instead of the SCOM's serial
	// link, and 1 = MAME's free-running periodic IRQ instead of the board's
	// ack-gated divider.
	parameter bit MAME_MAILBOX       = 1'b0,
	parameter bit MAME_IRQ_FREERUN   = 1'b0
)
(
	input  logic        clk,
	input  logic        ce_14m,         // UNUSED -- see the header
	input  logic        ce_7m,          // UNUSED -- see the header
	input  logic        ce_3m58,        // 3579K : YM2151 OM, the LS393 chain
	input  logic        ce_1m79,        // 1790K : 6502 O0 / O2
	input  logic        ce_1m19,        // 1193K : MSM6295 XT
	input  logic        por,            // the JSA board's power-on reset

	// ---- 68000 side of the SCOM link (the master, 120E on the game PCB) ----
	// The two flags leave this block as the board's own active-low nets.
	input  logic        audwr_stb,      // FF1400 write, 1 clk
	input  logic  [7:0] audwr_data,     // BD7:0 for that write
	input  logic        audrd_stb,      // FF5000/1 read, 1 clk -- the ONLY IRQ4 ack
	output logic  [7:0] audrd_data,     // the SCOM's D7:0
	input  logic        audres_stb,     // FF1800 write -> pin 7 /RESREQ
	input  logic        scom_ck,        // pin 11 CK = LS125 50H = /4H (a LEVEL)
	output logic        scom_full_n,    // pin 4 FULL -> /IPL2,          ACTIVE LOW
	output logic        audbusy_n,      // pin 5 BUSY -> status BD6,     ACTIVE LOW

	// ---- board inputs ----
	input  logic        self_test,      // 1 while the switch is ON
	input  logic  [3:0] coin,           // {J1-33, J1-31, J1-35, J1-36}

	// ---- coin counters ----
	output logic        cctr1,
	output logic        cctr2,
	output logic        cctr_wired_or,

	// ---- sound ROM load port (from the ROM loader) ----
	input  logic        rom_wr,
	input  logic [15:0] rom_addr,
	input  logic  [7:0] rom_data,

	// ---- MSM6295 sample ROM client (SDRAM arbiter) ----
	output logic        oki_req,
	output logic [17:0] oki_addr,
	input  logic        oki_ack,
	input  logic  [7:0] oki_data,

	// ---- audio (mono: both outputs carry the same sample) ----
	output logic signed [15:0] audio_l,
	output logic signed [15:0] audio_r
);

	// ---- SCOM 120E + SCOM 3D + the cable -----------------------------------
	wire [7:0] rdp_data;
	wire       scom_full, scom_sfull, scom_res;
	wire       sel_rdv, sel_rdp, sel_rdio, sel_irqack;
	wire       sel_wrv, sel_wrp, sel_wrio, sel_mix;
	wire [7:0] cpu_dout;

	wire audfull, audbusy;      // the LOGICAL (active-high) flags
	skullxbo_scom #(.MAME_MAILBOX(MAME_MAILBOX)) u_scom (
		.clk(clk), .reset(por), .scom_ck(scom_ck),
		.audwr_stb(audwr_stb), .audwr_data(audwr_data),
		.audrd_stb(audrd_stb), .audrd_data(audrd_data),
		.audres_stb(audres_stb), .audfull(audfull), .audbusy(audbusy),
		.jsa_rdp(sel_rdp), .jsa_wrp(sel_wrp), .jsa_wrp_data(cpu_dout),
		.jsa_cmd_data(rdp_data), .jsa_nmi(scom_full), .jsa_sfull(scom_sfull),
		.jsa_res(scom_res) );

	// BUSY is active low (though drawn without a bar) and FULL is /IPL2.  The
	// block outputs the board's own nets; skullxbo_scom uses active high.
	assign scom_full_n = ~audfull;
	assign audbusy_n   = ~audbusy;

	// ---- LS273 4D / LS174 3C / LS240 2F ------------------------------------
	wire [1:0] bank;
	wire       vfreq, okires_n, yamres_n, lpf, sp0, reset_n;
	wire [2:0] ym_vol;
	wire [7:0] rdio_data;

	skullxbo_snd_io u_io (
		.clk(clk), .reset_n(reset_n),
		.wrio_stb(sel_wrio), .wrio_data(cpu_dout),
		.mix_stb(sel_mix),   .mix_data(cpu_dout),
		.self_test(self_test), .cmd_pending(scom_full),
		.resp_pending(scom_sfull), .coin(coin),
		.mame_polarity(MAME_RDIO_POLARITY),
		.bank(bank), .cctr2(cctr2), .cctr1(cctr1),
		.cctr_wired_or(cctr_wired_or),
		.vfreq(vfreq), .okires_n(okires_n), .yamres_n(yamres_n),
		.lpf(lpf), .ym_vol(ym_vol), .sp0(sp0),
		.rdio_data(rdio_data) );

	// ---- 6502A 1D + PAL 2D + LS138 3F + the memories + the IRQ chain -------
	wire        ym_cs, ym_a0, ym_we, ym_rd;
	wire [7:0]  ym_dout, ym_din;
	wire        ym_irq;
	wire [7:0]  rdv_data;
	wire [15:0] cpu_addr;
	wire [7:0]  cpu_din;
	wire        cpu_rnw, cpu_sync, irq_periodic;

	// The instance MUST be named `u_bus` -- SkullXBones.sdc addresses the 6502
	// as *u_sound|u_bus|u_cpu|u_t65|*.
	skullxbo_snd_bus #(.MAME_FREERUN(MAME_IRQ_FREERUN)) u_bus (
		.clk(clk), .ce_1m79(ce_1m79), .ce_3m58(ce_3m58), .por(por),
		.sndres(scom_res), .scom_full(scom_full), .ym_irq(ym_irq),
		.bank(bank),
		.rdp_data(rdp_data), .rdio_data(rdio_data), .rdv_data(rdv_data),
		.ym_cs(ym_cs), .ym_a0(ym_a0), .ym_we(ym_we), .ym_rd(ym_rd),
		.ym_dout(ym_dout), .ym_din(ym_din),
		.sel_rdv(sel_rdv), .sel_rdp(sel_rdp), .sel_rdio(sel_rdio),
		.sel_irqack(sel_irqack), .sel_wrv(sel_wrv), .sel_wrp(sel_wrp),
		.sel_wrio(sel_wrio), .sel_mix(sel_mix),
		.rom_wr(rom_wr), .rom_wr_addr(rom_addr), .rom_wr_data(rom_data),
		.reset_n(reset_n), .irq_periodic(irq_periodic),
		.cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
		.cpu_rnw(cpu_rnw), .cpu_sync(cpu_sync) );

	// ---- YM2151 3A + YM3012 5A ---------------------------------------------
	wire signed [15:0] ym_ch1, ym_ch2;
	wire               ym_sample;
	// The instance MUST be named `u_ym` -- the SDC addresses jt51 as
	// *u_sound|u_ym|u_jt51|...
	skullxbo_ym u_ym (
		.clk(clk), .cen(ce_3m58), .cen_p1(ce_1m79), .yamres_n(yamres_n),
		.ym_cs(ym_cs), .ym_a0(ym_a0), .ym_we(ym_we),
		.ym_dout(ym_dout), .ym_din(ym_din), .ym_irq(ym_irq),
		.sample(ym_sample), .aud_ch1(ym_ch1), .aud_ch2(ym_ch2) );

	// ---- MSM6295 6D/E + the four 27512s ------------------------------------
	wire signed [15:0] oki_audio;
	skullxbo_oki u_oki (
		.clk(clk), .ce_1m19(ce_1m19), .okires_n(okires_n), .vfreq(vfreq),
		.wr_stb(sel_wrv), .wr_data(cpu_dout), .rd_stb(sel_rdv),
		.rd_data(rdv_data),
		.oki_req(oki_req), .oki_addr(oki_addr),
		.oki_ack(oki_ack), .oki_data(oki_data),
		.audio(oki_audio) );

	// ---- the analogue chain ------------------------------------------------
	wire signed [15:0] aud;
	wire               aud_clipped;
	wire signed [15:0] dbg_ym_hp, dbg_ym, dbg_oki_s2, dbg_oki_s3, dbg_oki;
	skullxbo_snd_filter u_filt (
		.clk(clk), .ce(ce_1m79), .reset(por), .bypass(1'b0),
		.ym_vol(ym_vol), .lpf(lpf), .sp0(sp0),
		.ym_ch1(ym_ch1), .ym_ch2(ym_ch2), .oki_in(oki_audio),
		.out(aud), .clipped(aud_clipped),
		.dbg_ym_hp(dbg_ym_hp), .dbg_ym(dbg_ym), .dbg_oki_s2(dbg_oki_s2),
		.dbg_oki_s3(dbg_oki_s3), .dbg_oki(dbg_oki) );

	// Mono: the TDA2030 speaker output (J1-15/16) is the board's only output,
	// so both MiSTer channels carry the same signal.
	assign audio_l = aud;
	assign audio_r = aud;

	// Unused here:
	//  * ce_14m, ce_7m -- nothing on the JSA II runs at those rates.
	//  * ym_rd         -- the YM2151 status comes back through the same read
	//                     mux as every other source, so the strobe itself is
	//                     applied inside skullxbo_snd_bus.
	//  * sel_rdio      -- /RDIO gates the LS240 2F's output drivers, which
	//                     skullxbo_snd_bus already applies in its read mux.
	//  * sel_irqack    -- consumed inside skullxbo_snd_bus (the LS74 /CLR).
	//  * irq_periodic  -- Q6's state (debug).
	//  * cpu_addr / cpu_din / cpu_rnw / cpu_sync -- debug.
	//  * ym_sample, aud_clipped, the five filter taps -- diagnostics.
	wire _unused_snd = &{ 1'b0, ce_14m, ce_7m, ym_rd, sel_rdio, sel_irqack,
	                      irq_periodic, cpu_addr, cpu_din, cpu_rnw, cpu_sync,
	                      ym_sample, aud_clipped,
	                      dbg_ym_hp, dbg_ym, dbg_oki_s2, dbg_oki_s3, dbg_oki };

endmodule
