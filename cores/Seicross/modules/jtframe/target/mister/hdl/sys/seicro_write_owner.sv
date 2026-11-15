// Isolated policy candidate. NOT bound into production ascal.
// RAM write and burst publication inputs must be the actual same-half signals.
module seicro_write_owner(
 input wire reset_n,input wire i_clk,input wire avl_clk,input wire o_clk,
 input wire frame_start,input wire frame_end,input wire pipeline_empty,
 input wire [1:0] frame_fields,input wire [31:0] frame_metadata,
 input wire ram_write,input wire ram_half,output wire ram_write_allow,
 input wire publish,input wire publish_half,input wire [31:0] relative_address,
 input wire publish_line,
 output reg dropping,output reg frame_active,
 output reg frame_complete,output reg [1:0] complete_fields,output reg [31:0] complete_metadata,
 input wire [31:0] next_base0,input wire [31:0] next_base1,
 output reg write_valid,output reg write_half,output reg [31:0] write_address,
 input wire write_done
);

 (* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
 reg [1:0] i_reset_pipe=2'b11,a_reset_pipe=2'b11,o_reset_pipe=2'b11;
 always @(posedge i_clk or negedge reset_n)
  if(!reset_n)i_reset_pipe<=2'b11;else i_reset_pipe<={i_reset_pipe[0],1'b0};
 always @(posedge avl_clk or negedge reset_n)
  if(!reset_n)a_reset_pipe<=2'b11;else a_reset_pipe<={a_reset_pipe[0],1'b0};
 always @(posedge o_clk or negedge reset_n)
  if(!reset_n)o_reset_pipe<=2'b11;else o_reset_pipe<={o_reset_pipe[0],1'b0};
 wire i_reset_n=~i_reset_pipe[1],a_reset_n=~a_reset_pipe[1],o_reset_n=~o_reset_pipe[1];
 reg [1:0] req,ack,ack_meta,ack_sync,req_meta,req_sync;
 reg [31:0] held_address[0:1];reg [1:0] held_sequence[0:1];
 reg [1:0] source_sequence,dest_sequence;reg [31:0] active_metadata,held_metadata;
 reg frame_ended,allocation_valid,allocation_waiting,allocation_capture;
 reg alloc_request,alloc_ack,alloc_ack_meta,alloc_ack_sync;
 reg alloc_req_meta,alloc_req_sync,alloc_req_seen;
 reg allocation_is_frame;reg [1:0] held_fields;
 reg [31:0] allocation0,allocation1,base0,base1;
 reg [2:0] alloc_delay;
 wire [1:0] busy=req^ack_sync;
 assign ram_write_allow=ram_write&&frame_active&&!dropping&&!busy[ram_half]&&(frame_metadata==active_metadata);
 // Busy includes both queued and physically executing bursts. A half is freed
 // only by the complete physical burst, never by descriptor dispatch.
 always @(posedge i_clk or negedge i_reset_n) begin
  if(!i_reset_n) begin
   req<=0;ack_meta<=0;ack_sync<=0;source_sequence<=0;
   dropping<=1;frame_active<=0;frame_ended<=0;active_metadata<=0;held_metadata<=0;
   allocation_valid<=0;allocation_waiting<=1;allocation_capture<=0;
   alloc_request<=1;alloc_ack_meta<=0;alloc_ack_sync<=0;
   allocation_is_frame<=0;held_fields<=0;base0<=0;base1<=0;
   held_address[0]<=0;held_address[1]<=0;
   held_sequence[0]<=0;held_sequence[1]<=0;
  end else begin
   ack_meta<=ack;ack_sync<=ack_meta;
   alloc_ack_meta<=alloc_ack;alloc_ack_sync<=alloc_ack_meta;
   if(allocation_waiting && alloc_ack_sync==alloc_request) begin
    // Extra destination edge after the two-flop acknowledgement.
    if(allocation_capture) begin
     base0<=allocation0;base1<=allocation1;allocation_valid<=1;
     allocation_waiting<=0;allocation_capture<=0;
    end else allocation_capture<=1;
   end
   if(frame_start) begin
    active_metadata<=frame_metadata;
    frame_ended<=0;
    frame_active<=allocation_valid && busy==0 && !allocation_waiting;
    dropping<=!(allocation_valid && busy==0 && !allocation_waiting);
   end
   if(frame_active && frame_metadata!=active_metadata) begin dropping<=1;frame_active<=0;end
   if(ram_write && frame_active && busy[ram_half]) begin
    dropping<=1;frame_active<=0;
   end
   if(publish && frame_active && !dropping && frame_metadata==active_metadata) begin
    if(busy[publish_half]) begin dropping<=1;frame_active<=0;end
    else begin
     held_address[publish_half]<=relative_address+(publish_line?base1:base0);
     held_sequence[publish_half]<=source_sequence;
     source_sequence<=source_sequence+1'b1;
     req[publish_half]<=~req[publish_half];
    end
   end
   if(frame_end && frame_active && !dropping && !allocation_waiting && frame_metadata==active_metadata) begin
    held_metadata<=active_metadata;allocation_is_frame<=1;
    frame_ended<=1;held_fields<=frame_fields;
   end else if(frame_end && dropping) frame_ended<=1;
   // End is a fence: the ascal producer must first flush its delayed write
   // publication pipeline. A new input frame is dropped while this drains.
   if(frame_ended && pipeline_empty && busy==0 && !publish) begin
    frame_ended<=0;frame_active<=0;
    if(!dropping && allocation_valid) begin
     alloc_request<=~alloc_request;
     allocation_valid<=0;allocation_waiting<=1;
    end
   end
  end
 end
 // Existing output buffer allocator sees one complete-frame pulse, then has
 // three complete output edges to update both buffer offsets before capture.
 always @(posedge o_clk or negedge o_reset_n) begin
  if(!o_reset_n) begin
   alloc_req_meta<=0;alloc_req_sync<=0;alloc_req_seen<=0;
   alloc_ack<=0;alloc_delay<=0;allocation0<=0;allocation1<=0;
   frame_complete<=0;complete_fields<=0;complete_metadata<=0;
  end else begin
   alloc_req_meta<=alloc_request;alloc_req_sync<=alloc_req_meta;
   frame_complete<=0;
   if(alloc_req_sync!=alloc_req_seen && alloc_delay==0) begin
    alloc_req_seen<=alloc_req_sync;alloc_delay<=4;
    frame_complete<=allocation_is_frame;
    complete_fields<=held_fields;complete_metadata<=held_metadata;
   end else if(alloc_delay!=0) begin
    alloc_delay<=alloc_delay-1'b1;
    if(alloc_delay==1) begin
     allocation0<=next_base0;allocation1<=next_base1;
     alloc_ack<=alloc_req_seen;
    end
   end
  end
 end
 always @(posedge avl_clk or negedge a_reset_n) begin
  if(!a_reset_n) begin
   req_meta<=0;req_sync<=0;ack<=0;dest_sequence<=0;
   write_valid<=0;write_half<=0;write_address<=0;
  end else begin
   req_meta<=req;req_sync<=req_meta;
   if(!write_valid) begin
    if(req_sync[0]!=ack[0] && held_sequence[0]==dest_sequence) begin
     write_valid<=1;write_half<=0;write_address<=held_address[0];
    end else if(req_sync[1]!=ack[1] && held_sequence[1]==dest_sequence) begin
     write_valid<=1;write_half<=1;write_address<=held_address[1];
    end
   end else if(write_done) begin
    ack[write_half]<=req_sync[write_half];
    dest_sequence<=dest_sequence+1'b1;write_valid<=0;
   end
  end
 end
endmodule
