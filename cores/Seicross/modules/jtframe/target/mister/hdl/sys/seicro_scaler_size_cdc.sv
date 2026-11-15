// Persistent latest geometry mailbox. Soft reset never erases a held word or
// its request phase. The input/core clock supplies both settling/hold guards.
module seicro_scaler_size_cdc(
 input wire src_clk,dst_clk,input wire [23:0] src_size,
 output reg [23:0] dst_size=0,output reg dst_update=0
);
 (* preserve *) reg [23:0] held=0;
 (* preserve *) reg req=0,publish=0,ack=0;
 (* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
 reg ack_meta=0,ack_sync=0,req_meta=0,req_sync=0;
 reg [1:0] ack_guard=0;
 reg captured_phase=0;
 always @(posedge src_clk) begin
  ack_meta<=ack;ack_sync<=ack_meta;publish<=req;
  if(ack_sync==req)begin held<=src_size;req<=~req;end
 end
 always @(posedge dst_clk)begin
  req_meta<=publish;req_sync<=req_meta;dst_update<=0;
  if(ack_guard!=0)begin
   ack_guard<=ack_guard-1'b1;
   if(ack_guard==1)ack<=captured_phase;
  end else if(req_sync!=ack)begin
   dst_size<=held;dst_update<=1;captured_phase<=req_sync;ack_guard<=2;
  end
 end
endmodule
