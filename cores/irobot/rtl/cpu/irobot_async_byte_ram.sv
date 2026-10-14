// Inferable registered-read byte RAM, shared verbatim by Quartus synthesis
// and Verilator simulation.
//
// Previously this module split into an unregistered `altsyncram` primitive
// (`IROBOT_QUARTUS`, address valid to data valid same cycle) and a
// zero-latency behavioural array (simulation), so Verilator never exercised
// the production memory timing (plan blocker B15). Both flows now elaborate
// the same template: read data is registered and appears one `clk` cycle
// after `rd_addr` is presented, matching a plain M10K block with a
// registered output (the fitted 6116-2 SRAMs' 120 ns access sits inside the
// 661 ns E cycle with room for this extra clock of latency; see
// docs/BRINGUP_PLAN.md S1b). A read and a write to the same address in the
// same cycle returns the OLD data, not the new write -- this is the M10K's
// default read-during-write behavior for the two-port case here, and callers
// must not assume same-cycle read-your-write.
// SPDX-License-Identifier: GPL-3.0-or-later
module irobot_async_byte_ram #(
	parameter integer ADDR_WIDTH = 17,
	parameter integer NUM_WORDS  = (1 << ADDR_WIDTH)
) (
	input  logic                  clk,
	input  logic [ADDR_WIDTH-1:0] rd_addr,
	input  logic [ADDR_WIDTH-1:0] wr_addr,
	input  logic [7:0]            wr_data,
	input  logic                  wr_en,
	output logic [7:0]            rd_data
);

	// No initial block: Quartus 17 refuses loops above 5,000 iterations and the
	// M10K contents power up as zero on the device anyway; the simulation lanes
	// resolve the array through their --x-initial policy exactly as before.
	(* ramstyle = "M10K, no_rw_check" *) logic [7:0] mem [0:NUM_WORDS-1];

	always_ff @(posedge clk) begin
		if (wr_en)
			mem[wr_addr] <= wr_data;
		rd_data <= mem[rd_addr];
	end
endmodule

// Two-port byte RAM for a board-visible asynchronous CPU port and a
// synchronous device port. The CPU-facing port maps an SRAM/EPROM data bus;
// the device port retains one registered read for sequencer/video clients.
module irobot_async_cpu_sync_byte_ram #(
	parameter integer ADDR_WIDTH = 11,
	parameter integer NUM_WORDS  = (1 << ADDR_WIDTH)
) (
	input  logic                  clk,
	input  logic [ADDR_WIDTH-1:0] cpu_addr,
	input  logic [7:0]            cpu_wdata,
	input  logic                  cpu_we,
	output logic [7:0]            cpu_rdata,
	input  logic [ADDR_WIDTH-1:0] device_addr,
	input  logic [7:0]            device_wdata,
	input  logic                  device_we,
	output logic [7:0]            device_rdata
);

`ifdef IROBOT_QUARTUS
	altsyncram ram (
		.address_a     (cpu_addr),
		.clock0        (clk),
		.data_a        (cpu_wdata),
		.wren_a        (cpu_we),
		.q_a           (cpu_rdata),
		.address_b     (device_addr),
		.clock1        (clk),
		.data_b        (device_wdata),
		.wren_b        (device_we),
		.q_b           (device_rdata),
		.aclr0         (1'b0),
		.aclr1         (1'b0),
		.addressstall_a(1'b0),
		.addressstall_b(1'b0),
		.byteena_a     (1'b1),
		.byteena_b     (1'b1),
		.clocken0      (1'b1),
		.clocken1      (1'b1),
		.clocken2      (1'b1),
		.clocken3      (1'b1),
		.eccstatus     (),
		.rden_a        (1'b1),
		.rden_b        (1'b1)
	);
	defparam
		ram.address_reg_a = "UNREGISTERED",
		// A writable altsyncram port requires its address on the same clock
		// as data/wren. Registering this address gives the device side its
		// one-cycle response; leaving q_b unregistered avoids a second stage.
		ram.address_reg_b = "CLOCK1",
		ram.clock_enable_input_a = "BYPASS",
		ram.clock_enable_input_b = "BYPASS",
		ram.clock_enable_output_a = "BYPASS",
		ram.clock_enable_output_b = "BYPASS",
		ram.intended_device_family = "Cyclone V",
		ram.lpm_type = "altsyncram",
		ram.numwords_a = NUM_WORDS,
		ram.numwords_b = NUM_WORDS,
		ram.operation_mode = "BIDIR_DUAL_PORT",
		ram.outdata_reg_a = "UNREGISTERED",
		ram.outdata_reg_b = "UNREGISTERED",
		ram.power_up_uninitialized = "FALSE",
		ram.ram_block_type = "M10K",
		ram.read_during_write_mode_mixed_ports = "DONT_CARE",
		ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
		ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
		ram.widthad_a = ADDR_WIDTH,
		ram.widthad_b = ADDR_WIDTH,
		ram.width_a = 8,
		ram.width_b = 8,
		ram.width_byteena_a = 1,
		ram.width_byteena_b = 1;
`else
	logic [7:0] mem [0:NUM_WORDS-1];
	integer init_i;

	assign cpu_rdata = mem[cpu_addr];

	initial begin
		for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1)
			mem[init_i] = 8'h00;
	end

	always_ff @(posedge clk) begin
		if (device_we)
			mem[device_addr] <= device_wdata;
		if (cpu_we)
			mem[cpu_addr] <= cpu_wdata;
		device_rdata <= mem[device_addr];
	end
`endif
endmodule

// Synchronous-read byte RAM used where the board exposes a registered memory
// response. Port A is the read port and Port B is the sole writer. Keeping the
// byte lane as the physical word avoids Quartus 17's failure to infer a packed
// word RAM with partial-select writes.
module irobot_sync_byte_ram #(
	parameter integer ADDR_WIDTH = 11,
	parameter integer NUM_WORDS  = (1 << ADDR_WIDTH)
) (
	input  logic                  clk,
	input  logic [ADDR_WIDTH-1:0] rd_addr,
	input  logic [ADDR_WIDTH-1:0] wr_addr,
	input  logic [7:0]            wr_data,
	input  logic                  wr_en,
	output logic [7:0]            rd_data
);

`ifdef IROBOT_QUARTUS
	altsyncram ram (
		.address_a     (rd_addr),
		.clock0        (clk),
		.data_a        (8'b0),
		.wren_a        (1'b0),
		.q_a           (rd_data),
		.address_b     (wr_addr),
		.clock1        (clk),
		.data_b        (wr_data),
		.wren_b        (wr_en),
		.aclr0         (1'b0),
		.aclr1         (1'b0),
		.addressstall_a(1'b0),
		.addressstall_b(1'b0),
		.byteena_a     (1'b1),
		.byteena_b     (1'b1),
		.clocken0      (1'b1),
		.clocken1      (1'b1),
		.clocken2      (1'b1),
		.clocken3      (1'b1),
		.eccstatus     (),
		.q_b           (),
		.rden_a        (1'b1),
		.rden_b        (1'b1)
	);
	defparam
		ram.address_reg_a = "UNREGISTERED",
		ram.clock_enable_input_a = "BYPASS",
		ram.clock_enable_input_b = "BYPASS",
		ram.clock_enable_output_a = "BYPASS",
		ram.clock_enable_output_b = "BYPASS",
		ram.intended_device_family = "Cyclone V",
		ram.lpm_type = "altsyncram",
		ram.numwords_a = NUM_WORDS,
		ram.numwords_b = NUM_WORDS,
		ram.operation_mode = "BIDIR_DUAL_PORT",
		ram.outdata_reg_a = "CLOCK0",
		ram.outdata_reg_b = "UNREGISTERED",
		ram.power_up_uninitialized = "FALSE",
		ram.ram_block_type = "M10K",
		ram.read_during_write_mode_mixed_ports = "DONT_CARE",
		ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
		ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
		ram.widthad_a = ADDR_WIDTH,
		ram.widthad_b = ADDR_WIDTH,
		ram.width_a = 8,
		ram.width_b = 8,
		ram.width_byteena_a = 1,
		ram.width_byteena_b = 1;
`else
	logic [7:0] mem [0:NUM_WORDS-1];
	integer init_i;

	initial begin
		for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1)
			mem[init_i] = 8'h00;
	end

	always_ff @(posedge clk) begin
		rd_data <= mem[rd_addr];
		if (wr_en)
			mem[wr_addr] <= wr_data;
	end
`endif
endmodule

// Alpha storage: both ports read synchronously; port B is the sole writer.
module irobot_async_byte_ram_dualclock #(
	parameter integer ADDR_WIDTH = 10,
	parameter integer NUM_WORDS  = (1 << ADDR_WIDTH)
) (
	input  logic                  rd_clk,
	input  logic [ADDR_WIDTH-1:0] rd_addr,
	input  logic                  wr_clk,
	input  logic [ADDR_WIDTH-1:0] wr_addr,
	input  logic [7:0]            wr_data,
	input  logic                  wr_en,
	output logic [7:0]            rd_data,
	output logic [7:0]            wr_rd_data
);

`ifdef IROBOT_QUARTUS
	altsyncram ram (
		.address_a     (rd_addr),
		.clock0        (rd_clk),
		.data_a        (8'b0),
		.wren_a        (1'b0),
		.q_a           (rd_data),
		.address_b     (wr_addr),
		.clock1        (wr_clk),
		.data_b        (wr_data),
		.wren_b        (wr_en),
		.aclr0         (1'b0),
		.aclr1         (1'b0),
		.addressstall_a(1'b0),
		.addressstall_b(1'b0),
		.byteena_a     (1'b1),
		.byteena_b     (1'b1),
		.clocken0      (1'b1),
		.clocken1      (1'b1),
		.clocken2      (1'b1),
		.clocken3      (1'b1),
		.eccstatus     (),
		.q_b           (wr_rd_data),
		.rden_a        (1'b1),
		.rden_b        (1'b1)
	);
	defparam
		ram.clock_enable_input_a = "BYPASS",
		ram.clock_enable_input_b = "BYPASS",
		ram.clock_enable_output_a = "BYPASS",
		ram.clock_enable_output_b = "BYPASS",
		ram.intended_device_family = "Cyclone V",
		ram.lpm_type = "altsyncram",
		ram.numwords_a = NUM_WORDS,
		ram.numwords_b = NUM_WORDS,
		ram.operation_mode = "BIDIR_DUAL_PORT",
		ram.outdata_reg_a = "UNREGISTERED",
		ram.outdata_reg_b = "UNREGISTERED",
		ram.power_up_uninitialized = "FALSE",
		ram.ram_block_type = "M10K",
		ram.read_during_write_mode_mixed_ports = "DONT_CARE",
		ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
		ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
		ram.widthad_a = ADDR_WIDTH,
		ram.widthad_b = ADDR_WIDTH,
		ram.width_a = 8,
		ram.width_b = 8,
		ram.width_byteena_a = 1,
		ram.width_byteena_b = 1;
`else
	logic [7:0] mem [0:NUM_WORDS-1];
	integer init_i;

	always_ff @(posedge rd_clk) rd_data <= mem[rd_addr];
	always_ff @(posedge wr_clk) wr_rd_data <= mem[wr_addr];

	initial begin
		for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1)
			mem[init_i] = 8'h00;
	end

	always_ff @(posedge wr_clk) begin
		if (wr_en)
			mem[wr_addr] <= wr_data;
	end
`endif
endmodule
