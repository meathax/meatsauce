/*  This file is part of JT49.

    JT49 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT49 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT49.  If not, see <http://www.gnu.org/licenses/>.
    
    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 10-Nov-2018
    
    Based on sqmusic, by the same author
    
    */

/* verilator coverage_off */
module jt49_div #(parameter W=12 )(   
    (* direct_enable *) input cen,
    input           clk, // this is the divided down clock from the core
    input           rst_n,
    input [W-1:0]  period,
    output reg      div
);

reg [W-1:0]count;

wire [W-1:0] one = { {W-1{1'b0}}, 1'b1};

always @(posedge clk, negedge rst_n ) begin
  if( !rst_n) begin
    count <= one;
    div   <= 1'b0;
  end else if(cen) begin
    if( count>=period ) begin
        count <= one;
        div   <= ~div;
    end else begin
        count <=  count + one ;
    end
    // SunA8bit local change (R084): upstream held div low for period 0
    // ("if(period==0) div<=0;"). On the AY-3-8910/YM2149 family a period of
    // 0 behaves as 1, and MAME's ymfm SSG and ay8910 both model it that way:
    // with count>=period always true the output simply toggles every cen,
    // exactly as for period 1. Holding it low made tone AND noise zero, so
    // every noise burst a game plays with tone period 0 (Super Ranger's
    // YM2203 hit/explosion effects: r04=r05=0, noise period 16, volume ramp
    // 15..0) was silent. The same divider clocks the noise generator, whose
    // period 0 MAME likewise treats as 1.
  end
end

endmodule
