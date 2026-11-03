//============================================================================
//  Xybots (Atari Games, 1987) — JSA I board I/O: the /WRIO output register,
//  the /RDIO input port, ROM banking and the periodic sound IRQ.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_jsa_io.sv
//  (GPL-3.0-or-later); see NOTICE.md.
//
//  ---- /WRIO output register (SP-313 sheet 12, 5H 74LS273A) ----------------
//  CK(11) = /WRIO, /CLR(1) = /POR (R103 150K + C84 0.1 uF, ~15 ms), so every
//  bit powers up at 0 — including /YAMRES, i.e. the YM2151 is held in reset
//  until the 6502's first /WRIO write.  (The Xybots sound ROM's very first
//  bus cycle is `STA $2A04` with 0x01 at pc=0x4007, which releases it.)
//
//    SD7 -> BA13     ROM bank bit 1
//    SD6 -> BA12     ROM bank bit 0
//    SD5 -> CCTR2    coin counter 2 (Q10 2N5306 -> CC2+/CC2-)
//    SD4 -> CCTR1    coin counter 1 (Q9  2N5306 -> CC1+/CC1-)
//    SD3 -> SQUEAK   TMS5220 clock-divider select  (socket empty on Xybots)
//    SD2 -> /SPHRES  TMS5220 RS                    (socket empty on Xybots)
//    SD1 -> /SPHWR   TMS5220 WS                    (socket empty on Xybots)
//    SD0 -> /YAMRES  YM2151 /IC (active low: 1 = run)
//  MAME `wrio_w` agrees bit for bit.
//
//  ---- /RDIO input port (SP-313 sheet 14, 5J 74LS240A) ---------------------
//  **The LS240 is an INVERTING buffer**, enabled by /RDIO on /1G(1) and /2G(19):
//
//    SD7 = ~SELF-TEST   SW1 on the audio PCB (ON shorts to GND) and JSCOM-1
//    SD6 = ~(/NMI)      the slave SCOM's FULL output
//    SD5 = ~SFULL       the slave SCOM's BUSY output
//    SD4 = ~(/SPHRDY)   TMS5220 RDY                (socket empty -> reads 0)
//    SD3 = ~COIN4       JCOIN-1, R76 1K
//    SD2 = ~COIN3       JCOIN-2, R81 1K
//    SD1 = ~COIN2       JCOIN-3, R79 1K
//    SD0 = ~COIN1       JCOIN-4, R80 1K
//  Each coin line is pulled up (R74/R75/R77/R78 1K) and filtered (C62-C65
//  0.1 uF); a closed coin switch pulls it to JCOIN-6 = GND, so after the
//  inverter a closed switch reads as a 1.
//
//  Both SCOM flag outputs are ACTIVE LOW — the master's pin 4 /FULL (-> /IPL1)
//  and pin 5 /BUSY (-> /AUDBUSY), whose slave-side copies land on the nets
//  /NMI and SFULL — so after the inverting LS240 both read back as 1 =
//  "pending", which is why `resp_full` and `~nmi_line_n` are used un-inverted
//  below.  That reading is confirmed on SD5, the one bit the sound ROM tests:
//  $4152 and $5691 do `LDA #$20 / BIT $280C / BNE`, i.e. they skip the "send a
//  response" path while the bit is SET, so set must mean "the response latch
//  is still full" — also MAME's `0x20 = sound output full`, IP_ACTIVE_HIGH.
//
//  Three Xybots-specific points:
//
//   1. **Coins are swapped.**  MAME's xybots.cpp calls
//      `m_jsa->set_swapped_coins(true)`, and the operator manual's Sound Test
//      page makes LEFT the higher of the two coin bits and RIGHT the lower,
//      while the board's own net names put COIN1 on SD0 and COIN2 on SD1.  So
//      the cabinet harness runs the LEFT chute into the board's COIN2 net and
//      the RIGHT chute into COIN1; SWAP_COINS models that crossover.  (The
//      harness itself, A044900-01, is not drawn in SP-313; the manual and MAME
//      agree on it.)
//   2. **Bit 3 is a real COIN4 input** (JCOIN-1) which MAME calls "+5 V" /
//      IPT_UNUSED; bit 2 is COIN3, which MAME does model.  Both are brought
//      out as ports here and default inactive, so the RTL is a superset of
//      MAME rather than a copy of its omission.  The sound ROM polls all four
//      lanes: the coin scan at $5ABA is `LDA $280C / LDX #$03 / LSR ...`, an
//      LSR walk over D0..D3 with a 4-entry index, and the self-test variant at
//      $5A98 has the same shape.
//   3. **Bits 7 and 6 follow the schematic, not MAME.**  MAME's
//      `atari_jsa_i_device::rdio_r` applies the service-switch inversion twice
//      (the JSAI ioport's D7 is already `main_test_read_line()`, then
//      `if (!m_test_read_cb()) result ^= 0x80`), so its D7 reads 0 whether or
//      not the switch is held and the JSA's own sound self-test is unreachable
//      there; this RTL drives D7 from the real SW1/JSCOM-1 line.  On D6 the
//      LS240 inverts the physical /NMI, so the 6502 reads 1 while a
//      main->sound command is pending, where MAME declares D6 IP_ACTIVE_LOW.
//      Both are unobservable: the ROM's only /RDIO tests are bit 7 ($4016,
//      $5A91), bit 5 ($4152, $4516, $4522, $5691) and the bits 0-3 walk.
//
//  ---- periodic sound IRQ (SP-313 sheet 14) --------------------------------
//  A cascade of LS393 halves (6K, 6J, 6J, 6K) drives two 5K LS74 flip-flops
//  whose /CLR is /IRQACK; Q8 2N3904 (R51 10K) is an open-collector driver that
//  pulls /IRQ low, wire-ORed with the YM2151's own /IRQ.  The ratio is
//  3.579545 MHz /4/16/16/14 = 249.689 Hz = one pulse per 14336 master-clock
//  ticks, so IRQ_DIV counts ce_jsa (= ce_ym = 3.579545 MHz) and not the
//  half-rate ce_6502, which would halve the IRQ rate to ~125 Hz.
//============================================================================

module xybots_jsa_io #(
	parameter int IRQ_DIV    = 14336,
	parameter bit SWAP_COINS = 1'b1   // Xybots: MAME set_swapped_coins(true)
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_jsa,        // JSA master-clock enable (3.579545 MHz)

	// /WRIO write (0x2A04)
	input  logic        wrio_wr,
	input  logic  [7:0] wrio_data,
	// /IRQACK strobe (a READ of 0x2806; the 2L-PAL's /SRD disables the LS138
	// for writes there) clears the periodic IRQ
	input  logic        irqack,

	// input-port sources (all logical "asserted" = 1)
	input  logic        self_test,     // SW1 on the audio PCB / JSCOM-1
	input  logic        nmi_line_n,    // physical /NMI, before the LS240 inverts it
	input  logic        resp_full,     // sound->main response pending (SFULL)
	input  logic        coin1,         // LEFT  chute  (player 1 / "Plyr 0 Coins")
	input  logic        coin2,         // RIGHT chute  (player 2 / "Plyr 1 Coins")
	input  logic        coin3,         // JCOIN-2, board net COIN3 — normally unused
	input  logic        coin4,         // JCOIN-1, board net COIN4 — normally unused

	// outputs
	output logic  [1:0] cpu_bank,      // BA13:BA12 -> the 0x3000-0x3FFF window
	output logic        coin_ctr1,
	output logic        coin_ctr2,
	output logic        ym_reset_n,    // /YAMRES (active low: 1 = run)
	output logic  [7:0] rdio_data,     // assembled /RDIO byte
	output logic        sound_irq      // level, into the 6502 /IRQ wired-OR
);

	// bits [3:1] drive the (unpopulated) TMS5220 strobes
	wire unused_tms = &{1'b0, wrio_data[3:1]};

	// ---- /WRIO output latch (5H LS273A, cleared by /POR) ----
	always_ff @(posedge clk) begin
		if (reset) begin
			cpu_bank <= 2'd0; coin_ctr1 <= 1'b0; coin_ctr2 <= 1'b0; ym_reset_n <= 1'b0;
		end else if (wrio_wr) begin
			cpu_bank   <= wrio_data[7:6];
			coin_ctr2  <= wrio_data[5];
			coin_ctr1  <= wrio_data[4];
			ym_reset_n <= wrio_data[0];
		end
	end

	// ---- /RDIO input assembly (5J LS240A, inverting) ----
	// The harness crossover: the board's COIN1 net (SD0) carries the RIGHT
	// chute on an Xybots cabinet and COIN2 (SD1) carries the LEFT one.
	wire net_coin1 = SWAP_COINS ? coin2 : coin1;   // -> SD0
	wire net_coin2 = SWAP_COINS ? coin1 : coin2;   // -> SD1

	// SD4: /SPHRDY floats high at the empty TMS5220 socket, so the inverting
	// LS240 drives 0.  MAME reaches the same value via `result &= ~0x10`.
	assign rdio_data = { self_test, ~nmi_line_n, resp_full, 1'b0,
	                     coin4, coin3, net_coin2, net_coin1 };

	// ---- periodic sound IRQ ----
	// The 5K LS74 pair is CLOCKED by the divider chain and CLEARED by /IRQACK on
	// its asynchronous /CLR, so /CLR wins a coincidence: a divider edge that
	// lands while /IRQACK is asserted cannot set Q.  The clear is therefore
	// written after the set below, so that it dominates exactly as the part
	// does.  (The ordering is unobservable in practice — /IRQACK is one 6502
	// bus cycle (559 ns) and the divider fires every 4.005 ms, so the two
	// collide on ~0.014 % of interrupts.)
	localparam int CW = $clog2(IRQ_DIV);
	logic [CW-1:0] irq_cnt;
	always_ff @(posedge clk) begin
		if (reset) begin irq_cnt <= '0; sound_irq <= 1'b0; end
		else begin
			if (ce_jsa) begin
				if (irq_cnt == CW'(IRQ_DIV-1)) begin irq_cnt <= '0; sound_irq <= 1'b1; end
				else irq_cnt <= irq_cnt + 1'b1;
			end
			if (irqack) sound_irq <= 1'b0;   // /CLR is asynchronous and dominant
		end
	end

endmodule
