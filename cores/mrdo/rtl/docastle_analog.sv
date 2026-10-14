//============================================================================
// Signed MiSTer analog-stick to active-high digital directions.
// X is bits 7:0, Y is bits 15:8. Hysteresis prevents threshold chatter.
//============================================================================
module docastle_analog
(
	input         clk,
	input         reset,
	input  [15:0] analog,
	output reg    right,
	output reg    left,
	output reg    down,
	output reg    up
);

wire signed [7:0] axis_x = analog[7:0];
wire signed [7:0] axis_y = analog[15:8];

always @(posedge clk) begin
	if (reset) begin
		right <= 0;
		left <= 0;
		down <= 0;
		up <= 0;
	end else begin
		if (axis_x >= 8'sd32) begin
			right <= 1;
			left <= 0;
		end else if (axis_x <= -8'sd32) begin
			right <= 0;
			left <= 1;
		end else begin
			if (right && (axis_x <= 8'sd20)) right <= 0;
			if (left && (axis_x >= -8'sd20)) left <= 0;
		end

		if (axis_y >= 8'sd32) begin
			down <= 1;
			up <= 0;
		end else if (axis_y <= -8'sd32) begin
			down <= 0;
			up <= 1;
		end else begin
			if (down && (axis_y <= 8'sd20)) down <= 0;
			if (up && (axis_y >= -8'sd20)) up <= 0;
		end
	end
end

endmodule
