`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// CPU-board address decode and storage. ROM addresses use the compact index-0
// ABI documented by tools/rom/irobot_rom.py.
module irobot_mainboard (
	input logic clk, input logic reset,
	input logic bus_valid, input logic rw, input logic [15:0] addr,
	input logic [7:0] cpu_dout, output logic [7:0] cpu_din,
	input logic [7:0] in0, in1, dsw1,
	input logic math_busy, video_busy, vblank,
	input logic [7:0] nvram_dout, adc_dout, pokey_dout, shared_dout, alpha_dout,
	input logic rom_wr, input logic [16:0] rom_addr, input logic [7:0] rom_din,
	output logic nvram_cs, adc_start, pokey_cs, shared_cs,
	output logic nvram_we, pokey_we,
	output logic [1:0] adc_channel,
	output logic palette_we, alpha_we,
	output logic [9:0] alpha_addr, output logic [7:0] alpha_data,
	output logic [7:0] peripheral_din,
	output logic [7:0] statwr, out0, bankctl,
	output logic [2:0] rom_bank, output logic [1:0] ram_bank,
	output logic math_start, video_start, irq_clear, firq_clear,
	// SP-251 sheet 3A: the $1900-$19FF write decode (net WDOG/WDCLR) drives the
	// R0(1)/R0(2) pins of the 74LS90 watchdog at 7A.  MAME 0.289 maps this range
	// as nopw() and models no watchdog; the board really does have one.
	output logic wdclr
);
	wire write_cycle=bus_valid && !rw;
	wire nvram_sel=addr>=16'h1200&&addr<=16'h12ff;
	wire pokey_sel=addr>=16'h1400&&addr<=16'h143f;
	// SP-251 sheets 3A/5A: STATWR DB3 drives /ADDCON, the active-low enable
	// for the main-CPU-to-mathbox address bridge.  The shared window exists
	// only while that bridge is connected.
	wire shared_sel=addr>=16'h2000&&addr<=16'h3fff&&!statwr[3];
	wire [16:0] fixed_rom_index = {1'b0, addr - 16'h6000};
	// MAME's maincpu region places the six 8 KiB bank pages at region offset
	// 0x10000, after the fixed CPU image at 0x6000..0xffff.  The compact
	// concatenated stream removes that 0x6000 prefix, so the bank pages begin
	// at stream offset 0x0a000.
	wire [16:0] bank_rom_index = 17'h0a000 + {1'b0,rom_bank,13'b0} + {4'b0,addr[12:0]};
	wire [16:0] cpu_rom_index = (addr>=16'h6000) ? fixed_rom_index : bank_rom_index;
	// fixed_ram/bank_ram/program_rom are the inferable registered-read
	// irobot_async_byte_ram wrapper, used identically by Quartus synthesis and
	// the Verilator simulator (see rtl/cpu/irobot_async_byte_ram.sv). Read
	// data appears one clk cycle after the address; the write-decode terms
	// below (fixed_mem_we, bank_mem_we) drive the wrapper's wr_en and are
	// also reused by the bank-select/rom-bank logic further down.
	wire [12:0] bank_ram_index = {ram_bank, addr[10:0]};
	wire fixed_mem_we = write_cycle && (addr <= 16'h07ff);
	wire bank_mem_we = write_cycle && (addr >= 16'h0800) && (addr <= 16'h0fff);
	logic [7:0] fixed_ram_dout, bank_ram_dout;
	irobot_async_byte_ram #(.ADDR_WIDTH(11), .NUM_WORDS(2048)) fixed_ram (
		.clk(clk), .rd_addr(addr[10:0]), .wr_addr(addr[10:0]),
		.wr_data(cpu_dout), .wr_en(fixed_mem_we), .rd_data(fixed_ram_dout)
	);
	irobot_async_byte_ram #(.ADDR_WIDTH(13), .NUM_WORDS(6144)) bank_ram (
		.clk(clk), .rd_addr(bank_ram_index), .wr_addr(bank_ram_index),
		.wr_data(cpu_dout), .wr_en(bank_mem_we), .rd_data(bank_ram_dout)
	);
	// Kept as a hierarchical wrapper instance (not a bare array) named
	// `program_rom` so the ROM-loader tests can still reach into it via
	// `program_rom.mem[...]`; see the wrapper module for the storage array.
	logic [7:0] program_rom_dout;
	irobot_async_byte_ram #(.ADDR_WIDTH(17), .NUM_WORDS(90112)) program_rom (
		.clk(clk), .rd_addr(cpu_rom_index), .wr_addr(rom_addr),
		.wr_data(rom_din), .wr_en(rom_wr), .rd_data(program_rom_dout)
	);
	logic statwr_prev_math, statwr_prev_video;

	always_ff @(posedge clk) begin
		palette_we<=0; alpha_we<=0; adc_start<=0; math_start<=0; video_start<=0;
		irq_clear<=0; firq_clear<=0; wdclr<=0;
		if(reset) begin statwr<=0; out0<=0; bankctl<=0; rom_bank<=0; ram_bank<=0;
			alpha_data<=0;
			statwr_prev_math<=0; statwr_prev_video<=0; end
		else if(write_cycle) begin
			if(addr<=16'h07ff) begin
				// fixed_ram write is applied by the wrapper instance above via
				// fixed_mem_we.
			end
			else if(addr>=16'h0800 && addr<=16'h0fff) begin
				// bank_ram write is applied by the wrapper instance above via
				// bank_mem_we.
			end
			else casez(addr)
				16'h1100: irq_clear<=1;
				16'h1140: begin
					statwr<=cpu_dout; statwr_prev_math<=cpu_dout[4]; statwr_prev_video<=cpu_dout[2];
					math_start<=cpu_dout[4]&&!statwr_prev_math;
					video_start<=cpu_dout[2]&&!statwr_prev_video;
				end
				16'h1180: begin out0<=cpu_dout; if(cpu_dout[6:5]!=2'b11) ram_bank<=cpu_dout[6:5]; end
				16'h11c0: begin bankctl<=cpu_dout; if(cpu_dout[3:1]<6) rom_bank<=cpu_dout[3:1]; end
				16'h1a00: firq_clear<=1;
				default: begin
					if(addr>=16'h1800&&addr<=16'h18ff) palette_we<=1;
					if(addr>=16'h1b00&&addr<=16'h1bff) begin adc_start<=1; adc_channel<=addr[1:0]; end
					if(addr>=16'h1900&&addr<=16'h19ff) wdclr<=1;
					if(addr>=16'h1c00&&addr<=16'h1fff) begin
						alpha_we<=1; alpha_data<=cpu_dout;
					end
				end
			endcase
		end
	end

	// alpha_addr must track addr[9:0] on every cycle that addresses
	// $1C00-$1FFF, read or write, not only on a write cycle. irobot_alpha.sv
	// registers its CPU-side read (alpha_cpu_data <= alpha_ram[cpu_addr]) off
	// this address, so a read-only cycle that never touched alpha_addr left
	// the RAM pointed at whatever address the last write happened to use,
	// returning stale data. alpha_we/alpha_data stay write-only above.
	//
	// The address decode must NOT be qualified with bus_valid here. bus_valid
	// is the 6809E's AVMA, which per the MC6809E data sheet is a LOOK-AHEAD:
	// it says the processor will use the bus in the FOLLOWING cycle, not that
	// the address on the bus this cycle is real. About 20 % of the CPU's own
	// read cycles run with AVMA low (measured: 17,422 of 87,113 in
	// sim/tb/alpha_selftest_tb.sv), and on those cycles the latch never
	// loaded, so cpu_dout still held the previous alpha access's byte. That is
	// what made the board's own RAM test print "BAD RAM AL 1C01": it writes a
	// non-zero byte to $1C00 and then reads $1C01, which came back with the
	// $1C00 data. Writes are unaffected (0 of 7,175 write cycles ran with AVMA
	// low, because a store is always followed by a bus cycle), so write_cycle
	// above keeps its bus_valid qualifier.
	//
	// alpha_we and alpha_data are latched from the same live bus on the same
	// clock edges as alpha_addr, so the strobe never outlives its own address
	// and data: no phantom write can be created by this.
	always_ff @(posedge clk) begin
		if(reset) alpha_addr<=0;
		else if(addr>=16'h1c00 && addr<=16'h1fff) alpha_addr<=addr[9:0];
	end

	// The MC6809E samples D on the E falling edge of the same bus cycle in
	// which AVMA/RW/ADDR are asserted (Q-rise). The SRAM/ROM outputs below
	// (fixed_ram_dout/bank_ram_dout/program_rom_dout) come from the
	// irobot_async_byte_ram wrapper, which registers its read data one clk
	// cycle after rd_addr changes -- this lands well inside the same E cycle,
	// since the fitted 6116-2 SRAMs' 120 ns access time is a fraction of the
	// 661 ns E cycle (docs/BRINGUP_PLAN.md S1b/B15). Peripheral sources
	// (adc_dout, pokey_dout, ...) remain purely combinational from their own
	// modules; this mux just selects among them.
	always_comb begin
		cpu_din = 8'hff;
		if (rw) begin
			if(addr<=16'h07ff) begin
				cpu_din = fixed_ram_dout;
			end
			else if(addr<=16'h0fff) begin
				cpu_din = bank_ram_dout;
			end
			else if(addr>=16'h1000&&addr<=16'h103f) cpu_din = in0;
			else if(addr==16'h1040) cpu_din = in1;
			// STATRD reports completed, rather than running, for both engines.
		else if(addr==16'h1080) cpu_din = {vblank,video_busy,!math_busy,5'b0};
			else if(addr==16'h10c0) cpu_din = dsw1;
			else if(nvram_sel) cpu_din = nvram_dout;
			else if(addr>=16'h1300&&addr<=16'h13ff) cpu_din = adc_dout;
			else if(pokey_sel) cpu_din = pokey_dout;
			else if(addr>=16'h1c00&&addr<=16'h1fff) cpu_din = alpha_dout;
			else if(shared_sel) cpu_din = shared_dout;
			else if(addr>=16'h4000) begin
				cpu_din = program_rom_dout;
			end
		end
	end

	always_comb begin
		peripheral_din=cpu_dout;
		nvram_cs=bus_valid&&nvram_sel; nvram_we=nvram_cs&&!rw;
		pokey_cs=bus_valid&&pokey_sel; pokey_we=pokey_cs&&!rw;
		shared_cs=bus_valid&&shared_sel;
	end
endmodule
