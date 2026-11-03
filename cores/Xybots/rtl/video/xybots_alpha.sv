`timescale 1ns/1ps
//============================================================================
//  Xybots alphanumerics layer — SP-313 sheet 7 (6D/7D LS174E, 5C 2764,
//  2C/3C LS194A) and the VIRQ tap that sheet 2 turns into IRQ1.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  ---- the sequence, in SYNGEN counts -------------------------------------
//  Everything repeats every 8 counts.  For alpha tile column k = h[8:3]:
//
//    h = 8k+3   ALPHA VRAC phase: the word is on the SCRAM data bus
//    -> 8k+4    6D/7D LS174E clock on 4H rising: code[9:0] and VIRQ latched;
//               the attribute nibble (D15, D14:12) is NOT latched here on the
//               board -- it runs straight to the GPC -- so it is captured in
//               `attr_a` at the same edge and moved on with the pixels below
//    h = 8k+6   5C addressed with A0 = /4H = 0  -> byte 0 (pixels 0..3)
//    -> 8k+7    2C/3C LS194A parallel load (S1 = 1H2H), attr_a -> attr_b
//    h = 8k+10  5C addressed with A0 = /4H = 1  -> byte 1 (pixels 4..7)
//    -> 8k+11   second load
//
//  so `anpix` presents pixel p of column k during count 8k+7+p, and
//  `acol`/`aopaque` are valid over exactly the same eight counts.  Two more
//  pipeline stages downstream (GPC, then CRAM + 18L/19L) put that pixel on the
//  DAC during count 8k+9+p, i.e. at hpos = 8k+p — where MAME's alpha tilemap
//  puts it.  The board's VIDCLK / /VIDCLK / /7M edges all collapse onto ce_7m,
//  which is why some latches below sit one count earlier than a naive reading
//  of the sheet would put them.
//
//  ---- the character ROM is an 8 KB part in a 16 KB socket -----------------
//  Sheet 7 draws a U27128 at 5C with A13 wired to code bit 9, but the dumped
//  part 136054-1101.5c is a 2764.  With a 2764 fitted A13 is a don't-care and
//  codes 512..1023 mirror 0..511, which is why
//  this module drops code[9] and why xybots_mem's char port is 13 bits.
//  Measured over every captured frame of the game: an alpha word with a code
//  >= 512 only ever appears in rows 30/31, the off-screen scratch rows, so the
//  mirror is never visible.
//
//  ---- VIRQ ---------------------------------------------------------------
//  6D LS174E pin 3 -> pin 2 is SCRAMD10 of the alpha word, i.e. a per-tile-row
//  programmable scanline interrupt.  It leaves here as the RAW 6D output: the
//  gate with V[2:0]==7 & HBLANK & ~VBLANK and the 1C 74S74 latch are on
//  sheet 2 and live in rtl/main/xybots_irq.sv, which xybots_main_bus feeds
//  from this port.
//  It must NEVER be delayed by the compositor's PIPE_DLY -- it is a board net,
//  not a picture.
//============================================================================

module xybots_alpha (
	input  logic        clk,        // clk_sys 57.272727 MHz
	input  logic        ce_7m,      // VIDCLK enable
	input  logic        reset,      // synchronous, active high

	// ---- SYNGEN counters (SP-313 sheet 4) ----
	input  logic  [8:0] h,          // 1H..256H
	input  logic  [7:0] v,          // 1V..128V

	// ---- video-side SCRAM data bus (the address mux lives in xybots_video) --
	input  logic [15:0] scram_d,

	// ---- 5C character ROM, xybots_mem's `char_*` port (BRAM, latency 1) ----
	output logic [12:0] char_addr,
	input  logic  [7:0] char_data,

	// ---- pixel stream: valid during count h for hpos = h - 7 ----
	output logic  [1:0] anpix,      // 2C QD = ANPIX1, 3C QD = ANPIX0
	output logic  [2:0] acol,       // alpha word bits 14:12
	output logic        aopaque,    // alpha word bit 15

	// ---- board net, undelayed ----
	output logic        virq        // 6D LS174E pin 2 = alpha word bit 10
);

	// =====================================================================
	//  6D / 7D LS174E — clocked by 4H, which rises entering count h ≡ 4.
	//  At the ce_7m edge that ends count h ≡ 3 the SCRAM data bus still
	//  carries the word addressed during that count, so `h[2:0] == 3` is the
	//  right condition on the PRE-edge counter.
	// =====================================================================
	logic [9:0] code;
	logic [3:0] attr_a;             // {D15, D14:12} captured with the code

	always_ff @(posedge clk) begin
		if (reset) begin
			code   <= '0;
			attr_a <= '0;
			virq   <= 1'b0;
		end else if (ce_7m && (h[2:0] == 3'd3)) begin
			code   <= scram_d[9:0];
			virq   <= scram_d[10];
			attr_a <= {scram_d[15], scram_d[14:12]};
		end
	end

	// =====================================================================
	//  5C character ROM address, straight off sheet 7
	//    A13..A4 = code (A13 unconnected on the fitted 2764 -> code[9] dropped)
	//    A3..A1  = 4V, 2V, 1V        A0 = /4H
	// =====================================================================
	assign char_addr = {code[8:0], v[2:0], ~h[2]};

	// code[9] reaches 5C's A13, which is a bare pin on the fitted 2764; the
	// tile column/row bits h[8:3] and v[7:3] address the SCRAM and are consumed
	// by the sheet-5 multiplexer in xybots_video; scram_d[11] is the spare
	// alpha word bit (6D pin 5, no net).
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_alpha = |{code[9], h[8:3], v[7:3], scram_d[11]};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  2C / 3C LS194A — S1 = 1H2H (load), CK = /VIDCLK.
	//  Collapsed onto ce_7m one count earlier than the naive mapping, because
	//  the board's /VIDCLK edge sits half a count before the GPC's 7M edge
	//  that samples it: the load edge is the one
	//  whose PRE-edge counter has h[1:0] == 2, i.e. entering counts h ≡ 3, 7.
	//  QD is the leftmost pixel, so the register shifts LEFT and bit 3 is the
	//  output.
	//
	//  Byte / plane order (MAME's `anlayout`):
	//    char_data[7:4] = ANPIX1 of pixels 0..3   (plane 0 = the MSB pen bit)
	//    char_data[3:0] = ANPIX0 of pixels 0..3
	//  and A0 = /4H already selected pixels 0..3 vs 4..7.
	// =====================================================================
	logic [3:0] sr1, sr0;
	logic [3:0] attr_b;

	always_ff @(posedge clk) begin
		if (reset) begin
			sr1    <= '0;
			sr0    <= '0;
			attr_b <= '0;
		end else if (ce_7m) begin
			if (h[1:0] == 2'b10) begin
				sr1    <= char_data[7:4];
				sr0    <= char_data[3:0];
				attr_b <= attr_a;
			end else begin
				sr1 <= {sr1[2:0], 1'b0};
				sr0 <= {sr0[2:0], 1'b0};
			end
		end
	end

	assign anpix   = {sr1[3], sr0[3]};
	assign acol    = attr_b[2:0];
	assign aopaque = attr_b[3];

endmodule
