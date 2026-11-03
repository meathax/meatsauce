// Project-owned parent-local HDMI pipelines with acknowledged mode blanking.
// Raw configuration request is sampled ONLY by desired_meta.
module darkmist_hdmi_parent_pipeline(
 input wire game_clk,scaler_clk,request_mode,
 input wire [23:0] game_data,scaler_data,
 input wire game_hs,game_vs,game_de,scaler_hs,scaler_vs,scaler_de,
 input wire scaler_cs,scaler_csync,
 output wire [23:0] out_data,output wire out_hs,out_vs,out_de,
 output wire mode_ready,output reg active_mode=0
);
 reg [26:0] g0=0,g1=0,g2=0,s0=0,s1=0;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
 reg desired_meta=0,desired_sync=0;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
 reg active_meta=0,active_sync=0,blank_meta=0,blank_sync=0,csync_meta=0,csync_sync=0;
 reg blank=0,target=0;
 reg [1:0] state=0,flush_count=0;
 reg [2:0] prepare_count=0,game_warm=0,scaler_warm=0;
 reg game_prepared=0,game_ready=0,scaler_ready=0,gprevvs=0,sprevvs=0;
 wire command=target;
 wire scaler_command,game_ack;
 wire command_valid,ack_valid,command_commit,ack_commit;
 reg scaler_seen=0;
 reg [2:0] scaler_prepare_count=0;
 reg scaler_prepared=0;
 // Constant reset: original HDMI pipeline has power-up initialization but no
 // game-reset action. Mailbox's existing local release initialization applies.
 darkmist_audio_mailbox #(.W(1),.INIT(1'b0)) mode_to_scaler(
  .src_clk(game_clk),.dst_clk(scaler_clk),.reset(1'b0),
  .src_valid(state==1),.src_data(command),.src_idle(),.src_current(),
  .dst_data(scaler_command),.dst_valid(command_valid),.dst_commit(command_commit));
 darkmist_audio_mailbox #(.W(1),.INIT(1'b0)) mode_ack_to_game(
  .src_clk(scaler_clk),.dst_clk(game_clk),.reset(1'b0),
  .src_valid(scaler_prepared),.src_data(scaler_seen),.src_idle(),.src_current(),
  .dst_data(game_ack),.dst_valid(ack_valid),.dst_commit(ack_commit));
 always @(posedge game_clk) begin
  g0<={game_de,game_vs,game_hs,game_data};g1<=g0;g2<=g1;
  desired_meta<=request_mode;desired_sync<=desired_meta;
  gprevvs<=g2[25];
  if(blank || !active_mode) begin game_warm<=0;game_ready<=0;end
  else begin game_warm<={game_warm[1:0],1'b1};if(game_warm[2] && !g2[25] && g1[25])game_ready<=1;end
  case(state)
   0:if(desired_sync!=active_mode)begin
     blank<=1;target<=desired_sync;state<=1;
     prepare_count<=0;game_prepared<=0;
    end
   1:begin
     if(prepare_count<3)prepare_count<=prepare_count+1'b1;
     else if(!target || (!gprevvs && g2[25]))game_prepared<=1;
     if(game_prepared && ack_valid && game_ack==command)begin
      active_mode<=target;flush_count<=0;state<=2;
     end
    end
   2:if(flush_count==3)begin blank<=0;state<=0;end
     else flush_count<=flush_count+1'b1;
   default:begin blank<=1;state<=0;end
  endcase
 end
 always @(posedge scaler_clk) begin
  s0<={scaler_de,scaler_vs,(csync_sync ? scaler_cs : scaler_hs),scaler_data};s1<=s0;
  csync_meta<=scaler_csync;csync_sync<=csync_meta;
  active_meta<=active_mode;active_sync<=active_meta;
  blank_meta<=blank;blank_sync<=blank_meta;
  sprevvs<=s1[25];
  if(active_sync || blank_sync)begin scaler_warm<=0;scaler_ready<=0;end
  else begin scaler_warm<={scaler_warm[1:0],1'b1};if(scaler_warm[2] && !s1[25] && s0[25])scaler_ready<=1;end
  if(command_valid && scaler_command!=scaler_seen)begin
   scaler_seen<=scaler_command;scaler_prepare_count<=0;scaler_prepared<=0;
   // Explicitly discard previous mode's display qualification.
   scaler_ready<=0;scaler_warm<=0;
  end else if(command_valid && !scaler_prepared)begin
   if(scaler_prepare_count<3)scaler_prepare_count<=scaler_prepare_count+1'b1;
   else if(scaler_seen || (!sprevvs && s1[25]))scaler_prepared<=1;
  end
 end
 wire game_qualified=!blank && game_ready;
 wire scaler_qualified=!blank_sync && scaler_ready;
 wire ready=active_mode ? game_qualified : scaler_qualified;
 wire [26:0] selected=active_mode ? g2 : s1;
 assign out_data=ready ? selected[23:0] : 24'b0;
 assign out_hs=ready && selected[24];assign out_vs=ready && selected[25];
 assign out_de=ready && selected[26];assign mode_ready=ready;
endmodule
