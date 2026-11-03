`timescale 1ns/1ps
//============================================================================
//  Xybots — the motion-object engine: SP-313 sheets 5, 6 and 8 tied together.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//      xybots_mo_fetch    sheets 5 + 6 — the table walk, the object word
//                         latches, the vertical match (xybots_mo_vmatch),
//                         the sprite-ROM client and the pixel path
//      xybots_mo_linebuf  sheet 8 — the two LB customs (9K, 8K) as ping-pong
//                         line buffers with their write gating and their
//                         clear-on-read
//
//  ---------------------------------------------------------------------------
//  WHAT COMES OUT, AND WHEN
//  ---------------------------------------------------------------------------
//  `lb_pix`, `lb_col`, `lb_pri` are the LB customs' DO pins, in the INVERTED
//  sense the parts carry: LBPIX = ~pen, LBCOL = ~colour, LBPRI = ~priority,
//  and an untouched location reads 4'hF on all three.  That is the sense the
//  sheet-8 mixing logic expects — 9C LS10's PRIEN is ~(LBPIX3 & LBPIX2 &
//  LBPIX1), 12J's A input is LBPRI, and 11K's A input is LBCOL — so nothing
//  here re-inverts anything.
//
//  TIMING: during count h the three nibbles carry the motion-object pixel for
//  screen column `hpos = h - 7`, which is the phase xybots_video's compositor
//  expects, so its `MO_PIPE_ADJ` is 0.  The read pointer is cleared by /MOHR at
//  h = 6 and runs one address per pixel from there, and the store is addressed
//  with the pointer's next state so the registered BRAM output lands on the
//  same count the custom's asynchronous DO pins would.  `mo_hpos` reports that
//  column on every count, so a compositor that re-times the other layers can
//  check the phase rather than assume it.
//
//  ---------------------------------------------------------------------------
//  THE VRAM VIDEO PORT
//  ---------------------------------------------------------------------------
//  `xybots_video` owns the sheet-5 LS253 address bank and hands this module
//  the shared read data as `scram_d`: the word addressed during a count is on
//  `scram_d` at that count's `ce_7m`, which is exactly when the sheet's
//  LS273/LS174 latches take it.  `vram_vaddr` is this module's own copy of the
//  motion-object phase address — identical to the row `xybots_video` drives
//  for `vram_phase == 1`.  It lets the engine be driven standalone, and in the
//  core xybots_core connects it for observation only; nothing reads it.
//============================================================================

module xybots_mo (
	input  logic        clk,          // clk_sys, 57.272727 MHz
	input  logic        reset,        // synchronous, active high
	input  logic        ce_7m,        // the LAST clk_sys cycle of each pixel

	// ---- SYNGEN (sheet 4) ----
	input  logic [8:0]  h,
	input  logic [7:0]  v,
	input  logic        vblank,
	input  logic        h_2hd1h,
	input  logic        h_4hd2h_n,
	input  logic        v1d8h,
	input  logic        mohld0_n,
	input  logic        mohld1_n,
	input  logic        mohr0_n,
	input  logic        mohr1_n,

	// ---- video-side VRAM read port ----
	output logic [12:0] vram_vaddr,   // observation only; xybots_video owns it
	input  logic [15:0] scram_d,      // the shared video-side VRAM read data

	// ---- sprite ROM client (xybots_gfx_mem) ----
	output logic        mo_req,
	output logic [18:2] mo_addr,
	input  logic        mo_valid,
	input  logic [31:0] mo_data,

	// ---- to the sheet-8 mixer ----
	output logic [3:0]  lb_pix,
	output logic [3:0]  lb_col,
	output logic [3:0]  lb_pri,
	output logic [8:0]  mo_hpos,

	// ---- status ----
	output logic        fetch_late
);

	logic [3:0] mopix, mocol, mopri;

	xybots_mo_fetch u_fetch (
		.clk        (clk),
		.reset      (reset),
		.ce_7m      (ce_7m),
		.h          (h),
		.v          (v),
		.vblank     (vblank),
		.h_2hd1h    (h_2hd1h),
		.h_4hd2h_n  (h_4hd2h_n),
		.vram_vaddr (vram_vaddr),
		.scram_d    (scram_d),
		.mo_req     (mo_req),
		.mo_addr    (mo_addr),
		.mo_valid   (mo_valid),
		.mo_data    (mo_data),
		.mopix      (mopix),
		.mocol      (mocol),
		.mopri      (mopri),
		.fetch_late (fetch_late)
	);

	// The LB customs take their address inputs A8..A0 straight off SCRAMD15..7
	// (sheet 8): the object's X is loaded by /MOHLD during the word-3 fetch,
	// from the video data bus, not from a latch.
	xybots_mo_linebuf u_lb (
		.clk       (clk),
		.reset     (reset),
		.ce_7m     (ce_7m),
		.mohld0_n  (mohld0_n),
		.mohld1_n  (mohld1_n),
		.mohr0_n   (mohr0_n),
		.mohr1_n   (mohr1_n),
		.v1        (v[0]),
		.v1d8h     (v1d8h),
		.a_in      (scram_d[15:7]),
		.mopix     (mopix),
		.mocol     (mocol),
		.mopri     (mopri),
		.lb_pix    (lb_pix),
		.lb_col    (lb_col),
		.lb_pri    (lb_pri),
		.mo_hpos   (mo_hpos)
	);

endmodule
