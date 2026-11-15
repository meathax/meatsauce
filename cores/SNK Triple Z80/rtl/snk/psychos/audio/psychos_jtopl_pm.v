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
    Date: 21-6-2020
    */

// Based on Nuked's work on OPLL and OPL3

module psychos_jtopl_pm (
    input [2:0] vib_cnt,
    input [9:0] fnum,
    input vib_dep,
    input viben,
    output reg signed [5:0] pm_offset
);
reg signed [4:0] raw_pm;
reg signed [8:0] pm_product;
always @(*) begin
    // Official MAME0.289 OPL PM starts at the positive peak.
    case(vib_cnt)
        3'd0: raw_pm = 5'sd8;
        3'd1: raw_pm = 5'sd4;
        3'd2: raw_pm = 5'sd0;
        3'd3: raw_pm = -5'sd4;
        3'd4: raw_pm = -5'sd8;
        3'd5: raw_pm = -5'sd4;
        3'd6: raw_pm = 5'sd0;
        default: raw_pm = 5'sd4;
    endcase
    if(!vib_dep) raw_pm = raw_pm >>> 1;
    // Signed quarter-FNUM units: round only at the primary-defined shifts.
    pm_product = raw_pm * $signed({1'b0,fnum[9:7]});
    pm_offset = pm_product >>> 1;
    if(!viben) pm_offset = 6'd0;
end
endmodule
