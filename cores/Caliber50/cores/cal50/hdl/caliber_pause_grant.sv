// SPDX-License-Identifier: GPL-3.0-or-later
// A request alone is not a grant: wait until the 68000 has sampled HALTn
// on phi1 and its bus has remained idle long enough to drain a late cycle.
module caliber_pause_grant(
 input wire clk, reset, pause_request, halt_n, cpu_cen,
 input wire as_n, uds_n, lds_n,
 output reg granted=0
);
 reg sampled_halt=0;
 reg [4:0] idle_count=0;
 always @(posedge clk) begin
  if(reset || !pause_request || halt_n) begin
   sampled_halt<=0;idle_count<=0;granted<=0;
  end else begin
   if(cpu_cen) sampled_halt<=1;
   if(!sampled_halt || !as_n || !uds_n || !lds_n) begin idle_count<=0;granted<=0;end
   else if(idle_count<16) begin idle_count<=idle_count+1'b1;granted<=0;end
   else granted<=1;
  end
 end
endmodule
