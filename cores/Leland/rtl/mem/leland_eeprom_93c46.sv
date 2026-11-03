// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Leland - 93C46 3-wire serial EEPROM (64 x 16-bit)
//
//  Standard Microwire protocol, as in MAME leland.cpp/leland_m.cpp (64 words x 16 bits).
//    Wiring (leland_master_output_w, /MCONT write, port 0x09):
//      bit4 = DI (data in), bit5 = CLK, bit6 = CS
//    Wiring (leland_master_input_r, /GIN3 read): bit0 = DO (data out),
//      via PORT_READ_LINE_DEVICE_MEMBER("eeprom", ...::do_read).
//
//  Command format (shifted in MSB-first while CS=1, sampled on CLK rising
//  edge): START(1) + OPCODE(2) + ADDRESS(6), then 16 data bits for WRITE,
//  or 16 clocks of DO output for READ (MSB first). EWEN/EWDS/ERASE
//  opcodes are accepted but are no-ops (no write-protect model).
//============================================================================

module leland_eeprom_93c46
(
	input        clk_sys,
	input        reset,
	input        cs,      // chip select (MCONT bit6)
	input        clk_in,  // serial clock (MCONT bit5)
	input        di,      // data in (MCONT bit4)
	output reg   do_out,  // data out (GIN3 bit0)

	// Per-game default-content load port: leland_board's boot FSM writes all 64 words here
	// (from the MRA image at leland_board_pkg::ADDR_EEPROM_BASE) before releasing the CPUs.
	input        mem_wr,
	input  [5:0] mem_wr_addr,
	input [15:0] mem_wr_data,

	// Save port (HPS NVRAM upload). nv_rd_addr is a byte address into the 128-byte
	// image, big-endian (even byte = high half of the word), read combinationally.
	// nv_dirty goes high when the game writes a word and stays high until nv_dirty_clr.
	input  [6:0] nv_rd_addr,
	output [7:0] nv_rd_data,
	output reg   nv_dirty,
	input        nv_dirty_clr
);

reg [15:0] mem [0:63];

localparam S_WAIT_START = 0, S_CMD = 1, S_DATA = 2;
reg [1:0]  state;
reg [7:0]  cmd_shift;   // {op[1:0], addr[5:0]} accumulated after the start bit
reg [3:0]  cmd_bits;    // 0..8
reg [15:0] data_shift;
reg [4:0]  data_bits;   // 0..16
reg [1:0]  op;
reg [5:0]  eaddr;
reg        clk_prev;

wire clk_rise = clk_in & ~clk_prev;

wire [15:0] nv_word = mem[nv_rd_addr[6:1]];
assign nv_rd_data   = nv_rd_addr[0] ? nv_word[7:0] : nv_word[15:8];

always @(posedge clk_sys) begin
	clk_prev <= clk_in;

	// Boot-time default-content load. mem[] has a single driver (this block); mem_wr
	// only pulses during boot, before cs/clk_in toggle.
	if (mem_wr) mem[mem_wr_addr] <= mem_wr_data;

	if (nv_dirty_clr) nv_dirty <= 1'b0;

	if (reset || !cs) begin
		state    <= S_WAIT_START;
		cmd_bits <= 4'd0;
		data_bits<= 5'd0;
		do_out   <= 1'b1; // idle/ready high
	end else if (clk_rise) begin
		case (state)
			S_WAIT_START: begin
				if (di) state <= S_CMD; // start bit seen; ignore leading zeros
			end

			S_CMD: begin
				cmd_shift <= {cmd_shift[6:0], di};
				cmd_bits  <= cmd_bits + 4'd1;
				if (cmd_bits == 4'd7) begin
					// This shift completes the 8th bit after start: op[1:0]
					// then addr[5:0], MSB-first -> {cmd_shift[6:0],di}.
					op     <= {cmd_shift[6], cmd_shift[5]};
					eaddr  <= {cmd_shift[4:0], di};
					state  <= S_DATA;
					data_bits <= 5'd0;
				end
			end

			S_DATA: begin
				if (op == 2'b10) begin // READ
					// First data clock: load the word and drive its MSB; later
					// clocks shift. Load and shift must stay exclusive per edge.
					if (data_bits == 5'd0) begin
						do_out     <= mem[eaddr][15];
						data_shift <= mem[eaddr] << 1;
					end else begin
						do_out     <= data_shift[15];
						data_shift <= data_shift << 1;
					end
					data_bits  <= data_bits + 5'd1;
				end else if (op == 2'b01) begin // WRITE
					data_shift <= {data_shift[14:0], di};
					data_bits  <= data_bits + 5'd1;
					if (data_bits == 5'd15) begin
						mem[eaddr] <= {data_shift[14:0], di};
						nv_dirty   <= 1'b1;
					end
				end
				// EWEN/EWDS/ERASE: accepted, no effect.
			end
		endcase
	end
end

endmodule
