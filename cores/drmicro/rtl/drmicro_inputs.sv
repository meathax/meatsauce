// SPDX-License-Identifier: GPL-3.0-or-later
module drmicro_inputs(
 input logic clk,reset,
 input logic [31:0] joy0,joy1,
 input logic [10:0] ps2_key,
 output logic [7:0] p1,p2
);
 logic toggle;
 logic [15:0] keys;
 function automatic [3:0] fourway(input logic up,right,down,left);
  // Opposites cancel; vertical wins a simultaneous diagonal.
  if(up^down)fourway=up?4'b0001:4'b0100;
  else if(right^left)fourway=right?4'b0010:4'b1000;
  else fourway=0;
 endfunction
 always_ff @(posedge clk) begin
  if(reset)begin keys<=0;toggle<=ps2_key[10];end
  else if(toggle!=ps2_key[10])begin
   toggle<=ps2_key[10];
   case(ps2_key[8:0])
    9'h175:keys[0]<=ps2_key[9];9'h174:keys[1]<=ps2_key[9];
    9'h172:keys[2]<=ps2_key[9];9'h16b:keys[3]<=ps2_key[9];
    9'h014:keys[4]<=ps2_key[9];9'h02e:keys[5]<=ps2_key[9];
    9'h016:keys[6]<=ps2_key[9];9'h01e:keys[7]<=ps2_key[9];
    9'h02d:keys[8]<=ps2_key[9];9'h02b:keys[9]<=ps2_key[9];
    9'h02c:keys[10]<=ps2_key[9];9'h023:keys[11]<=ps2_key[9];
    9'h011:keys[12]<=ps2_key[9];9'h004:keys[13]<=ps2_key[9];
    default:;
   endcase
  end
 end
 always_comb begin
  p1={1'b0,joy0[8]|keys[13],joy0[7]|keys[5],joy0[4]|keys[4],fourway(joy0[3]|keys[0],joy0[0]|keys[1],joy0[2]|keys[2],joy0[1]|keys[3])};
  p2={1'b0,joy0[6]|joy1[6]|keys[7],joy0[5]|joy1[5]|keys[6],joy1[4]|keys[12],fourway(joy1[3]|keys[8],joy1[0]|keys[9],joy1[2]|keys[10],joy1[1]|keys[11])};
  if(reset)begin p1=0;p2=0;end
 end
endmodule
