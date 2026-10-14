`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// SP-251 sheet 9A polygon palette. Address A0 supplies the ninth color bit;
// data and address are inverted by the physical output stages.
//
// The write strobe is decoded from the live CPU bus, exactly as the PCB does:
// the palette RAM's /WE is the $1800-$18FF address decode ANDed with R/W, so a
// cycle that is not a write into that page can never disturb the RAM.  The
// mainboard's `palette_we` is a registered decode and therefore stays asserted
// for one clock after the CPU bus has already advanced to the next cycle; on
// that trailing clock the live address is the next cycle's (normally an opcode
// fetch) and the 6809's write-data output reads back $00, which used to write
// colour $1FF/$1FE into an unrelated pen.  Re-qualifying here restores MAME's
// one-call-per-CPU-write behaviour (irobot_v.cpp:70 paletteram_w).
module irobot_palette (
	input logic cpu_clk,input logic video_clk,
	input logic reset,
	input logic cpu_we, input logic cpu_rw,
	/* verilator lint_off UNUSEDSIGNAL */ // A7 is a mirror: MAME masks the pen with &0x3f (irobot_v.cpp:82).
	input logic [15:0] cpu_addr,
	/* verilator lint_on UNUSEDSIGNAL */
	input logic [7:0] cpu_data,
	input logic [5:0] pixel_index,
	output logic [7:0] red, green, blue
);
	logic [8:0] color_ram[0:63];
	logic [8:0] color;
	logic [2:0] intensity;
	logic [1:0] rbits,gbits,bbits;
	logic [7:0] rlevel,glevel,blevel;
	logic write_enable;
	integer index;
	assign write_enable = cpu_we && !cpu_rw && (cpu_addr[15:8] == 8'h18);
	always_ff @(posedge cpu_clk) begin
		if(reset) begin
			for(index=0;index<64;index=index+1) color_ram[index] <= 9'd0;
		end else if(write_enable) color_ram[cpu_addr[6:1]] <= ~{cpu_data,cpu_addr[0]};
	end
	always_ff @(posedge video_clk) begin
		if(reset) color <= 9'd0;
		else color <= color_ram[pixel_index];
	end
	always_comb begin
		intensity=color[2:0]; bbits=color[4:3]; gbits=color[6:5]; rbits=color[8:7];
		rlevel=8'(12*rbits*intensity); glevel=8'(12*gbits*intensity); blevel=8'(12*bbits*intensity);
		red=rlevel;green=glevel;blue=blevel;
	end
endmodule
