`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// SP-251 sheet 7A: 20 MHz parent, 5 MHz dots, 320x256 total raster.
//
// Counter chain traced on sheet 7A (KNOWN):
//   Y1 20.000 MHz -> 9M LS74 /2 -> 10MHZ -> 10M S112 /2 -> 5MHZ (dot clock)
//   -> 10N S112 /2 -> 1H (2.5 MHz).  One "1H" tick therefore spans 2 dots.
//   10L 74S163 (binary, ET=1H, EP=5MHZ, no load/clear) -> 2H,4H,8H,16H
//   10K 74S160 (DECADE, no load/clear)                 -> 32H,64H,128H,HBLANK
// The decade stage makes the line 160 1H periods = 320 dot clocks = 64.000 us
// (fH 15.625 kHz).  hcount below counts dots, so hcount = 2 * (1H count).
//
// V chain: 10D LS163A + 10E S163, both clocked by HBLANK, free running with
// no clear/load anywhere -> 256 lines/frame, fV = 61.035 Hz (KNOWN topology,
// INFERRED arithmetic). The V chain advances on the rising edge of HBLANK,
// i.e. when the dot counter enters dot 256. That phase matters to the CPU
// scanline interrupt, watchdog 128V edge, and blanking-phase video address.
module irobot_timing #(
	// KNOWN (SP-251 7A): 160 1H periods per line, 2 dots per 1H.
	parameter int H_TOTAL      = 320,
	// KNOWN (SP-251 7A): free-running 8-bit V chain, no clear/load.
	parameter int V_TOTAL      = 256,
	// KNOWN structure (7A: HBLANK = QD of decade 10K), count INFERRED:
	// asserted at 1H count 128 = dot 256, released on the wrap at count 0.
	parameter int HBLANK_START = 256,
	// INFERRED (SP-251 9A LS74 10J pins 1-6 decoded against the 7A counters):
	// D=32H, CK=8H, PRESET=HBLANK holds the FF preset through active video.
	// Preset releases at 1H count 128; the 8H rising edges inside blanking are
	// at counts 136 and 152; 32H (QA of decade 10K) is low for 128..143 and
	// high for 144..159.  So HSYNC asserts at 1H 136 (dot 272) and releases at
	// 1H 152 (dot 304): 16 1H = 6.4 us sync, 3.2 us front and back porch.
	// That is a textbook 15.625 kHz line, which independently corroborates the
	// decade reading of 10K.  Numerically unchanged from the previous guess.
	parameter int HSYNC_START  = 272,
	parameter int HSYNC_END    = 304,
	// KNOWN (Clay Cowgill 136029.131 dump, 82S129 at video 10C): O1 is high
	// for V=0..231 and low for V=232..255; O3 is high for V=236..238.
	// SP-251 sheet 9A connects O1 to LS74 D and /Q to VBLANK, and O3 directly
	// to VSYNC.  The raw PROM remains private evidence; these transition
	// points are the minimized hardware truth table.
	parameter int VSYNC_START  = 236,
	parameter int VSYNC_END    = 239,
	parameter int VBLANK_START = 232
) (
	input  logic       clk_20m,
	output logic       ce_pixel,
	output logic [8:0] hcount,
	output logic [7:0] vcount,
	output logic       hblank,
	output logic       vblank,
	output logic       hsync,
	output logic       vsync,
	output logic       frame_start,
 output logic       display_blank,
 // Bundled-data CDC event: toggles exactly when vcount changes. vcount is
 // held stable for the rest of the line so the CPU domain can synchronize
 // this event and sample a coherent snapshot without bitwise CDC.
 output logic       line_toggle
);
	logic [1:0] div;
	logic vblank_q;
	logic prom_o1, prom_o3;
	// SP-251 7A has no reset, clear or load connection on the raster divider
	// or either counter chain.  FPGA configuration supplies a deterministic
	// power-up value, after which the chain runs continuously across CPU,
	// watchdog, OSD and ROM-download resets just like the independently
	// clocked PCB video section.
	initial begin
		div = 2'd0;
		hcount = 9'd0;
		vcount = 8'd0;
		vblank_q = 1'b0;
		frame_start = 1'b0;
		line_toggle = 1'b0;
	end
	// Plain sequential process is intentional: the configuration-time initial
	// values and this process describe one FPGA register bank, not a PCB reset.
	always @(posedge clk_20m) begin
		frame_start <= 0;
		div <= div + 1'd1;
		if (div == 2'd3) begin
			// The vertical LS163 pair is clocked by the rising HBLANK
			// edge. hcount is still the old value in this clocked block,
			// so 255->256 is that edge.
			if (hcount == 9'(HBLANK_START - 1)) begin
				if (vcount == 8'(V_TOTAL - 1)) begin vcount <= 0; frame_start <= 1; end
				else vcount <= vcount + 1'd1;
				line_toggle <= ~line_toggle;
			end
			// 10C O1 is sampled by the LS74 on the rising HSYNC phase.
			// VBLANK is the flip-flop's /Q output, hence the inversion.
			if (hcount == 9'(HSYNC_START - 1)) vblank_q <= ~prom_o1;
			if (hcount == 9'(H_TOTAL - 1)) hcount <= 0;
			else hcount <= hcount + 1'd1;
		end
	end
	assign ce_pixel = (div == 2'd3);
	assign hblank = hcount >= 9'(HBLANK_START);
	assign prom_o1 = vcount < 8'(VBLANK_START);
	assign prom_o3 = (vcount >= 8'(VSYNC_START)) && (vcount < 8'(VSYNC_END));
	assign vblank = vblank_q;
	// The board has one VBLANK net; the prior MAME-status/display split was a
	// workaround made before the 10C dump was available.
	assign display_blank = vblank_q;
	assign hsync = (hcount >= 9'(HSYNC_START)) && (hcount < 9'(HSYNC_END));
	assign vsync = prom_o3;
endmodule
