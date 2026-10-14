// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only graphics ROM cache. Reset invalidates tags on a game download.
// Both sides use held requests with one low clock between transactions.
// A hit needs no shared SDRAM transaction; misses retain the arbiter's order.
`default_nettype none
module stone_gfxcache(
 input wire clk,reset,req,cache_enable,input wire [22:0] addr,
 output wire ack,output wire [15:0] dout,
 output wire mem_req,output wire [22:0] mem_addr,
 input wire mem_ack,input wire [15:0] mem_data);
 localparam IDLE=2'd0,LOOKUP=2'd1,MISS=2'd2,DROP=2'd3;
 reg [1:0] state;
 reg [22:0] held_addr;
 reg ack_q,mem_req_q;reg [15:0] dout_q;reg [22:0] mem_addr_q;
 assign ack=cache_enable ? ack_q:mem_ack;
 assign dout=cache_enable ? dout_q:mem_data;
 assign mem_req=cache_enable ? mem_req_q:req;
 assign mem_addr=cache_enable ? mem_addr_q:addr;
 // Data and tags have no reset, so the synchronous array infers M10Ks.
 // Only validity resets; its 1,024 bits cannot expose old ROM contents.
 (* ramstyle="M10K, no_rw_check" *) reg [28:0] entries[0:1023];
 reg [28:0] entry_q;reg valid_q;reg [1023:0] valid;
 always @(posedge clk)begin
  entry_q<=entries[addr[9:0]];
  valid_q<=valid[addr[9:0]];
  if(!reset && state==MISS && mem_ack)
   entries[held_addr[9:0]]<={held_addr[22:10],mem_data};
 end
 always @(posedge clk)begin
  ack_q<=0;
  if(reset)begin
   state<=IDLE;held_addr<=0;valid<=0;mem_req_q<=0;mem_addr_q<=0;dout_q<=0;
  end else if(!cache_enable)begin state<=IDLE;mem_req_q<=0;end
  else case(state)
   IDLE:if(req)begin held_addr<=addr;state<=LOOKUP;end
   LOOKUP:if(valid_q && entry_q[28:16]==held_addr[22:10])begin
    dout_q<=entry_q[15:0];ack_q<=1;state<=DROP;
   end else begin mem_addr_q<=held_addr;mem_req_q<=1;state<=MISS;end
   MISS:if(mem_ack)begin
    valid[held_addr[9:0]]<=1;dout_q<=mem_data;
    mem_req_q<=0;ack_q<=1;state<=DROP;
   end
   DROP:if(!req)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
`default_nettype wire
