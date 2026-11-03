// Project-owned stable source bundle followed by acknowledged CDC.
// Publish only after three quiet source edges; reset asserts asynchronously
// and releases through two source-clock edges before observing the bundle.
module darkmist_geometry_mailbox #(parameter W=32)(
 input wire src_clk,dst_clk,reset,
 input wire [W-1:0] src_data,output wire [W-1:0] dst_data
);
 (* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED; -name DONT_MERGE_REGISTER ON" *)
 reg [1:0] source_reset=2'b11;
 always @(posedge src_clk or posedge reset) begin
  if(reset) source_reset<=2'b11;
  else source_reset<={source_reset[0],1'b0};
 end
 reg [W-1:0] observed=0;
 reg [1:0] quiet=0;
 always @(posedge src_clk or posedge source_reset[1]) begin
  if(source_reset[1])begin observed<=0;quiet<=0;end
  else if(observed!=src_data)begin observed<=src_data;quiet<=0;end
  else if(quiet!=3)quiet<=quiet+1'b1;
 end
 darkmist_audio_mailbox #(.W(W)) payload(
  .src_clk(src_clk),.dst_clk(dst_clk),.reset(reset),
  .src_valid(quiet==3),.src_data(observed),.dst_data(dst_data),
  .src_idle(),.src_current(),.dst_valid(),.dst_commit());
endmodule