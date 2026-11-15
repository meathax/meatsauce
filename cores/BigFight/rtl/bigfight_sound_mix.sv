// Exact for signed16 YM and signed14 OKI inputs; no latency or cadence change.
module bigfight_sound_mix (
    input logic signed [15:0] ym_left, ym_right,
    input logic signed [13:0] oki_mono,
    output logic signed [17:0] mixed_left, mixed_right
);
    wire signed [23:0] numerator_left = $signed(ym_left)*24'sd9 + $signed(oki_mono)*24'sd240;
    wire signed [23:0] numerator_right = $signed(ym_right)*24'sd9 + $signed(oki_mono)*24'sd240;

    function automatic signed [17:0] divide_twenty(input signed [23:0] numerator);
        reg [21:0] magnitude;
        reg [19:0] quarter;
        reg [39:0] product;
        reg signed [17:0] quotient;
        begin
            // n is in [-2260992,2260743], so magnitude fits22 and u<=565248.
            // 5*838861=2^22+1. Its error u/(5*2^22)<0.027<1/5
            // cannot cross an integer boundary of u/5. Divide magnitude by4
            // before5, then restore sign to retain truncation toward zero.
            magnitude = numerator[23] ? -numerator : numerator;
            quarter = magnitude[21:2];
            product = quarter * 20'd838861;
            quotient = $signed(product[39:22]);
            divide_twenty = numerator[23] ? -quotient : quotient;
        end
    endfunction
    assign mixed_left = divide_twenty(numerator_left);
    assign mixed_right = divide_twenty(numerator_right);
endmodule
