//============================================================================
//  Xybots (Atari Games, 1987) — the complete JSA I audio PCB.
//
//  6502 (T65) + xybots_jsa_bus (decode / memory / I/O / SCOM mailbox) +
//  YM2151 (jt51) + the /MIX mixer + the sheet-13 output low-pass.  One
//  instantiable module, wired up by rtl/xybots_core.sv.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_jsa.sv
//  (GPL-3.0-or-later), minus POKEY; see NOTICE.md.
//
//  ---- what is different about Xybots' JSA I -------------------------------
//  The Stand-Alone Audio PCB drawing (SP-313 sheets 11-14 = PDF pages 13-16,
//  Atari drawing 043713-xx rev A) is the generic one shared with Blasteroids,
//  Toobin', Vindicators and Escape; it carries no "not loaded" annotations at
//  all.  Which sockets are stuffed is a per-game build decision:
//
//   * **No POKEY (3K) and no TMS5220C (3D).**  MAME's xybots.cpp removes both
//     (`config.device_remove("jsa:pokey")`, `"jsa:tms"`).  Everything around
//     them is still on the board: the /VOICE latch (3F LS374), the POKEY chip
//     select (CS0 = /REST, CS1 = SA10 -> 0x2C00-0x2FFF), the speech/POKEY
//     volume bits of /MIX, the PS summing network and the CT1/CT2 stereo
//     gates.  They are decoded here and drive nothing.  Reads of the empty
//     POKEY socket return 0xFF (xybots_jsa_bus's header says why).
//   * **Coins are swapped** — see xybots_jsa_io's header.
//   * **Self-test** is the SW1 switch on this board (SP-313 sheet 14), which
//     fans out to /RDIO bit 7 *and* to JSCOM-1 -> the game PCB's /SYSIN bit 8.
//     One logical input, active high = "self test requested".
//
//  ---- clock enables -------------------------------------------------------
//  Only two, both integer decodes of one counter in rtl/xybots_core.sv:
//     ce_6502  = clk_sys/32 = 1.7897725 MHz  (6502, jt51 cen_p1, the LPF)
//     ce_ym    = clk_sys/16 = 3.579545  MHz  (jt51 cen, the periodic-IRQ
//                                             divider)
//  clk_sys is 4 x the video crystal and the JSA crystal is that crystal / 4,
//  so both enables are exact and ce_6502 is a strict subset of ce_ym — which
//  is the cen/cen_p1 relationship jt51 needs.  jt51 documents cen_p1 as "clock
//  enable at half the speed" (rtl/lib/jt51/hdl/jt51.v line 28) and drives
//  every register/EG/LFO block from it, so cen_p1 on this board IS the 6502
//  enable (3.579545/2 = 1.7897725 MHz, the sheet-12 `1790K` net).  It is wired
//  from ce_6502 below rather than taken as a third port.
//
//  T65 is instantiated as T65_wrap (VHDL, for Quartus).
//============================================================================

module xybots_jsa #(
	parameter int IRQ_DIV    = 14336,   // 3.579545 MHz /4/16/16/14 = 249.689 Hz
	parameter bit SWAP_COINS = 1'b1     // MAME xybots.cpp set_swapped_coins(true)
) (
	input  logic        clk,
	input  logic        reset,
	// clock enables
	input  logic        ce_6502,
	input  logic        ce_ym,
	// sound ROM loader (64 KB; download-stream offset 0x030000)
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,
	// main-CPU mailbox (SCOM, SP-313 sheet 3 / sheet 14)
	input  logic        main_cmd_wr,           // 68000 word write to 0x806900, D7:0
	input  logic  [7:0] main_cmd_data,
	input  logic        main_resp_rd,          // 68000 byte read of 0x806001 (clears IRQ2)
	input  logic        main_sndrst_wr,        // 68000 write to 0x806E00
	output logic  [7:0] main_resp_data,
	output logic        main_irq,              // -> 68000 IRQ2
	output logic        main_to_sound_ready,   // /SYSIN bit 9 is the COMPLEMENT of this
	// board inputs
	input  logic        coin1,                 // LEFT  chute (player 1)
	input  logic        coin2,                 // RIGHT chute (player 2)
	input  logic        coin3,                 // JCOIN-2, normally unused
	input  logic        coin4,                 // JCOIN-1, normally unused
	input  logic        self_test,             // SW1 / JSCOM-1, active high
	// board outputs
	output logic        coin_ctr1,
	output logic        coin_ctr2,
	// audio options
	input  logic        lpf_bypass,            // 1 = skip the sheet-13 output low-pass
	// audio
	output logic signed [15:0] aud_left,
	output logic signed [15:0] aud_right
);

	// ---- 6502 <-> bus ----
	wire [15:0] cpu_a; wire [7:0] cpu_do, cpu_di; wire cpu_rwn;
	wire cpu_irq, cpu_nmi, cpu_reset;
	wire [7:0] dbgA_nc, dbgX_nc, dbgY_nc, dbgS_nc, dbgP_nc; wire cpu_sync_nc;
	T65_wrap u_cpu (
		.Mode(2'b00), .Res_n(~(reset | cpu_reset)), .Clk(clk), .Enable(ce_6502), .Rdy(1'b1),
		.IRQ_n(~cpu_irq), .NMI_n(~cpu_nmi), .DI(cpu_di),
		.A(cpu_a), .DO(cpu_do), .R_W_n(cpu_rwn), .Sync(cpu_sync_nc),
		.dbg_A(dbgA_nc), .dbg_X(dbgX_nc), .dbg_Y(dbgY_nc), .dbg_S(dbgS_nc), .dbg_P(dbgP_nc) );

	// ---- bus (decode + memory + I/O + SCOM mailbox) ----
	wire ym_reset_n; wire [1:0] cpu_bank_nc;
	wire ym_cs, ym_a0, ym_we, ym_rd; wire [7:0] ym_dout, ym_din;
	wire mix_wr; wire [7:0] mix_data;
	wire ym_irq_w;
	xybots_jsa_bus #(.IRQ_DIV(IRQ_DIV), .SWAP_COINS(SWAP_COINS)) u_bus (
		// ce_jsa is the periodic-IRQ divider enable: IRQ_DIV counts MASTER-clock
		// ticks (3.579545 MHz /4/16/16/14 = 249.689 Hz), so it must be ce_ym and
		// NOT the half-rate ce_6502.
		.clk(clk), .reset(reset), .ce(ce_6502), .ce_jsa(ce_ym),
		.cpu_addr(cpu_a), .cpu_dout(cpu_do), .cpu_rnw(cpu_rwn), .cpu_din(cpu_di),
		.cpu_irq(cpu_irq), .ym_irq(ym_irq_w), .cpu_nmi(cpu_nmi), .cpu_reset(cpu_reset),
		.rom_wr(rom_wr), .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data),
		.main_cmd_wr(main_cmd_wr), .main_cmd_data(main_cmd_data), .main_resp_rd(main_resp_rd),
		.main_sndrst_wr(main_sndrst_wr), .main_resp_data(main_resp_data), .main_irq(main_irq),
		.main_to_sound_ready(main_to_sound_ready),
		.coin1(coin1), .coin2(coin2), .coin3(coin3), .coin4(coin4), .self_test(self_test),
		.ym_reset_n(ym_reset_n), .coin_ctr1(coin_ctr1), .coin_ctr2(coin_ctr2),
		.cpu_bank(cpu_bank_nc),
		.ym_cs(ym_cs), .ym_a0(ym_a0), .ym_we(ym_we), .ym_rd(ym_rd),
		.ym_dout(ym_dout), .ym_din(ym_din),
		.mix_wr(mix_wr), .mix_data(mix_data) );

	// ---- YM2151 (jt51) ----
	wire signed [15:0] ym_l, ym_r, ym_l_lo_nc, ym_r_lo_nc;
	wire ym_sample_nc, ym_ct1_nc, ym_ct2_nc;
	xybots_ym u_ym (
		.clk(clk), .reset(reset), .cen(ce_ym), .cen_p1(ce_6502), .ym_reset_n(ym_reset_n),
		.ym_cs(ym_cs), .ym_a0(ym_a0), .ym_we(ym_we), .ym_dout(ym_dout), .ym_din(ym_din),
		.sample(ym_sample_nc), .aud_left(ym_l), .aud_right(ym_r),
		.aud_left_lo(ym_l_lo_nc), .aud_right_lo(ym_r_lo_nc),
		.ct1(ym_ct1_nc), .ct2(ym_ct2_nc), .ym_irq(ym_irq_w) );

	// CT1/CT2 gate the PS (POKEY + speech) sum into the left/right analogue
	// paths on SP-313 sheet 13.  Both of those sockets are empty on Xybots, so
	// PS is silent and the gates have nothing to switch — they are read here
	// and discarded rather than left dangling.  Likewise ym_rd (the YM2151 is
	// read through the same combinational path as any other source), the ROM
	// bank output, the T65 debug ports and jt51's low-resolution audio.
	wire _unused_jsa = &{1'b0, ym_rd, cpu_bank_nc, cpu_sync_nc,
		dbgA_nc, dbgX_nc, dbgY_nc, dbgS_nc, dbgP_nc, ym_sample_nc,
		ym_ct1_nc, ym_ct2_nc, ym_l_lo_nc, ym_r_lo_nc};

	// ---- /MIX audio mixer ----
	wire signed [15:0] mix_l, mix_r; wire lpf_engage;
	xybots_jsa_mix u_mix (
		.clk(clk), .reset(reset), .mix_wr(mix_wr), .mix_data(mix_data),
		.ym_left(ym_l), .ym_right(ym_r),
		.out_left(mix_l), .out_right(mix_r), .lpf_engage(lpf_engage) );

	// ---- output low-pass (SP-313 sheet 13) ----
	// LM324 4A Sallen-Key on each channel, with Q5/Q6 switching C54/C56 in.
	xybots_jsa_lpf u_lpf_l (
		.clk(clk), .reset(reset), .ce(ce_6502), .engage(lpf_engage), .bypass(lpf_bypass),
		.in(mix_l), .out(aud_left) );
	xybots_jsa_lpf u_lpf_r (
		.clk(clk), .reset(reset), .ce(ce_6502), .engage(lpf_engage), .bypass(lpf_bypass),
		.in(mix_r), .out(aud_right) );

endmodule
