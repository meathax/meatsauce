// SPDX-License-Identifier: GPL-3.0-or-later
// Host/clock-domain reset and persistence guard for the universal SSV core.
`timescale 1ns/1ps

module ssv_host_guard #(
	parameter integer RESET_HOLD_CYCLES = 8
) (
	input  logic        clk_sys,
	input  logic        clk_ram,
	input  logic        pll_locked_async,
	input  logic        reset_async,
	input  logic        reset_request,
	input  logic        sdram_ready_async,
	input  logic        ioctl_download,
	input  logic        ioctl_upload,
	input  logic [15:0] ioctl_index,
	input  logic        rom_loaded,
	input  logic        nv_init_done,
	input  logic        nv_init_busy,
	input  logic        hs_pause,
	input  logic        wdog_rst,

	output logic        pll_ready_sys,
	output logic        pll_ready_ram,
	output logic        sdram_ready_sys,
	output logic        nvram_transfer,
	output logic        game_pause,
	output logic        loader_reset,
	output logic        video_reset,
	output logic        core_cold_reset,
	output logic        core_reset
);

localparam integer RESET_HOLD_WIDTH =
	(RESET_HOLD_CYCLES < 2) ? 1 : $clog2(RESET_HOLD_CYCLES + 1);
localparam logic [RESET_HOLD_WIDTH-1:0] RESET_HOLD_VALUE = RESET_HOLD_CYCLES;

// PLL lock is asynchronous to both generated clocks. Assertion must be
// immediate, while release is qualified independently in each destination
// domain so no state machine observes a runt first clock or metastable release.
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [1:0] pll_sys_sync;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [1:0] pll_ram_sync;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [1:0] reset_async_sync = 2'b00;

always_ff @(posedge clk_sys or negedge pll_locked_async) begin
	if (!pll_locked_async)
		pll_sys_sync <= 2'b00;
	else
		pll_sys_sync <= {pll_sys_sync[0], 1'b1};
end

always_ff @(posedge clk_ram or negedge pll_locked_async) begin
	if (!pll_locked_async)
		pll_ram_sync <= 2'b00;
	else
		pll_ram_sync <= {pll_ram_sync[0], 1'b1};
end

// The MiSTer shell RESET pin is asynchronous to clk_sys. Assert immediately,
// then release through two destination edges. Keep the hps_io status/button
// reset term outside this synchronizer so its established release phase does
// not move.
always_ff @(posedge clk_sys or posedge reset_async) begin
	if (reset_async)
		reset_async_sync <= 2'b11;
	else
		reset_async_sync <= {reset_async_sync[0], 1'b0};
end

wire host_reset_request = reset_request | reset_async_sync[1];

always_comb begin
	pll_ready_sys = pll_sys_sync[1];
	pll_ready_ram = pll_ram_sync[1];
end

// SDRAM ready crosses from clk_ram. Once initialization has completed it is
// sticky until PLL loss: a one-cycle synchronizer upset must not cold-reset a
// running machine. The controller itself only drops ready during re-init.
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic sdram_ready_meta;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic sdram_ready_sync;

always_ff @(posedge clk_sys or negedge pll_locked_async) begin
	if (!pll_locked_async) begin
		sdram_ready_meta <= 1'b0;
		sdram_ready_sync <= 1'b0;
		sdram_ready_sys  <= 1'b0;
	end
	else if (!pll_ready_sys) begin
		sdram_ready_meta <= 1'b0;
		sdram_ready_sync <= 1'b0;
		sdram_ready_sys  <= 1'b0;
	end
	else begin
		sdram_ready_meta <= sdram_ready_async;
		sdram_ready_sync <= sdram_ready_meta;
		if (sdram_ready_sync)
			sdram_ready_sys <= 1'b1;
	end
end

// Stretch front-panel/OSD reset requests so every synchronous subsystem sees
// a clean reset interval even if Main emits only a short pulse.
logic [RESET_HOLD_WIDTH-1:0] reset_hold_count;
logic                        host_reset;

always_ff @(posedge clk_sys or negedge pll_locked_async) begin
	if (!pll_locked_async)
		reset_hold_count <= RESET_HOLD_VALUE;
	else if (!pll_ready_sys || host_reset_request)
		reset_hold_count <= RESET_HOLD_VALUE;
	else if (reset_hold_count != 0)
		reset_hold_count <= reset_hold_count - 1'b1;
end

always_comb begin
	host_reset = host_reset_request | (reset_hold_count != 0);

	// Only descriptor and ROM downloads replace the running machine. Hiscore
	// config/data and battery-NVRAM transfers are live persistence operations.
	nvram_transfer = (ioctl_download || ioctl_upload) &&
	                 (ioctl_index == 16'd8);
	game_pause      = hs_pause | nvram_transfer | nv_init_busy;

	loader_reset    = ~pll_ready_sys;
	video_reset     = ~pll_ready_sys | host_reset;
	core_cold_reset = video_reset |
	                  (ioctl_download && ((ioctl_index == 16'd0) ||
	                                      (ioctl_index == 16'd1))) |
	                  ~rom_loaded | ~sdram_ready_sys | ~nv_init_done;
	core_reset      = core_cold_reset | wdog_rst;
end

endmodule
