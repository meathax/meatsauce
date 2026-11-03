// SPDX-License-Identifier: GPL-3.0-or-later
// Audio smoothing: ah_sound holds each OKI sample (7.576 kHz zero-order hold).  Two cascaded one-pole low-pass
// stages at 48 kHz (y += (x-y)*3/8, fc ~ 3.9 kHz each) remove the hold images above the OKI band.
module ah_audio(
    input  wire clk, rst, bypass,
    input  wire signed [15:0] in,
    output wire signed [15:0] out
);
    reg [9:0] div;
    wire ce = (div == 10'd999);                     // clk / 1000 = 47.95 kHz
    reg signed [19:0] y1, y2;
    wire signed [19:0] x = {{4{in[15]}}, in};
    wire signed [19:0] d1 = x - y1, d2 = y1 - y2;
    always @(posedge clk) begin
        div <= ce ? 10'd0 : div + 10'd1;
        if (rst) begin y1 <= 0; y2 <= 0; end
        else if (ce) begin
            y1 <= y1 + ((d1 * 3) >>> 3);
            y2 <= y2 + ((d2 * 3) >>> 3);
        end
    end
    reg signed [15:0] filt;
    always @(posedge clk) if (ce) filt <= y2[15:0];
    assign out = bypass ? in : filt;
endmodule
