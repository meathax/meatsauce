// SPDX-License-Identifier: GPL-3.0-or-later
// Decode one 16-pixel row from SSV's four paired-bitplane ROM quarters.
`timescale 1ns/1ps

module ssv_gfx_row_decode (
    input  logic [31:0] plane01,
    input  logic [31:0] plane23,
    input  logic [31:0] plane45,
    input  logic [31:0] plane67,
    input  logic  [2:0] gfx_mode,
    input  logic        flip_x,
    output logic [127:0] pens
);

logic [7:0] decoded [0:15];
logic [7:0] masked;
integer x;
integer source_x;

function automatic logic pair_bit(
    input logic [31:0] row,
    input integer      pixel,
    input integer      plane_in_pair
);
    integer row_byte;
    integer row_bit;
    begin
        row_byte = ((pixel >> 3) << 1) + plane_in_pair;
        row_bit  = 7 - (pixel & 7);
        pair_bit = row[row_byte * 8 + row_bit];
    end
endfunction

always_comb begin
    for (x = 0; x < 16; x = x + 1) begin
        decoded[x] = {
            pair_bit(plane67, x, 1), pair_bit(plane67, x, 0),
            pair_bit(plane45, x, 1), pair_bit(plane45, x, 0),
            pair_bit(plane23, x, 1), pair_bit(plane23, x, 0),
            pair_bit(plane01, x, 1), pair_bit(plane01, x, 0)
        };
    end

    pens = '0;
    for (x = 0; x < 16; x = x + 1) begin
        source_x = flip_x ? (15 - x) : x;
        unique case (gfx_mode)
            3'd0, 3'd2, 3'd6: masked = decoded[source_x] & 8'h3f;
            3'd4:             masked = decoded[source_x] & 8'h0f;
            3'd5:             masked = (decoded[source_x] & 8'hf0) >> 4;
            default:          masked = decoded[source_x];
        endcase
        pens[x * 8 +: 8] = masked;
    end
end

endmodule
