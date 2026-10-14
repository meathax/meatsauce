// SPDX-License-Identifier: GPL-3.0-or-later
module appoooh_inputs(
 input logic clk,reset,
 input logic [31:0] joy0,joy1,
 input logic [10:0] ps2_key,
 output logic [7:0] p1,p2,
 output logic [7:0] button3
);
 logic toggle;
 logic [15:0] keys;
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
    // Appoooh's active-high P1 port: directions, button 1, coin 1,
    // service, and button 2, in ascending bit order.
    p1={joy0[5],joy0[11]|keys[12],joy0[9]|keys[5],joy0[4]|keys[4],
        joy0[1]|keys[3],joy0[2]|keys[1],joy0[0]|keys[2],joy0[3]|keys[0]};
    // The cocktail P2 port has starts in bits 5/6 and its own two buttons.
    p2={joy1[5],joy0[8]|keys[7],joy0[7]|keys[6],joy1[4],
        joy1[1]|keys[11],joy1[2]|keys[10],joy1[0]|keys[9],joy1[3]|keys[8]};
    // Third port: player 1/2 button 3 and coin 2.
    button3={5'd0,joy0[10],joy1[6],joy0[6]|keys[13]};
   if(reset)begin p1=0;p2=0;button3=0;end
 end
endmodule
