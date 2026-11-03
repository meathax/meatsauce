
module i2s
#(
	parameter AUDIO_DW = 16
)
(
	input      reset,
	input      clk,
	input      ce,

	output reg sclk = 0,
	output reg lrclk = 1,
	output reg sdata = 0,

	input [AUDIO_DW-1:0]	left_chan,
	input [AUDIO_DW-1:0]	right_chan
);

always @(posedge clk) begin
	reg  [7:0] bit_cnt = 1;
	reg msclk = 0;

	reg [AUDIO_DW-1:0] left = 0;
	reg [AUDIO_DW-1:0] right = 0;

	if (reset) begin
		bit_cnt <= 1;
		lrclk   <= 1;
		sclk    <= 0;
		msclk   <= 0;
		sdata   <= 0;
		left    <= 0;
		right   <= 0;
	end
	else begin
		sclk <= msclk;
		if(ce) begin
			msclk <= ~msclk;
			if(msclk) begin
				if(bit_cnt >= AUDIO_DW) begin
					bit_cnt <= 1;
					lrclk <= ~lrclk;
					if(lrclk) begin
						left  <= left_chan;
						right <= right_chan;
					end
				end
				else begin
					bit_cnt <= bit_cnt + 1'd1;
				end
				sdata <= lrclk ? right[AUDIO_DW - bit_cnt] : left[AUDIO_DW - bit_cnt];
			end
		end
	end
end

endmodule
