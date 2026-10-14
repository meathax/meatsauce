`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Complete mathbox integration boundary: control PROMs, four AM2901 slices,
// sequencer, math RAM, object ROM, address latch and communication writes.
module irobot_mathbox_system (
	input logic clk_12m096,input logic reset,input logic start,
	input logic prom_we,input logic[9:0]prom_word_addr,input logic[3:0]prom_plane,input logic[3:0]prom_nibble,
	input logic object_we,input logic[15:0]object_byte_addr,input logic[7:0]object_byte_data,
	output logic busy,output logic done,output logic[9:0]micro_pc,output logic[15:0]alu_y,
	output logic comm_we,output logic[10:0]comm_addr,output logic[15:0]comm_dout,
	output logic[15:0]address_latch,output logic[7:0]trace_flags,output logic trace_memory_read,
	output logic trace_memory_write,output logic[11:0]debug_slices,
	input logic cpu_byte_we,input logic[12:0]cpu_byte_addr,input logic[7:0]cpu_byte_din,
	output logic[7:0]cpu_byte_dout,input logic[15:0]cpu_object_byte_addr,output logic[7:0]cpu_object_dout
);
	logic[15:0]memory_din /* verilator public_flat_rd */,latch_mask;logic[7:0]direct_address;logic[1:0]ram_select;
	logic direct_enable,microstep /* verilator public_flat_rd */;
	irobot_mathbox control(.clk_12m096(clk_12m096),.reset(reset),.start(start),
		.prom_we(prom_we),.prom_word_addr(prom_word_addr),.prom_plane(prom_plane),.prom_nibble(prom_nibble),
		.memory_din(memory_din),.busy(busy),.done(done),.micro_pc(micro_pc),.alu_y(alu_y),
		.current_flags(trace_flags),.direct_address(direct_address),.latch_mask(latch_mask),
		.ram_select(ram_select),.direct_enable(direct_enable),.memory_read(trace_memory_read),
		.memory_write(trace_memory_write),.microstep(microstep),.debug_slices(debug_slices));
	irobot_math_memory memory(.clk_12m096(clk_12m096),.reset(reset),.object_we(object_we),
		.object_byte_addr(object_byte_addr),.object_byte_data(object_byte_data),
		.mbmemdec(trace_flags[2]),.adden(trace_flags[3]),.mbrw(trace_flags[7]),
		.direct_address(direct_address),.latch_mask(latch_mask),.ram_select(ram_select),
		.direct_enable(direct_enable),.microstep(microstep),.alu_y(alu_y),.memory_dout(memory_din),
		.address_latch(address_latch),.comm_we(comm_we),
		.comm_addr(comm_addr),.comm_dout(comm_dout),.cpu_byte_we(cpu_byte_we),
		.cpu_byte_addr(cpu_byte_addr),.cpu_byte_din(cpu_byte_din),.cpu_byte_dout(cpu_byte_dout),
		.cpu_object_byte_addr(cpu_object_byte_addr),.cpu_object_dout(cpu_object_dout));
endmodule
