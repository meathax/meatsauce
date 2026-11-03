
module i2s
#(
	parameter AUDIO_DW = 16
)
(
	input      reset,
	input      clk,
	input      ce,

	output reg sclk,
	output reg lrclk,
	output reg sdata,

	input [AUDIO_DW-1:0]	left_chan,
	input [AUDIO_DW-1:0]	right_chan
);

// Keep positive-edge framing state, but launch the ADV7513-facing data and
// channel clock on the opposite MCLK edge. The receiver samples on BCLK rising;
// this preserves the I2S bit sequence while giving the pins a half-cycle setup
// and hold margin, including during reset and CE stalls.
reg lrclk_launch;
reg sdata_launch;

always @(negedge clk) begin
	lrclk <= lrclk_launch;
	sdata <= sdata_launch;
end

always @(posedge clk) begin
	reg  [7:0] bit_cnt;
	reg msclk;

	reg [AUDIO_DW-1:0] left;
	reg [AUDIO_DW-1:0] right;

	if (reset) begin
		bit_cnt <= 1;
		lrclk_launch <= 1;
		sclk    <= 1;
		msclk   <= 1;
		sdata_launch <= 0;
		left <= 0;
		right <= 0;
	end
	else begin
		sclk <= msclk;
		if(ce) begin
			msclk <= ~msclk;
			if(msclk) begin
				if(bit_cnt >= AUDIO_DW) begin
					bit_cnt <= 1;
					lrclk_launch <= ~lrclk_launch;
					if(lrclk_launch) begin
						left  <= left_chan;
						right <= right_chan;
					end
				end
				else begin
					bit_cnt <= bit_cnt + 1'd1;
				end
				sdata_launch <= lrclk_launch ? right[AUDIO_DW - bit_cnt] : left[AUDIO_DW - bit_cnt];
			end
		end
	end
end

endmodule
