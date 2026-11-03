`timescale 1ns/1ps
//============================================================================
//  Xybots — SP-313 sheet 4: master clock tree, SYNGEN custom (11E/F) and the
//  discrete glue that surrounds it.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Gauntlet_MiSTer core's SYNGEN.vhd
//  (GPL-3.0-or-later); see NOTICE.md.
//
//  This module is the whole of sheet 4 except the LS244 switch-input buffers
//  (18F/18J/21E) — i.e. the oscillator/divider chain, the SYNGEN custom itself,
//  and every gate that shapes SYNGEN's outputs into the nets the other eight
//  sheets consume.
//
//  ---------------------------------------------------------------------------
//  WHAT SYNGEN IS, AND WHERE ITS BEHAVIOUR COMES FROM
//  ---------------------------------------------------------------------------
//  11E/F is a 40-pin Atari custom.  SP-313 draws only its pinout, so its
//  internal behaviour is reconstructed from the *same part* as implemented
//  discretely on Atari System 1 (SP-277) and modelled in
//  the Arcade-Gauntlet_MiSTer core's `rtl/gauntlet/SYNGEN.vhd`
//  (d18c7db, GPL-3.0) + its `ROMS.G1/PROM_5E.vhd` (the 256x4 sync PROM
//  136032-102).  That model is:
//
//      * a 9-bit horizontal counter cleared by NXL,
//      * an 82S153 PLA (Atari 136032-103) decoding H into
//        NXL/HSYNC/HBLANK/LMPD/PFHST/BUFCLR/C0/C1/C2,
//        all of them taken through one register (the "7E" 74S174),
//      * an 8-bit vertical counter plus one extra state bit ("3A5"),
//        stepped once per line and decoded by the 256x4 PROM into
//        VRES / VSYNC / 3A5 / VBLANK.
//
//  Every number that model produces for the horizontal axis reproduces the
//  published Xybots raster exactly — 456 counts per line, 336 of them visible —
//  and its vertical axis reproduces 240 visible lines exactly.  The one place
//  it does NOT agree with MAME is the total line count: this model gives
//  **263 lines**, MAME's `set_raw` says 262.  MAME's own comment at that line
//  says those parameters come from published specs rather than from the board,
//  so the derived value is used here.  Frame rate is therefore
//  7 159 090 / (456*263) = 59.696 Hz instead of MAME's 59.923 Hz.
//
//  ---------------------------------------------------------------------------
//  PIN DIRECTIONS ON SP-313 SHEET 4
//  ---------------------------------------------------------------------------
//  INPUTS   30 CK = 7M · 5 TEST = GND · 19 BGND = GND · 40 VCC · 20 GND
//  OUTPUTS  3/2/1/39/38/37/34/32/31 = 256H..1H   ·   6..13 = 128V..1V
//           14 /VBLK · 27 /HSYNC · 15 /VSYNC · 26 HBK = /HBLANK
//           16 VIDB = /BLANK · 25 LMPD = /MOHR · 23 C1 = VRAC1 · 22 C2 = VRAC2
//           4 /CKO · 29 CKO · 33 /2HD1H · 35 /4HD1H · 36 /4HD2H
//  UNCONNECTED STUBS  17 /VRES · 18 VSCK · 21 NXL · 24 C0 · 28 /PFHST
//
//  1V..128V, VRAC1 and VRAC2 (and /HBLANK, /BLANK) have no other driver
//  anywhere in the schematic package, so they are SYNGEN outputs, not inputs.
//  The vertical counter is therefore inside the custom, which is why no 256V
//  net exists and why NXL (pin 21, "next line") is left unconnected.  VSCK
//  (vertical scroll clock) and /PFHST (playfield horizontal start) are the
//  System-1 scrolling hooks: Xybots has no scrolling playfield, so both are
//  bare stubs, as is C0 (Xybots makes its own VRAC0 with 8M 74S32 instead).
//
//  ---------------------------------------------------------------------------
//  CLOCKING
//  ---------------------------------------------------------------------------
//  Everything runs in the single clk_sys (57.272727 MHz) domain off the two
//  enables from xybots_core: ce_14m (clk_sys/4) and ce_7m (clk_sys/8).  SYNGEN
//  is clocked by 7M, so the whole custom advances on ce_7m; only the 14M-rate
//  flip-flops 9B (DCLK) and 1C (RCLK) need the intermediate phases, which are
//  recovered from a local 3-bit phase counter locked to ce_7m.
//
//  Convention: a level named after a PCB net is high during the clk_sys cycles
//  in which that net is high on the board.
//
//  ce_7m marks the LAST clk_sys cycle of each pixel — the counters below sit in
//  `else if (ce_7m)`, so during the cycle in which ce_7m is high `h` still holds
//  the count whose pixel is being produced, and the edge that ends that cycle
//  makes it h+1.  Every marker here is qualified that way (`line_start = ce_7m &
//  (h == 0)`).
//============================================================================

module xybots_syngen (
	input  logic       clk,          // clk_sys, 57.272727 MHz
	input  logic       reset,        // synchronous, active high; see section 4
	input  logic       ce_14m,       // clk_sys/4 — 14.318181 MHz
	input  logic       ce_7m,        // clk_sys/8 —  7.159091 MHz, SYNGEN CK

	// ---- sheet-4 clock tree (levels, not clocks — never use as a clock) ----
	output logic       m14,          // 14M   (8B 74S04 1->2)
	output logic       m14p_n,       // /14MP (8B 74S04 13->12)
	output logic       m7,           // 7M    (7B 74S74 Q)
	output logic       m7_n,         // /7M   (7B 74S74 /Q)
	output logic       dclk,         // DCLK  (9B 74S74 Q)
	output logic       rclk,         // RCLK  (1C 74S74 Q, /PRE = DCLK)
	output logic       vidclk,       // VIDCLK  (11J 74S04 3->4 from /CKO)
	output logic       vidclk_n,     // /VIDCLK (8B  74S04 9->8 from  CKO)

	// ---- SYNGEN counters ----
	output logic [8:0] h,            // 1H..256H, pins 31,32,34,37,38,39,1,2,3
	output logic [7:0] v,            // 1V..128V, pins 13,12,11,10,9,8,7,6
	output logic       v256,         // internal 9th line-state bit ("3A5"); no pin
	output logic [8:0] hpos,         // visible pixel index = h - 9 (MAME hpos)
	output logic       h256,         // 256H tap read by /SYSIN D10

	// ---- blanking and sync ----
	output logic       hblank,       // active high
	output logic       hblank_n,     // pin 26 HBK  = /HBLANK
	output logic       vblank,       // 9F LS04 3->4
	output logic       vblank_n,     // pin 14 /VBLK
	output logic       hsync_n,      // pin 27
	output logic       vsync_n,      // pin 15
	output logic       blank_n,      // pin 16 VIDB = /BLANK

	// ---- horizontal taps and their inverters ----
	output logic       h1_n,         // /1H (8B 11->10)
	output logic       h2_n,         // /2H (8B  3-> 4)
	output logic       h4_n,         // /4H (8B  5-> 6)
	output logic       h1h2,         // 2B LS08 (13,12->11)
	output logic       h1h2h4h_n,    // 10E 74S00 (1,2->3)
	output logic       h_2hd1h,      // 11J 74S04 (9->8)
	output logic       h_2hd1h_n,    // pin 33
	output logic       h_4hd1h,      // 11J 74S04 (11->10)
	output logic       h_4hd1h_n,    // pin 35
	output logic       h_4hd2h,      // 11J 74S04 (1->2)
	output logic       h_4hd2h_n,    // pin 36

	// ---- vertical taps ----
	output logic       v1_n,         // /1V (4A LS04 5->6)
	output logic       v1d8h,        // 4B LS74 Q  (D = 1V, CK = 8H)
	output logic       v1d8h_n,      // 4B LS74 /Q

	// ---- video-RAM access phase (sheet 5 LS253 select) ----
	output logic       vrac0,        // 8M 74S32 (4 = /2HD1H, 5 = 4HD2H -> 6)
	output logic       vrac1,        // SYNGEN C1
	output logic       vrac2,        // SYNGEN C2
	output logic [1:0] vram_phase,   // {SB,SA} = {VRAC1, VRAC0}: 3 CPU 2 AN 1 MO 0 PF

	// ---- motion-object fetch strobes ----
	output logic       mohr_n,       // /MOHR, SYNGEN pin 25 (LMPD)
	output logic       mohld0_n,     // 8C LS32 (12 = /1V,      13 = /1H2H4H -> 11)
	output logic       mohld1_n,     // 8C LS32 ( 9 = /1H2H4H,  10 = 1V      ->  8)
	output logic       mohr0_n,      // 5B LS32 (10 = 1V,        9 = 6B/8    ->  8)
	output logic       mohr1_n,      // 6B LS32 (12 = 6B/8,     13 = /1V     -> 11)

	// ---- interrupt ----
	// Sheet 2: 1B LS02 (11 = VBLANK, 12 = /HBLANK -> 13) then 10A LS20 with
	// 4V,2V,1V then 4A LS04 (9->8).  The IRQ1 latch is set by
	// `virq_gate & VIRQ`, where VIRQ is alpha-RAM bit 10 latched by 6D LS174E
	// on sheet 7; that half comes out of xybots_alpha.
	output logic       virq_gate,

	// ---- line / frame markers (one clk_sys cycle wide, aligned to ce_7m) ----
	output logic       nxl_n,        // SYNGEN pin 21 (unconnected on the PCB)
	output logic       line_start,   // h == 0
	output logic       frame_start,  // h == 0, v == 0, v256 == 0
	output logic       vblank_start  // h == 0, first blanked line (v == 240)
);

	// =====================================================================
	// 1. clk_sys phase, and the 14M / 7M chain (SP-313 sheet 4)
	// =====================================================================
	// ph is the position inside one 7M period: ce_7m is ph == 0 and ce_14m is
	// ph == 0 or 4 (ce_7m is a strict subset of ce_14m, see xybots_core).  Both
	// enables are used to load it, so it re-locks immediately and cannot drift
	// away from the enables it is meant to describe.
	logic [2:0] ph;
	always_ff @(posedge clk) begin
		if      (ce_7m)  ph <= 3'd1;
		else if (ce_14m) ph <= 3'd5;
		else             ph <= ph + 3'd1;
	end

	// 14M is the buffered crystal: high for the first half of each 14M period.
	assign m14    = ~ph[1];
	assign m14p_n = ~m14;

	// 7B 74S74: D = /7M, CK = 14M  ->  divide by two, rising with ce_7m.
	assign m7   = ~ph[2];
	assign m7_n =  ph[2];

	// 9B 74S74: D = /7M, CK = /14MP.  /14MP rises entering ph 2 and ph 6, so
	// DCLK is 7M advanced by a quarter period: high over ph {6,7,0,1}.
	always_ff @(posedge clk) begin
		if (reset)                            dclk <= 1'b1;
		else if ((ph == 3'd1) || (ph == 3'd5)) dclk <= m7_n;
	end

	// 1C 74S74: D = 7M, CK = 14M, /PRE = DCLK (asynchronous), /CLR = PR1 = 1.
	// The preset holds RCLK high whenever DCLK is low, so RCLK is low only over
	// ph {0,1} — a quarter-period active-low pulse once per pixel.
	logic rclk_q;
	always_ff @(posedge clk) begin
		if (reset)                             rclk_q <= 1'b0;
		else if ((ph == 3'd7) || (ph == 3'd3)) rclk_q <= m7;
	end
	assign rclk = dclk ? rclk_q : 1'b1;

	// SYNGEN CKO (pin 29) = CK, /CKO (pin 4) = ~CK; both are re-inverted on the
	// board, so VIDCLK is in phase with 7M and is the 68000 clock (sheet 2).
	assign vidclk   =  m7;
	assign vidclk_n = ~m7;

	// =====================================================================
	// 2. SYNGEN horizontal PLA (Atari 136032-103 / 82S153), sheet-4 black box
	// =====================================================================
	// Terms named as in the reference model's comment block.  All of o11..o19
	// are combinational functions of the CURRENT h; the ones the board uses are
	// then taken through one 7M register, which is why every horizontal edge
	// below sits one count later than its raw decode.
	wire o19 = (h[8:6] == 3'b111)   & (h[2:0] == 3'b110);            // NXL  : h == 454
	wire o18 =  h[0] & ~h[1];                                         // C2
	wire o17 = ( h[0] & ~h[1] & ~h[2]) |
	           (~h[0] &  h[1] & ~h[2]) |
	           ( h[0] & ~h[1] &  h[2]);                               // C1
	wire o15 = ((h[8:3] == 6'd0) &  h[2]) |                           // LMPD : h 2..9
	           ((h[8:2] == 7'd0) &  h[1]) |
	           ((h[8:4] == 5'd0) &  h[3] & ~h[2] & ~h[1]);
	// HBLANK, raw = h 0..7 + 344..351 + 352..383 + 384..455 = 0..7 and 344..455
	wire o14 =  (h[8:3] == 6'd0)        |                             // h   0..  7
	            (h[8:3] == 6'b101011)   |                             // h 344..351
	            (h[8:5] == 4'b1011)     |                             // h 352..383
	            (h[8:7] == 2'b11);                                    // h 384..455
	// HSYNC, raw = h 400..407 + 384..399 + 376..383 = 376..407
	wire o13 =  (h[8:3] == 6'b110010)   |                             // h 400..407
	            (h[8:4] == 5'b11000)    |                             // h 384..399
	            (h[8:3] == 6'b101111);                                // h 376..383

	// o16 (C0), o12 (/PFHST) and o11 (BUFCLR) are deliberately not implemented:
	// pins 24 and 28 are bare stubs on sheet 4 and BUFCLR has no pin at all in
	// the Xybots symbol, so nothing in this game can observe them.

	// =====================================================================
	// 3. SYNGEN vertical PROM (Atari 136032-102, 256 x 4), sheet-4 black box
	// =====================================================================
	// Address = {3A5, 128V&64V, 32V..1V}; the two top counter bits are ANDed,
	// so lines 0..191 all alias onto rows 0x00..0x3F (which are inert) and only
	// v >= 192 and the 3A5 phase reach the decoded rows.  The four data bits
	// are, from the dump: b0 = /VRES, b1 = /VSYNC, b2 = next 3A5, b3 = VBLANK.
	// The four range compares below are exactly that 256-entry table.
	wire [7:0] prom_a = {v256, v[7] & v[6], v[5:0]};

	wire p_vblank  =  (prom_a >= 8'h6F) & (prom_a != 8'hFF);   // rows 6F..FE
	wire p_v256    =  (prom_a >= 8'h7F) & (prom_a != 8'hFF);   // rows 7F..FE
	wire p_vres_n  = ~((prom_a >= 8'h85) & (prom_a <= 8'hFE)); // rows 85..FE
	wire p_vsync_n = ~((prom_a >= 8'h73) & (prom_a <= 8'h76)); // rows 73..76

	// The PROM output is registered every 7M clock in the reference model.  The
	// address only moves at a line boundary, so the only visible consequence is
	// that /VSYNC changes one pixel into the line instead of at h == 0.
	logic p_vblank_q, p_v256_q, p_vres_n_q;
	always_ff @(posedge clk) begin
		if (reset) begin
			p_vblank_q <= 1'b0;
			p_v256_q   <= 1'b0;
			p_vres_n_q <= 1'b1;
			vsync_n    <= 1'b1;
		end else if (ce_7m) begin
			p_vblank_q <= p_vblank;
			p_v256_q   <= p_v256;
			p_vres_n_q <= p_vres_n;
			vsync_n    <= p_vsync_n;
		end
	end

	// =====================================================================
	// 4. The counters and the SYNGEN output register (74S174 "7E" / "7D")
	// =====================================================================
	// There is no reset on the PCB (TEST is grounded, VRES is an output): the
	// counters free-run from power-on.  The reset values below are simply the
	// exact state of the model at (v256, v, h) = (0, 0, 0), so a simulation
	// starts on a real state instead of an invented one.
	always_ff @(posedge clk) begin
		if (reset) begin
			h         <= 9'd0;
			v         <= 8'd0;
			v256      <= 1'b0;
			nxl_n     <= 1'b1;
			vrac1     <= 1'b0;
			vrac2     <= 1'b0;
			mohr_n    <= 1'b1;
			hblank_n  <= 1'b0;   // HBLANK is active at h == 0
			hsync_n   <= 1'b1;
			vblank_n  <= 1'b1;
			h_2hd1h_n <= 1'b0;   // 2HD1H = 2H(h-1) = 1 at h == 0
			h_4hd1h_n <= 1'b0;   // 4HD1H = 4H(h-1) = 1 at h == 0
			h_4hd2h_n <= 1'b0;   // 4HD2H = 4H(h-2) = 1 at h == 0
		end else if (ce_7m) begin
			// 7D: the delayed horizontal taps, all inverted at the pins
			h_2hd1h_n <= ~h[1];
			h_4hd1h_n <= ~h[2];
			h_4hd2h_n <=  h_4hd1h_n;

			// 7E: the registered PLA outputs
			nxl_n     <= ~o19;
			vrac2     <=  o18;
			vrac1     <=  o17;
			mohr_n    <= ~o15;
			hblank_n  <= ~o14;
			hsync_n   <= ~o13;

			// horizontal counter, cleared by the REGISTERED NXL (so the line is
			// 0..455 = 456 counts), and the vertical counter one step per line
			if (!nxl_n) begin
				h        <= 9'd0;
				v        <= p_vres_n_q ? (v + 8'd1) : 8'hFF;
				v256     <= p_v256_q;
				vblank_n <= ~p_vblank_q;
			end else begin
				h <= h + 9'd1;
			end
		end
	end

	// 4B LS74: D = 1V, CK = 8H, /PRE = /CLR = PR1.  8H rises as h steps 7 -> 8,
	// so 1VD8H is 1V delayed by eight pixels.
	// The reset value is 1 because the line before (v256, v) = (0, 0) is
	// (1, 255), whose 1V is 1 — i.e. the true steady-state value at h = 0.
	always_ff @(posedge clk) begin
		if (reset)                                  v1d8h <= 1'b1;
		else if (ce_7m && (h[3:0] == 4'h7))         v1d8h <= v[0];
	end
	assign v1d8h_n = ~v1d8h;

	// =====================================================================
	// 5. Sheet-4 glue around SYNGEN
	// =====================================================================
	assign h256      =  h[8];
	assign hpos      =  h - 9'd9;              // first visible pixel is h == 9

	assign hblank    = ~hblank_n;
	assign vblank    = ~vblank_n;              // 9F LS04 (3->4)
	assign blank_n   =  vblank_n & hblank_n;   // pin 16 VIDB

	assign h1_n      = ~h[0];                  // 8B 74S04
	assign h2_n      = ~h[1];
	assign h4_n      = ~h[2];
	assign h1h2      =  h[0] & h[1];           // 2B LS08
	assign h1h2h4h_n = ~(h1h2 & h[2]);         // 10E 74S00

	assign h_2hd1h   = ~h_2hd1h_n;             // 11J 74S04
	assign h_4hd1h   = ~h_4hd1h_n;
	assign h_4hd2h   = ~h_4hd2h_n;

	assign v1_n      = ~v[0];                  // 4A LS04

	// 8M 74S32: VRAC0 = /2HD1H | 4HD2H.  With SYNGEN's C1 this gives the
	// four-phase video-RAM schedule: 3 CPU, 2 alpha, 1 motion object, 0
	// playfield, repeating every eight counts.
	assign vrac0      = h_2hd1h_n | h_4hd2h;
	assign vram_phase = {vrac1, vrac0};

	// Motion-object fetch strobes.  g3b/g6b are the two unnamed intermediate
	// nets on sheet 4; /MOHR itself comes out of SYNGEN pin 25.
	wire g3b = ~(vrac2 & h_4hd1h);             // 3B LS00 (9,10 -> 8)
	wire g6b =   mohr_n | g3b;                 // 6B LS32 ( 9,10 -> 8)

	assign mohld0_n = v1_n       | h1h2h4h_n;  // 8C LS32 (12,13 -> 11)
	assign mohld1_n = h1h2h4h_n  | v[0];       // 8C LS32 ( 9,10 ->  8)
	assign mohr0_n  = v[0]       | g6b;        // 5B LS32 (10, 9 ->  8)
	assign mohr1_n  = g6b        | v1_n;       // 6B LS32 (12,13 -> 11)

	// Sheet-2 scanline-interrupt gate: ~VBLANK & HBLANK & V[2:0] == 7.
	assign virq_gate = ~vblank & hblank & (v[2:0] == 3'b111);

	// Markers, aligned to the ce_7m cycle they name.
	assign line_start   = ce_7m & (h == 9'd0);
	assign frame_start  = line_start & ~v256 & (v == 8'd0);
	assign vblank_start = line_start & ~v256 & (v == 8'd240);

endmodule
