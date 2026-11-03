// exterm_audio_dc -- DC-blocking high-pass for the core's audio (clk_sys domain, mono signed 16-bit).
//
// exterm_core.audio carries MAME's DC offset (idle -12288, attract ~ -9621).  A first-order IIR
// high-pass is evaluated at a fixed ~47.96 kHz tick (20 MHz / 417), independent of how often the
// sound board updates the sample (the latest value is held):
//     dc  += (x - dc) / 2^K      y = x - dc          K = 10  ->  fc = fs / (2*pi*2^K) = 7.5 Hz
// (same idea as the sys/audio_out DC_blocker).  Output is saturated to 16 bit; measured on
// sim/snd/out/exterm_sound.wav the post-filter peak is -22288 / +16507 (no clipping); the raw core
// signal itself already hits -32768, so headroom comes from removing the offset, not from scaling.
// No decimation / low-pass is added: the held 48 kHz stream goes straight to the 48 kHz-class I2S/DAC path.
module exterm_audio_dc #(parameter K = 10) (
	input                    clk,
	input                    rst,
	input  signed     [15:0] din,
	output reg signed [15:0] dout
);
	reg [8:0] tcnt = 9'd0;
	wire      tick = (tcnt == 9'd416);
	always @(posedge clk) tcnt <= tick ? 9'd0 : tcnt + 9'd1;

	// dc estimate with K fractional bits
	reg signed [16+K-1:0] dc = 0;
	wire signed [16:0]    y  = {din[15], din} - {dc[16+K-1], dc[16+K-1:K]};

	always @(posedge clk) begin
		if (rst) begin
			dc   <= 0;
			dout <= 16'sd0;
		end
		else if (tick) begin
			dc   <= dc + {{(K){din[15]}}, din} - {{(K){dc[16+K-1]}}, dc[16+K-1:K]};   // dc += x - dc/2^K  (dc is scaled by 2^K)
			dout <= (y > 17'sd32767) ? 16'sh7FFF : (y < -17'sd32768) ? 16'sh8000 : y[15:0];
		end
	end
endmodule
