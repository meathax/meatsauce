// Action Hollywood video RAM primitives (altsyncram-inferable, single clock)

// CPU port (read/write, byte enables, registered read) + render read port. Read-first on port A.
module ah_vid_cpuram #(parameter AW = 13) (
	input  wire          clk,
	input  wire [AW-1:0] a_addr,
	input  wire [15:0]   a_din,
	input  wire          a_we_h,
	input  wire          a_we_l,
	output reg  [15:0]   a_dout,
	input  wire [AW-1:0] b_addr,
	output reg  [15:0]   b_dout
);
	reg [7:0] mh [0:(1<<AW)-1];
	reg [7:0] ml [0:(1<<AW)-1];
	always @(posedge clk) begin
		if (a_we_h) mh[a_addr] <= a_din[15:8];
		a_dout[15:8] <= mh[a_addr];
		b_dout[15:8] <= mh[b_addr];
	end
	always @(posedge clk) begin
		if (a_we_l) ml[a_addr] <= a_din[7:0];
		a_dout[7:0] <= ml[a_addr];
		b_dout[7:0] <= ml[b_addr];
	end
endmodule

// simple dual port: one write port, one registered read port
module ah_vid_sdp #(parameter AW = 7, parameter DW = 68) (
	input  wire          clk,
	input  wire          we,
	input  wire [AW-1:0] wa,
	input  wire [DW-1:0] wd,
	input  wire [AW-1:0] ra,
	output reg  [DW-1:0] rq
);
	reg [DW-1:0] m [0:(1<<AW)-1];
	always @(posedge clk) begin
		if (we) m[wa] <= wd;
		rq <= m[ra];
	end
endmodule
