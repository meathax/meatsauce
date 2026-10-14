/*  This file is part of JTKCPU.
    JTKCPU program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTKCPU program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTKCPU.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 14-02-2023 */

module jtkcpu_idx(
    input             rst,
    input             clk,
    input             cen /* synthesis direct_enable */,

    input      [15:0] idx_racc, // a,b,d or dp
    input      [15:0] idx_reg,
    input      [15:0] mdata,
    input      [ 7:0] dp,

    // Control
    input             data2addr,
    input             idx_acc,
    input             idx_dp,
    input             idx_ld,
    input             idx_16,
    input             idx_8,
    input             idx_pc,

    output reg [15:0] addr
);

reg  [15:0] offset;

always @* begin
    offset = 0;
    if( idx_8   ) offset = { {8{mdata[7]}}, mdata[7:0] };
    if( idx_16  ) offset = mdata;
    if( idx_acc ) offset = idx_racc;
    if( idx_pc && !idx_acc ) offset = offset - (16'd1<<idx_16);
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        addr <= 0;
    end else if (cen) begin
        if( idx_ld | idx_8 | idx_16 ) addr <= idx_reg + offset;
        if( idx_dp    ) addr <= { dp, mdata[7:0] };
        if( data2addr ) addr <= mdata;
    end
end

endmodule
