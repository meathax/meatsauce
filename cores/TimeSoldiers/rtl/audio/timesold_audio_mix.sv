// Keep the YM2203 FM and unsigned PSG outputs separate until the final mix.
// jt03's signed16 combined output wraps when FM + (PSG << 5) exceeds 32767.
module timesold_audio_mix(
    input wire signed [15:0] fm, opll, dac,
    input wire [9:0] psg,
    output wire [15:0] sample
);
    wire signed [17:0] fm_wide={{2{fm[15]}},fm};
    wire signed [17:0] opll_wide={{2{opll[15]}},opll};
    wire signed [17:0] dac_wide={{2{dac[15]}},dac};
    wire signed [17:0] psg_wide={3'b000,psg,5'b00000};
    wire signed [17:0] mixed=fm_wide+opll_wide+dac_wide+psg_wide;
    // All legal inputs fit: -98304..131037, /4 = -24576..32759.
    // One final division leaves headroom for all four contributors.
    assign sample=mixed[17:2];
endmodule
