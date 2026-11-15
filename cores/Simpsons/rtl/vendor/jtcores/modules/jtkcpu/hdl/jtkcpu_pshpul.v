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

module jtkcpu_pshpul(
    input               rst,
    input               clk,
    input               cen /* synthesis direct_enable */,

    input        [15:0] postdata,
    input        [ 7:0] op,
    input        [ 7:0] cc,
    input        [ 7:0] psh_bit,
    input               psh_all,
    input               pul_go,
    input               psh_go,
    input               psh_pc,
    input               psh_cc,
    input               rti_cc,
    input               rti_other,

    output   reg [ 7:0] psh_sel,
    output   reg        hihalf,
    output   reg        pul_en,
    output   reg        us_sel,
    output              psh_dec,
    output              busy

);

`include "jtkcpu.inc"

wire [7:0] postbyte;
reg        dec_en;

assign busy     = psh_sel!=0;
assign psh_dec  = dec_en & busy;
assign postbyte = rti_cc    ? 8'h01 :
                  psh_pc    ? 8'h80 :
                  psh_cc    ? 8'h81 :
                  // the CC is read from postdata (memory output) directly
                  // because it takes an extra cycle for it to be available
                  // at the register
                  rti_other ? ( postdata[{1'b0,CC_E}] ? 8'hFE : 8'h80 ) : // pull all but CC or only PC
                  psh_all   ? 8'hFF : postdata[7:0];

always @(posedge clk or posedge rst) begin
    if( rst ) begin
        psh_sel <= 0;
        hihalf  <= 0;
        us_sel  <= 0;
        pul_en  <= 0;
        dec_en  <= 0;
    end else if( cen ) begin
        if( !busy ) begin
            pul_en <= 0;
            dec_en <= 0;
            if( psh_go || pul_go ) begin
                psh_sel <= postbyte;
                us_sel  <= op[0] && op!=LBSR && !rti_cc && !psh_pc && !psh_cc && !rti_other && !psh_all;
                hihalf  <= 0;
                pul_en  <= pul_go;
                dec_en  <= psh_go;
            end
        end else begin
            if( psh_bit[7:4]!=0 && !hihalf ) begin
                hihalf <= 1;
            end else begin
                hihalf <= 0;
                psh_sel <= psh_sel & ~psh_bit;
            end
        end
    end
end

endmodule


