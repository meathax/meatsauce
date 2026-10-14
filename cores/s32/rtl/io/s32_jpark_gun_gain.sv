// Jurassic Park's game-facing gun ADC range is half the normalized host span.
// Keep the transform after source selection so analog sticks and GunCon use
// the same calibration, while the disabled path is a literal Alien 3 bypass.
module s32_jpark_gun_gain (
    input        enable,
    input  [7:0] p1_x_in,
    input  [7:0] p1_y_in,
    input  [7:0] p2_x_in,
    input  [7:0] p2_y_in,
    output [7:0] p1_x_out,
    output [7:0] p1_y_out,
    output [7:0] p2_x_out,
    output [7:0] p2_y_out
);

function automatic [7:0] centered_half(input [7:0] value);
    logic signed [8:0] delta;
    logic signed [9:0] scaled;
begin
    delta = $signed({1'b0, value}) - 9'sd128;
    scaled = 10'sd128 + (delta >>> 1);
    centered_half = scaled[7:0];
end
endfunction

assign p1_x_out = enable ? centered_half(p1_x_in) : p1_x_in;
assign p1_y_out = enable ? centered_half(p1_y_in) : p1_y_in;
assign p2_x_out = enable ? centered_half(p2_x_in) : p2_x_in;
assign p2_y_out = enable ? centered_half(p2_y_in) : p2_y_in;

endmodule
