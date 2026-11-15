//
// snk_scandoubler.sv - core-local copy of MiSTer sys/scandoubler.v without HQ2x (hq2x is permanently 0 in this core).
// Original: Copyright (c) 2015 Till Harbaum <till@harbaum.org>, (c) 2017-2021 Alexey Melnikov, GPL-3.0-or-later.
//
// The timing/ce/hs/vs/blank logic is a verbatim copy of sys/scandoubler.v. Only the Hq2x instance is replaced by
// snk_linedbl: with disable_hq2x=1 the HQ2x pipeline reduces to "centre pixel, delayed by one line and two pixels,
// replicated into the four 2x2 sub-pixels", so its blend/diff logic, the 3-line window and the 96-bit-wide output
// buffer (hq2x_buf, 123,840 bits) are not needed. The `hq2x` port is kept for interface compatibility and ignored.
//
module snk_scandoubler #(parameter LENGTH, parameter HALF_DEPTH)
(
	input             clk_vid,
	input             hq2x,       // ignored: HQ2x removed, behaves as hq2x=0

	input             ce_pix,
	input             hs_in,
	input             vs_in,
	input             hb_in,
	input             vb_in,
	input  [DWIDTH:0] r_in,
	input  [DWIDTH:0] g_in,
	input  [DWIDTH:0] b_in,

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

	ce_x4i <= 0;
	ce_x1i <= 0;

	if((pc_in == pixsz4) || (pc_in == pixsz2) || (pc_in == (pixsz2+pixsz4))) ce_x4i <= 1;

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
		ce_x4i <= 1;
		ce_x1i <= 1;
		pix_in_cnt <= 0;
	end

	if(hb_in | vb_in) valid <= 0;
end

reg req_line_reset;
reg [DWIDTH:0] r_d, g_d, b_d;
always @(posedge clk_vid) begin
	if(ce_x1i) begin
		req_line_reset <= hb_in;
		r_d <= r_in;
		g_d <= g_in;
		b_d <= b_in;
	end
end

reg ce_x4o, ce_x2o;
reg [1:0] sd_line;
reg [3:0] vbo;
reg [3:0] vso;
reg [8:0] hbo;

snk_linedbl #(.LENGTH(LENGTH), .HALF_DEPTH(HALF_DEPTH)) linedbl
(
	.clk(clk_vid),

	.ce_in(ce_x4i),
	.inputpixel({b_d,g_d,r_d}),
	.reset_frame(vb_in),
	.reset_line(req_line_reset),

	.ce_out(ce_x4o),
	.read_y(sd_line),
	.hblank(hbo[0]&hbo[8]),
	.outpixel({b_out,g_out,r_out})
);

reg  [7:0] pix_out_cnt = 0;
wire [7:0] pc_out = pix_out_cnt + 1'b1;

always @(posedge clk_vid) begin
	reg hs;

	if(~&pix_out_cnt) pix_out_cnt <= pc_out;

	ce_x4o <= 0;
	ce_x2o <= 0;

	if((pc_out == pixsz4) || (pc_out == pixsz2) || (pc_out == (pixsz2+pixsz4))) ce_x4o <= 1;
	if( pc_out == pixsz2) ce_x2o <= 1;

	hs <= hs_out;
	if((~hs & hs_out) || (pc_out >= pixsz)) begin
		ce_x2o <= 1;
		ce_x4o <= 1;
		pix_out_cnt <= 0;
	end
end

always @(posedge clk_vid) begin

	reg [31:0] hcnt;
	reg [30:0] sd_hcnt;
	reg [30:0] hs_start, hs_end;
	reg [30:0] hde_start, hde_end;

	reg hs, hb;

	if(ce_x4o) begin
		hbo[8:1] <= hbo[7:0];
	end

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

	if(hs && !hs_in) begin
		hs_end <= hcnt[31:1];
		vso[0] <= vs_in;
	end

	if(!hs && hs_in) hs_start <= hcnt[31:1];
end

assign vs_out = vso[3];
assign ce_pix_out = ce_x2o;

assign vb_out = vbo[3];
assign hb_out = hbo[6];

endmodule


// Plain 2x line doubler equivalent to Hq2x with disable_hq2x=1 (same control state machine and write/read timing).
// Data path: centre pixel (Curr0) of the previous input line, 4 ce_in stages later (Hq2x blend pipeline latency),
// stored once per pixel instead of four identical sub-pixels.
module snk_linedbl #(parameter LENGTH, parameter HALF_DEPTH)
(
	input             clk,

	input             ce_in,
	input  [DWIDTH:0] inputpixel,
	input             reset_frame,
	input             reset_line,

	input             ce_out,
	input       [1:0] read_y,
	input             hblank,
	output [DWIDTH:0] outpixel
);

localparam AWIDTH = $clog2(LENGTH)-1;
localparam DWIDTH = HALF_DEPTH ? 11 : 23;

// input line buffers (ping-pong): write current input line, read previous line
reg [DWIDTH:0] inbuf0[0:LENGTH-1];
reg [DWIDTH:0] inbuf1[0:LENGTH-1];
reg [DWIDTH:0] inq0, inq1;
reg [AWIDTH:0] offs;
reg            curbuf;
reg [AWIDTH:0] wrin_addr2;
reg [DWIDTH:0] wrpix;
reg            wrin_en;
wire           iobuf = !curbuf;

always @(posedge clk) begin
	if(wrin_en && iobuf == 0) inbuf0[wrin_addr2] <= wrpix;
	inq0 <= inbuf0[offs];
end
always @(posedge clk) begin
	if(wrin_en && iobuf == 1) inbuf1[wrin_addr2] <= wrpix;
	inq1 <= inbuf1[offs];
end
wire [DWIDTH:0] Curr21 = curbuf ? inq1 : inq0;

// centre-pixel window and 4-stage ce_in delay (Hq2x: Blend 3 register stages + Result register)
reg [DWIDTH:0] Curr0, Curr1, Curr2;
reg [DWIDTH:0] d1, d2, d3, Result;
reg [DWIDTH:0] wrdata0;               // sub-pixel 0 (cyc 0); sub-pixels 1..3 carry the same pixel

reg [AWIDTH+1:0] read_x;
reg [AWIDTH+1:0] wrout_addr;
reg              wrout_en;
reg  [1:0]       cyc;

// output line buffer: one pixel per entry, address {x/2, line parity}
reg [DWIDTH:0] outbuf[0:LENGTH*2-1];
reg [DWIDTH:0] outq;
always @(posedge clk) begin
	if(wrout_en) outbuf[wrout_addr] <= wrdata0;
	outq <= outbuf[{read_x[AWIDTH+1:1],read_y[1]}];
end

reg [DWIDTH:0] outpixel_r;
assign outpixel = outpixel_r;

always @(posedge clk) begin
	if(ce_out) begin
		if(read_x[0]) outpixel_r <= outq;
		if(~hblank & ~&read_x) read_x <= read_x + 1'd1;
		if(hblank) read_x <= 0;
	end
end

always @(posedge clk) begin
	reg old_reset_line;
	reg old_reset_frame;
	reg [3:0] wrdata_finished;
	reg [AWIDTH+1:0] waddr;

	wrout_en <= 0;
	wrin_en  <= 0;

	if(ce_in) begin
		// Blend pipeline (rule 0 = pass-through of the centre pixel)
		d1 <= Curr0; d2 <= d1; d3 <= d2; Result <= d3;

		if(cyc == 0) wrdata0 <= Result;

		wrdata_finished <= wrdata_finished << 1;
		if(wrdata_finished[3]) begin
			wrout_en <= 1;
			wrout_addr <= waddr;
		end

		if(~&offs) begin
			if (cyc == 1) begin
				Curr2 <= Curr21;
				wrpix <= inputpixel;
				wrin_addr2 <= offs;
				wrin_en <= 1;
			end

			if(cyc==3) begin
				offs <= offs + 1'd1;
				waddr <= {offs, curbuf};
				wrdata_finished[0] <= 1;
			end
		end

		if(cyc==3) begin
			Curr0 <= Curr1;
			Curr1 <= Curr2;
		end

		cyc <= cyc + 1'b1;
		if(old_reset_line && ~reset_line) begin
			old_reset_frame <= reset_frame;
			offs <= 0;
			cyc <= 0;
			curbuf <= ~curbuf;
			{Curr0, Curr1, Curr2} <= '0;
			if(old_reset_frame & ~reset_frame) begin
				curbuf <= 0;
			end
		end

		old_reset_line  <= reset_line;
	end
end

endmodule
