//
// scandoubler.v
// 
// Copyright (c) 2015 Till Harbaum <till@harbaum.org> 
// Copyright (c) 2017-2021 Alexey Melnikov
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 

// TODO: Delay vsync one line

module scandoubler #(
	parameter LENGTH,
	parameter HALF_DEPTH,
	parameter HQ2X = 1,
	parameter LITE_RGB555 = 0
)
(
	// system interface
	input             clk_vid,
	input             hq2x,

	// shifter video interface
	input             ce_pix,
	input             hs_in,
	input             vs_in,
	input             hb_in,
	input             vb_in,
	input  [DWIDTH:0] r_in,
	input  [DWIDTH:0] g_in,
	input  [DWIDTH:0] b_in,

	// output interface
	output            ce_pix_out,
	output reg        hs_out,
	output            vs_out,
	output            hb_out,
	output            vb_out,
	output [DWIDTH:0] r_out,
	output [DWIDTH:0] g_out,
	output [DWIDTH:0] b_out
);

localparam DWIDTH = HALF_DEPTH ? 3 : 7;

reg  [7:0] pix_len = 0;
wire [7:0] pl = pix_len + 1'b1;

reg  [7:0] pix_in_cnt = 0;
wire [7:0] pc_in = pix_in_cnt + 1'b1;
reg  [7:0] pixsz, pixsz2, pixsz4 = 0;

reg ce_x4i, ce_x1i;
always @(posedge clk_vid) begin
	reg old_ce, valid, hs;

	if(~&pix_len) pix_len <= pl;
	if(~&pix_in_cnt) pix_in_cnt <= pc_in;

	if (HQ2X) ce_x4i <= 0;
	ce_x1i <= 0;

	// use such odd comparison to place ce_x4 evenly if master clock isn't multiple of 4.
	if(HQ2X && ((pc_in == pixsz4) || (pc_in == pixsz2) || (pc_in == (pixsz2+pixsz4)))) ce_x4i <= 1;

	old_ce <= ce_pix;
	if(~old_ce & ce_pix) begin
		if(valid & ~hb_in & ~vb_in) begin
			pixsz  <= pl;
			pixsz2 <= {1'b0,  pl[7:1]};
			pixsz4 <= {2'b00, pl[7:2]};
		end
		pix_len <= 0;
		valid <= 1;
	end

	hs <= hs_in;
	if((~hs & hs_in) || (pc_in >= pixsz)) begin
		if (HQ2X) ce_x4i <= 1;
		ce_x1i <= 1;
		pix_in_cnt <= 0;
	end

	if(hb_in | vb_in) valid <= 0;
end

reg req_line_reset;
reg [DWIDTH:0] r_d, g_d, b_d;
always @(posedge clk_vid) begin
	if(ce_x1i) begin
		if (HQ2X) begin
			req_line_reset <= hb_in;
			r_d <= r_in;
			g_d <= g_in;
			b_d <= b_in;
		end
	end
end

wire [DWIDTH:0] hq_r, hq_g, hq_b;
wire [DWIDTH:0] lite_r, lite_g, lite_b;
wire lite_hb;

generate
	if(HQ2X) begin : g_hq2x
		Hq2x #(.LENGTH(LENGTH), .HALF_DEPTH(HALF_DEPTH)) Hq2x
		(
			.clk(clk_vid),

			.ce_in(ce_x4i),
			.inputpixel({b_d,g_d,r_d}),
			.mono(1'b0),
			.disable_hq2x(~hq2x),
			.reset_frame(vb_in),
			.reset_line(req_line_reset),

			.ce_out(ce_x4o),
			.read_y(sd_line),
			.hblank(hbo[0]&hbo[8]),
			.outpixel({hq_b,hq_g,hq_r})
		);
		assign {b_out,g_out,r_out} = {hq_b,hq_g,hq_r};
	end
	else begin : g_lite
		// NARC already presents 512x400 RGB to MiSTer's main scaler.  Retain the
		// ordinary line doubler needed by forced-scandoubler and CRT modes, but
		// omit the optional HQ2x four-pixel work buffer. NARC's original source
		// (DIAG/DMASYS.INC and TVMCHECK.ASM) specifies five bits per R/G/B. Keep
		// 7/6/7 bits: this exactly reconstructs the native {v,v[4:2]} expansion,
		// while retaining all but 1/2/1 LSBs after optional gamma correction. At
		// exactly 512 pixels the 20-bit line still fits one M10K.
		if(LITE_RGB555) begin : g_rgb555
			wire [19:0] lite_native_color;
			scandoubler_lite_buffer #(
				.LENGTH(LENGTH), .COLOR_WIDTH(20)
			) lite
			(
				.clk(clk_vid),
				.wr_ce(ce_x1i), .hb_in(hb_in), .vb_in(vb_in),
				.pixel_in({b_in[7:1],g_in[7:2],r_in[7:1]}),
				.rd_ce(ce_x2o), .hb_timing(hbo[0]),
				.pixel_out(lite_native_color), .hb_out(lite_hb)
			);
			assign lite_r = {lite_native_color[6:0], lite_native_color[4]};
			assign lite_g = {lite_native_color[12:7], lite_native_color[11:10]};
			assign lite_b = {lite_native_color[19:13], lite_native_color[17]};
		end
		else begin : g_full_color
			scandoubler_lite_buffer #(
				.LENGTH(LENGTH), .COLOR_WIDTH(3*(DWIDTH+1))
			) lite
			(
				.clk(clk_vid),
				.wr_ce(ce_x1i), .hb_in(hb_in), .vb_in(vb_in),
				.pixel_in({b_in,g_in,r_in}),
				.rd_ce(ce_x2o), .hb_timing(hbo[0]),
				.pixel_out({lite_b,lite_g,lite_r}), .hb_out(lite_hb)
			);
		end
		assign {b_out,g_out,r_out} = {lite_b,lite_g,lite_r};
	end
endgenerate

reg  [7:0] pix_out_cnt = 0;
wire [7:0] pc_out = pix_out_cnt + 1'b1;

reg ce_x4o, ce_x2o;
always @(posedge clk_vid) begin
	reg hs;

	if(~&pix_out_cnt) pix_out_cnt <= pc_out;

	ce_x4o <= 0;
	ce_x2o <= 0;

	// use such odd comparison to place ce_x4 evenly if master clock isn't multiple of 4.
	if((pc_out == pixsz4) || (pc_out == pixsz2) || (pc_out == (pixsz2+pixsz4))) ce_x4o <= 1;
	if( pc_out == pixsz2) ce_x2o <= 1;

	hs <= hs_out;
	if((~hs & hs_out) || (pc_out >= pixsz)) begin
		ce_x2o <= 1;
		ce_x4o <= 1;
		pix_out_cnt <= 0;
	end
end

reg [1:0] sd_line;
reg [3:0] vbo;
reg [3:0] vso;
reg [8:0] hbo;
always @(posedge clk_vid) begin

	reg [31:0] hcnt;
	reg [30:0] sd_hcnt;
	reg [30:0] hs_start, hs_end;
	reg [30:0] hde_start, hde_end;

	reg hs, hb;

	if(ce_x4o) begin
		hbo[8:1] <= hbo[7:0];
	end

	// output counter synchronous to input and at twice the rate
	sd_hcnt <= sd_hcnt + 1'd1;
	if(sd_hcnt == hde_start) begin
		sd_hcnt <= 0;
		vbo[3:1] <= vbo[2:0];
	end

	if(sd_hcnt == hs_end) begin
		sd_line <= sd_line + 1'd1;
		if(&vbo[3:2]) sd_line <= 1;
		vso[3:1] <= vso[2:0];
	end

	if(sd_hcnt == hde_start)hbo[0] <= 0;
	if(sd_hcnt == hde_end)  hbo[0] <= 1;

	// replicate horizontal sync at twice the speed
	if(sd_hcnt == hs_end)   hs_out <= 0;
	if(sd_hcnt == hs_start) hs_out <= 1;

	hs <= hs_in;
	hb <= hb_in;

	hcnt <= hcnt + 1'd1;
	if(hb && !hb_in) begin
		hde_start <= hcnt[31:1];
		hbo[0] <= 0;
		hcnt <= 0;
		sd_hcnt <= 0;
		vbo <= {vbo[2:0],vb_in};
	end

	if(!hb && hb_in) hde_end <= hcnt[31:1];

	// falling edge of hsync indicates start of line
	if(hs && !hs_in) begin
		hs_end <= hcnt[31:1];
		vso[0] <= vs_in;
	end

	// save position of rising edge
	if(!hs && hs_in) hs_start <= hcnt[31:1];
end

assign vs_out = vso[3];
assign ce_pix_out = (HQ2X && hq2x) ? ce_x4o : ce_x2o;

//Compensate picture shift after HQ2x
assign vb_out = vbo[3];
assign hb_out = HQ2X ? hbo[6] : lite_hb;

endmodule

// Resource-light simple line buffer used when a core does not expose HQ2x.
// Both arrays have one synchronous read and one synchronous write port and map
// to native M10Ks.  While one bank captures the current input line, the other
// is read twice at the doubled line rate by scandoubler's existing timing FSM.
module scandoubler_lite_buffer #(parameter LENGTH, parameter COLOR_WIDTH)
(
	input                    clk,
	input                    wr_ce,
	input                    hb_in,
	input                    vb_in,
	input  [COLOR_WIDTH-1:0] pixel_in,
	input                    rd_ce,
	input                    hb_timing,
	output wire [COLOR_WIDTH-1:0] pixel_out,
	output reg               hb_out
);

localparam AWIDTH = $clog2(LENGTH);
localparam integer LAST_ADDR = LENGTH-1;
(* ramstyle = "M10K, no_rw_check" *) reg [COLOR_WIDTH-1:0] line0 [0:LENGTH-1];
(* ramstyle = "M10K, no_rw_check" *) reg [COLOR_WIDTH-1:0] line1 [0:LENGTH-1];

reg wr_bank = 0;
reg wr_hb_d = 1;
reg [AWIDTH-1:0] wr_x = 0;
reg [AWIDTH-1:0] rd_x = 0;
reg [COLOR_WIDTH-1:0] q0, q1;

always @(posedge clk) begin
	if(wr_ce) begin
		wr_hb_d <= hb_in;
		if(wr_hb_d && !hb_in) begin
			wr_bank <= ~wr_bank;
			wr_x <= 1;
			if(wr_bank) line0[0] <= pixel_in;
			else        line1[0] <= pixel_in;
		end
		else if(!hb_in && !vb_in) begin
			if(wr_bank) line1[wr_x] <= pixel_in;
			else        line0[wr_x] <= pixel_in;
			if(wr_x != LAST_ADDR[AWIDTH-1:0]) wr_x <= wr_x + 1'b1;
		end
	end

	if(rd_ce) begin
		hb_out <= hb_timing;
		if(hb_timing) rd_x <= 0;
		else if(rd_x != LAST_ADDR[AWIDTH-1:0]) rd_x <= rd_x + 1'b1;
		q0 <= line0[rd_x];
		q1 <= line1[rd_x];
	end
end

// wr_bank names the bank currently being filled; display the completed bank.
assign pixel_out = wr_bank ? q0 : q1;

endmodule
