// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// 93C56, 128 x 16-bit, 3-wire. Start bit, 2-bit opcode, 8-bit address (MAME
// EEPROM_93C56_16BIT with streaming reads: CS held high keeps shifting out the next word).

module leland_eeprom_93c56
(
	input        clk_sys,
	input        reset,
	input        cs,
	input        clk_in,
	input        di,
	output reg   do_out,

	input        mem_wr,
	input  [6:0] mem_wr_addr,
	input [15:0] mem_wr_data,

	// HPS save port: byte address into the 256-byte big-endian image
	input  [7:0] nv_rd_addr,
	output [7:0] nv_rd_data,
	output reg   nv_dirty,
	input        nv_dirty_clr
);

reg [15:0] mem [0:127];

localparam S_WAIT_START = 0, S_CMD = 1, S_DATA = 2;
reg [1:0]  state;
reg [9:0]  cmd_shift;
reg [3:0]  cmd_bits;
reg [15:0] data_shift;
reg [11:0] data_bits;
reg [1:0]  op;
reg [6:0]  eaddr;
reg        clk_prev;

wire clk_rise = clk_in & ~clk_prev;
wire [6:0]  rd_idx = eaddr + data_bits[10:4];
wire [15:0] rd_word = mem[rd_idx];

wire [15:0] nv_word = mem[nv_rd_addr[7:1]];
assign nv_rd_data   = nv_rd_addr[0] ? nv_word[7:0] : nv_word[15:8];

always @(posedge clk_sys) begin
	clk_prev <= clk_in;

	if (mem_wr) mem[mem_wr_addr] <= mem_wr_data;

	if (nv_dirty_clr) nv_dirty <= 1'b0;

	if (reset || !cs) begin
		state     <= S_WAIT_START;
		cmd_bits  <= 4'd0;
		data_bits <= 12'd0;
		do_out    <= 1'b1;
	end else if (clk_rise) begin
		case (state)
			S_WAIT_START: begin
				if (di) state <= S_CMD;
			end

			S_CMD: begin
				cmd_shift <= {cmd_shift[8:0], di};
				cmd_bits  <= cmd_bits + 4'd1;
				if (cmd_bits == 4'd9) begin
					op        <= cmd_shift[8:7];
					eaddr     <= {cmd_shift[5:0], di};
					state     <= S_DATA;
					data_bits <= 12'd0;
				end
			end

			S_DATA: begin
				if (op == 2'b10) begin
					if (data_bits[3:0] == 4'd0) begin
						do_out     <= rd_word[15];
						data_shift <= rd_word << 1;
					end else begin
						do_out     <= data_shift[15];
						data_shift <= data_shift << 1;
					end
					data_bits <= data_bits + 12'd1;
				end else if (op == 2'b01) begin
					data_shift <= {data_shift[14:0], di};
					data_bits  <= data_bits + 12'd1;
					if (data_bits == 12'd15) begin
						mem[eaddr] <= {data_shift[14:0], di};
						nv_dirty   <= 1'b1;
					end
				end
			end
		endcase
	end
end

endmodule
