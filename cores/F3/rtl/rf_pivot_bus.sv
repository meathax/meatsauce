// SPDX-License-Identifier: GPL-3.0-or-later
// Complete pivot row banks: publication follows fill completion; late rows
// read zero. Logical reset invalidates data while accepted transfers drain.
module rf_pivot_bus #(parameter [26:1] BASE=26'h0a00000,parameter SEPARATE_INIT=0)(
 input wire reset,init,clk_sys,input wire [14:0] cpu_addr,input wire [15:0] cpu_din,
 input wire [1:0] cpu_be,input wire cpu_wr,output wire cpu_busy,
 input wire [4:0] row,input wire [14:0] v_addr,output wire [15:0] v_q,
 input wire clk_ram,output reg [26:1] ch_addr,output reg [15:0] ch_din,
 output reg [1:0] ch_be,output reg ch_rnw,ch_req,input wire ch_ready,input wire [63:0] ch_dout);
 wire cold=SEPARATE_INIT?init:reset;
 reg wr_lvl,wr_ack_t;
 reg [14:0] wr_addr;reg [15:0] wr_data;reg [1:0] wr_mask;
 (* preserve, dont_replicate, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name SYNCHRONIZATION_REGISTER_CHAIN_LENGTH 2" *) reg wr_ack_s,wr_ack_1;
 reg wr_ack_2;
 assign cpu_busy=wr_lvl;
 always @(posedge clk_sys)begin
  if(cold)begin wr_lvl<=0;wr_addr<=0;wr_data<=0;wr_mask<=0;wr_ack_s<=0;wr_ack_1<=0;wr_ack_2<=0;end
  else begin
   wr_ack_s<=wr_ack_t;wr_ack_1<=wr_ack_s;wr_ack_2<=wr_ack_1;
   if(wr_lvl && (wr_ack_1^wr_ack_2))wr_lvl<=0;
   else if(!reset && !wr_lvl && cpu_wr)begin wr_lvl<=1;wr_addr<=cpu_addr;wr_data<=cpu_din;wr_mask<=cpu_be;end
  end
 end
 reg [1:0] bank_valid,bank_stale;
 reg [4:0] bank_row[0:1];
 reg request_t,request_pending,request_bank,fill_dirty,fill_cancelled;
 reg [4:0] request_row;
 reg complete_t;
 (* preserve, dont_replicate, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name SYNCHRONIZATION_REGISTER_CHAIN_LENGTH 2" *) reg complete_s,complete_1;
 reg complete_2;
 wire row0=bank_valid[0] && bank_row[0]==row;
 wire row1=bank_valid[1] && bank_row[1]==row;
 wire [4:0] next_row=row+5'd1;
 wire next0=bank_valid[0] && bank_row[0]==next_row;
 wire next1=bank_valid[1] && bank_row[1]==next_row;
 wire read_enable=!reset && (row0 || row1);
 wire read_bank=!row0;
 reg read_valid;
 integer b;
 always @(posedge clk_sys)begin
  if(cold)begin
   bank_valid<=0;bank_stale<=0;bank_row[0]<=0;bank_row[1]<=0;
   request_t<=0;request_pending<=0;request_bank<=0;request_row<=0;
   fill_dirty<=0;fill_cancelled<=0;complete_s<=0;complete_1<=0;complete_2<=0;read_valid<=0;
  end else begin
   complete_s<=complete_t;complete_1<=complete_s;complete_2<=complete_1;read_valid<=read_enable;
   if(complete_1^complete_2)begin
    request_pending<=0;bank_row[request_bank]<=request_row;bank_stale[request_bank]<=0;
    bank_valid[request_bank]<=!reset && !fill_cancelled && !fill_dirty && !(cpu_wr && cpu_addr[8:4]==request_row);
   end
   for(b=0;b<2;b=b+1)begin
    if(bank_stale[b] && bank_row[b]!=row)begin bank_valid[b]<=0;bank_stale[b]<=0;end
    if(cpu_wr && bank_valid[b] && cpu_addr[8:4]==bank_row[b])begin
     if(bank_row[b]==row)bank_stale[b]<=1;
     else begin bank_valid[b]<=0;bank_stale[b]<=0;end
    end
   end
   if(request_pending && cpu_wr && cpu_addr[8:4]==request_row)fill_dirty<=1;
   if(reset)begin bank_valid<=0;bank_stale<=0;read_valid<=0;if(request_pending)fill_cancelled<=1;end
   else if(!request_pending)begin
    if(!row0 && !row1)begin
     request_bank<=next0?1'b1:1'b0;request_row<=row;bank_valid[next0?1:0]<=0;
     request_t<=~request_t;request_pending<=1;fill_dirty<=0;fill_cancelled<=0;
    end else if(!next0 && !next1)begin
     request_bank<=row0?1'b1:1'b0;request_row<=next_row;bank_valid[row0?1:0]<=0;
     request_t<=~request_t;request_pending<=1;fill_dirty<=0;fill_cancelled<=0;
    end
   end
  end
 end
 (* preserve, dont_replicate, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name SYNCHRONIZATION_REGISTER_CHAIN_LENGTH 2" *) reg wr_s,wr_1,request_s,request_1,reset_s,reset_1;
 reg request_2,wr_seen;
 reg [2:0] state;
 localparam IDLE=0,WRITE=1,READ=2,SPILL=3,FINISH=4;
 reg fill_busy,fill_bank;reg [4:0] fill_row;reg [5:0] fill_col;
 reg [1:0] fill_burst,spill_count;reg [63:0] read_data;
 reg cache_we;reg [10:0] cache_addr;reg [15:0] cache_data;
 always @(posedge clk_ram)begin
  if(cold)begin
   wr_s<=0;wr_1<=0;wr_seen<=0;request_s<=0;request_1<=0;request_2<=0;
   reset_s<=1;reset_1<=1;state<=IDLE;fill_busy<=0;fill_bank<=0;
   fill_row<=0;fill_col<=0;fill_burst<=0;spill_count<=0;read_data<=0;
   ch_req<=0;ch_addr<=0;ch_din<=0;ch_be<=3;ch_rnw<=1;
   wr_ack_t<=0;complete_t<=0;cache_we<=0;cache_addr<=0;cache_data<=0;
  end else begin
   wr_s<=wr_lvl;wr_1<=wr_s;request_s<=request_t;request_1<=request_s;request_2<=request_1;
   reset_s<=reset;reset_1<=reset_s;cache_we<=0;
   if(!wr_1)wr_seen<=0;
   if(request_1^request_2)begin fill_busy<=1;fill_bank<=request_bank;fill_row<=request_row;fill_col<=0;fill_burst<=0;end
   case(state)
    IDLE:begin
     if(wr_1 && !wr_seen)begin
      ch_addr<=BASE+{11'd0,wr_addr};ch_din<=wr_data;ch_be<=wr_mask;ch_rnw<=0;ch_req<=1;state<=WRITE;
     end else if(fill_busy)begin
      if(reset_1)begin fill_busy<=0;complete_t<=~complete_t;end
      else begin ch_addr<=BASE+{11'd0,fill_col,fill_row,fill_burst,2'b00};ch_be<=3;ch_rnw<=1;ch_req<=1;state<=READ;end
     end
    end
    WRITE:if(ch_ready)begin ch_req<=0;wr_ack_t<=~wr_ack_t;wr_seen<=1;state<=IDLE;end
    READ:if(ch_ready)begin ch_req<=0;read_data<=ch_dout;spill_count<=0;state<=SPILL;end
    SPILL:begin
     cache_we<=1;cache_addr<={fill_bank,fill_col,fill_burst,spill_count};cache_data<=read_data[spill_count*16+:16];
     if(spill_count==3)begin
      if(fill_col==63 && fill_burst==3)state<=FINISH;
      else begin
       if(fill_burst==3)begin fill_burst<=0;fill_col<=fill_col+1'b1;end else fill_burst<=fill_burst+1'b1;
       state<=IDLE;
      end
     end else spill_count<=spill_count+1'b1;
    end
    // Last registered write reaches RAM on this edge before publication.
    FINISH:begin fill_busy<=0;complete_t<=~complete_t;state<=IDLE;end
   endcase
  end
 end
 wire [15:0] cache_q;
 rf_bram_dc #(.WIDTH_A(16),.AW_A(11),.RATIO_B(1),.GATED_READ(1)) u_cache(
  .clk_a(clk_ram),.addr_a(cache_addr),.wdata_a(cache_data),.wren_a(cache_we),.q_a(),
  .clk_b(clk_sys),.addr_b({read_bank,v_addr[14:9],v_addr[3:0]}),.read_enable_b(read_enable),.q_b(cache_q));
 assign v_q=(!reset && read_valid)?cache_q:16'd0;
endmodule
