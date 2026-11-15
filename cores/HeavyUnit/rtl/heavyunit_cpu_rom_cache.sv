// SPDX-License-Identifier: GPL-3.0-or-later
// PRIVATE PROTOTYPE: independent 1KiB program caches ahead of board arbitration.
// Only qualified ROM reads enter this interface. Responses are pulses.
module heavyunit_cpu_rom_cache (
 input logic clk,reset,invalidate,image_valid,accept_enable,
 input logic [2:0] cpu_quiesce,cpu_req_valid,
 output logic [2:0] cpu_req_ready,cpu_rsp_valid,cpu_pending,
 input logic [47:0] cpu_req_addr,
 output logic [23:0] cpu_rsp_data,
 input logic [2:0] main_bank,
 input logic [1:0] sub_bank,sound_bank,
 output logic backend_req_valid,
 input logic backend_req_ready,
 output logic [21:0] backend_req_addr,
 input logic backend_rsp_valid,
 input logic [31:0] backend_rsp_line_data,
 // Main and sub programs are served from complete on-chip copies (always hit,
 // never wait on SDRAM); only the sound CPU uses the cache/SDRAM refill path.
 output logic [16:0] main_rom_addr,
 input logic [7:0] main_rom_data,
 output logic [15:0] sub_rom_addr,
 input logic [7:0] sub_rom_data,
 output logic cleared,drained,
 output logic [95:0] hit_count,miss_count,
 output logic [31:0] refill_count,stale_fill_drops,cancel_count
);
 typedef enum logic [1:0] {C_IDLE,C_LOOKUP,C_PENDING,C_REFILL} client_t;
 typedef enum logic [1:0] {R_IDLE,R_SEND,R_WAIT} refill_t;
 client_t client [0:2];
 refill_t refill_state;
 logic [1:0] owner,next_owner,selected;
 logic selected_valid,owner_poison;
 logic clearing;
 logic [7:0] clear_index;
 logic [16:0] decoded_local [0:2];
 logic [21:0] decoded_absolute [0:2];
 logic [21:0] accepted_absolute [0:2];
 logic [7:0] accepted_index [0:2];
 logic [6:0] accepted_tag [0:2];
 logic [1:0] accepted_offset [0:2];
 logic [16:0] accepted_local [0:1];
 assign main_rom_addr=cpu_req_valid[0] && cpu_req_ready[0] ? decoded_local[0] : accepted_local[0];
 assign sub_rom_addr=cpu_req_valid[1] && cpu_req_ready[1] ? decoded_local[1][15:0] : accepted_local[1][15:0];
 logic [39:0] cache_q [0:2];
 logic [7:0] read_index [0:2];
 logic [7:0] write_index [0:2];
 logic [39:0] write_word [0:2];
 logic [2:0] write_enable,cancel_mask;
 wire backend_accept=backend_req_valid && backend_req_ready;
 wire return_owned=refill_state==R_WAIT && backend_rsp_valid;
 wire fill_allowed=return_owned && !owner_poison && !invalidate && !clearing && image_valid && !reset;
 assign cleared=!clearing && !reset;
 assign backend_req_valid=refill_state==R_SEND && !reset;
 assign drained=refill_state==R_IDLE && cpu_pending==0 && !reset;
 always_comb begin
  decoded_local[0]=cpu_req_addr[15:0]<16'h8000 ? {1'b0,cpu_req_addr[15:0]} : {main_bank,cpu_req_addr[13:0]};
  decoded_local[1]=cpu_req_addr[31:16]<16'h8000 ? {1'b0,cpu_req_addr[31:16]} : {1'b0,sub_bank,cpu_req_addr[29:16]};
  decoded_local[2]=cpu_req_addr[47:32]<16'h8000 ? {1'b0,cpu_req_addr[47:32]} : {1'b0,sound_bank,cpu_req_addr[45:32]};
  decoded_absolute[0]={5'd0,decoded_local[0]};
  decoded_absolute[1]=22'h020000+{5'd0,decoded_local[1]};
  decoded_absolute[2]=22'h030000+{5'd0,decoded_local[2]};
  for(integer i=0;i<3;i=i+1) begin
   cancel_mask[i]=invalidate && (client[i]==C_LOOKUP || client[i]==C_PENDING || (refill_state==R_SEND && !backend_accept && owner==i));
   cpu_req_ready[i]=client[i]==C_IDLE && !reset && !invalidate && !clearing && image_valid && accept_enable && !cpu_quiesce[i];
   cpu_pending[i]=client[i]!=C_IDLE || cpu_rsp_valid[i];
   read_index[i]=cpu_req_valid[i] && cpu_req_ready[i] ? decoded_local[i][9:2] : accepted_index[i];
   write_enable[i]=!reset && (clearing || (fill_allowed && owner==i));
   write_index[i]=clearing ? clear_index : accepted_index[i];
   write_word[i]=clearing ? 40'd0 : {1'b1,accepted_tag[i],backend_rsp_line_data};
  end
  selected=next_owner;
  selected_valid=client[0]==C_PENDING || client[1]==C_PENDING || client[2]==C_PENDING;
  case(next_owner)
   0: if(client[0]==C_PENDING) selected=0; else if(client[1]==C_PENDING) selected=1; else selected=2;
   1: if(client[1]==C_PENDING) selected=1; else if(client[2]==C_PENDING) selected=2; else selected=0;
   default: if(client[2]==C_PENDING) selected=2; else if(client[0]==C_PENDING) selected=0; else selected=1;
  endcase
 end
 genvar bank;
 generate for(bank=0;bank<3;bank=bank+1) begin: cache_bank
  (* ramstyle="M10K" *) logic [39:0] memory [0:255];
  always_ff @(posedge clk) begin
   if(write_enable[bank]) memory[write_index[bank]]<=write_word[bank];
   cache_q[bank]<=memory[read_index[bank]];
  end
 end endgenerate
 always_ff @(posedge clk) begin
  cpu_rsp_valid<=0;
  if(reset) begin
   clearing<=1;clear_index<=0;refill_state<=R_IDLE;owner<=0;next_owner<=0;owner_poison<=0;backend_req_addr<=0;
   cpu_rsp_data<=24'hffffff;accepted_local[0]<=0;accepted_local[1]<=0;hit_count<=0;miss_count<=0;refill_count<=0;stale_fill_drops<=0;cancel_count<=0;
   for(integer i=0;i<3;i=i+1) begin client[i]<=C_IDLE;accepted_absolute[i]<=0;accepted_index[i]<=0;accepted_tag[i]<=0;accepted_offset[i]<=0;end
  end else begin
   if(clearing) begin
    if(clear_index==255) clearing<=0;else clear_index<=clear_index+8'd1;
   end
   if(invalidate) begin
    // Cores are held reset by the machine during image change. Complete queued
    // but unissued old reads to drain their adapters; never issue them later.
    clearing<=1;clear_index<=0;
    cancel_count<=cancel_count+{31'd0,cancel_mask[0]}+{31'd0,cancel_mask[1]}+{31'd0,cancel_mask[2]};
    for(integer i=0;i<3;i=i+1) begin
     if(client[i]==C_LOOKUP || client[i]==C_PENDING) begin
      client[i]<=C_IDLE;cpu_rsp_valid[i]<=1;cpu_rsp_data[8*i+:8]<=8'hff;
     end
    end
    if(refill_state==R_SEND && !backend_accept) begin
     client[owner]<=C_IDLE;cpu_rsp_valid[owner]<=1;cpu_rsp_data[8*owner+:8]<=8'hff;refill_state<=R_IDLE;
    end else if(refill_state==R_SEND && backend_accept) begin
     refill_state<=R_WAIT;owner_poison<=1;next_owner<=owner==2 ? 0 : owner+2'd1;refill_count<=refill_count+1;
    end else if(refill_state==R_WAIT) owner_poison<=1;
   end else begin
    for(integer i=0;i<3;i=i+1) begin
     case(client[i])
      C_IDLE: if(cpu_req_valid[i] && cpu_req_ready[i]) begin
       accepted_absolute[i]<=decoded_absolute[i];accepted_index[i]<=decoded_local[i][9:2];
       accepted_tag[i]<=decoded_local[i][16:10];accepted_offset[i]<=decoded_local[i][1:0];client[i]<=C_LOOKUP;
       if(i<2) accepted_local[i[0]]<=decoded_local[i];
      end
      C_LOOKUP: if(i<2) begin
       cpu_rsp_valid[i]<=1;cpu_rsp_data[8*i+:8]<=i==0 ? main_rom_data : sub_rom_data;
       client[i]<=C_IDLE;hit_count[32*i+:32]<=hit_count[32*i+:32]+1;
      end else if(cache_q[i][39] && cache_q[i][38:32]==accepted_tag[i]) begin
       cpu_rsp_valid[i]<=1;cpu_rsp_data[8*i+:8]<=cache_q[i][8*accepted_offset[i]+:8];
       client[i]<=C_IDLE;hit_count[32*i+:32]<=hit_count[32*i+:32]+1;
      end else begin client[i]<=C_PENDING;miss_count[32*i+:32]<=miss_count[32*i+:32]+1;end
      default: ;
     endcase
    end
    case(refill_state)
     R_IDLE: if(selected_valid) begin
      owner<=selected;backend_req_addr<={accepted_absolute[selected][21:2],2'b00};
      owner_poison<=0;refill_state<=R_SEND;client[selected]<=C_REFILL;
     end
     R_SEND: if(backend_accept) begin refill_state<=R_WAIT;next_owner<=owner==2 ? 0 : owner+2'd1;refill_count<=refill_count+1;end
     default: ;
    endcase
   end
   // Already accepted ownership always drains, even on image invalidation.
   // A poison latch cannot wrap across multiple image transitions.
   if(return_owned) begin
    cpu_rsp_valid[owner]<=1;cpu_rsp_data[8*owner+:8]<=backend_rsp_line_data[8*accepted_offset[owner]+:8];
    client[owner]<=C_IDLE;refill_state<=R_IDLE;
    if(!fill_allowed) stale_fill_drops<=stale_fill_drops+1;
   end
  end
 end
endmodule
