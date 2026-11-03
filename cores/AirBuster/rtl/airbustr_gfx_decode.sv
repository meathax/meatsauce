// SPDX-License-Identifier: GPL-3.0-or-later
// Packed Kaneko gfx_8x8x4_row_2x2_group_packed_msb.
// Address is aligned to eight bytes: one quadrant, two adjacent rows.
module airbustr_gfx_decode (
    input logic [13:0] code,
    input logic [3:0] x, y,
    input logic [63:0] data,
    output logic [20:0] address,
    output logic [3:0] pen
);
    logic [7:0] byte_data;
    assign address = {code,7'b0} | {14'b0,y[3],x[3],y[2:1],3'b0};
    assign byte_data = data[{y[0],x[2:1]}*8 +: 8];
    assign pen = x[0] ? byte_data[3:0] : byte_data[7:4];
endmodule
