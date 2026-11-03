`timescale 1ns/1ps
//============================================================================
//  Xybots main CPU — fx68k (cycle-exact 68000), wired as SP-313 sheet 2 draws
//  it.  This is the only 68000 in the core.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  The CPU itself is Jorge Cwik's fx68k, GPL-3.0-or-later, vendored verbatim
//  in `rtl/lib/fx68k/`; see `rtl/lib/README.md` and NOTICE.md.
//
//  fx68k is a microcode-level model of the real part, so its instruction timing
//  is the datasheet's — which this game needs.  The X2804A software write-wait
//  loop at pc 0x122A costs 959 888 clk_sys per entry, the 68000 timing tables'
//  figure to the clock, and a read-modify-write on a long operand emits its two
//  writes in the real descending order.
//
//  ---- clock enables -------------------------------------------------------
//  fx68k is fully synchronous on `clk` (= clk_sys, 57.272727 MHz) and takes TWO
//  enables per CPU clock, one for each phase of the nominal 7.15909 MHz clock:
//
//      enPhi1  -> the CPU clock's HIGH phase   -> the `ce_7m` tick (clk_sys/8)
//      enPhi2  -> the CPU clock's LOW  phase   -> 4 clk_sys later (clk_sys/4)
//
//  fx68k's flops are `always_ff @(posedge clk) if (enPhiN)`, so `enPhi1 = ce_7m`
//  puts the fx68k CPU clock edge on the `ce_7m` cycle itself and the rest of
//  sheet 2 — the 5A LS163A /DTACK counter, the 7B 74S74 VRAC arbitration and the
//  E-clock/VPA path — needs no change.  `xybots_main_bus` has no second enable
//  port, so the low phase is regenerated here by a counter re-zeroed on every
//  ce_7m tick: it is locked to ce_7m by construction and cannot drift.  The
//  resulting E clock is CPU-clock/10 with the datasheet's 6-low / 4-high duty.
//
//  ---- pins as wired -------------------------------------------------------
//    clk        = clk_sys, CPU clock = VIDCLK 7.15909 MHz via enPhi1/enPhi2
//    extReset   = the /RESET net + power-up
//    DTACKn     = /DTACK  (xybots_dtack; `dtack` here is ACTIVE HIGH)
//    VPAn       = /VPA    (10A LS20 -> 16A pin 21)
//    BERRn      = 1 (16A pin 22 = PR2): sheet 2 has no bus-error source.
//    IPL2n/1n/0n= `ipl[2:1:0]`, active low, "111" = none (xybots_irq)
//    BRn/BGACKn = 1, BGn unused — there is no second bus master on this board.
//    E/VMAn       unused — no 6800 peripheral on this board.
//    eab[23:1]  = A23..A1.  There is no A0 on this board and no decoder looks
//                 at one; fx68k presents A23..A1 and drives /UDS //LDS from its
//                 internal A0, which is what the 12B/13B LS244 buffers carry.
//    iEdb/oEdb  = the 16-bit data bus, split into `rdata`/`wdata` (this core
//                 has no bidirectional board bus; `xybots_main_bus` muxes the
//                 read sources).
//
//  ---- two deviations from a literal pin-for-pin transcription -------------
//  1. **HALTn is tied INACTIVE (1), not to the /RESET net.**  On the board 16A
//     pin 17 (HALT) is tied to pin 18 (RESET), so the watchdog stops and resets
//     the CPU with one net.  In fx68k, `extReset` alone performs the whole
//     68000 reset, and `HALTn` is the single-step / bus-arbitration input — it
//     only gates `busAvail` in the bus arbiter.  Driving it low alongside
//     extReset would add a bus-grant interaction the board does not have and
//     model nothing the reset does not already model.  `oHALTEDn` (fx68k's
//     double-bus-fault output) has no load on sheet 2 and is left unconnected.
//  2. **`pwrUp` is driven from the same `reset`**, as fx68k's own top level
//     does, for the registers it has no other reset for.  On this board the
//     /RESET net is a full CPU reset either way, so a watchdog timeout re-inits
//     the sequencer the way power-up does.
//
//  ---- /VPA, autovectoring and the RESET instruction -----------------------
//  Sheet 2 makes `/VPA = ~(FC0 & FC1 & FC2 & AS)` (10A LS20) and wires it to
//  BOTH the 68000's VPA pin (21) and the 5A LS163A's ENT input.  Every interrupt
//  is autovectored and there is no vector hardware anywhere; because /VPA is the
//  5A's ENT, an FC = 7 cycle deliberately gets no /DTACK and can only end
//  through the CPU's own E-synchronised VPA path.
//
//  `oRESETn` is fx68k's outgoing RESET, asserted while a `RESET` instruction
//  runs (the game executes one at pc 0x4A2).  On this board that net reaches
//  ONLY the 4B LS74 EEPROM unlock flip-flop's /CLR and the 2A LS08 that gates
//  the EEPROM /OE, which is what `reset_inst` drives in `xybots_main_bus`.
//============================================================================

module xybots_cpu
(
	input  logic        clk,        // clk_sys, 57.272727 MHz
	input  logic        ce_7m,      // VIDCLK enable, clk_sys / 8
	input  logic        reset,      // active high: the /RESET net + power-up
	input  logic  [2:0] ipl,        // active low, "111" = none (xybots_irq)

	output logic [23:1] a,
	output logic [15:0] wdata,
	input  logic [15:0] rdata,
	output logic        as,         // ACTIVE HIGH copy of /AS (11A LS14)
	output logic        uds_n,
	output logic        lds_n,
	output logic        rw,         // 1 = read, 0 = write
	input  logic        dtack,      // active high (= ~/DTACK)
	input  logic        vpa_n,      // 10A LS20, active low; 16A pin 21
	output logic  [2:0] fc,
	output logic        reset_inst  // 1 while a RESET instruction drives /RESET
);

	// ---------------------------------------------------------------- phases
	// `ph` is the clk_sys position inside one CPU clock, re-zeroed by every
	// ce_7m tick so the two enables can never drift apart or double up.  It
	// saturates at 7 instead of wrapping.  While ce_7m runs that changes
	// nothing, because the tick re-zeroes it on the very cycle it reaches 7.
	// While the OSD pause withholds ce_7m (xybots_core), a wrapping counter
	// would keep firing en_phi2 every 8 clk_sys on its own; saturated, each
	// en_phi1 is followed by exactly one en_phi2 and then the CPU stands still.
	logic [2:0] ph;
	always_ff @(posedge clk) begin
		if (ce_7m)             ph <= 3'd0;
		else if (ph != 3'd7)   ph <= ph + 3'd1;
	end

	wire en_phi1 = ce_7m;          // CPU clock high phase (= the ce_7m tick)
	wire en_phi2 = (ph == 3'd3);   // 4 clk_sys later (= the ce_14m tick between)

	// ------------------------------------------------------------------- IPL
	// Two posedge stages.  fx68k is fully synchronous on posedge clk and samples
	// IPL under `enPhi2` into its own two-deep `rIpl`/`iIpl` synchroniser, so
	// ordinary posedge staging is correct and the extra latency is invisible at
	// the ce_7m sampling rate.
	logic [2:0] ipl_r, ipl_rr;
	always_ff @(posedge clk) begin
		if (reset) begin
			ipl_r  <= 3'b111;
			ipl_rr <= 3'b111;
		end else begin
			ipl_r  <= ipl;
			ipl_rr <= ipl_r;
		end
	end

	// ----------------------------------------------------------------- fx68k
	wire        fx_as_n, fx_reset_n;
	wire [23:1] fx_eab;

	/* verilator lint_off UNUSEDSIGNAL */
	wire        fx_e, fx_vma_n;    // 6800 bus, unused on this board
	wire        fx_bg_n;           // no second bus master
	wire        fx_halted_n;       // double bus fault; no load on sheet 2
	/* verilator lint_on UNUSEDSIGNAL */

	assign a          = fx_eab;
	assign as         = ~fx_as_n;
	assign reset_inst = ~fx_reset_n;

	fx68k u_fx68k (
		.clk      (clk),
		.HALTn    (1'b1),          // see deviation 1 in the header
		.extReset (reset),
		.pwrUp    (reset),         // see deviation 2 in the header
		.enPhi1   (en_phi1),
		.enPhi2   (en_phi2),

		.eRWn     (rw),            // 1 = read, 0 = write
		.ASn      (fx_as_n),
		.LDSn     (lds_n),
		.UDSn     (uds_n),
		.E        (fx_e),
		.VMAn     (fx_vma_n),

		.FC0      (fc[0]),
		.FC1      (fc[1]),
		.FC2      (fc[2]),
		.BGn      (fx_bg_n),
		.oRESETn  (fx_reset_n),
		.oHALTEDn (fx_halted_n),

		.DTACKn   (~dtack),        // xybots_dtack is active high here
		.VPAn     (vpa_n),         // 10A LS20 -> 16A pin 21
		.BERRn    (1'b1),          // 16A pin 22 = PR2, inactive
		.BRn      (1'b1),
		.BGACKn   (1'b1),
		.IPL0n    (ipl_rr[0]),
		.IPL1n    (ipl_rr[1]),
		.IPL2n    (ipl_rr[2]),

		.iEdb     (rdata),
		.oEdb     (wdata),
		.eab      (fx_eab)
	);

endmodule
