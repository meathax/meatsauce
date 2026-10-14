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

// Compression vs dynamic range
// 0 -> 43.6dB
// 1 -> 29.1
// 2 -> 21.8
// 3 -> 13.4
/* verilator coverage_off */
// AY16 resistor transfer from MAME 0.289 legacy RL=1000.
// din[0]: envelope/fixed curve. Legacy half-scale and offset belong in mixer.
module a68n_ay49_exp(input clk,input [2:0] comp,input [4:0] din,output reg [7:0] dout);
reg [7:0] lut[0:31];
always @(posedge clk) dout <= lut[din];
initial begin
    lut[0] = 8'd0;
    lut[1] = 8'd0;
    lut[2] = 8'd3;
    lut[3] = 8'd2;
    lut[4] = 8'd5;
    lut[5] = 8'd3;
    lut[6] = 8'd6;
    lut[7] = 8'd5;
    lut[8] = 8'd8;
    lut[9] = 8'd7;
    lut[10] = 8'd11;
    lut[11] = 8'd10;
    lut[12] = 8'd15;
    lut[13] = 8'd14;
    lut[14] = 8'd24;
    lut[15] = 8'd23;
    lut[16] = 8'd30;
    lut[17] = 8'd29;
    lut[18] = 8'd49;
    lut[19] = 8'd48;
    lut[20] = 8'd68;
    lut[21] = 8'd67;
    lut[22] = 8'd90;
    lut[23] = 8'd89;
    lut[24] = 8'd120;
    lut[25] = 8'd120;
    lut[26] = 8'd153;
    lut[27] = 8'd152;
    lut[28] = 8'd202;
    lut[29] = 8'd202;
    lut[30] = 8'd255;
    lut[31] = 8'd255;
end
endmodule
