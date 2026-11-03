// SPDX-License-Identifier: GPL-3.0-or-later
// Register all 27 HDMI signals after the parent mux, on its selected clock.
module darkmist_hdmi_output_stage(
 input wire clk,input wire [26:0] in_data,
 output reg [26:0] out_data=0
);
 always @(posedge clk) out_data<=in_data;
endmodule
