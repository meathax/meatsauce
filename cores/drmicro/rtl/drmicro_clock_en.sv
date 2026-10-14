// SPDX-License-Identifier: GPL-3.0-or-later
module drmicro_ce #(parameter integer RATE=3072000, CLOCK=50000000, INITIAL_PHASE=0)(
 input logic clk, reset, output logic ce
);
 logic [31:0] phase;
 always_ff @(posedge clk) begin
  if(reset) begin phase<=INITIAL_PHASE; ce<=0; end
  else if(phase>=CLOCK-RATE) begin phase<=phase-(CLOCK-RATE);ce<=1;end
  else begin phase<=phase+RATE;ce<=0;end
 end
endmodule
