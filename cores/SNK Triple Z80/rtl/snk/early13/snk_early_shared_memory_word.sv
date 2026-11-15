// SPDX-License-Identifier: GPL-3.0-or-later
// Private six-title integration component. One scheduled 16 KiB CPU/HS RAM
// and one 2 KiB sound RAM; acknowledged writes feed the selected renderer.
module snk_early_shared_memory_word (
 input wire clk,reset,cpu_commit_allowed,
 input wire [13:0] addr_a,addr_b,
 input wire write_a,write_b,input wire [7:0] data_a,data_b,
 output reg [7:0] q_a,q_b,output wire b_wait_n,
 input wire [11:0] sound_addr,input wire sound_write,
 input wire [7:0] sound_data,output reg [7:0] sound_q,
 input wire hs_grant,hs_req,hs_write,input wire [13:0] hs_addr,
 input wire [7:0] hs_wdata,output reg hs_ack,output reg [7:0] hs_rdata,
 input wire [3:0] video_valid,
 input wire [13:0] video_addr0,video_addr1,video_addr2,video_addr3,
 output wire [31:0] video_data,output wire [127:0] video_words,
 output wire drained,output reg commit,
 output reg [13:0] commit_addr,output reg [7:0] commit_data
);
 reg [7:0] sound_memory [0:4095]; // 4 KiB: athena/fitegolf/countryc sound RAM is C000-CFFF
 reg last_a,last_b,last_sound;
 reg pending_a,pending_b;
 reg [13:0] pending_addr_a,pending_addr_b;
 reg [7:0] pending_data_a,pending_data_b;
 reg turn,hs_seen,hs_pending;
 wire [7:0] read_q;
 reg response_valid,response_owner;
 wire take_a=cpu_commit_allowed&&write_a&&!last_a;
 wire take_b=cpu_commit_allowed&&write_b&&!last_b;
 wire selected=pending_a&&pending_b?turn:(pending_b?1'b1:(pending_a?1'b0:turn));
 wire cpu_write=!hs_grant&&(selected?pending_b:pending_a);
 wire hs_accept=hs_grant&&hs_req&&!hs_seen&&!pending_a&&!pending_b;
 wire [13:0] selected_addr=hs_accept?hs_addr:(cpu_write?
  (selected?pending_addr_b:pending_addr_a):(selected?addr_b:addr_a));
 wire [7:0] selected_data=hs_accept?hs_wdata:(selected?pending_data_b:pending_data_a);
 wire selected_write=hs_accept?hs_write:cpu_write;
 assign b_wait_n=!(pending_b||take_b);
 // Drained = no queued CPU writes. It must not include hs_pending: hs_grant depends on drained, and the HS
 // acknowledge needs hs_grant while hs_pending is set, so including it deadlocked every hiscore borrow
 // (CPUs left paused forever after the MRA hiscore config arrived).
 assign drained=!pending_a&&!pending_b;
 // No RAM clearing on reset: the actual CPUs establish their own state.
 // CPU/HS write responses return the byte just written; renderer collision reads retain old data.
 // Timing: the renderer address (TTL timing counters -> scroll adders -> tile index -> bank mux) was the 96MHz
 // critical path (-0.96ns, r41). Register the video read request once here; the data comes back one clock later.
 // The TTL-level renderer samples the response at its own clock-enable edges (>=7 master clocks apart).
 reg [3:0] vv_q=0;reg [13:0] va0_q=0,va1_q=0,va2_q=0,va3_q=0;
 always @(posedge clk)begin
  vv_q<=video_valid;va0_q<=video_addr0;va1_q<=video_addr1;va2_q<=video_addr2;va3_q<=video_addr3;
 end
 wire [31:0] cpu_bank_q[0:7],video_bank_q[0:7];
 reg [2:0] cpu_bank,video_bank0,video_bank1,video_bank2,video_bank3;
 reg [1:0] cpu_lane,video_lane0,video_lane1,video_lane2,video_lane3;
 assign read_q=8'(cpu_bank_q[cpu_bank]>>(cpu_lane*8));
 assign video_words={video_bank_q[video_bank3],video_bank_q[video_bank2],video_bank_q[video_bank1],video_bank_q[video_bank0]};
 // Register one-hot byte selection alongside the RAM address. Flattening the
 // bank/lane mux removes a serial 8:1 then 4:1 selection from RAM -> gfx ROM.
 // Address/data latency and mixed-port OLD_DATA collision semantics are unchanged.
 wire [13:0] video_request_addr[0:3];
 assign video_request_addr[0]=va0_q;assign video_request_addr[1]=va1_q;
 assign video_request_addr[2]=va2_q;assign video_request_addr[3]=va3_q;
 genvar port_index,byte_index;
 generate for(port_index=0;port_index<4;port_index=port_index+1)begin:video_byte_mux
  reg [31:0] select_q;
  always @(posedge clk)select_q<=32'b1 << {video_request_addr[port_index][13:11],video_request_addr[port_index][1:0]};
  wire [7:0] term[0:31];
  for(byte_index=0;byte_index<32;byte_index=byte_index+1)begin:byte_term
   assign term[byte_index]=video_bank_q[byte_index/4][(byte_index%4)*8+:8]&{8{select_q[byte_index]}};
  end
  reg [7:0] result;
  integer term_index;
  always @* begin
   result=0;
   for(term_index=0;term_index<32;term_index=term_index+1)result=result|term[term_index];
  end
  assign video_data[port_index*8+:8]=result;
 end endgenerate
 always @(posedge clk)begin
  cpu_bank<=selected_addr[13:11];cpu_lane<=selected_addr[1:0];
  video_lane0<=va0_q[1:0];video_lane1<=va1_q[1:0];video_lane2<=va2_q[1:0];video_lane3<=va3_q[1:0];
  video_bank0<=va0_q[13:11];video_bank1<=va1_q[13:11];
  video_bank2<=va2_q[13:11];video_bank3<=va3_q[13:11];
  sound_q<=sound_memory[sound_addr];
  if(!reset&&cpu_commit_allowed&&sound_write&&!last_sound)sound_memory[sound_addr]<=sound_data;
 end
 genvar bank_index,lane_index;
 generate for(bank_index=0;bank_index<8;bank_index=bank_index+1)begin:bank
  wire [8:0] video_address=vv_q[0]&&va0_q[13:11]==bank_index?va0_q[10:2]:
    vv_q[1]&&va1_q[13:11]==bank_index?va1_q[10:2]:
    vv_q[2]&&va2_q[13:11]==bank_index?va2_q[10:2]:va3_q[10:2];
  wire wen=!reset&&selected_write&&selected_addr[13:11]==bank_index;
  wire [3:0] byte_enable=4'b0001<<selected_addr[1:0];
  wire [31:0] cpu_q,video_q;
  assign cpu_bank_q[bank_index]=cpu_q;
  assign video_bank_q[bank_index]=video_q;
 `ifndef VERILATOR
  altsyncram #(
   .operation_mode("BIDIR_DUAL_PORT"),.intended_device_family("Cyclone V"),
   .width_a(32),.widthad_a(9),.numwords_a(512),.width_b(32),.widthad_b(9),.numwords_b(512),
   .width_byteena_a(4),.width_byteena_b(4),.byte_size(8),.address_reg_b("CLOCK0"),
   .indata_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),.byteena_reg_b("CLOCK0"),
   .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
   .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
   .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
   .read_during_write_mode_mixed_ports("OLD_DATA"),.power_up_uninitialized("TRUE"),
   .ram_block_type("M10K"),.lpm_type("altsyncram")
  ) native_ram(.clock0(clk),.clocken0(1'b1),.clocken1(1'b1),
   .clocken2(1'b1),.clocken3(1'b1),.aclr0(1'b0),.aclr1(1'b0),
   .address_a(selected_addr[10:2]),.address_b(video_address),
   .addressstall_a(1'b0),.addressstall_b(1'b0),
   .data_a({4{selected_data}}),.data_b(32'd0),.wren_a(wen),.wren_b(1'b0),
   .rden_a(1'b1),.rden_b(1'b1),.byteena_a(byte_enable),.byteena_b(4'b1111),
   .q_a(cpu_q),.q_b(video_q),.eccstatus());
 `else
  reg [31:0] words_mem[0:511];reg [31:0] sim_cpu_q,sim_video_q;
  assign cpu_q=sim_cpu_q;assign video_q=sim_video_q;
  always @(posedge clk)begin
   sim_video_q<=words_mem[video_address];
   sim_cpu_q<=words_mem[selected_addr[10:2]];
   if(wen)begin
    words_mem[selected_addr[10:2]][selected_addr[1:0]*8+:8]<=selected_data;
    sim_cpu_q[selected_addr[1:0]*8+:8]<=selected_data;
   end
  end
 `endif
 end endgenerate
 always @(posedge clk) begin
  commit<=0;hs_ack<=0;
  if(reset)begin
   last_a<=0;last_b<=0;last_sound<=0;
   pending_a<=0;pending_b<=0;pending_addr_a<=0;pending_addr_b<=0;
   pending_data_a<=0;pending_data_b<=0;turn<=0;
   hs_seen<=0;hs_pending<=0;hs_rdata<=0;
   response_valid<=0;response_owner<=0;q_a<=0;q_b<=0;
   commit_addr<=0;commit_data<=0;
  end else begin
   // Preserve held-bus history through pause; resume cannot repeat a write.
   last_a<=write_a;last_b<=write_b;last_sound<=sound_write;
   turn<=!turn;
   if(cpu_write)begin
    if(selected)pending_b<=0;else pending_a<=0;
   end
   if(take_a)begin pending_a<=1;pending_addr_a<=addr_a;pending_data_a<=data_a;end
   if(take_b)begin pending_b<=1;pending_addr_b<=addr_b;pending_data_b<=data_b;end
   if(selected_write)begin
    commit<=1;commit_addr<=selected_addr;commit_data<=selected_data;
   end
   response_valid<=!hs_grant;response_owner<=selected;
   if(response_valid)begin
    if(response_owner)q_b<=read_q;else q_a<=read_q;
   end
   if(!hs_grant||!hs_req)hs_seen<=0;
   if(hs_accept)hs_seen<=1;
   hs_pending<=hs_accept;
   if(hs_pending&&hs_grant&&hs_req)begin hs_ack<=1;hs_rdata<=read_q;end
  end
 end
 `ifdef SIMULATION
 function automatic collision(input bit av,bv,input [13:0] aa,ba);
  collision=av&&bv&&aa[13:11]==ba[13:11]&&aa[13:2]!=ba[13:2];
 endfunction
 always @(posedge clk)if(!reset)begin
  if(collision(video_valid[0],video_valid[1],video_addr0,video_addr1)||
     collision(video_valid[0],video_valid[2],video_addr0,video_addr2)||
     collision(video_valid[0],video_valid[3],video_addr0,video_addr3)||
     collision(video_valid[1],video_valid[2],video_addr1,video_addr2)||
     collision(video_valid[1],video_valid[3],video_addr1,video_addr3)||
     collision(video_valid[2],video_valid[3],video_addr2,video_addr3))$fatal(1,"Early video read word bank collision");
  if(take_a&&pending_a&&!(cpu_write&&!selected))$fatal(1,"Early A write queue overflow");
  if(take_b&&pending_b&&!(cpu_write&&selected))$fatal(1,"Early B write queue overflow");
  if(hs_grant&&(pending_a||pending_b))$fatal(1,"Early HS grant before CPU writes drained");
 end
 `endif
endmodule
