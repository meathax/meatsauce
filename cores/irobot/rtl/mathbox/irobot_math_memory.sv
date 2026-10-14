`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Mathbox RAM/object-ROM/address-latch subsystem.
//
// math_ram and object_rom each need exactly two independent access agents on
// real hardware: the AM2901 mathbox microsequencer, and the 6809 CPU (which
// can only ever address them byte-wide -- it has no 16-bit bus). Cyclone V
// M10K blocks are true dual-port: two ports total, each independently R, W
// or R+W. A prior revision of this module also exposed a 16-bit-wide
// "cpu_we/cpu_addr/cpu_din/cpu_dout" port with no hardware counterpart (the
// board integration tied it permanently to 1'b0/0/0 and discarded its
// output), and mixed both arrays' reads into one shared destination register
// behind nested conditionals. Between the extra phantom port and the
// unrecognizable read/write templates, Quartus silently dropped both arrays
// into logic instead of M10K (569,271 ALUTs, 0 uninferred-RAM diagnostic).
// Each array below now gets exactly two ports, each a plain, unconditional,
// single-array read alongside its own write -- the same clean shape already
// proven for irobot_framebuffers/irobot_palette/irobot_mainboard.
module irobot_math_memory (
	input  logic       clk_12m096,
	input  logic       reset,
	input  logic       object_we,
	input  logic [15:0] object_byte_addr,
	input  logic [7:0] object_byte_data,
	input  logic       mbmemdec,
	input  logic       adden,
	input  logic       mbrw,
	input  logic [7:0] direct_address,
	input  logic [15:0] latch_mask,
	input  logic [1:0] ram_select,
	input  logic       direct_enable,
	input  logic       microstep,
	input  logic [15:0] alu_y,
	output logic [15:0] memory_dout,
	output logic [15:0] address_latch,
	output logic       comm_we,
	output logic [10:0] comm_addr,
	output logic [15:0] comm_dout,
	input logic cpu_byte_we,input logic[12:0]cpu_byte_addr,input logic[7:0]cpu_byte_din,
	output logic[7:0]cpu_byte_dout,
	input logic[15:0]cpu_object_byte_addr,output logic[7:0]cpu_object_dout
);
	// math_ram is split into two byte-wide arrays (hi/lo) instead of one
	// 16-bit array. Quartus 17 can't resolve two separate always_ff blocks
	// that both target the same 16-bit array through bit-selects of
	// differing width (mathbox: full word; CPU: one byte) -- elaboration
	// reports conflicting constant drivers for every bit (Error 10028) and
	// never reaches RAM inference. Two plain byte-wide arrays give every
	// port a whole-element, non-bit-selected write, the same clean shape
	// already proven for irobot_framebuffers/irobot_palette/irobot_mainboard.
	`ifndef IROBOT_QUARTUS
	(* ramstyle="M10K, no_rw_check" *) logic [7:0] math_ram_hi[0:4095];
	(* ramstyle="M10K, no_rw_check" *) logic [7:0] math_ram_lo[0:4095];
	// object_rom is split hi/lo for the same reason as math_ram above: the
	// ROM-load port writes one byte at a time, and expressing that as a
	// bit-select into a 16-bit element defeats M10K inference. At 24576x16
	// (393,216 bits) an uninferred object_rom is not merely slow -- it is
	// ~5x the whole device's register capacity, which is what drove
	// quartus_map to 14 GB and a crash inside its mux-combining optimizer.
	(* ramstyle="M10K, no_rw_check" *) logic [7:0] object_rom_hi[0:24575];
	(* ramstyle="M10K, no_rw_check" *) logic [7:0] object_rom_lo[0:24575];
	`endif
	logic [15:0] effective_full;
	logic [13:0] effective_address;
	logic [11:0] math_address;
	logic [14:0] object_address;
	logic [14:0] object_load_word;
	logic [14:0] cpu_object_word_addr;
	logic select_math;
	always_comb begin
		effective_full={8'h00,direct_address}|(address_latch&latch_mask);
		// The decoded PROM masks never select bits 15:14.  Clamp an invalid
		// externally supplied mask rather than allowing an out-of-range ROM
		// address; this also keeps those interface bits explicitly covered.
		effective_address=effective_full[13:0];
		if (effective_full[15:14] != 2'b00) effective_address=14'h3fff;
		math_address=effective_address[11:0];
		select_math=direct_enable||(address_latch[14:13]==0);
		// The mathbox presents the object ROM as 16-bit big-endian words.
		// CEMATH selects the upper 8K-word half; the address supplied by the
		// microcode is the low 13-bit word address in either half.  Do not add
		// 0x2000 to a full CEMATH-bearing address (that produced an index past
		// the 0x6000-word array).
		object_address = address_latch[14] ?
				15'h2000 + {1'b0,effective_address[13:0]} :
				{2'b0,effective_address[12:0]};
		if (object_byte_addr < 16'h2000)
			object_load_word = {2'b00,object_byte_addr[12:0]};
		else if (object_byte_addr < 16'h4000)
			object_load_word = {2'b00,object_byte_addr[12:0]};
		else if (object_byte_addr < 16'h8000)
			object_load_word = 15'h2000 + {1'b0,object_byte_addr[13:0]};
		else
			object_load_word = 15'h2000 + {1'b0,object_byte_addr[13:0]};
		cpu_object_word_addr=cpu_object_byte_addr[15:1];
	end

	wire math_we = microstep && !mbrw && !mbmemdec && select_math;
	// Each byte-wide array gets its OWN dedicated output register, read with
	// a bare "reg <= array[addr]" -- the exact single-array template Quartus
	// 17 pattern-matches for M10K inference (the same shape already proven
	// in irobot_framebuffers/irobot_palette/irobot_mainboard). Combining two
	// arrays' data into one register in the same statement -- concatenation
	// or a ternary mux of two array reads -- is enough to defeat that
	// pattern match; Quartus falls back to modeling the array as plain
	// registers ("uninferred due to asynchronous read logic"), which is how
	// a 393,216-bit object_rom ends up exceeding the device's entire
	// register budget (Error 276003). Any combining happens strictly after
	// the register, on data already latched.
	logic [7:0] math_ram_hi_q, math_ram_lo_q;
	logic [7:0] object_rom_hi_q, object_rom_lo_q;
	logic [15:0] math_ram_q, object_rom_mb_q;
	logic [7:0] cpu_byte_hi_data, cpu_byte_lo_data;
	logic [7:0] cpu_object_hi_data, cpu_object_lo_data;
	logic select_math_q;
	assign math_ram_q = {math_ram_hi_q, math_ram_lo_q};
	assign object_rom_mb_q = {object_rom_hi_q, object_rom_lo_q};

	// math_ram port A: mathbox microcode, word-wide R+W -- a plain,
	// unconditional whole-element write/read to each byte-wide array.
	`ifndef IROBOT_QUARTUS
	always_ff @(posedge clk_12m096) begin
		if(math_we) begin
			math_ram_hi[math_address] <= alu_y[15:8];
			math_ram_lo[math_address] <= alu_y[7:0];
		end
		math_ram_hi_q <= math_ram_hi[math_address];
		math_ram_lo_q <= math_ram_lo[math_address];
		select_math_q <= select_math;
	end

	// math_ram port B: CPU shared-window byte access, R+W. The 6809 samples
	// this byte-wide static-RAM view at E-fall, so its read is combinational;
	// only the mathbox port retains a registered response.
	always_ff @(posedge clk_12m096) begin
		if(cpu_byte_we) begin
			if(cpu_byte_addr[0]) math_ram_lo[cpu_byte_addr[12:1]]<=cpu_byte_din;
			else math_ram_hi[cpu_byte_addr[12:1]]<=cpu_byte_din;
		end
	end
	assign cpu_byte_hi_data = math_ram_hi[cpu_byte_addr[12:1]];
	assign cpu_byte_lo_data = math_ram_lo[cpu_byte_addr[12:1]];
	`else
	irobot_async_cpu_sync_byte_ram #(.ADDR_WIDTH(12), .NUM_WORDS(4096)) math_ram_hi_port(
		.clk(clk_12m096), .cpu_addr(cpu_byte_addr[12:1]), .cpu_wdata(cpu_byte_din),
		.cpu_we(cpu_byte_we && !cpu_byte_addr[0]), .cpu_rdata(cpu_byte_hi_data),
		.device_addr(math_address), .device_wdata(alu_y[15:8]), .device_we(math_we),
		.device_rdata(math_ram_hi_q));
	irobot_async_cpu_sync_byte_ram #(.ADDR_WIDTH(12), .NUM_WORDS(4096)) math_ram_lo_port(
		.clk(clk_12m096), .cpu_addr(cpu_byte_addr[12:1]), .cpu_wdata(cpu_byte_din),
		.cpu_we(cpu_byte_we && cpu_byte_addr[0]), .cpu_rdata(cpu_byte_lo_data),
		.device_addr(math_address), .device_wdata(alu_y[7:0]), .device_we(math_we),
		.device_rdata(math_ram_lo_q));
	always_ff @(posedge clk_12m096)
		select_math_q <= select_math;
	`endif
	assign cpu_byte_dout = cpu_byte_addr[0] ? cpu_byte_lo_data : cpu_byte_hi_data;

	// object_rom port A: ROM load (write, ioctl-time only) + mathbox
	// microcode read. Load and normal operation never overlap in time (the
	// board holds mathbox in reset until rom_loaded), so sharing one port
	// between them is a real hardware-equivalent 2-port shape, not a
	// three-port device.
	// The load byte order is unchanged: the 0x0000/0x4000 halves supply the
	// high byte of each word and the 0x2000/0x8000 halves the low byte --
	// the same mapping the previous bit-select form expressed, now selecting
	// which byte-wide array to write instead of which half of an element.
	`ifndef IROBOT_QUARTUS
	always_ff @(posedge clk_12m096) begin
		if(object_we) begin
			if(object_byte_addr<16'h2000)
				object_rom_hi[object_load_word]<=object_byte_data;
			else if(object_byte_addr<16'h4000)
				object_rom_lo[object_load_word]<=object_byte_data;
			else if(object_byte_addr<16'h8000)
				object_rom_hi[object_load_word]<=object_byte_data;
			else if(object_byte_addr<16'hc000)
				object_rom_lo[object_load_word]<=object_byte_data;
		end
		object_rom_hi_q <= object_rom_hi[object_address];
		object_rom_lo_q <= object_rom_lo[object_address];
	end

	// object_rom port B: CPU shared-window read-only static-ROM view.
	assign cpu_object_hi_data = object_rom_hi[cpu_object_word_addr];
	assign cpu_object_lo_data = object_rom_lo[cpu_object_word_addr];
	`else
	logic [14:0] object_device_addr;
	assign object_device_addr = object_we ? object_load_word : object_address;
	irobot_async_cpu_sync_byte_ram #(.ADDR_WIDTH(15), .NUM_WORDS(24576)) object_rom_hi_port(
		.clk(clk_12m096), .cpu_addr(cpu_object_word_addr), .cpu_wdata(8'h00), .cpu_we(1'b0),
		.cpu_rdata(cpu_object_hi_data), .device_addr(object_device_addr),
		.device_wdata(object_byte_data), .device_we(object_we &&
			(object_byte_addr < 16'h2000 || (object_byte_addr >= 16'h4000 && object_byte_addr < 16'h8000))),
		.device_rdata(object_rom_hi_q));
	irobot_async_cpu_sync_byte_ram #(.ADDR_WIDTH(15), .NUM_WORDS(24576)) object_rom_lo_port(
		.clk(clk_12m096), .cpu_addr(cpu_object_word_addr), .cpu_wdata(8'h00), .cpu_we(1'b0),
		.cpu_rdata(cpu_object_lo_data), .device_addr(object_device_addr),
		.device_wdata(object_byte_data), .device_we(object_we &&
			(object_byte_addr >= 16'h2000 && object_byte_addr < 16'hc000) &&
			!(object_byte_addr >= 16'h4000 && object_byte_addr < 16'h8000)),
		.device_rdata(object_rom_lo_q));
	`endif
	assign cpu_object_dout = cpu_object_byte_addr[0] ? cpu_object_lo_data : cpu_object_hi_data;

	// memory_dout is a plain mux of the two already-registered array reads,
	// selected by select_math captured the same cycle those reads were
	// issued -- net one clock of latency from address to data, matching the
	// original single shared-register contract without adding a stage.
	assign memory_dout = select_math_q ? math_ram_q : object_rom_mb_q;

	always_ff @(posedge clk_12m096) begin
		comm_we<=0;
		if(reset) begin
			// Registered observables at the mathbox boundary. Reset them
			// explicitly even though the large RAM arrays themselves are
			// intentionally not cleared.
			address_latch<=0;
			comm_addr<=0;
			comm_dout<=0;
			comm_we<=0;
		end
		else if(microstep) begin
			if(!mbrw) begin
				if(ram_select==3) begin comm_we<=1;comm_addr<=address_latch[10:0];comm_dout<=alu_y;end
			end
			if(!adden) address_latch<=mbrw?memory_dout:alu_y;
		end
	end
endmodule
