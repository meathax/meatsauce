// Project-owned bundled-data CDC proposal. Does not modify sys/.
// One held source word; synchronized request/ack; extra destination settling edge.
// source_valid describes a coherent source-domain bundle; latest unsent data may coalesce.
module darkmist_audio_mailbox #(parameter W=32, parameter [W-1:0] INIT={W{1'b0}})(
 input wire src_clk,dst_clk,reset,
 input wire src_valid,input wire [W-1:0] src_data,
 output wire src_idle,output wire src_current,
 output reg [W-1:0] dst_data=INIT,output reg dst_valid=0,
 output reg dst_commit=0
);
 reg [W-1:0] source_hold=INIT;
 reg request=0,acknowledge=0;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
 reg req_meta=0,req_sync=0,ack_meta=0,ack_sync=0;
 reg src_seen=0,dst_pending=0,dst_request=0;
 // Asynchronous common assertion; independent synchronized release in each domain.
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
 reg [1:0] src_reset=2'b11,dst_reset=2'b11;
 always @(posedge src_clk or posedge reset)
  if(reset)src_reset<=2'b11;else src_reset<={src_reset[0],1'b0};
 always @(posedge dst_clk or posedge reset)
  if(reset)dst_reset<=2'b11;else dst_reset<={dst_reset[0],1'b0};
 assign src_idle=(ack_sync==request)&&!src_reset[1];
 assign src_current=src_idle&&src_seen&&(source_hold==src_data);
 always @(posedge src_clk or posedge src_reset[1])begin
  if(src_reset[1])begin ack_meta<=0;ack_sync<=0;request<=0;source_hold<=INIT;src_seen<=0;end
  else begin
   ack_meta<=acknowledge;ack_sync<=ack_meta;
   if(src_valid&&src_idle&&(!src_seen||source_hold!=src_data))begin
    source_hold<=src_data;request<=~request;src_seen<=1;
   end
  end
 end
 always @(posedge dst_clk or posedge dst_reset[1])begin
  if(dst_reset[1])begin req_meta<=0;req_sync<=0;acknowledge<=0;dst_pending<=0;dst_request<=0;dst_data<=INIT;dst_valid<=0;dst_commit<=0;end
  else begin
   req_meta<=request;req_sync<=req_meta;dst_commit<=0;
   if(!dst_pending&&req_sync!=acknowledge)begin dst_pending<=1;dst_request<=req_sync;end
   if(dst_pending)begin
    dst_data<=source_hold;dst_valid<=1;dst_commit<=1;acknowledge<=dst_request;dst_pending<=0;
   end
  end
 end
endmodule
