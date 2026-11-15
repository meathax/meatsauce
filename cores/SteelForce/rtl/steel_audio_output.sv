// Board-owned normalization: MAME OKI mix / 2048 at unit speaker gain.
// Input is at the OKI accumulator scale (14-bit range; the interpolator may overshoot it, hence 16 bits).
// Preserve all voice accumulator bits; clip only at the signed DAC output.
module steel_audio_output(
    input wire signed [15:0] pcm,
    input wire [1:0] gain,
    output reg signed [15:0] pcm16
);
    reg signed [19:0] scaled;
    always @* begin
        case (gain)
            2'd0: scaled = $signed({pcm,4'b0});
            2'd1: scaled = $signed({pcm[15],pcm,3'b0});
            2'd2: scaled = $signed({{2{pcm[15]}},pcm,2'b0});
            default: scaled = 20'sd0;
        endcase
        if (scaled > 20'sd32767) pcm16 = 16'sh7fff;
        else if (scaled < -20'sd32768) pcm16 = 16'sh8000;
        else pcm16 = scaled[15:0];
    end
endmodule
