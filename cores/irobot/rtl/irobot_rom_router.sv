`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Routes the locked index-0 MRA stream directly to each hardware subsystem.
// No program/PROM contents are retained in this glue block.
module irobot_rom_router (
	input logic clk,input logic reset,input logic rom_download,input logic ioctl_wr,
	input logic[24:0]ioctl_addr,input logic[7:0]ioctl_data,
	output logic cpu_we,output logic[16:0]cpu_addr,output logic[7:0]cpu_data,
	output logic object_we,output logic[15:0]object_addr,output logic[7:0]object_data,
	output logic alpha_we,output logic[10:0]alpha_addr,output logic[7:0]alpha_data,
	output logic color_we,output logic[4:0]color_addr,output logic[7:0]color_data,
	output logic micro_we,output logic[9:0]micro_word_addr,
	output logic[3:0]micro_plane,output logic[3:0]micro_nibble,
	// Cyclone V configuration initializes this shell-level media-residency
	// latch before the first HPS transfer. It has one sequential writer below.
	/* verilator lint_off PROCASSINIT */
	output logic loaded = 1'b0
	/* verilator lint_on PROCASSINIT */
);
	logic[13:0]offset;
	logic[15:0]object_stream_offset;
	logic download_prev;
	// This is media-residency state, not board reset state. Configuration gives
	// the latch a deterministic empty value; ordinary reset and the index-254
	// DIP transfer must leave the already-downloaded EPROM image resident.
	always_comb offset=ioctl_addr[13:0]-14'h2820;
	always_comb object_stream_offset=ioctl_addr[15:0]-16'h6000;
	always_ff @(posedge clk)begin
		cpu_we<=0;object_we<=0;alpha_we<=0;color_we<=0;micro_we<=0;
		// MiSTer asserts reset while the ROM stream is being downloaded. The
		// board memories must still accept that stream. Clear the completion latch
		// once per new ROM download, then retain it across board/DIP resets after
		// the final byte so the CPU can leave reset when rom_download drops.
		if (reset && !rom_download) begin
			// A board/DIP reset may re-arm the download edge detector, but the
			// resident ROM image remains populated just like physical EPROMs.
			download_prev <= 1'b0;
		end else if (!rom_download) begin
			download_prev <= 1'b0;
		end else begin
			if (!download_prev) loaded <= 1'b0;
			download_prev <= 1'b1;
		end
		if(ioctl_wr)begin
			if(ioctl_addr<25'h16000)begin cpu_we<=1;cpu_addr<=ioctl_addr[16:0];cpu_data<=ioctl_data;end
			else if(ioctl_addr<25'h22000)begin
				// The four math/object ROM chips occupy the contiguous stream
				// interval 0x16000..0x21fff.  Keep the subtraction explicit
				// rather than depending on truncation of the 25-bit address to
				// 16 bits (which obscures the loader ABI and is easy to break).
				object_we<=1;object_addr<=object_stream_offset[15:0];object_data<=ioctl_data;
			end
			else if(ioctl_addr<25'h22800)begin alpha_we<=1;alpha_addr<=ioctl_addr[10:0];alpha_data<=ioctl_data;end
			else if(ioctl_addr<25'h22820)begin color_we<=1;color_addr<=ioctl_addr[4:0];color_data<=ioctl_data;end
			else if(ioctl_addr<25'h25c20)begin
				micro_we<=1;micro_word_addr<=offset[9:0];micro_plane<=offset[13:10];micro_nibble<=ioctl_data[3:0];
			end
			if(ioctl_addr==25'h25c1f)loaded<=1;
		end
	end
endmodule
