`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Two 7-bit ICY framebuffers (SP-251 7B, 4164 banks).  Each bank is split into
// WAYS equal contiguous slices so the buffer clear can zero WAYS words per
// cycle.  Ordinary draw and display accesses still touch exactly one slice,
// selected by the top address bits, so the slicing costs nothing at draw time.
//
// The width matters because the game does not treat the clear as free-running:
// measured over the attract sequence, every STATWR that raises the clear bit is
// followed by the STATWR that starts the vector generator 6,750 CPU-clock
// cycles later, and the board holds the generator off until the clear is done
// (irobot_board.sv clear_active).  A one-word-per-cycle sweep of the 65,536
// word bank needs ten times that budget, so the generator used to start about
// 5.4 ms late -- a third of a frame -- by which time the 6809 had already
// replaced the display list it was meant to draw, and the whole polygon layer
// came out empty.  WAYS=16 finishes the sweep in 4,096 cycles, inside the
// budget the game allows.
module irobot_framebuffers #(
	parameter integer ADDR_WIDTH = 16,
	parameter integer WAY_BITS   = 4
) (
	input  logic draw_clk,
	input  logic display_clk,
	input  logic reset,
	input  logic draw_we,
	input  logic [ADDR_WIDTH-1:0] draw_addr,
	input  logic [6:0] draw_data,
	input  logic [ADDR_WIDTH-1:0] display_addr,
	input  logic swap,
	input  logic clear_start,
	output logic [6:0] display_data,
	output logic draw_bank,
	output logic display_bank,
	output logic clear_busy,
	output logic clear_done,
	output logic draw_ready
);
	localparam integer WAYS = 1 << WAY_BITS;
	localparam integer SUB_WIDTH = ADDR_WIDTH - WAY_BITS;
	localparam integer SUB_DEPTH = 1 << SUB_WIDTH;

	logic draw_bank_meta, draw_bank_display;
	logic [SUB_WIDTH-1:0] clear_addr;
	logic clear_bank, init_clear, initialized;
	logic effective_we, effective_bank;
	logic [ADDR_WIDTH-1:0] effective_addr;
	logic [6:0] effective_data;
	logic [SUB_WIDTH-1:0] write_addr;
	logic [WAY_BITS-1:0] write_way, display_way;
	logic [6:0] bank0_way_q [0:WAYS-1];
	logic [6:0] bank1_way_q [0:WAYS-1];
	// Kept as scalars under their original names: these are the words the
	// display stage actually selects, and the differential harness samples them.
	logic [6:0] bank0_q /* verilator public_flat_rd */;
	logic [6:0] bank1_q /* verilator public_flat_rd */;
	logic [WAY_BITS-1:0] display_way_q;

	assign display_bank = ~draw_bank_display;
	assign draw_ready = initialized && ~clear_busy;
	assign effective_we = clear_busy | (draw_we & draw_ready);
	assign effective_bank = clear_busy ? clear_bank : draw_bank;
	assign effective_addr = clear_busy ? {{WAY_BITS{1'b0}}, clear_addr} : draw_addr;
	assign effective_data = clear_busy ? 7'd0 : draw_data;
	// During a clear every slice takes the same sub-address; otherwise the
	// address selects one slice and supplies its offset.
	assign write_addr = effective_addr[SUB_WIDTH-1:0];
	assign write_way = effective_addr[ADDR_WIDTH-1:SUB_WIDTH];
	assign display_way = display_addr[ADDR_WIDTH-1:SUB_WIDTH];
	assign bank0_q = bank0_way_q[display_way_q];
	assign bank1_q = bank1_way_q[display_way_q];
	assign display_data = initialized ? (display_bank ? bank1_q : bank0_q) : 7'd0;

	genvar w;
	generate
		for (w = 0; w < WAYS; w = w + 1) begin : slice
			(* ramstyle = "M10K, no_rw_check" *) logic [6:0] bank0 [0:SUB_DEPTH-1];
			(* ramstyle = "M10K, no_rw_check" *) logic [6:0] bank1 [0:SUB_DEPTH-1];
			wire selected = clear_busy || (write_way == WAY_BITS'(w));
			always_ff @(posedge draw_clk) begin
				if (effective_we && selected && !effective_bank) bank0[write_addr] <= effective_data;
			end
			always_ff @(posedge draw_clk) begin
				if (effective_we && selected && effective_bank) bank1[write_addr] <= effective_data;
			end
			always_ff @(posedge display_clk) begin
				bank0_way_q[w] <= bank0[display_addr[SUB_WIDTH-1:0]];
				bank1_way_q[w] <= bank1[display_addr[SUB_WIDTH-1:0]];
			end
		end
	endgenerate

	always_ff @(posedge display_clk) begin
		display_way_q <= display_way;
		if (reset) begin draw_bank_meta <= 1'b0; draw_bank_display <= 1'b0; end
		else begin draw_bank_meta <= draw_bank; draw_bank_display <= draw_bank_meta; end
	end

	always_ff @(posedge draw_clk) begin
		clear_done <= 1'b0;
		if (reset) begin
			draw_bank  <= 1'b0;
			clear_busy <= 1'b0;
			clear_addr <= '0;
			clear_bank <= 1'b1;
			init_clear <= 1'b1;
			initialized <= 1'b0;
		end else begin
			if (!initialized && !clear_busy) begin
				// The visible bank must be known black before the first raster.
				// This models the board's reset/video-start clear without relying
				// on FPGA RAM power-up contents.
				clear_busy <= 1'b1;
				clear_bank <= ~draw_bank;
				clear_addr <= '0;
			end else if (clear_busy) begin
				if (&clear_addr) begin
					if (init_clear) begin
						if (clear_bank) begin
							// MAME clears both polygon bitmaps before the first frame.
							clear_bank <= 1'b0;
							clear_addr <= '0;
						end else begin
							clear_busy <= 1'b0;
							init_clear <= 1'b0;
							initialized <= 1'b1;
							clear_done <= 1'b1;
						end
					end else begin
						clear_busy <= 1'b0;
						clear_done <= 1'b1;
					end
				end else begin
					clear_addr <= clear_addr + 1'b1;
				end
			end else if (swap || clear_start) begin
				// STATWR can set bufsel (swap) and the clear bit (clear_start)
				// in the same write, matching MAME's statwr_w, which sets
				// m_bufsel first and then clears polybitmap[m_bufsel] (the
				// NEW bank). Apply both in one cycle here: the swap branch no
				// longer shadows clear_start, and the clear targets the
				// post-swap bank (~draw_bank when swap fires this cycle)
				// rather than the bank draw_bank held before the swap.
				if (swap) draw_bank <= ~draw_bank;
				if (clear_start) begin
					clear_busy <= 1'b1;
					clear_bank <= swap ? ~draw_bank : draw_bank;
					clear_addr <= '0;
				end
			end
		end
	end
endmodule
