// Gaiapolis adapter. Source provenance: rtl/vendor/violent_storm_k054539/source.json
// SPDX-License-Identifier: GPL-2.0-only
// K054539 coefficient/address primitive, derived from public SiliconRE.
// Source: furrtek/SiliconRE c926ce92fdebd7613c8712b42c45a059d63548e0,
// Konami/054539/hdl/054539.v:906-970, 1368-1424, 1809-1833.
// ROM data/provenance/license: k054539_romb.hex / k054539_roms.LICENSE.
// This block describes coefficients, not an assumed ordering of gain stages.
module gaiapolis_k054539_gain (
    input [7:0] volume,
    input [7:0] channel_control,
    input [6:0] global_228,
    input [6:0] global_229,
    input [6:0] global_22a,
    input [6:0] global_22b,
    input [7:0] pan,
    input [7:0] effect_volume,
    input       fixed_pan,
    output [1:0] global_select,
    output signed [15:0] volume_coefficient,
    output signed [15:0] global_coefficient,
    output signed [15:0] main_left_coefficient,
    output signed [15:0] main_right_coefficient,
    output signed [15:0] effect_left_coefficient,
    output signed [15:0] effect_right_coefficient,
    output signed [15:0] effect_a_coefficient,
    output signed [15:0] effect_b_coefficient
);

reg [15:0] coefficients [0:255];
initial $readmemh("rtl/vendor/violent_storm_k054539/k054539_romb.hex", coefficients);

// The public behavioral HDL loses a selector inversion. Physical sheets14/18:
// the two MUX41N levels preserve CTRL, AB119/121 invert it, and AK43..49
// reverse D0..D3 (22B..228). Those last two operations cancel. The preset
// LATCHN.NQ and MUX41N.Z also cancel their DATA polarity inversions.
// Effective software mapping: CTRL00/01/10/11 -> 228/229/22A/22B.
// See evidence/gaiapolis_pause_pcm-sfx-20261004 for the independent gate-path oracle.
assign global_select = channel_control[1:0];
reg [6:0] global_index;
always @* begin
    case (global_select)
        2'd0: global_index = global_228;
        2'd1: global_index = global_229;
        2'd2: global_index = global_22a;
        default: global_index = global_22b;
    endcase
end

// CLKDIV[2:1] = 01/10 selects the main (low-nibble) pan;
// 00/11 selects the effects (high-nibble) pan. CLKDIV[1] chooses
// the forward/reverse curve. It does not select the pan nibble.
wire [3:0] main_pan = fixed_pan ? 4'd8 : pan[3:0];
wire [3:0] effect_pan = fixed_pan ? 4'd8 : pan[7:4];
wire main_left_negative = !fixed_pan && !channel_control[7];
wire main_right_negative = !fixed_pan && !channel_control[6];
wire [7:0] main_left_index = {2'b10, main_left_negative, 1'b0, main_pan};
wire [7:0] main_right_index = {2'b10, main_right_negative, 1'b1, main_pan};
wire [7:0] effect_left_index = {4'b1000, effect_pan};
wire [7:0] effect_right_index = {4'b1001, effect_pan};

assign volume_coefficient = coefficients[{1'b0, volume[6:0]}];
assign global_coefficient = coefficients[{1'b0, global_index}];
assign main_left_coefficient = coefficients[main_left_index];
assign main_right_coefficient = coefficients[main_right_index];
assign effect_left_coefficient = coefficients[effect_left_index];
assign effect_right_coefficient = coefficients[effect_right_index];
assign effect_a_coefficient = coefficients[{1'b0, effect_volume[3:0], 3'b111}];
// Physical AJ81/AP40 preserve RVVOL bit7; both sends use four-bit nibbles.
// The public HDL's RAMB_DO[6:0] capture omits that connected physical bit.
assign effect_b_coefficient = coefficients[{1'b0, effect_volume[7:4], 3'b111}];
endmodule

// Main voice contribution, in the chip's fixed-width arithmetic domain.
// Coefficients come from gaiapolis_k054539_gain; this separates register
// routing from the multiplier sequence so a slot controller can retain
// the original coefficient/sample latch timing.
//
// Physical/source reconciliation: AS70 is NOR3, not the public HDL's OR3;
// MUXC_PRE_B clocks !SRA5 and PRE_C !SRA1. The corrected public gain probe
// confirms volume -> global -> main pan. Each product keeps bits31:16.
// The final arithmetic half plus bit0 is ACCE's ceil-half contribution.
// Signed multiplication is required by the dumped negative pan banks;
// final six-accumulator destination/timing is outside this primitive.
module gaiapolis_k054539_voice_gain (
    input  signed [15:0] sample,
    input  signed [15:0] volume_coefficient,
    input  signed [15:0] global_coefficient,
    input  signed [15:0] left_coefficient,
    input  signed [15:0] right_coefficient,
    output signed [15:0] after_volume,
    output signed [15:0] after_global,
    output signed [15:0] left_product,
    output signed [15:0] right_product,
    output signed [15:0] left_contribution,
    output signed [15:0] right_contribution
);
    gaiapolis_k054539_mulb volume_stage (
        .sample(sample), .coefficient(volume_coefficient),
        .value(after_volume), .rounded_half(), .unsigned_value()
    );
    gaiapolis_k054539_mulb global_stage (
        .sample(after_volume), .coefficient(global_coefficient),
        .value(after_global), .rounded_half(), .unsigned_value()
    );
    gaiapolis_k054539_mulb left_stage (
        .sample(after_global), .coefficient(left_coefficient),
        .value(left_product), .rounded_half(left_contribution), .unsigned_value()
    );
    gaiapolis_k054539_mulb right_stage (
        .sample(after_global), .coefficient(right_coefficient),
        .value(right_product), .rounded_half(right_contribution), .unsigned_value()
    );
endmodule

// Physical MULB extraction is product[31:16], followed in ACCE by a
// rounded arithmetic half. The signed interpretation is a documented
// inference from negative pan coefficients; the raw unsigned output is
// retained explicitly for comparison with the public HDL transcription.
module gaiapolis_k054539_mulb (
    input signed [15:0] sample,
    input signed [15:0] coefficient,
    output signed [15:0] value,
    output signed [15:0] rounded_half,
    output [15:0] unsigned_value
);
wire signed [31:0] product = sample * coefficient;
wire [31:0] unsigned_product = $unsigned(sample) * $unsigned(coefficient);
assign value = product[31:16];
assign unsigned_value = unsigned_product[31:16];
assign rounded_half = $signed({value[15], value[15:1]}) +
                      $signed({15'd0, value[0]});
endmodule
