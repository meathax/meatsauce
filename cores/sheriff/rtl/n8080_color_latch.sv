// SPDX-License-Identifier: GPL-3.0-or-later
// 3K LS175 digital state: q[0..3] are Q1..Q4, q_n their complements.
// Caller supplies CE for HREAD_n rising (!4I QD), every16 counter clocks. Physical 3K
// CLR1 is tied high; caller/reset/power-up policy is not qualified here.
module n8080_color_latch (
 input wire clk,
 input wire clear_n,
 input wire ce_capture,
 input wire [3:0] d,
 output reg [3:0] q,
 output wire [3:0] q_n
);
 always @(posedge clk) begin
  if (!clear_n) q <= 4'b0000;
  else if (ce_capture) q <= d;
 end
 assign q_n = ~q;
endmodule
