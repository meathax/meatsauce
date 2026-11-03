// SPDX-License-Identifier: GPL-3.0-or-later
// Both source clocks must run for switch completion.
// A stopped selected source parks safely; no timeout can force clock selection.
module spinal_video_clock_switch #(parameter PAYLOAD_WIDTH=4)(
 input wire clk_sys,clk_native,clk_hdmi,reset,request_native,
 input wire [PAYLOAD_WIDTH-1:0] request_payload,
 input wire frame_native,frame_hdmi,
 output wire clk_output,blank_output,pipeline_blank,
 output reg selected_native=0,
 output reg [PAYLOAD_WIDTH-1:0] active_payload=0,
 output wire [5:0] debug_state,
 output wire busy
);
 localparam IDLE=0,OFF_WAIT=1,SETTLE=2,ON_WAIT=3;
 reg [1:0] state=SETTLE;
 reg target_native=0,enable=1;
 reg [PAYLOAD_WIDTH-1:0] target_payload=0;
 reg [2:0] settle=0;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
 reg [1:0] enable_sync=2'b11;
 wire mux_clock,enable_actual;
 cyclonev_clkselect mux(.inclk({clk_native,clk_hdmi,2'b00}),
  .clkselect({1'b1,selected_native}),.outclk(mux_clock));
 cyclonev_clkena #(.clock_type("global clock"),.ena_register_mode("double register"))
  gate(.inclk(mux_clock),.ena(enable),.enaout(enable_actual),.outclk(clk_output));
 always @(posedge clk_sys) begin
  enable_sync<={enable_sync[0],enable_actual};
  if(reset) begin
   // Keep the current selection until the actual dedicated gate acknowledges off.
   enable<=0;state<=OFF_WAIT;enable_sync<=2'b11;
   target_native<=request_native;target_payload<=request_payload;
  end else case(state)
   IDLE:if(request_native!=selected_native || request_payload!=active_payload) begin
    target_native<=request_native;target_payload<=request_payload;
    enable<=0;state<=OFF_WAIT;
   end
   OFF_WAIT:if(!enable_sync[1]) begin
    selected_native<=target_native;active_payload<=target_payload;
    settle<=0;state<=SETTLE;
   end
   SETTLE:if(settle==3) begin enable<=1;state<=ON_WAIT;end
          else settle<=settle+1'b1;
   ON_WAIT:if(enable_sync[1]) state<=IDLE;
  endcase
 end
 assign debug_state={enable_sync[1],enable,state,busy,selected_native};
 assign busy=state!=IDLE || request_native!=selected_native || request_payload!=active_payload;
 wire hold_pipeline=reset || busy;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
 reg [1:0] warm_reset=2'b11;
 always @(posedge clk_output or posedge hold_pipeline)
  if(hold_pipeline) warm_reset<=2'b11;
  else warm_reset<={warm_reset[0],1'b0};
 // HDMI needs only the two output-pipeline drain edges. Frame qualification
 // remains available for the VGA path without holding HDMI DE indefinitely.
 assign pipeline_blank=warm_reset[1];
 reg old_frame=0;
 reg [1:0] complete_frames=0;
 wire selected_frame=selected_native ? frame_native : frame_hdmi;
 always @(posedge clk_output) begin
  if(warm_reset[1]) begin complete_frames<=0;old_frame<=selected_frame;end
  else begin
   old_frame<=selected_frame;
   if(selected_frame && !old_frame && complete_frames!=2) complete_frames<=complete_frames+1'b1;
  end
 end
 assign blank_output=warm_reset[1] || complete_frames!=2;
endmodule
