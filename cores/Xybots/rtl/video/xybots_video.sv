`timescale 1ns/1ps
//============================================================================
//  Xybots video top — SYNGEN + the sheet-5 VRAM address multiplexer + the
//  sheet-7 alphanumerics and playfield layers + the sheet-8 priority network
//  and GPC + the sheet-9 colour RAM and DACs.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  ---- what this module does NOT contain ----------------------------------
//  The motion-object engine (rtl/video/xybots_mo*.sv) is a separate module,
//  instantiated alongside this one by xybots_core.  It consumes `scram_d` and
//  the SYNGEN taps exported below, drives its own xybots_mem sprite client,
//  and hands back the three line-buffer nibbles on `lb_pix/lb_col/lb_pri`.
//  The contract is: inverted sense, 4'hF where no object covers the pixel, and
//  "during count h the nibbles carry hpos = h - 7".  Tie all three to 4'hF and
//  there is simply no motion-object layer.
//
//  ---- pipeline ------------------------------------------------------------
//  The three layers present, during SYNGEN count h, the pixel for
//  hpos = h - 7; the compositor adds two ce_7m stages (the GPC input register,
//  then the colour RAM plus 18L/19L), so the DAC shows hpos = h - 9.  That is
//  exactly where the board puts it and exactly where MAME puts tile column k:
//  at x = 8k.
//
//  PIPE_DLY = 8 counts is the one deviation, forced by SDRAM latency: the
//  playfield prefetches one tile ahead, so the alphanumerics, the motion-object
//  nibbles AND the blanking/sync are delayed by the same eight counts on their
//  way out.  Every VRAM fetch keeps its drawn phase and its drawn address, and
//  the picture leaves the core with its own sync, so nothing observable moves.
//============================================================================

module xybots_video #(
	parameter bit DAC_MAME_COMPAT = 1'b0,   // 1 = MAME's IRGB_4444 transfer
	parameter int MO_PIPE_ADJ     = 0       // extra ce_7m delay on lb_* if the MO
	                                        // engine cannot hit hpos = h - 7
)(
	input  logic        clk,           // clk_sys 57.272727 MHz
	input  logic        ce_7m,
	input  logic        ce_14m,
	input  logic        reset,

	// ================= video RAM (xybots_main_bus video port) =================
	output logic [12:0] vram_vaddr,
	input  logic [15:0] vram_vdata,

	// ================= colour RAM (xybots_main_bus video port) ===============
	output logic  [9:0] cram_vaddr,
	input  logic [15:0] cram_vdata,

	// ================= 5C character ROM (xybots_mem) =========================
	output logic [12:0] char_addr,
	input  logic  [7:0] char_data,

	// ================= playfield tile client (xybots_mem) ====================
	output logic        pf_req,
	output logic [17:2] pf_addr,
	input  logic        pf_valid,
	input  logic [31:0] pf_data,

	// ================= motion objects (xybots_mo, inverted sense) ===========
	input  logic  [3:0] lb_pix,
	input  logic  [3:0] lb_col,
	input  logic  [3:0] lb_pri,

	// the shared video-side SCRAM data bus, for the MO engine's word latches
	output logic [15:0] scram_d,

	// ================= debug layer switches (1 = layer on) ==================
	// Hardwired to 3'b111 by xybots_core; there is no OSD option for them.
	input  logic  [2:0] dbg_layer_en,  // [0] alpha  [1] playfield  [2] motion obj

	// ================= board nets the CPU side needs =========================
	output logic        virq,          // 6D LS174E: raw alpha bit 10, UNDELAYED
	output logic  [1:0] vrac,          // {VRAC1, VRAC0} -- the VRAM phase
	output logic        vrac2,
	output logic  [8:0] h,
	output logic  [7:0] v,
	output logic        h256,
	output logic        hblank,        // undelayed board nets
	output logic        vblank,
	output logic        virq_gate,

	// ================= SYNGEN taps the MO engine consumes ====================
	output logic        h_2hd1h,
	output logic        h_2hd1h_n,
	output logic        h_4hd1h,
	output logic        h_4hd1h_n,
	output logic        h_4hd2h,
	output logic        h_4hd2h_n,
	output logic        h1_n,
	output logic        h2_n,
	output logic        h4_n,
	output logic        v1_n,
	output logic        v1d8h,
	output logic        v1d8h_n,
	output logic        mohr_n,
	output logic        mohld0_n,
	output logic        mohld1_n,
	output logic        mohr0_n,
	output logic        mohr1_n,
	output logic        dclk,
	output logic        rclk,

	// ================= video output (delayed by PIPE_DLY, all together) ======
	output logic  [7:0] red,
	output logic  [7:0] green,
	output logic  [7:0] blue,
	output logic        hsync,         // active high, for the MiSTer scaler
	output logic        vsync,
	output logic        hblank_out,
	output logic        vblank_out,
	output logic        ce_pix,

	// ================= diagnostics ==========================================
	output logic        pf_late,       // a tile-row fetch missed its deadline
	output logic  [8:0] hpos_out       // hpos of the pixel currently on red/green/blue
);

	localparam int PIPE_DLY = 8;       // the playfield's one-tile prefetch
	localparam int LB_DLY   = PIPE_DLY + MO_PIPE_ADJ;

	// =====================================================================
	//  SYNGEN 11E/F and the sheet-4 glue
	// =====================================================================
	logic       v256, hblank_n, vblank_n, hsync_n, vsync_n, blank_n;
	logic [8:0] hpos;
	logic       m14, m14p_n, m7, m7_n, vidclk, vidclk_n;
	logic       h1h2, h1h2h4h_n;
	logic       vrac0, vrac1;
	logic       nxl_n, line_start, frame_start, vblank_start;

	xybots_syngen u_syngen (
		.clk(clk), .reset(reset), .ce_14m(ce_14m), .ce_7m(ce_7m),
		.m14(m14), .m14p_n(m14p_n), .m7(m7), .m7_n(m7_n),
		.dclk(dclk), .rclk(rclk), .vidclk(vidclk), .vidclk_n(vidclk_n),
		.h(h), .v(v), .v256(v256), .hpos(hpos), .h256(h256),
		.hblank(hblank), .hblank_n(hblank_n), .vblank(vblank), .vblank_n(vblank_n),
		.hsync_n(hsync_n), .vsync_n(vsync_n), .blank_n(blank_n),
		.h1_n(h1_n), .h2_n(h2_n), .h4_n(h4_n), .h1h2(h1h2), .h1h2h4h_n(h1h2h4h_n),
		.h_2hd1h(h_2hd1h), .h_2hd1h_n(h_2hd1h_n),
		.h_4hd1h(h_4hd1h), .h_4hd1h_n(h_4hd1h_n),
		.h_4hd2h(h_4hd2h), .h_4hd2h_n(h_4hd2h_n),
		.v1_n(v1_n), .v1d8h(v1d8h), .v1d8h_n(v1d8h_n),
		.vrac0(vrac0), .vrac1(vrac1), .vrac2(vrac2), .vram_phase(vrac),
		.mohr_n(mohr_n), .mohld0_n(mohld0_n), .mohld1_n(mohld1_n),
		.mohr0_n(mohr0_n), .mohr1_n(mohr1_n),
		.virq_gate(virq_gate),
		.nxl_n(nxl_n), .line_start(line_start),
		.frame_start(frame_start), .vblank_start(vblank_start));

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_syngen = |{v256, hpos, m14, m14p_n, m7, m7_n, vidclk, vidclk_n,
	                       h1h2, h1h2h4h_n, vrac0, vrac1, hblank_n, vblank_n,
	                       nxl_n, line_start, frame_start, vblank_start};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  Sheet-5 LS253 address multiplexer.
	//  One bank, shared by all four phases; the CPU's own port is elsewhere,
	//  so phase 3 simply repeats the motion-object address.
	// =====================================================================
	wire [12:0] addr_alpha = {2'b00, v[7:3], h[8:3]};
	wire [12:0] addr_pf    = {2'b11, v[7:3], h[8:3]};
	wire [12:0] addr_mo    = {5'b10111, h[8:3], h_2hd1h, h[2]};

	always_comb begin
		case (vrac)
			2'd0: vram_vaddr = addr_pf;
			2'd2: vram_vaddr = addr_alpha;
			default: vram_vaddr = addr_mo;   // phase 1 (MO) and phase 3 (CPU)
		endcase
	end

	assign scram_d = vram_vdata;

	// =====================================================================
	//  Layers
	// =====================================================================
	logic [1:0] anpix;
	logic [2:0] acol;
	logic       aopaque;

	xybots_alpha u_alpha (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.h(h), .v(v), .scram_d(scram_d),
		.char_addr(char_addr), .char_data(char_data),
		.anpix(anpix), .acol(acol), .aopaque(aopaque), .virq(virq));

	logic [3:0] pfpix, pfcol;

	xybots_pf u_pf (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.h(h), .v(v), .scram_d(scram_d),
		.pf_req(pf_req), .pf_addr(pf_addr), .pf_valid(pf_valid), .pf_data(pf_data),
		.pfpix(pfpix), .pfcol(pfcol), .late(pf_late));

	// =====================================================================
	//  PIPE_DLY — the alphanumerics, the MO nibbles and the whole raster are
	//  delayed to meet the playfield's one-tile SDRAM prefetch.
	// =====================================================================
	logic [5:0]  a_sr  [PIPE_DLY];     // {aopaque, acol, anpix}
	logic [11:0] lb_sr [LB_DLY];       // {lb_pri, lb_col, lb_pix}
	logic [4:0]  r_sr  [PIPE_DLY];     // {blank_n, hblank, vblank, hsync_n, vsync_n}

	always_ff @(posedge clk) begin
		if (reset) begin
			for (int i = 0; i < PIPE_DLY; i++) begin
				a_sr[i] <= '0;
				r_sr[i] <= 5'b0_0_0_11;
			end
			for (int i = 0; i < LB_DLY; i++) lb_sr[i] <= {12{1'b1}};
		end else if (ce_7m) begin
			a_sr[0]  <= {aopaque, acol, anpix};
			r_sr[0]  <= {blank_n, hblank, vblank, hsync_n, vsync_n};
			lb_sr[0] <= {lb_pri, lb_col, lb_pix};
			for (int i = 1; i < PIPE_DLY; i++) begin
				a_sr[i] <= a_sr[i-1];
				r_sr[i] <= r_sr[i-1];
			end
			for (int i = 1; i < LB_DLY; i++) lb_sr[i] <= lb_sr[i-1];
		end
	end

	wire [5:0]  a_d  = a_sr[PIPE_DLY-1];
	wire [11:0] lb_d = lb_sr[LB_DLY-1];
	wire [4:0]  r_d  = r_sr[PIPE_DLY-1];

	// Debug layer switches, applied where the layers meet.  `acol_c` is
	// deliberately ungated: with the pen forced to 0 and the opaque bit
	// cleared, the alpha colour cannot reach the colour-RAM address anyway.
	wire [1:0] anpix_c   = dbg_layer_en[0] ? a_d[1:0] : 2'b00;
	wire [2:0] acol_c    = a_d[4:2];
	wire       aopaque_c = dbg_layer_en[0] ? a_d[5]   : 1'b0;
	wire [3:0] pfpix_c   = dbg_layer_en[1] ? pfpix    : 4'h0;
	wire [3:0] pfcol_c   = dbg_layer_en[1] ? pfcol    : 4'h0;
	wire [3:0] lbpix_c   = dbg_layer_en[2] ? lb_d[3:0]   : 4'hF;
	wire [3:0] lbcol_c   = dbg_layer_en[2] ? lb_d[7:4]   : 4'hF;
	wire [3:0] lbpri_c   = dbg_layer_en[2] ? lb_d[11:8]  : 4'hF;

	// =====================================================================
	//  Compositor stage 1 — the GPC's 7M input register (sheet 8).  Every
	//  layer is sampled on the same edge, which is what puts them all on the
	//  same pixel.
	// =====================================================================
	logic [1:0] s1_anpix;
	logic [2:0] s1_acol;
	logic       s1_aopaque;
	logic [3:0] s1_pfpix, s1_pfcol, s1_lbpix, s1_lbcol, s1_lbpri;

	always_ff @(posedge clk) begin
		if (reset) begin
			s1_anpix <= '0; s1_acol <= '0; s1_aopaque <= 1'b0;
			s1_pfpix <= '0; s1_pfcol <= '0;
			s1_lbpix <= 4'hF; s1_lbcol <= 4'hF; s1_lbpri <= 4'hF;
		end else if (ce_7m) begin
			s1_anpix   <= anpix_c;
			s1_acol    <= acol_c;
			s1_aopaque <= aopaque_c;
			s1_pfpix   <= pfpix_c;
			s1_pfcol   <= pfcol_c;
			s1_lbpix   <= lbpix_c;
			s1_lbcol   <= lbcol_c;
			s1_lbpri   <= lbpri_c;
		end
	end

	logic       prien, pf_mo;
	logic [7:0] p_bus, m_bus;

	xybots_prio u_prio (
		.pfpix(s1_pfpix), .pfcol(s1_pfcol),
		.lb_pix(s1_lbpix), .lb_col(s1_lbcol), .lb_pri(s1_lbpri),
		.prien(prien), .pf_mo(pf_mo), .p_bus(p_bus), .m_bus(m_bus));

	logic [9:0] cram_a;

	xybots_gpc u_gpc (
		.anpix(s1_anpix), .acol(s1_acol), .aopaque(s1_aopaque),
		.prien(prien), .pf_mo(pf_mo), .p_bus(p_bus), .m_bus(m_bus),
		.cram_a(cram_a));

	// =====================================================================
	//  Compositor stage 2 — colour RAM + 18L/19L.
	//
	//  The raster does NOT go through the two compositor stages: the board's
	//  /BLANK is not pipelined at all (it is wired into the ZREF generator),
	//  and the board's two stages are exactly what makes the DAC show
	//  hpos = h - 9 against an un-delayed HBLANK.  Here everything is pushed
	//  out by PIPE_DLY and nothing else, so `r_d` -- blank/sync delayed by
	//  PIPE_DLY and by nothing more -- is what the outputs and the DAC use.
	// =====================================================================
	logic [3:0] z4, r4, g4, b4;

	xybots_cram u_cram (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.cram_a(cram_a), .cram_vaddr(cram_vaddr), .cram_vdata(cram_vdata),
		.z(z4), .r(r4), .g(g4), .b(b4));

	xybots_dac #(.DAC_MAME_COMPAT(DAC_MAME_COMPAT)) u_dac (
		.z(z4), .r4(r4), .g4(g4), .b4(b4), .blank_n(r_d[4]),
		.red(red), .green(green), .blue(blue));

	assign hblank_out = r_d[3];
	assign vblank_out = r_d[2];
	assign hsync      = ~r_d[1];
	assign vsync      = ~r_d[0];
	assign ce_pix     = ce_7m;

	// hpos of the pixel on red/green/blue right now: the board's hpos = h - 9,
	// pushed out by PIPE_DLY.
	assign hpos_out = h - 9'd9 - 9'(PIPE_DLY);

endmodule
