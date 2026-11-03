// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from the preserved HeavyUnit owner in donors/hangzo-ddr-owner.
// One clk domain arbitrates ROM reads and queued screen_rotate writes.
module hangzo_ddr_owner #(parameter integer ROT_FIFO_DEPTH=64)(
 input logic clk,reset,load_claim,rotation_quiescent,
 output wire load_grant,rotation_pause,drained,
 input logic load_rd,
 input logic [28:0] load_addr,
 input logic [7:0] load_burstcnt,
 output wire load_busy,load_data_ready,
 output wire [63:0] load_data,
 input logic rotate_we,
 input logic [28:0] rotate_addr,
 input logic [63:0] rotate_data,
 input logic [7:0] rotate_be,
 output wire rotate_busy,
 input logic ram_busy,ram_data_ready,
 input logic [63:0] ram_data,
 output wire ram_rd,ram_we,
 output wire [28:0] ram_addr,
 output wire [7:0] ram_burstcnt,ram_be,
 output wire [63:0] ram_writedata,
 output logic protocol_error=0,
 output logic [31:0] queued_writes=0,accepted_writes=0,accepted_reads=0,
 output wire [$clog2(ROT_FIFO_DEPTH+1)-1:0] queue_level
);
 localparam integer PW=$clog2(ROT_FIFO_DEPTH),CW=$clog2(ROT_FIFO_DEPTH+1);
 logic [28:0] addresses[0:ROT_FIFO_DEPTH-1];
 logic [63:0] values[0:ROT_FIFO_DEPTH-1];
 logic [7:0] masks[0:ROT_FIFO_DEPTH-1];
 logic [PW-1:0] head=0,tail=0;
 logic [CW-1:0] count=0;
 logic owner_load=0,read_pending=0,reset_pending=0,ready_block=0;
 logic response_valid=0;
 logic [63:0] response_data=64'd0;

 wire bad_load_burst=owner_load&&load_rd&&(load_burstcnt!=8'd1);
 wire ready_event=ram_data_ready&&!ready_block;
 wire pop=!owner_load&&count!=0&&!ram_busy&&!reset&&!reset_pending;
 wire push=rotate_we&&!owner_load&&!reset&&!reset_pending;
 wire accepted_read=ram_rd&&!ram_busy;
 wire response_event=ready_event&&(read_pending||accepted_read);

 assign queue_level=count;
 assign load_grant=owner_load;
 assign rotation_pause=load_claim||owner_load||reset||reset_pending;
 // This is an advisory high-water signal. screen_rotate does not consume it;
 // the FIFO accepts every pulse through capacity and flags overflow explicitly.
 assign rotate_busy=load_claim||owner_load||reset||reset_pending||
                    (count>=ROT_FIFO_DEPTH-2);
 assign drained=(count==0)&&!read_pending&&!response_valid&&!owner_load&&!reset_pending&&
                !reset&&!rotate_we;
 assign load_busy=!owner_load||ram_busy||read_pending||reset||reset_pending||
                  response_valid||bad_load_burst||(load_rd&&ready_block);
 // Capture a returned beat in the port clock domain, then present its data
 // and valid together one cycle later. This preserves an immediate reply while
 // keeping the memory handshake off the ROM loader's counter-enable path.
 assign load_data_ready=response_valid;
 assign load_data=response_data;
 assign ram_rd=owner_load&&load_rd&&(load_burstcnt==8'd1)&&!read_pending&&!ready_block&&
                !response_valid&&!reset&&!reset_pending;
 // When reset has ended but an old queued frame still exists, the reset
 // epoch drains those already-accepted writes before clearing its counters.
 assign ram_we=!owner_load&&count!=0&&!reset;
 assign ram_addr=owner_load?load_addr:addresses[head];
 assign ram_burstcnt=owner_load?load_burstcnt:8'd1;
 assign ram_be=owner_load?8'hff:masks[head];
 assign ram_writedata=owner_load?64'd0:values[head];

 always_ff @(posedge clk)begin
  // Treat each contiguous high period as one response event. This prevents a
  // held-ready beat from being reused as a later read's immediate response.
  ready_block<=ram_data_ready;
  response_valid<=1'b0;
  if(reset)begin
   response_data<=64'd0;
   // Pause both users immediately. Accepted reads retain the load owner until
   // their response arrives; queued writes survive reset and drain afterward.
   if(read_pending||count!=0)reset_pending<=1;
   else begin
    owner_load<=0;head<=0;tail<=0;count<=0;reset_pending<=0;protocol_error<=0;
    queued_writes<=0;accepted_writes<=0;accepted_reads<=0;
   end
   if(read_pending&&ready_event)read_pending<=0;
  end else if(reset_pending)begin
   if(read_pending)begin
    if(ready_event)read_pending<=0;
   end else if(count!=0)begin
    if(!owner_load&&!ram_busy)begin head<=head+1'b1;count<=count-1'b1;accepted_writes<=accepted_writes+1;end
   end else begin
    owner_load<=0;head<=0;tail<=0;count<=0;reset_pending<=0;protocol_error<=0;
    queued_writes<=0;accepted_writes<=0;accepted_reads<=0;
   end
  end else begin
   if(response_event)begin
    response_valid<=1'b1;
    response_data<=ram_data;
   end
   if(push)begin
    if(count==ROT_FIFO_DEPTH&&!pop)protocol_error<=1;
    else begin
     addresses[tail]<=rotate_addr;values[tail]<=rotate_data;masks[tail]<=rotate_be;
     tail<=tail+1'b1;queued_writes<=queued_writes+1;
    end
   end
   if(pop)begin head<=head+1'b1;accepted_writes<=accepted_writes+1;end
   if(push&&(count!=ROT_FIFO_DEPTH||pop)&&!pop)count<=count+1'b1;
   else if(pop&&!push)count<=count-1'b1;

   // Grant only after the producer reports quiescence and all earlier pulses
   // have reached memory. load_claim pauses new pixels while that drain occurs.
   if(!owner_load&&load_claim&&rotation_quiescent&&count==0&&!rotate_we)
    owner_load<=1;
   if(owner_load&&!load_claim&&!read_pending&&!response_valid&&!load_rd)owner_load<=0;

   if(accepted_read)begin
    accepted_reads<=accepted_reads+1;
    if(!ready_event)read_pending<=1;
   end
   if(ready_event)begin
    if(read_pending)read_pending<=0;
    else if(!accepted_read)protocol_error<=1;
   end
   if(bad_load_burst)protocol_error<=1;
   if(owner_load&&rotate_we)protocol_error<=1;
  end
 end

`ifdef SIMULATION
 initial begin
  if(ROT_FIFO_DEPTH<4 || (ROT_FIFO_DEPTH&(ROT_FIFO_DEPTH-1))!=0)
   $fatal(1,"DDR_OWNER_FIFO_DEPTH_MUST_BE_POWER_OF_TWO_AT_LEAST_4");
 end
`endif
endmodule
