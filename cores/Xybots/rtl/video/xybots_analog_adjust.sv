// Xybots analog-output alignment stage: the OSD decode, the read-rate
// generator and the blanking glue around rmonic79's `crt_adjust`
// (rtl/video/crt_adjust.sv, vendored from MiSTer-CRT-Adjust).  Written from
// that project's examples/core_side_snippet.v (GPL-3.0, Umberto Parisi) by way
// of the Blasteroids core's glue, re-derived for an 8-clock pixel and for
// feeding arcade_video rather than the VGA_* pins directly.
//
// Copyright (C) 2026 the Xybots MiSTer core authors.
// GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
// The OSD carries three controls plus an On/Off: CRT H-Size, CRT H-Position and
// CRT V-Shift.  H-Position has two possible mechanisms inside `crt_adjust`,
// picked at compile time by `HPOS_MODE`:
//
//   HPOS_CONTENTSHIFT (1)  shifts the CONTENT in the line buffer, HSync native
//   HPOS_SYNCSHIFT    (0)  shifts the HSYNC, content native
//
// Only one of the two may be built, and the whole engine restarts on one line
// reference, `hs_ref_out`.  The read-rate accumulator below must be reset on
// that edge rather than on the raw HSync, or the picture trembles.
//
// ---------------- HPOS_MODE for Xybots: CONTENTSHIFT ------------------------
// Upstream's rule is "CONTENTSHIFT for wide/centred games, SYNCSHIFT for narrow
// side-anchored ones, because CONTENTSHIFT runs the picture out of the buffer
// window on the short-margin side and shows a black block there".  Our numbers
// (xybots_syngen, in ce_pix after its output register):
//
//     line total        456 px
//     active            px 9 .. 344           (336 px)
//     HSync high        px 377 .. 408
//
// The line buffer's write pointer resets on the HSync rise, so in BUFFER
// coordinates the active region is 88 .. 423 of 456: an 88-pixel lead-in and a
// 32-pixel run-out.  The short margin is therefore the RIGHT one.  At H-Size 0
// a line delivers 456 read ticks, so an H-Position above +32 pushes the right
// edge of the picture past the end of the line and those columns are lost
// (they come out as blanking); so does enlarging (H-Size > 0) at H-Position 0,
// because the slower read stretches the 88-pixel lead-in too.  This is the
// same limit the analog_hsize stage this replaces had, since it shifted the
// content the same way, and CONTENTSHIFT is upstream's default, so it is what
// this core builds: no behaviour change for anyone who had the old stage set.
//
// A NEGATIVE H-Position pulls the content earlier and buys that room back --
// the 88-pixel lead-in covers the whole -64 range -- which is why enlarging
// wants a negative H-Position here.  SYNCSHIFT cannot do that: it moves the
// sync and the content together, so it re-centres the picture on the tube but
// never changes what fits in a line.
//
// If a real CRT ever shows a black block at the right edge, HPOS_MODE = 0 here
// is the one-line fallback; nothing else changes.
//
// ---------------- the read rate, and why 64/CLK_PER_PIX ---------------------
// Upstream steps the read period in quarter clocks because its reference core's
// pixel is 16 clk_sys cycles: 64 quarters = one pixel, so one H-Size click is
// 1/64 = 1.56%.  Ours is 8 (ce_7m = clk_sys/8 at 57.27 MHz), and a fixed
// quarter-clock step would make one click 3.1% instead.  The accumulator below
// counts 1/CLK_PER_PIX-th of a clock instead, which keeps the 1.56% step at any
// pixel period:
//
//     period = 64 + hsize      units, where 64 units == CLK_PER_PIX clocks
//     acc   += 64/CLK_PER_PIX  per clock
//
// so hsize spans 48..79 units = 6.00..9.88 clocks per pixel at CLK_PER_PIX = 8.
// ACC_STEP must stay an exact integer -- 64/CLK_PER_PIX with CLK_PER_PIX a
// power of two -- or the OSD step silently drifts away from the menu text.
//
// ---------------- where this sits, and the DE it hands on -------------------
// Between xybots_core and arcade_video, so the mixer, the scandoubler, gamma
// and video_freak all see the adjusted raster and the adjusted pixel enable.
// Nothing here touches the core's own timing: the pixel clock and the native
// sync rates are untouched, so there is no jitter and nothing the game can see.
//
// Upstream's core-side glue also builds a `de_osd` window whose rising edge is
// pinned to the NATIVE active region, so the MiSTer OSD (which centres itself on
// the rise of VGA_DE) does not slide when H-Position moves the picture.  This
// core deliberately does not use it -- see the DE section below for why it does
// not survive this raster.
//
// All three OSD fields are plain two's complement, so the config string just
// lists 0,+1..+max then -min..-1 and the decode is a $signed() -- no bespoke
// mapping to get out of step with the menu text.

module xybots_analog_adjust #(
	parameter int H_TOTAL     = 456,   // ce_pix ticks per line (xybots_syngen: 456)
	parameter int V_TOTAL     = 263,   // lines per frame       (xybots_syngen: 263)
	parameter int CLK_PER_PIX = 8,     // clk_sys cycles per ce_pix (ce_7m = clk_sys/8)
	parameter int HPOS_MODE   = 1,     // 1 = CONTENTSHIFT, 0 = SYNCSHIFT (see above)
	parameter int AW          = 11     // line-buffer address bits (see crt_adjust.sv)
) (
	input  logic       clk,
	input  logic       ce_pix,

	// OSD
	input  logic       osd_on,         // CRT Adjust Off/On; Off is a bit-exact bypass
	input  logic [4:0] osd_hsize,      // CRT H-Size        +15 / -16   two's complement
	input  logic [6:0] osd_hpos,       // CRT H-Position    +63 / -64   two's complement
	input  logic [5:0] osd_vshift,     // CRT V-Shift       +31 / -32   two's complement

	input  logic [7:0] r_in, g_in, b_in,
	input  logic       hs_in, vs_in, hb_in, vb_in,

	output logic [7:0] r_out, g_out, b_out,
	output logic       hs_out, vs_out, hb_out, vb_out,
	output logic       ce_out
);

	localparam [7:0] ACC_STEP = 8'(64 / CLK_PER_PIX);

	// ---------------- OSD decode ----------------
	// Everything is sampled at ce_pix so a mid-frame menu change lands on a
	// pixel boundary rather than anywhere inside one.
	logic              active;
	logic signed [4:0] hsize_s;
	logic signed [8:0] hpos_s;
	logic signed [5:0] vshift_s;

	always_ff @(posedge clk) if (ce_pix) begin
		active   <= osd_on;
		hsize_s  <= $signed(osd_hsize);
		hpos_s   <= 9'($signed(osd_hpos));    // sign-extend 7 -> 9 bits
		vshift_s <= $signed(osd_vshift);
	end

	// ---------------- read-rate generator ----------------
	// The wiring rule: reset the accumulator on the rise of the module's
	// `hs_ref_out`, never on the raw HSync, so the write side, the module's read
	// counter and this read rate all restart on the same edge.
	wire  hs_ref;
	logic hs_ref_d;
	always_ff @(posedge clk) hs_ref_d <= hs_ref;
	wire  hs_ref_rise = hs_ref & ~hs_ref_d;

	wire  [7:0] rd_period = 8'd64 + {{3{hsize_s[4]}}, hsize_s};   // 48..79
	logic [7:0] rd_acc;
	wire        rd_tick = (rd_acc + ACC_STEP) >= rd_period;

	always_ff @(posedge clk) begin
		if      (hs_ref_rise) rd_acc <= 8'd0;
		else if (rd_tick)     rd_acc <= rd_acc + ACC_STEP - rd_period;
		else                  rd_acc <= rd_acc + ACC_STEP;
	end

	// When On the line buffer is always live -- even at H-Size 0, where rd_tick
	// runs at the same average rate as ce_pix but re-phased onto hs_ref.
	wire rd_ce = active ? rd_tick : ce_pix;

	// ---------------- the engine ----------------
	wire [7:0] str_r, str_g, str_b;
	wire       str_hs, str_vs, str_hb, str_vb;

	crt_adjust #(
		.VTOTAL    (V_TOTAL),
		.HTOTAL    (H_TOTAL),
		.HPOS_MODE (HPOS_MODE),
		.AW        (AW),
		.VB_LATE   (0)              // HSync follows the active line: crt_adjust.sv note 4
	) u_crt_adjust (
		.clk        (clk),
		.pxl_cen    (ce_pix),
		.pxl2_cen   (rd_ce),
		.active     (active),
		.hsize      (hsize_s),      // kept for upstream parity; the rate above is H-Size
		.hoffset    (hpos_s),
		.voffset    (vshift_s),
		.r_in       (r_in), .g_in (g_in), .b_in (b_in),
		.hs_in      (hs_in),        // NATIVE sync in -- the module derives hs_ref itself
		.vs_in      (vs_in),
		.hb_in      (hb_in | vb_in),
		.vb_in      (vb_in),        // TRUE vertical blank, not the combined blank
		.r_out      (str_r), .g_out (str_g), .b_out (str_b),
		.hs_out     (str_hs), .vs_out (str_vs),
		.hb_out     (str_hb), .vb_out (str_vb),
		.hs_ref_out (hs_ref)
	);

	// ---------------- the vertical blank handed to arcade_video ------------
	// While On, the picture comes out of the line buffer one line behind the
	// native raster: the bank that closes at line L's HSync rise holds line L
	// (HSync follows the active pixels here), and it is read out during native
	// line L+1.  crt_adjust gates its own `pass_q` with `vb_active`, which with
	// VB_LATE = 0 is vb_in sampled once per line on that same HSync rise --
	// i.e. the blank of the line being READ.
	//
	// `str_vb` is not that signal: it is the native, write-rate blank, one line
	// early against the buffered picture, and arcade_video latches VBlank where
	// HBlank falls (sys/arcade_video.v: `if(HBL & ~HBlank) VBL <= VBlank;`), so
	// handing it `str_vb` would lose the bottom line and open DE over a line of
	// stale buffer below the picture.  `vb_read` below is a bit-exact replica of
	// the module's `vb_active`: ONE flop, sampled on the same hs_ref edge.  It
	// must stay one flop for as long as VB_LATE is 0 -- a second flop is the
	// upstream two-line delay again and the bottom line breaks with it.
	logic hs_ref_q;
	always_ff @(posedge clk) if (ce_pix) hs_ref_q <= hs_ref;
	wire  ref_line_tick = ce_pix & hs_ref & ~hs_ref_q;

	logic vb_read;
	always_ff @(posedge clk) if (ref_line_tick) vb_read <= vb_in;

	// ---------------- what is NOT here: upstream's `de_osd` ----------------
	// Upstream's core-side snippet hands the framework a DE window whose rising
	// edge is anchored to the native active region and whose falling edge
	// follows the stretched one, so the MiSTer OSD -- which centres itself on
	// the rise of VGA_DE -- stays put while H-Position moves the picture.  It is
	// a real improvement and it does not work on this raster.
	//
	// It assumes the stretched active never STARTS before the native one.  Our
	// active region sits 88 pixels into the line buffer (see the HPOS_MODE
	// discussion above), and pulling the content left is exactly what a negative
	// H-Position is for here -- it is the direction that buys back room when
	// H-Size enlarges.  The moment `hoffset` goes negative the content opens
	// before the window does, and everything to the left of the native active
	// start is DE-blanked: the picture loses its left edge, and if the content
	// finishes before the native rise the window opens on nothing and stays open
	// across HSync.  (Measured on the Blasteroids core, whose glue this is.)
	//
	// So DE here simply follows the picture.  The cost is the one upstream set
	// out to remove: the OSD slides with H-Position.  Anyone re-attempting the
	// anchored window has to make its rising edge the EARLIER of the native and
	// the stretched active, and suppress the native rise on a line whose
	// stretched active has already ended -- do not just copy the snippet back in.

	// ---------------- outputs ----------------
	// Off: `crt_adjust` is in its own pure bypass, so everything here is the
	// native stream delayed by the module's two input registers.
	assign r_out  = str_r;
	assign g_out  = str_g;
	assign b_out  = str_b;
	assign hs_out = str_hs;
	assign vs_out = str_vs;
	assign hb_out = str_hb;
	assign vb_out = active ? vb_read : str_vb;
	assign ce_out = rd_ce;

endmodule
