// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Darkmist contributors
// Bundled snapshot mailbox. Control crosses through two registers; data stays
// held at source until capture completes and destination requests again.
// req/ack cross only through dedicated fanout-1 launch registers so fitter
// register duplication cannot create an unconstrained copy driving a synchronizer.
module darkmist_metrics_cdc #(parameter WIDTH=128, parameter SETTLE=2)(
 input src_clk,dst_clk,reset,
 input [WIDTH-1:0] src_metrics,
 output reg [WIDTH-1:0] dst_metrics,
 output reg dst_valid
);
 (* ASYNC_REG="TRUE",preserve *) reg [1:0] src_reset_pipe=3,dst_reset_pipe=3;
 always @(posedge src_clk or posedge reset)
  if(reset) src_reset_pipe<=3;else src_reset_pipe<={src_reset_pipe[0],1'b0};
 always @(posedge dst_clk or posedge reset)
  if(reset) dst_reset_pipe<=3;else dst_reset_pipe<={dst_reset_pipe[0],1'b0};
 reg req=0,ack=0;
 (* preserve *) reg req_launch=0,ack_launch=0;
 (* ASYNC_REG="TRUE",preserve *) reg [1:0] req_sync=0,ack_sync=0;
 reg [WIDTH-1:0] source_hold=0;
 reg busy=0,settling=0;
 integer settle_count=0;
 initial begin dst_metrics=0;dst_valid=0;end
 always @(posedge src_clk or posedge src_reset_pipe[1]) begin
  if(src_reset_pipe[1]) begin req_sync<=0;ack<=0;ack_launch<=0;source_hold<=0;end
  else begin
   req_sync<={req_sync[0],req_launch};
   ack_launch<=ack;
   if(req_sync[1]!=ack) begin source_hold<=src_metrics;ack<=req_sync[1];end
  end
 end
 always @(posedge dst_clk or posedge dst_reset_pipe[1]) begin
  if(dst_reset_pipe[1]) begin
   ack_sync<=0;req<=0;req_launch<=0;busy<=0;settling<=0;settle_count<=0;
   dst_metrics<=0;dst_valid<=0;
  end else begin
   ack_sync<={ack_sync[0],ack_launch};
   req_launch<=req;
   if(!busy) begin req<=~req;busy<=1;end
   else if(!settling && ack_sync[1]==req) begin
    settling<=1;settle_count<=SETTLE;
   end else if(settling) begin
    if(settle_count!=0) settle_count<=settle_count-1;
    else begin
     dst_metrics<=source_hold;dst_valid<=1;busy<=0;settling<=0;
    end
   end
  end
 end
endmodule
