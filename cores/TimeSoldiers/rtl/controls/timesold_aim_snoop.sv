// SPDX-License-Identifier: GPL-3.0-or-later
// Native global bytes040016(P1) and040017(P2) share one big-endian word.
module timesold_aim_snoop(
 input wire clk,reset,cpu_write,hs_access,write_high,write_low,
 input wire [23:0] address,
 input wire [15:0] data,
 output reg [1:0] actual_strobe=0,
 output reg [3:0] actual0=0,actual1=0
);
 always @(posedge clk)begin
  actual_strobe<=0;
  if(reset)begin actual0<=0;actual1<=0;end
  else if(cpu_write && !hs_access && address==24'h040016)begin
   if(write_high && data[15:8]<12)begin actual0<=data[11:8];actual_strobe[0]<=1;end
   if(write_low && data[7:0]<12)begin actual1<=data[3:0];actual_strobe[1]<=1;end
  end
 end
endmodule
