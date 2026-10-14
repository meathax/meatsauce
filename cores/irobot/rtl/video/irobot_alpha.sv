`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// 32x32 alpha layer. The 2 KiB character ROM is addressed as two 64-character
// banks; cocktail flip selects A10, ALPHAMAP selects the color-PROM map.
module irobot_alpha (
	input logic cpu_clk,input logic loader_clk,input logic video_clk,
	input logic cpu_we, input logic [9:0] cpu_addr, input logic [7:0] cpu_din,
	output logic [7:0] cpu_dout,
	input logic char_we, input logic [10:0] char_addr, input logic [7:0] char_din,
	input logic prom_we, input logic [4:0] prom_addr, input logic [7:0] prom_din,
	input logic alphamap, input logic cocktail_flip, input logic [7:0] hpos, vpos,
	output logic opaque, output logic [7:0] red, green, blue
);
	logic [2:0] h_q, v_q;
	wire [10:0] glyph_addr;
	logic [1:0] glyph_bit_q, tile_color_q;
	logic map_q0, map_q1, flip_q0;
	wire [4:0] color_addr;
	logic pixel_q;
	logic [7:0] alpha_pixel_data, alpha_cpu_data, char_rom_data, color_prom_data;
	`ifndef IROBOT_QUARTUS
	(* ramstyle="M10K, no_rw_check" *) logic [7:0] alpha_ram[0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [7:0] char_rom[0:2047];
	(* ramstyle="M10K, no_rw_check" *) logic [7:0] color_prom[0:31];
	integer alpha_powerup_addr;
	initial begin
		for(alpha_powerup_addr=0;alpha_powerup_addr<1024;alpha_powerup_addr=alpha_powerup_addr+1)
			alpha_ram[alpha_powerup_addr]=8'd0;
	end
	`endif
	wire [9:0] tile_addr={vpos[7:3],hpos[7:3]};

	`ifdef IROBOT_QUARTUS
	irobot_async_byte_ram_dualclock #(.ADDR_WIDTH(10), .NUM_WORDS(1024)) alpha_ram (
		.rd_clk(video_clk), .rd_addr(tile_addr),
		.wr_clk(cpu_clk), .wr_addr(cpu_addr), .wr_data(cpu_din), .wr_en(cpu_we),
		.rd_data(alpha_pixel_data), .wr_rd_data(alpha_cpu_data)
	);
	irobot_async_byte_ram_dualclock #(.ADDR_WIDTH(11), .NUM_WORDS(2048)) char_rom (
		.rd_clk(video_clk), .rd_addr(glyph_addr),
		.wr_clk(loader_clk), .wr_addr(char_addr), .wr_data(char_din),
		.wr_en(char_we), .rd_data(char_rom_data)
	);
	irobot_async_byte_ram_dualclock #(.ADDR_WIDTH(5), .NUM_WORDS(32)) color_prom (
		.rd_clk(video_clk), .rd_addr(color_addr),
		.wr_clk(loader_clk), .wr_addr(prom_addr), .wr_data(prom_din),
		.wr_en(prom_we), .rd_data(color_prom_data)
	);
	`else
	always_ff @(posedge video_clk) begin
		alpha_pixel_data <= alpha_ram[tile_addr];
		char_rom_data <= char_rom[glyph_addr];
		color_prom_data <= color_prom[color_addr];
	end
	always_ff @(posedge cpu_clk) alpha_cpu_data <= alpha_ram[cpu_addr];
	`endif

	// Both M10K ports require a read-clock edge.
	assign cpu_dout = alpha_cpu_data;

	`ifndef IROBOT_QUARTUS
	always_ff @(posedge cpu_clk) if(cpu_we) alpha_ram[cpu_addr] <= cpu_din;
	`endif
	always_ff @(posedge loader_clk) begin
		`ifndef IROBOT_QUARTUS
		if(char_we) char_rom[char_addr]<=char_din;
		if(prom_we) color_prom[prom_addr]<=prom_din;
		`endif
	end

	assign glyph_addr = {flip_q0,alpha_pixel_data[5:0],v_q,h_q[2]};
	assign color_addr = {map_q1,1'b0,char_rom_data[3'd3-{1'b0,glyph_bit_q}],tile_color_q[0],tile_color_q[1]};

	always_ff @(posedge video_clk) begin
		// Three synchronous reads finish before the fourth-clock pixel strobe.
		h_q          <= hpos[2:0];
		v_q          <= vpos[2:0];
		map_q0       <= alphamap;
		flip_q0      <= cocktail_flip;

		glyph_bit_q  <= h_q[1:0];
		tile_color_q <= alpha_pixel_data[7:6];
		map_q1       <= map_q0;

		pixel_q      <= char_rom_data[3'd3-{1'b0,glyph_bit_q}];
	end

	always_comb begin
		opaque = pixel_q;
		red   = 8'(28*color_prom_data[7:6]*color_prom_data[1:0]);
		green = 8'(28*color_prom_data[5:4]*color_prom_data[1:0]);
		blue  = 8'(28*color_prom_data[3:2]*color_prom_data[1:0]);
	end
endmodule
