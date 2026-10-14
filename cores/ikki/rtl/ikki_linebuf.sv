//============================================================================
// 256×10 line buffer — single-write dual-port style (M10K).
// 1-cycle read latency on q (address registered).
//============================================================================
module ikki_linebuf
(
	input         clk,
	input         we,
	input   [7:0] waddr,
	input   [9:0] wdata,
	input   [7:0] raddr,
	output reg [9:0] q
);

(* ramstyle = "no_rw_check, M10K" *) reg [9:0] mem [0:255];

always @(posedge clk) begin
	if (we) mem[waddr] <= wdata;
	q <= mem[raddr];
end

endmodule
