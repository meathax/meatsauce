//============================================================================
// PCB output-stage approximation derived from the 8302 audio schematic.
// Four equal 1.5k PSG feeds are already summed upstream. This stage models the
// AC-coupled MB3730 path at 48 kHz: a near-DC blocking pole and the measured/
// speaker-safe high-frequency roll-off, while retaining ample headroom.
//============================================================================
module docastle_audio_filter
(
	input clk, input reset, input enable,
	input signed [15:0] sample_in,
	output signed [15:0] sample_out
);

// 49.152 MHz / 1024 = 48 kHz.
reg [9:0] div;
wire ce_audio = &div;
reg signed [31:0] x_prev, hp_state, lp_state;
reg signed [15:0] result;
// Box-average every clk sample of the 1024-clk output period so the PSG's
// ~250 kHz stream is decimated to 48 kHz without aliasing.
reg signed [31:0] acc;
wire signed [31:0] acc_next = acc + {{16{sample_in[15]}},sample_in};
wire signed [31:0] x_extended = acc_next >>> 10;
reg [2:0] filter_step;
reg signed [31:0] hp_delta_pipe, hp_next_pipe, lp_delta_pipe, lp_next_pipe;
reg signed [63:0] hp_product_pipe, lp_product_pipe;

always @(posedge clk) begin
	if (reset) begin
		div <= 0; filter_step <= 0; acc <= 0;
		x_prev <= 0; hp_state <= 0; lp_state <= 0; result <= 0;
		hp_delta_pipe <= 0; hp_product_pipe <= 0; hp_next_pipe <= 0;
		lp_delta_pipe <= 0; lp_product_pipe <= 0; lp_next_pipe <= 0;
	end else begin
		div <= div + 1'd1;
		acc <= ce_audio ? 32'sd0 : acc_next;
		// The complete IIR update still occurs once per 48 kHz sample.  Breaking
		// its two multiplies and clamp into short stages avoids a false need for
		// all of that arithmetic to settle in one 49.152 MHz clock period.
		if (ce_audio && filter_step == 0) begin
			x_prev <= x_extended;
			hp_delta_pipe <= x_extended - x_prev;
			hp_product_pipe <= hp_state * 32'sd65523; // 1.5 Hz HP pole, Q16
			filter_step <= 1;
		end else begin
			case (filter_step)
			3'd1: begin
				hp_next_pipe <= hp_delta_pipe + $signed(hp_product_pipe[47:16]);
				filter_step <= 2;
			end
			3'd2: begin
				lp_delta_pipe <= hp_next_pipe - lp_state;
				filter_step <= 3;
			end
			3'd3: begin
				lp_product_pipe <= lp_delta_pipe * 32'sd51911; // about 12 kHz LP, Q16
				filter_step <= 4;
			end
			3'd4: begin
				lp_next_pipe <= lp_state + $signed(lp_product_pipe[47:16]);
				hp_state <= hp_next_pipe;
				filter_step <= 5;
			end
			3'd5: begin
				lp_state <= lp_next_pipe;
				if (lp_next_pipe > 32'sd32767) result <= 16'sh7fff;
				else if (lp_next_pipe < -32'sd32768) result <= -16'sd32768;
				else result <= lp_next_pipe[15:0];
				filter_step <= 0;
			end
			default: filter_step <= 0;
			endcase
		end
	end
end
assign sample_out = enable ? result : sample_in;
endmodule
