// System 24 page-15 output RC: 47 kohm in parallel with 220 pF.
// IKAOPM measures 62.5 kHz per channel, so for fc=15392.16 Hz:
// alpha=1-exp(-2*pi*fc/fs)=0.7871970581, represented as Q1.17 103179.
module s24_audio_lpf (
    input  logic               clk,
    input  logic               reset,
    input  logic               sample_strobe,
    input  logic signed [15:0] sample_in,
    output logic signed [15:0] sample_out
);
    localparam logic signed [17:0] ALPHA_Q17 = 18'sd103179;
    logic signed [16:0] error;
    logic signed [34:0] correction;
    logic signed [17:0] correction_scaled;
    logic signed [17:0] next_sample;

    always_comb begin
        error = $signed({sample_in[15],sample_in}) -
                $signed({sample_out[15],sample_out});
        correction = error * ALPHA_Q17;
        correction_scaled = correction[34:17];
        next_sample = $signed({{2{sample_out[15]}},sample_out}) +
                      correction_scaled;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            sample_out <= 16'sd0;
        end else if (sample_strobe) begin
            if (next_sample > 18'sd32767)
                sample_out <= 16'sh7fff;
            else if (next_sample < -18'sd32768)
                sample_out <= 16'sh8000;
            else
                sample_out <= next_sample[15:0];
        end
    end
endmodule
