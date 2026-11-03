// Project-owned 77-bit framebuffer descriptor CDC. Stock sys/ remains unchanged.
// Each accepted source word remains held until its output-frame commit is acknowledged.
module darkmist_framebuffer_mailbox(
 input wire src_clk,dst_clk,reset,src_valid,vs,
 input wire [76:0] src_data,
 output wire src_idle,src_current,
 output reg [76:0] dst_data=77'd0,
 output reg dst_valid=0,dst_commit=0
);
 reg [76:0] source_hold=77'd0;
 reg request=0,acknowledge=0;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS", preserve *)
 reg req_meta=0,req_sync=0,ack_meta=0,ack_sync=0;
 reg src_seen=0,dst_pending=0,dst_request=0,vs_previous=0;
 // Common asynchronous assertion, independently synchronized release in each clock domain.
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED", preserve *)
 reg [1:0] src_reset=2'b11,dst_reset=2'b11;
 always @(posedge src_clk or posedge reset)
  if(reset)src_reset<=2'b11;else src_reset<={src_reset[0],1'b0};
 always @(posedge dst_clk or posedge reset)
  if(reset)dst_reset<=2'b11;else dst_reset<={dst_reset[0],1'b0};
 assign src_idle=(ack_sync==request)&&!src_reset[1];
 assign src_current=src_idle&&src_seen&&(source_hold==src_data);
 always @(posedge src_clk or posedge src_reset[1])begin
  if(src_reset[1])begin ack_meta<=0;ack_sync<=0;request<=0;source_hold<=0;src_seen<=0;end
  else begin
   ack_meta<=acknowledge;ack_sync<=ack_meta;
   if(src_valid&&src_idle&&(!src_seen||source_hold!=src_data))begin
    source_hold<=src_data;request<=~request;src_seen<=1;
   end
  end
 end
 always @(posedge dst_clk or posedge dst_reset[1])begin
  if(dst_reset[1])begin
   req_meta<=0;req_sync<=0;acknowledge<=0;dst_pending<=0;dst_request<=0;
   dst_data<=0;dst_valid<=0;dst_commit<=0;vs_previous<=0;
  end else begin
   req_meta<=request;req_sync<=req_meta;dst_commit<=0;vs_previous<=vs;
   if(!dst_pending&&req_sync!=acknowledge)begin dst_pending<=1;dst_request<=req_sync;end
   // No ACK before this boundary: already accepted words cannot coalesce or tear a frame.
   if(dst_pending&&vs&&!vs_previous)begin
    dst_data<=source_hold;dst_valid<=1;dst_commit<=1;
    acknowledge<=dst_request;dst_pending<=0;
   end
  end
 end
endmodule
