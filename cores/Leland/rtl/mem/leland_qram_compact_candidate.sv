// SPDX-License-Identifier: GPL-3.0-or-later
// Opt-in Ataxx QRAM candidate. This is deliberately not the generic DPRAM.
// Port A uses the legal M10K NEW_DATA write reply; the consumed CPU read path
// is checked in sim/leland_qram_compact_candidate_tb.sv. Port B keeps the
// source's one-edge synchronous OLD_DATA behavior on the same clock. Its
// address register uses CLOCK1 and output is unregistered; the installed
// Quartus 17 primitive model is checked against the behavioral branch by
// sim/leland_qram_primitive_equivalence_tb.sv.
module leland_qram_compact_candidate #(
	parameter integer ADDR_WIDTH = 16,
	parameter integer DATA_WIDTH = 8
)(
	input                         clk,
	input      [ADDR_WIDTH-1:0]   addr_a,
	input      [DATA_WIDTH-1:0]   din_a,
	input                         we_a,
	output wire [DATA_WIDTH-1:0]  dout_a,
	input      [ADDR_WIDTH-1:0]   addr_b,
	input      [DATA_WIDTH-1:0]   din_b,
	input                         we_b,
	output wire [DATA_WIDTH-1:0]  dout_b
);

localparam integer NUM_WORDS = (1 << ADDR_WIDTH);

// Q17 defines ALTERA_RESERVED_QIS, not SYNTHESIS in the production project.
// SYNTHESIS remains supported by the separately qualified vendor-model test.
`ifdef ALTERA_RESERVED_QIS
`define ASYLUM_QRAM_USE_PRIMITIVE
`endif
`ifdef SYNTHESIS
`define ASYLUM_QRAM_USE_PRIMITIVE
`endif
`ifdef ASYLUM_QRAM_USE_PRIMITIVE
// Cyclone V M10K true-dual-port, one shared clock. Intel's Embedded Memory
// User Guide permits NEW_DATA_NO_NBE_READ on same-port writes and mixed-port
// OLD_DATA only in single-clock mode. Port B is left writable at the generic
// module boundary for shape compatibility; qram integration ties we_b low.
altsyncram #(
	.operation_mode("BIDIR_DUAL_PORT"),
	.intended_device_family("Cyclone V"),
	.ram_block_type("M10K"),
	.width_a(DATA_WIDTH),
	.widthad_a(ADDR_WIDTH),
	.numwords_a(NUM_WORDS),
	.width_b(DATA_WIDTH),
	.widthad_b(ADDR_WIDTH),
	.numwords_b(NUM_WORDS),
	.address_reg_b("CLOCK1"),
	.outdata_reg_a("UNREGISTERED"),
	.outdata_reg_b("UNREGISTERED"),
	.clock_enable_input_a("BYPASS"),
	.clock_enable_input_b("BYPASS"),
	.clock_enable_output_a("BYPASS"),
	.clock_enable_output_b("BYPASS"),
	.read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
	.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
	.read_during_write_mode_mixed_ports("OLD_DATA"),
	.power_up_uninitialized("FALSE")
) qram_m10k (
	.clock0(clk),
	.clock1(clk),
	.clocken0(1'b1),
	.clocken1(1'b1),
	.clocken2(1'b1),
	.clocken3(1'b1),
	.aclr0(1'b0),
	.aclr1(1'b0),
	.address_a(addr_a),
	.data_a(din_a),
	.wren_a(we_a),
	.rden_a(1'b1),
	.q_a(dout_a),
	.address_b(addr_b),
	.data_b({DATA_WIDTH{1'b0}}),
	.wren_b(1'b0),
	.rden_b(1'b1),
	.q_b(dout_b),
	.byteena_a(1'b1),
	.byteena_b(1'b1),
	.addressstall_a(1'b0),
	.addressstall_b(1'b0),
	.eccstatus()
);
`else
// Behavioral model follows the specific primitive contract selected above:
// Port A reports the written byte on a write edge, while B reads the old byte
// when both ports address the same word at that edge.
reg [DATA_WIDTH-1:0] mem [0:NUM_WORDS-1];
reg [DATA_WIDTH-1:0] dout_a_r, dout_b_r;
integer init_index;
assign dout_a = dout_a_r;
assign dout_b = dout_b_r;
initial begin
	dout_a_r = {DATA_WIDTH{1'b0}};
	dout_b_r = {DATA_WIDTH{1'b0}};
	for (init_index = 0; init_index < NUM_WORDS; init_index = init_index + 1)
		mem[init_index] = {DATA_WIDTH{1'b0}};
end
always @(posedge clk) begin
	if (we_b !== 1'b0)
		$fatal(1, "leland_qram_compact_candidate is read-only on Port B");
	dout_a_r <= we_a ? din_a : mem[addr_a];
	if (we_a)
		mem[addr_a] <= din_a;
	dout_b_r <= mem[addr_b];
end
`endif
`ifdef ASYLUM_QRAM_USE_PRIMITIVE
`undef ASYLUM_QRAM_USE_PRIMITIVE
`endif

endmodule
