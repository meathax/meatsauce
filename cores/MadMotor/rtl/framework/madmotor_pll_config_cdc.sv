// SPDX-License-Identifier: GPL-3.0-or-later
// Serialized HPS custom PLL commands. Source words remain owned while busy;
// the host acknowledgement stalls before the following word can overwrite them.
module madmotor_pll_config_cdc (
 input wire src_clk, dst_clk, dst_reset,
 input wire src_request, src_apply,
 input wire [37:0] src_payload,
 output wire src_busy, src_ready,
 input wire dst_waitrequest,
 output reg dst_write = 0,
 output reg [5:0] dst_address = 0,
 output reg [31:0] dst_data = 0
);
 (* preserve, dont_merge, dont_retime, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
 reg request_meta=0, request_sync=0, acknowledge_meta=0, acknowledge_sync=0;
 (* preserve, dont_merge, dont_retime, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
 reg apply_meta=0, apply_sync=0, apply_history=0, ready_meta=0, ready_sync=0;
 (* preserve, dont_merge, dont_retime *) reg acknowledge=0, ready=0;
 reg old_wait=0, apply_pending=0, active=0, active_custom=0;
 assign src_busy = src_request != acknowledge_sync;
 assign src_ready = ready_sync;
 always @(posedge src_clk) begin
  acknowledge_meta<=acknowledge; acknowledge_sync<=acknowledge_meta;
  ready_meta<=ready; ready_sync<=ready_meta;
 end
 always @(posedge dst_clk) begin
  request_meta<=src_request; request_sync<=request_meta;
  apply_meta<=src_apply; apply_sync<=apply_meta; apply_history<=apply_sync;
  old_wait<=dst_waitrequest;
  if(apply_sync && !apply_history) apply_pending<=1;
  // Reset pauses accepted source ownership; it never fabricates an ACK or
  // forgets a pending command. The controller retries after safe release.
  if(dst_reset) begin dst_write<=0; ready<=0; end
  else begin
   if(old_wait && !dst_waitrequest && apply_sync) ready<=1;
   if(active) begin
    dst_write<=1;
    if(dst_write && !dst_waitrequest) begin
     dst_write<=0; active<=0;
     if(active_custom) acknowledge<=request_sync;
    end
   end else if(apply_pending) begin
    dst_address<=2; dst_data<=0; active_custom<=0;
    dst_write<=1; active<=1; apply_pending<=0;
   end else if(request_sync!=acknowledge && !apply_sync) begin
    {dst_address,dst_data}<=src_payload; active_custom<=1;
    dst_write<=1; active<=1;
   end
  end
 end
endmodule
