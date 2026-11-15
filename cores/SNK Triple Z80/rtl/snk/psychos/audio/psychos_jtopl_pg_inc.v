/*  This file is part of JTOPL.

    JTOPL is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTOPL is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTOPL.  If not, see <http://www.gnu.org/licenses/>.
    
    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 13-6-2020
    
*/

module psychos_jtopl_pg_inc (
    input        [ 2:0] block,
    input        [ 9:0] fnum,
    input signed [ 5:0] pm_offset,
    output reg   [16:0] phinc_pure
);

reg [18:0] freq;
reg [11:0] fnum_fraction;
always @(*) begin
    // Apply signed PM to the 12-bit quarter-FNUM before block scaling.
    fnum_fraction = {fnum,2'b00} + {{6{pm_offset[5]}},pm_offset};
    freq = {7'd0,fnum_fraction} << block;
    phinc_pure = freq[18:2];
end

endmodule // psychos_jtopl_pg_inc