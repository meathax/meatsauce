// Asynchronous-assert / synchronous-release reset (2 flops), one per clock domain
// (mister-video-output.md black-screen item 3).
module exterm_reset_sync (
	input  clk,
	input  arst,      // async reset request, active high
	output rst        // synchronous release, active high
);
	reg [1:0] r = 2'b11;
	always @(posedge clk or posedge arst) begin
		if (arst) r <= 2'b11;
		else      r <= {r[0], 1'b0};
	end
	assign rst = r[1];
endmodule
