// SPDX-License-Identifier: GPL-3.0-or-later
// Consume actual qualified low-byte RAM writes, including writes draining a
// pause request. The memory arbiter supplies CPU ownership, never hs borrows.
module sar_aim_snoop(
 input wire clk,reset,cpu_write,hs_access,write_high,write_low,
 input wire [23:0] address,
 input wire [15:0] data,
 output reg [1:0] actual_strobe=0,
 output reg [2:0] actual0=0,actual1=0
);
 always @(posedge clk) begin
  actual_strobe<=0;
  if(reset)begin actual0<=0;actual1<=0;end
  else if(cpu_write && !hs_access && write_low && data[7:3]==0 && (!write_high || data[15:8]==0))begin
   if(address==24'h040196)begin actual0<=data[2:0];actual_strobe[0]<=1;end
   if(address==24'h04019a)begin actual1<=data[2:0];actual_strobe[1]<=1;end
  end
 end
endmodule
