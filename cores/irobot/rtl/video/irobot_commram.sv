`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Two 2Kx16 communication/display-list banks. The CPU and ICY share the bank
// selected by STATWR[7]; the mathbox writes the opposite bank. Each physical
// bank maps to the two ports of an M10K: an asynchronous CPU SRAM port and a
// registered ICY/mathbox port. The previous serialized arbiter returned the
// preceding CPU byte after the 6809 E-fall sample and could not implement the
// CPU board's static-RAM read contract.
module irobot_commram (
	input  logic clk,
	input  logic reset,
	// The CPU's live view of STATWR bit 7.
	input  logic cpu_bank,
	// The bank the ICY read port must use.  irobot_board.sv freezes this for
	// the duration of a vector-generator run (rtl/video/icy_run_control.sv) so
	// one run always walks one list, as MAME's run_video() does.
	input  logic video_bank,
	input  logic cpu_req,
	input  logic cpu_we,
	input  logic [11:0] cpu_addr,
	input  logic [7:0] cpu_wdata,
	output logic cpu_ack,
	output logic [7:0] cpu_rdata,
	input  logic video_req,
	input  logic [10:0] video_addr,
	output logic video_ack,
	output logic [15:0] video_rdata,
	input  logic math_we,
	input  logic [10:0] math_addr,
	input  logic [15:0] math_wdata
);
	logic response_video, response_bank;
	logic [10:0] bank0_device_addr, bank1_device_addr;
	logic bank0_cpu_we, bank1_cpu_we, bank0_math_we, bank1_math_we;
	logic [7:0] bank0_hi_cpu, bank0_lo_cpu, bank1_hi_cpu, bank1_lo_cpu;
	logic [7:0] bank0_hi_device, bank0_lo_device, bank1_hi_device, bank1_lo_device;

	assign bank0_cpu_we = cpu_req && cpu_we && !cpu_bank;
	assign bank1_cpu_we = cpu_req && cpu_we && cpu_bank;
	// The mathbox writes the bank opposite the CPU's selection
	// (MAME irobot_m.cpp:303, m_commram[m_commbank ^ 1]).
	assign bank0_math_we = math_we && cpu_bank;
	assign bank1_math_we = math_we && !cpu_bank;
	assign bank0_device_addr = bank0_math_we ? math_addr : video_addr;
	assign bank1_device_addr = bank1_math_we ? math_addr : video_addr;

`ifdef IROBOT_QUARTUS
	irobot_async_cpu_sync_byte_ram bank0_hi(
		.clk(clk), .cpu_addr(cpu_addr[11:1]), .cpu_wdata(cpu_wdata),
		.cpu_we(bank0_cpu_we && !cpu_addr[0]), .cpu_rdata(bank0_hi_cpu),
		.device_addr(bank0_device_addr), .device_wdata(math_wdata[15:8]),
		.device_we(bank0_math_we), .device_rdata(bank0_hi_device));
	irobot_async_cpu_sync_byte_ram bank0_lo(
		.clk(clk), .cpu_addr(cpu_addr[11:1]), .cpu_wdata(cpu_wdata),
		.cpu_we(bank0_cpu_we && cpu_addr[0]), .cpu_rdata(bank0_lo_cpu),
		.device_addr(bank0_device_addr), .device_wdata(math_wdata[7:0]),
		.device_we(bank0_math_we), .device_rdata(bank0_lo_device));
	irobot_async_cpu_sync_byte_ram bank1_hi(
		.clk(clk), .cpu_addr(cpu_addr[11:1]), .cpu_wdata(cpu_wdata),
		.cpu_we(bank1_cpu_we && !cpu_addr[0]), .cpu_rdata(bank1_hi_cpu),
		.device_addr(bank1_device_addr), .device_wdata(math_wdata[15:8]),
		.device_we(bank1_math_we), .device_rdata(bank1_hi_device));
	irobot_async_cpu_sync_byte_ram bank1_lo(
		.clk(clk), .cpu_addr(cpu_addr[11:1]), .cpu_wdata(cpu_wdata),
		.cpu_we(bank1_cpu_we && cpu_addr[0]), .cpu_rdata(bank1_lo_cpu),
		.device_addr(bank1_device_addr), .device_wdata(math_wdata[7:0]),
		.device_we(bank1_math_we), .device_rdata(bank1_lo_device));
`else
	(* ramstyle = "M10K, no_rw_check" *) logic [15:0] bank0 [0:2047];
	(* ramstyle = "M10K, no_rw_check" *) logic [15:0] bank1 [0:2047];

	assign bank0_hi_cpu = bank0[cpu_addr[11:1]][15:8];
	assign bank0_lo_cpu = bank0[cpu_addr[11:1]][7:0];
	assign bank1_hi_cpu = bank1[cpu_addr[11:1]][15:8];
	assign bank1_lo_cpu = bank1[cpu_addr[11:1]][7:0];

	always_ff @(posedge clk) begin
		if (bank0_math_we)
			bank0[math_addr] <= math_wdata;
		else if (bank0_cpu_we) begin
			if (cpu_addr[0]) bank0[cpu_addr[11:1]][7:0] <= cpu_wdata;
			else bank0[cpu_addr[11:1]][15:8] <= cpu_wdata;
		end
		bank0_hi_device <= bank0[bank0_device_addr][15:8];
		bank0_lo_device <= bank0[bank0_device_addr][7:0];
	end

	always_ff @(posedge clk) begin
		if (bank1_math_we)
			bank1[math_addr] <= math_wdata;
		else if (bank1_cpu_we) begin
			if (cpu_addr[0]) bank1[cpu_addr[11:1]][7:0] <= cpu_wdata;
			else bank1[cpu_addr[11:1]][15:8] <= cpu_wdata;
		end
		bank1_hi_device <= bank1[bank1_device_addr][15:8];
		bank1_lo_device <= bank1[bank1_device_addr][7:0];
	end
`endif

	always_comb begin
		if (cpu_bank)
			cpu_rdata = cpu_addr[0] ? bank1_lo_cpu : bank1_hi_cpu;
		else
			cpu_rdata = cpu_addr[0] ? bank0_lo_cpu : bank0_hi_cpu;
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			cpu_ack <= 1'b0;
			video_ack <= 1'b0;
			response_video <= 1'b0;
			response_bank <= 1'b0;
			video_rdata <= 16'h0000;
		end else begin
			// Completion monitor only: the CPU data bus itself is asynchronous
			// and is sampled at E-fall. ICY retains its registered response.
			cpu_ack <= cpu_req;
			video_ack <= response_video;
			if (response_video)
				video_rdata <= response_bank ? {bank1_hi_device, bank1_lo_device} :
					{bank0_hi_device, bank0_lo_device};
			response_video <= video_req;
			response_bank <= video_bank;
		end
	end
endmodule
