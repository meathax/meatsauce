`timescale 1ns/1ps
//============================================================================
//  Xybots — SP-313 sheet 8: the two Atari "LB" line-buffer customs (9K and 8K)
//  and the discrete logic that drives them.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Gauntlet_MiSTer core's LINEBUF.vhd
//  (GPL-3.0-or-later); see NOTICE.md.
//
//  9K carries the priority nibble (DI3..DI0 = MOPRI3..0, DO3..DO0 = LBPRI3..0)
//  and 8K the colour and pixel byte (DI7..DI4 = MOCOL, DI3..DI0 = MOPIX;
//  DO7..DO4 = LBCOL, DO3..DO0 = LBPIX).  Every control pin of the two parts is
//  wired to the same net, so they are modelled as one 12-bit-wide store.
//
//  ---------------------------------------------------------------------------
//  WHAT THE CUSTOM DOES — it is an Atari custom, and a black box
//  ---------------------------------------------------------------------------
//  Pins: A8..A0 = SCRAMD15..SCRAMD7, MDR1/MDL1/MDR0/MDL0 = /MOHR1 /MOHLD1
//  /MOHR0 /MOHLD0, ACLK = 7M, RCLK, DCLK, WE1/WE0 = /LBWR1 //LBWR0,
//  RSEL = 1V, /DIE1 //DIE0, /DOE = GND.
//
//  Four facts fix the behaviour, and each one is forced by the sheet-4 strobe
//  timing rather than assumed:
//
//  1. TWO buffers, ping-ponged by RSEL = 1V.  RSEL picks the buffer that is
//     READ; /DIE0 //DIE1 enable the DATA INPUT of the other one.  /DIE0 is
//     asserted when 1V & 1VD8H and /DIE1 when /1V & /1VD8H, so buffer 0 is
//     written on odd lines and read on even ones.
//  2. EACH BUFFER HAS TWO ADDRESS COUNTERS, one for each side.  MDL_n loads
//     buffer n's WRITE pointer from A8..A0 (the object's X, straight off the
//     video data bus during the word-3 fetch); MDR_n clears buffer n's READ
//     pointer.  That is the only reading under which sheet 4's *crossed*
//     pairing makes sense — /MOHLD1 (even lines) belongs to the buffer being
//     written and /MOHR0 (even lines) to the buffer being read — and it is the
//     only one in which the pointers do not collide.
//  3. READING CLEARS.  There is no BUFCLR pin on the Xybots LB symbol and no
//     other clear anywhere on sheet 8, yet a buffer written on line N and read
//     on line N+1 has to be empty again for line N+2.  Gauntlet's discrete
//     equivalent of the same block does exactly this (LINEBUF.vhd writes 0xFF
//     back at the read address on every read); so does this model.  A location
//     that was never written reads 12'hFFF, which is pen 0 (transparent),
//     colour 0 and priority 15 — i.e. "playfield wins", the correct idle state
//     for the sheet-8 comparator.
//     The clear is issued one pixel behind the read, at the address just read.
//     The read pointer only ever increments, and nothing else touches a buffer
//     while it is being read, so that is exactly equivalent to clearing in the
//     same cycle — and it keeps the store a plain simple-dual-port RAM
//     (one write port, one read port) that Quartus infers into two M10Ks.
//  4. WRITES ARE GATED BY TRANSPARENCY.  8D LS20 NANDs MOPIX3..MOPIX0; with
//     the inverted-sense pixel bus that is low exactly for pen 0, so pen 0 is
//     never written.  The polarity chain that ANDs this with 1VD8H // 1V and
//     DCLK is hard to read off the drawing — taken literally it would enable
//     the write on every line of the wrong parity — but the behaviour it has
//     to implement is unambiguous, and it is the same 1V/1VD8H term that
//     forms /DIE.
//
//  ---------------------------------------------------------------------------
//  THE WRITE WINDOW, AND WHY ONLY 56 ENTRIES CAN BE DRAWN
//  ---------------------------------------------------------------------------
//  1VD8H is 1V delayed eight pixels (4B LS74, CK = 8H), so a buffer's data
//  input is enabled only over h = 8..455 of its line.  Entry n's eight pixels
//  are shifted out over h = 8n+8..8n+15, so entries 0..55 land inside the
//  window and entry 56's column (h = 456..463, i.e. h = 0..7 of the next line)
//  is gated off — which is precisely what stops the previous line's last
//  column from leaking into the buffer that has just been switched to.
//  The shipping ROM agrees: in gameplay the object list is filled downwards
//  and always ENDS at entry 55, with entry 56 parked at X = 480 and every
//  field zero.
//============================================================================

module xybots_mo_linebuf (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_7m,

	// ---- sheet-4 strobes ----
	input  logic        mohld0_n,   // MDL0 — load buffer 0's write pointer
	input  logic        mohld1_n,   // MDL1
	input  logic        mohr0_n,    // MDR0 — clear buffer 0's read pointer
	input  logic        mohr1_n,    // MDR1
	input  logic        v1,         // RSEL: 1 = read buffer 1, write buffer 0
	input  logic        v1d8h,      // 4B LS74 — 1V delayed eight pixels

	// ---- write side ----
	input  logic [8:0]  a_in,       // A8..A0 = SCRAMD15..SCRAMD7 (word 3 X)
	input  logic [3:0]  mopix,      // inverted-sense pen
	input  logic [3:0]  mocol,      // inverted-sense colour
	input  logic [3:0]  mopri,      // inverted-sense priority

	// ---- read side (inverted sense, see the header) ----
	output logic [3:0]  lb_pix,
	output logic [3:0]  lb_col,
	output logic [3:0]  lb_pri,
	output logic [8:0]  mo_hpos     // the screen column these three belong to
);

	localparam logic [11:0] LB_EMPTY = 12'hFFF;

	// =====================================================================
	// 1. /DIE and /LBWR (sheet 8)
	// =====================================================================
	wire die0    =  v1 &  v1d8h;             // 6B LS32 (5 = /1V, 4 = /1VD8H)
	wire die1    = ~v1 & ~v1d8h;             // 6B LS32 (1 =  1V, 2 =  1VD8H)
	wire opaque  = ~(&mopix);                // 8D LS20 — pen 0 is not written
	wire lbwr0   = die0 & opaque;
	wire lbwr1   = die1 & opaque;

	// RSEL = 1V: the buffer being READ.  The other one is the one being
	// written, which is why die0/die1 above are the complements.
	wire rd0     = ~v1;
	wire rd1     =  v1;

	// =====================================================================
	// 2. Address counters — one write, one read, per buffer
	// =====================================================================
	logic [8:0] wa0, wa1, ra0, ra1;

	// The read counters' NEXT state: MDR clears, otherwise it runs while this
	// buffer owns the read side.  /MOHR is a one-count pulse at h = 6, so a
	// read counter is 0 during count 7 and h-7 from there on.
	wire [8:0] ra0_nxt = !mohr0_n ? 9'd0 : (rd0 ? (ra0 + 9'd1) : ra0);
	wire [8:0] ra1_nxt = !mohr1_n ? 9'd0 : (rd1 ? (ra1 + 9'd1) : ra1);

	always_ff @(posedge clk) begin
		if (reset) begin
			wa0 <= '0; wa1 <= '0; ra0 <= '0; ra1 <= '0;
		end else if (ce_7m) begin
			// MDL: load X, else run.  The counters are nine bits, so a column
			// that starts near 511 wraps into the left edge of the screen —
			// which is exactly MAME's `xpos & 0x1ff` followed by the
			// `xpos >= width ? xpos - 512` fold.
			wa0 <= mohld0_n ? (wa0 + 9'd1) : a_in;
			wa1 <= mohld1_n ? (wa1 + 9'd1) : a_in;
			ra0 <= ra0_nxt;
			ra1 <= ra1_nxt;
		end
	end

	// =====================================================================
	// 3. The stores
	// =====================================================================
	// Port A is write-only: either a motion-object pixel (write line) or the
	// deferred clear of the address read one pixel ago (read line).  Port B is
	// read-only.  The two never contend: a buffer is either being written or
	// being read, never both.
	logic [11:0] lb0 [0:511];
	logic [11:0] lb1 [0:511];

	wire [11:0] di = {mopri, mocol, mopix};

	logic [11:0] q0, q1;

	// The read port is addressed with the counter's NEXT state, so the
	// registered BRAM output reproduces the custom's ASYNCHRONOUS read: during
	// count h the output is the location the counter points at during count h.
	// The clear then writes that same location on the very count it is read,
	// which is what the custom does — and because the two ports differ by one
	// address by construction, the RAM never sees a read-during-write.
	wire        we0  = rd0 ? (ra0_nxt != ra0) : lbwr0;
	wire [8:0]  aw0  = rd0 ? ra0      : wa0;
	wire [11:0] dw0  = rd0 ? LB_EMPTY : di;

	wire        we1  = rd1 ? (ra1_nxt != ra1) : lbwr1;
	wire [8:0]  aw1  = rd1 ? ra1      : wa1;
	wire [11:0] dw1  = rd1 ? LB_EMPTY : di;

`ifndef ALTERA_RESERVED_QIS
	initial begin
		for (int i = 0; i < 512; i++) begin
			lb0[i] = LB_EMPTY;
			lb1[i] = LB_EMPTY;
		end
	end
`endif

	always_ff @(posedge clk) begin
		if (ce_7m) begin
			if (we0) lb0[aw0] <= dw0;
			q0 <= lb0[ra0_nxt];
		end
	end

	always_ff @(posedge clk) begin
		if (ce_7m) begin
			if (we1) lb1[aw1] <= dw1;
			q1 <= lb1[ra1_nxt];
		end
	end

	// =====================================================================
	// 4. Output mux — RSEL, exactly as the two customs' DO pins are wired
	// =====================================================================
	// During count h these carry the motion-object pixel for screen column
	// hpos = h - 7, which is what `mo_hpos` reports.
	wire [11:0] dout = rd1 ? q1 : q0;

	assign lb_pri  = dout[11:8];
	assign lb_col  = dout[7:4];
	assign lb_pix  = dout[3:0];
	assign mo_hpos = rd1 ? ra1 : ra0;

endmodule
