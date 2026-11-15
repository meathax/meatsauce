// SPDX-License-Identifier: GPL-3.0-or-later
// External Mermaid pins, following the pinned MAME 0.289 board model.
// The CPU owns its quasi-bidirectional output latches and RMW semantics.
// Raw input/DIP bytes retain physical polarity; no second inversion here.
`default_nettype none
module heavyunit_inputs (
    input  wire [1:0] input_select, // P0 latch bits 3:2
    input  wire [1:0] dip_select,   // P0 latch bits 6:5
    input  wire [7:0] system_inputs_n,
    input  wire [7:0] player1_inputs_n,
    input  wire [7:0] player2_inputs_n,
    input  wire [7:0] dsw1,
    input  wire [7:0] dsw2,
    input  wire       command_pending,
    input  wire       response_pending,
    output reg  [7:0] p2_external,
    output wire [7:0] p3_external
);
    always @* begin
        case (input_select)
            2'd0: p2_external = player1_inputs_n;
            2'd1: p2_external = player2_inputs_n;
            2'd2: p2_external = system_inputs_n;
            default: p2_external = 8'hff;
        endcase
    end
    assign p3_external = {
        dsw2[{1'b1, dip_select}], dsw2[{1'b0, dip_select}],
        dsw1[{1'b1, dip_select}], dsw1[{1'b0, dip_select}],
        response_pending, ~command_pending, 2'b00
    };
endmodule
`default_nettype wire
