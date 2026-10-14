// SPDX-License-Identifier: GPL-3.0-or-later
// Converts a held request to stock controller edge strobes. Always observes
// the controller busy transition before accepting ready (including reads cached
// by the stock controller, whose ready can remain high).
`default_nettype none
module stone_sdram_bridge(input wire clk,reset,req,we,input wire [22:0] addr,input wire [15:0] din,input wire [1:0] be,
 output reg ack,output wire [15:0] dout,output reg ready,
 inout wire [15:0] SDRAM_DQ,output wire [12:0] SDRAM_A,output wire [1:0] SDRAM_BA,
 output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nCS,SDRAM_nWE,SDRAM_nRAS,SDRAM_nCAS,SDRAM_CKE);
 reg rd_pulse,wr_pulse;wire ctl_ready;reg [2:0] state;
 reg [14:0] startup;
 sdram_stock ctl(.clk(clk),.init(reset),.addr({1'b0,addr,1'b0}),.din(din),.wtbt(be),.rd(rd_pulse),.we(wr_pulse),.ready(ctl_ready),.dout(dout),
 .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nCS(SDRAM_nCS),.SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_CKE(SDRAM_CKE));
 always @(posedge clk) begin
   ack<=0;rd_pulse<=0;wr_pulse<=0;
   if(reset) begin state<=0;ready<=0;startup<=0;end
   else begin
     if(!ready) begin if(startup==15000 && ctl_ready) ready<=1;else if(startup!=15000) startup<=startup+1'b1;end
     case(state)
       0:if(ready && req) begin rd_pulse<=!we;wr_pulse<=we;state<=1;end
       1:state<=2;
       2:state<=3;
       3:if(ctl_ready) begin ack<=1;state<=4;end
       4:if(!req) state<=0;
       default:state<=0;
     endcase
   end
 end
endmodule
`default_nettype wire
