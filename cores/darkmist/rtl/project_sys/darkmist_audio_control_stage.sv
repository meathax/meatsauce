// SPDX-License-Identifier: GPL-3.0-or-later
// Local audio-clock pipeline separates held CDC captures from DSP input packing.
module darkmist_audio_control_stage #(parameter W=179)(
 input wire clk,reset,input wire [W-1:0] in_data,input wire in_valid,
 output reg [W-1:0] out_data=0,output reg out_valid=0
);
 always @(posedge clk) begin
  if(reset) begin out_data<=0;out_valid<=0;end
  else begin out_data<=in_data;out_valid<=in_valid;end
 end
endmodule
