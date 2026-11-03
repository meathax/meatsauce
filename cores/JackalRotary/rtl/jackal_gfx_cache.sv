// SPDX-License-Identifier: GPL-3.0-or-later
// Independent tagged words for both005885s using the two read clients.
module jackal_gfx_cache(
 input wire clk,reset,fetch_pair,
 input wire [15:0] address0,address1,
 output wire [15:0] data0,data1,
 output reg [23:0] rom_addr0=0,rom_addr1=0,
 output reg rom_req0=0,rom_req1=0,
 input wire rom_ack0,rom_ack1,input wire [15:0] rom_data0,rom_data1,
 output wire ready0,ready1,
 output wire busy
);
 reg [15:0] tag0=0,tag1=0,held0=0,held1=0,buffer0=0,buffer1=0;
 reg valid0=0,valid1=0,pending0=0,pending1=0;
 reg [3:0] drain=8;
 wire done0=pending0 && rom_req0==rom_ack0;
 wire done1=pending1 && rom_req1==rom_ack1;
 assign ready0=(valid0 && tag0==address0)||(done0 && held0==address0);
 assign ready1=(valid1 && tag1==address1)||(done1 && held1==address1);
 // Same-clock ack-qualified bypass before the following registered hold.
 assign data0=done0?rom_data0:buffer0;
 assign data1=done1?rom_data1:buffer1;
 assign busy=pending0||pending1;
 always @(posedge clk)begin
  if(reset)begin
   rom_req0<=rom_ack0;rom_req1<=rom_ack1;
   pending0<=0;pending1<=0;valid0<=0;valid1<=0;
   buffer0<=0;buffer1<=0;drain<=8;
  end else if(drain!=0)begin
   // Let an interrupted transaction drain before accepting a new owner.
   rom_req0<=rom_ack0;rom_req1<=rom_ack1;drain<=drain-1'b1;
  end else begin
   if(done0)begin buffer0<=rom_data0;tag0<=held0;valid0<=1;pending0<=0;end
   if(done1)begin buffer1<=rom_data1;tag1<=held1;valid1<=1;pending1<=0;end
   if(fetch_pair)begin
    if(!pending0 && !ready0)begin
     held0<=address0;rom_addr0<={8'd0,address0};rom_req0<=~rom_req0;pending0<=1;
    end
    if(!pending1 && !ready1)begin
     held1<=address1;rom_addr1<={7'd0,1'b1,address1};rom_req1<=~rom_req1;pending1<=1;
    end
   end
  end
 end
endmodule
