// SPDX-License-Identifier: GPL-3.0-or-later
// Six held-request clients. Loader/video have priority; remaining ports rotate.
`default_nettype none
module stone_arbiter(input wire clk,reset,
 input wire [5:0] req,we,input wire [22:0] addr[6],input wire [15:0] din[6],input wire [1:0] be[6],
 output reg [5:0] ack,output wire [15:0] dout,
 output reg mem_req,mem_we,output reg [22:0] mem_addr,output reg [15:0] mem_din,output reg [1:0] mem_be,
 input wire mem_ack,input wire [15:0] mem_dout);
 reg [2:0] owner,rr;
 reg [1:0] state;
 integer pick,j,p;
 // Registered read data. The controller holds mem_dout stable from before its
 // ack until the next read starts, and clients sample dout in the clock their
 // ack is visible (one clock after mem_ack), so the register is transparent to
 // them. It lets the SDRAM-side data registers (pin-side) and the many
 // consumers in the core meet timing with a full clock of routing each.
 reg [15:0] dout_q;
 always @(posedge clk) dout_q<=mem_dout;
 assign dout=dout_q;
 always @* begin
   pick=-1;
   for(j=3;j>=0;j=j-1) begin
     p=2+((int'(rr)-2+j)%4);
     if(req[p]) pick=p;
   end
   if(req[1]) pick=1;
   if(req[0]) pick=0;
 end
 always @(posedge clk) begin
   ack<=0;
   if(reset) begin mem_req<=0;mem_we<=0;mem_addr<=0;mem_din<=0;mem_be<=0;owner<=0;rr<=2;state<=0;end
   else case(state)
     0:if(pick>=0) begin
       owner<=3'(pick);mem_req<=1;mem_we<=we[pick];mem_addr<=addr[pick];mem_din<=din[pick];mem_be<=be[pick];state<=1;
     end
     1:if(mem_ack) begin mem_req<=0;ack[owner]<=1;state<=2;if(owner>=2) rr<=owner==5 ? 3'd2:owner+1'b1;end
     2:state<=3;
     3:state<=0;
   endcase
 end
endmodule
`default_nettype wire
