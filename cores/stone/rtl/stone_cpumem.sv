// SPDX-License-Identifier: GPL-3.0-or-later
// Zero-wait-state front end for the 68000's ROM/RAM accesses.
//
// The 68000 must see DTACK within about one CPU clock (8 fabric clocks) of
// AS for a 4-clock bus cycle; a demand SDRAM read takes roughly twice that, so
// every ROM fetch became a 5-clock cycle (about 20% slower than the board).
// This block keeps a word-granular direct-mapped cache in one M10K array:
//  * hit_now/hit_data describe the current 68000 address; the board answers a
//    read hit at once, as fast as an on-chip peripheral.
//  * After every served read the next sequential word is prefetched, so
//    straight-line code and RAM sweeps hit; loops hit after their first pass.
//  * RAM writes are posted (write-through). The cache holds the newest data
//    until SDRAM has it, and one FSM serialises all SDRAM traffic in order, so
//    a later read can never overtake an earlier write.
// ROM is read-only and the 68000 RAM is private to it, so no other
// coherency is needed. A miss, or a request while the FSM is busy, simply
// takes wait states as before.
`default_nettype none
module stone_cpumem(input wire clk,reset,
 input wire [18:0] key,                    // {ram, ca[18:1]} of the current 68000 address
 output wire hit_now,output wire [15:0] hit_data,output wire idle,
 input wire rd_go,wr_go,touch,input wire [1:0] wbe,input wire [15:0] wdata,
 output reg done,output reg [15:0] rdata,
 output reg mem_req,mem_we,output wire [22:0] mem_addr,output wire [15:0] mem_din,output wire [1:0] mem_be,
 input wire mem_ack,input wire [15:0] mem_dout);
 localparam IDLE=0,RD=1,WR=2,PF0=3,PF1=4,PFR=5;
 reg [2:0] state;
 (* ramstyle="M10K" *) reg [21:0] cache[0:16383];               // {valid, tag[4:0], data[15:0]}
 reg [18:0] rkey,pfkey,pfa,qkey;   // pfkey: newest prefetch target; pfa: the prefetch in progress
 reg [15:0] wd;reg [1:0] wb;
 reg req_rd,req_wr,pf_pend,pf_sel;
 reg [13:0] clr_cnt;reg clr=1'b1,reset_d=1'b0;   // power-up: first clock sees a reset edge and clears the array
 reg cw_en;reg [13:0] cw_idx;reg [21:0] cw_data;
 wire [18:0] rkey_now=pf_sel ? pfa:key;
 reg [21:0] q;
 // A read that lands in the same clock as a write to the same entry returns
 // undefined data from a block RAM. rdw marks such a read: it is never a hit
 // and the requester simply looks again on the next clock, when the entry
 // reads back cleanly. (A prefetch fill completing exactly as the 68000
 // starts the next bus cycle on that address did this on hardware: the entry
 // read back with the new tag but stale data, and the CPU executed garbage.)
 reg rdw;
 always @(posedge clk) begin
   if(cw_en) cache[cw_idx]<=cw_data;
`ifdef CPUMEM_RDW_GARBAGE
   // Test-only model of the undefined read: new valid/tag with inverted old data.
   if(cw_en && cw_idx==rkey_now[13:0]) q<={cw_data[21:16],~cache[rkey_now[13:0]][15:0]};
   else
`endif
   q<=cache[rkey_now[13:0]];
   qkey<=rkey_now;
   rdw<=cw_en && cw_idx==rkey_now[13:0];
 end
 wire q_ok=!rdw && !clr;
 assign hit_now=q_ok && qkey==key && q[21] && q[20:16]==key[18:14];
 assign hit_data=q[15:0];
 assign idle=state==IDLE && !req_rd && !req_wr && !pf_pend && !clr && !rdw;
 wire [18:0] cur=(state==PFR) ? pfa:rkey;
 assign mem_addr=cur[18] ? (23'h280000 | {5'd0,cur[17:0]}) : {5'd0,cur[17:0]};
 assign mem_din=wd;
 assign mem_be=(state==WR) ? wb:2'b11;
 wire pfk_hit=!rdw && q[21] && q[20:16]==pfa[18:14];
 always @(posedge clk) begin
   done<=0;cw_en<=0;reset_d<=reset;
   if(reset && !reset_d) begin clr<=1;clr_cnt<=0;state<=IDLE;mem_req<=0;mem_we<=0;req_rd<=0;req_wr<=0;pf_pend<=0;pf_sel<=0;end
   else if(clr) begin
     cw_en<=1;cw_idx<=clr_cnt;cw_data<=22'd0;clr_cnt<=clr_cnt+1'b1;
     if(clr_cnt==14'd16383) clr<=0;
   end else begin
     if(rd_go) begin req_rd<=1;rkey<=key;end
     if(wr_go) begin req_wr<=1;rkey<=key;wd<=wdata;wb<=wbe;end
     if(touch) begin pf_pend<=1;pfkey<=key+1'b1;end
     case(state)
       IDLE:
         if(req_wr) begin
           req_wr<=0;
           // Full-word writes allocate; a byte write merges into a cached word
           // and otherwise invalidates its entry (SDRAM gets the byte).
           if(wb==2'b11) begin cw_en<=1;cw_idx<=rkey[13:0];cw_data<={1'b1,rkey[18:14],wd};end
           else if(hit_now && qkey==rkey) begin cw_en<=1;cw_idx<=rkey[13:0];cw_data<={1'b1,rkey[18:14],wb[1] ? wd[15:8]:hit_data[15:8],wb[0] ? wd[7:0]:hit_data[7:0]};end
           else begin cw_en<=1;cw_idx<=rkey[13:0];cw_data<=22'd0;end   // cannot merge: drop the entry
           mem_req<=1;mem_we<=1;state<=WR;
         end else if(req_rd) begin
           req_rd<=0;mem_req<=1;mem_we<=0;state<=RD;
         end else if(pf_pend) begin
           pf_pend<=0;
           if(pfkey[17:0]!=18'd0) begin pf_sel<=1;pfa<=pfkey;state<=PF0;end   // zero: address wrapped, nothing to prefetch
         end
       RD:if(mem_ack) begin
         mem_req<=0;rdata<=mem_dout;done<=1;
         cw_en<=1;cw_idx<=rkey[13:0];cw_data<={1'b1,rkey[18:14],mem_dout};
         state<=IDLE;
       end
       WR:if(mem_ack) begin mem_req<=0;mem_we<=0;state<=IDLE;end
       PF0:state<=PF1;
       PF1:begin
         pf_sel<=0;
         if(pfk_hit && qkey==pfa) state<=IDLE;
         else begin mem_req<=1;mem_we<=0;state<=PFR;end
       end
       PFR:if(mem_ack) begin
         mem_req<=0;
         cw_en<=1;cw_idx<=pfa[13:0];cw_data<={1'b1,pfa[18:14],mem_dout};
         state<=IDLE;
       end
       default:state<=IDLE;
     endcase
   end
 end
endmodule
`default_nettype wire
