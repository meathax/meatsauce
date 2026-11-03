// Latest-sample mono mailbox clk_sys -> CLK_AUDIO (same token scheme as donors/NARC narc_audio_cdc,
// reduced to one channel; the pair AUDIO_L/AUDIO_R is driven from the same output).
`timescale 1ns/1ps
module exterm_audio_cdc (
	input  wire               clk_sys,
	input  wire               clk_audio,
	input  wire               rst,
	input  wire signed [15:0] audio_in,
	output wire signed [15:0] audio_out
);
	reg signed [15:0] hold;
	reg               tgl;
	always @(posedge clk_sys) begin
		if (rst) begin
			hold <= 16'sd0;
			tgl  <= 1'b0;
		end else if (audio_in != hold) begin
			hold <= audio_in;
			tgl  <= ~tgl;
		end
	end

	reg signed [15:0] cdc1, cdc2;
	reg               tgl_m, tgl_q, tgl_seen;
	always @(posedge clk_audio) begin
		tgl_m <= tgl;
		tgl_q <= tgl_m;
		if (tgl_q != tgl_seen) begin
			cdc1     <= hold;
			tgl_seen <= tgl_q;
		end
		cdc2 <= cdc1;
	end
	assign audio_out = cdc2;
endmodule
