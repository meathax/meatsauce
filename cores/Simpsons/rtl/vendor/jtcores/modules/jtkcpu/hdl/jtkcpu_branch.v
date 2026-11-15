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

module jtkcpu_branch(
	input      [7:0] op,
	input      [7:0] cc,
    output reg       branch
);

`include "jtkcpu.inc"

always @* begin
    case( op )
        BRA,LBRA,BSR,LBSR: branch = 1;
        BRN,LBRN: branch = 0;
        BHI,LBHI: branch = !( cc[CC_Z] || cc[CC_C] );
        BLS,LBLS: branch =  ( cc[CC_Z] || cc[CC_C] );
        BCC,LBCC: branch =   !cc[CC_C];
        BCS,LBCS: branch =    cc[CC_C];
        BNE,LBNE: branch =   !cc[CC_Z];
        BEQ,LBEQ: branch =    cc[CC_Z];
        BVC,LBVC: branch =   !cc[CC_V];
        BVS,LBVS: branch =    cc[CC_V];
        BPL,LBPL: branch =   !cc[CC_N];
        BMI,LBMI: branch =    cc[CC_N];
        BGE,LBGE: branch =    cc[CC_N] == cc[CC_V];
        BLT,LBLT: branch =    cc[CC_N] != cc[CC_V];
        BGT,LBGT: branch =  ( cc[CC_N] == cc[CC_V] ) && !cc[CC_Z];
        BLE,LBLE: branch = !((cc[CC_N] == cc[CC_V] ) && !cc[CC_Z]);
        BSWI: branch = 1;
        default : branch = 0;
    endcase
end

endmodule
