// Mixed-clock, dual-port 16-bit RAM with 68000 byte enables.
// SPDX-License-Identifier: GPL-3.0-or-later

module gd_word_ram
#(
	parameter integer ADDR_WIDTH = 15,
	parameter integer NUM_WORDS = (1 << ADDR_WIDTH)
)
(
	input  logic                  clk,
	input  logic [ADDR_WIDTH-1:0] address,
	input  logic [15:0]           data,
	input  logic [1:0]            byte_enable,
	input  logic                  write,
	output logic [15:0]           q,
	input  logic                  video_clk,
	input  logic [ADDR_WIDTH-1:0] video_address,
	output logic [15:0]           video_q
);

`ifdef SYNTHESIS
// Quartus 17 can expand the generic mixed-clock array into individual logic
// before recognizing it as RAM, consuming tens of gigabytes during Analysis &
// Synthesis. Pin the implementation to Cyclone V M10Ks for hardware builds.
altsyncram #(
	.operation_mode("BIDIR_DUAL_PORT"),
	.width_a(16),
	.widthad_a(ADDR_WIDTH),
	.numwords_a(NUM_WORDS),
	.width_b(16),
	.widthad_b(ADDR_WIDTH),
	.numwords_b(NUM_WORDS),
	.width_byteena_a(2),
	.width_byteena_b(2),
	.address_reg_b("CLOCK1"),
	.outdata_reg_a("UNREGISTERED"),
	.outdata_reg_b("UNREGISTERED"),
	.power_up_uninitialized("FALSE"),
	.read_during_write_mode_mixed_ports("OLD_DATA"),
	.intended_device_family("Cyclone V"),
	.ram_block_type("M10K")
) ram (
	.clock0(clk),
	.clock1(video_clk),
	.address_a(address),
	.address_b(video_address),
	.data_a(data),
	.data_b(16'd0),
	.byteena_a(byte_enable),
	.byteena_b(2'b11),
	.wren_a(write),
	.wren_b(1'b0),
	.q_a(q),
	.q_b(video_q)
);
`else
logic [15:0] memory [0:NUM_WORDS-1];

always_ff @(posedge clk) begin
	if (write) begin
		if (byte_enable[1]) memory[address][15:8] <= data[15:8];
		if (byte_enable[0]) memory[address][7:0]  <= data[7:0];
	end
	q <= memory[address];
end

always_ff @(posedge video_clk)
	video_q <= memory[video_address];
`endif

endmodule
