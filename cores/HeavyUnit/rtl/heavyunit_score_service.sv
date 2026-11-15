// SPDX-License-Identifier: GPL-3.0-or-later
// Isolated stock-HPS score service. Board RAM remains owned by the board.
module heavyunit_score_service (
 input logic clk,platform_reset,game_reset,v_sync,osd_open,autosave,pause_active,
 input logic host_download,host_upload,host_wr,host_rd,
 input logic [15:0] host_index,host_dout,
 input logic [26:0] host_addr,
 output wire [15:0] host_din,
 output wire host_wait,host_selected,host_upload_req,
 output wire [7:0] host_upload_index,
 output wire pause_request,reset_blocked,game_reset_applied,
 output wire configured,table_initialized,save_pending,upload_ready,
 output wire upload_transfer_complete,drained,paused_quiet,owned,fault,protocol_error,
 output wire [3:0] error_code,
 output wire [5:0] transferred_bytes,
 input logic memory_idle,storage_drained,
 input logic [2:0] cpu_req_valid,cpu_req_io,cpu_req_write,cpu_wait_n,
 input logic [47:0] cpu_req_addr,
 input logic [23:0] cpu_req_data,
 output wire [2:0] cpu_req_ready,cpu_rsp_valid,
 output wire [23:0] cpu_rsp_data,
 output wire [2:0] board_req_valid,board_req_io,board_req_write,
 output wire [47:0] board_req_addr,
 output wire [23:0] board_req_data,
 input logic [2:0] board_req_ready,board_rsp_valid,
 input logic [23:0] board_rsp_data
);
 wire byte_download,byte_upload,byte_wr;
 wire [15:0] byte_index;
 wire [24:0] byte_addr;
 wire [7:0] byte_dout,byte_din,score_dout,score_din;
 wire [12:0] score_addr;
 wire score_req,score_write,score_ack,score_fault,arbiter_fault;
 wire score_blocked,word_blocked,arbiter_blocked,score_pause,score_upload_req;
 wire word_drained;
 logic deferred_game_reset=0;
 logic initialization_observed=0,first_endpoint_observed=0;
 logic [1:0] endpoint_pending=0,endpoint_is_last=0;
 logic [1:0][7:0] endpoint_value=0;
 wire donor_paused=pause_active && (paused_quiet || owned);
 assign reset_blocked=score_blocked || word_blocked || arbiter_blocked || fault;
 assign game_reset_applied=!platform_reset && (game_reset || deferred_game_reset) && !reset_blocked;
 always_ff @(posedge clk) begin
  if(platform_reset)deferred_game_reset<=0;
  else if(game_reset && reset_blocked)deferred_game_reset<=1;
  else if(game_reset_applied)deferred_game_reset<=0;
 end
 // Native sub CPU startup clears RAM and then writes E190=00 / E1B7=50.
 // Observe completed ordinary CPU transactions; never pause or scan RAM here.
 // Captured request fields survive bus latency until the matching response.
 always_ff @(posedge clk) begin
  if(platform_reset || game_reset_applied)begin
   initialization_observed<=0;first_endpoint_observed<=0;
   endpoint_pending<=0;endpoint_is_last<=0;endpoint_value<=0;
  end else begin
   for(integer cpu=0;cpu<2;cpu=cpu+1)begin
    if(!owned && cpu_req_valid[cpu] && cpu_req_ready[cpu] &&
       !cpu_req_io[cpu] && cpu_req_write[cpu] &&
       (cpu_req_addr[cpu*16+:16]==16'he190 || cpu_req_addr[cpu*16+:16]==16'he1b7))begin
     endpoint_pending[cpu]<=1;
     endpoint_is_last[cpu]<=cpu_req_addr[cpu*16+:16]==16'he1b7;
     endpoint_value[cpu]<=cpu_req_data[cpu*8+:8];
    end
    if(!owned && board_rsp_valid[cpu] && endpoint_pending[cpu])begin
     endpoint_pending[cpu]<=0;
     if(endpoint_is_last[cpu])begin
      if(endpoint_value[cpu]==8'h50 && first_endpoint_observed)initialization_observed<=1;
     end else first_endpoint_observed<=endpoint_value[cpu]==8'h00;
    end
   end
  end
 end
 assign pause_request=score_pause || owned || fault;
 assign host_upload_req=score_upload_req && upload_ready;
 assign host_upload_index=8'd4;
 // Host protocol errors are per-transfer (see heavyunit_hiscore_hps_words);
 // only internal RAM-ownership faults are fatal.
 assign fault=score_fault || arbiter_fault;
 assign drained=word_drained && !arbiter_blocked && !score_pause;
 heavyunit_hiscore_hps_words words(
  .clk,.reset(platform_reset),.host_download,.host_upload,.host_wr,.host_rd,
  .host_index,.host_dout,.host_addr,.host_din,.host_wait,.selected(host_selected),
  .upload_prepare(save_pending),.upload_ready,.upload_transfer_complete,.transferred_bytes,
  .drained(word_drained),.reset_blocked(word_blocked),.protocol_error,.error_code,
  .byte_download,.byte_upload,.byte_wr,.byte_index,.byte_addr,.byte_dout,.byte_din,
  .accepted_bytes(),.cached_bytes(),.committed_bytes()
 );
 heavyunit_hiscore #(.PASSIVE_INIT_WITNESS(1)) scores(
  .clk,.reset(platform_reset || game_reset_applied),.v_sync,.paused(donor_paused),.osd_open,.autosave,
  .initialization_witness(initialization_observed),
  .ioctl_upload(byte_upload),.ioctl_download(byte_download),.ioctl_wr(byte_wr),
  .ioctl_index(byte_index),.ioctl_addr(byte_addr),.ioctl_dout(byte_dout),.ioctl_din(byte_din),
  .ioctl_upload_req(score_upload_req),.configured,.transfer_complete(upload_transfer_complete),
  .transfer_failed(1'b0),.save_pending,.reset_blocked(score_blocked),
  .pause_request(score_pause),.table_initialized,.fault(score_fault),
  .ram_req(score_req),.ram_write(score_write),.ram_addr(score_addr),.ram_dout(score_dout),
  .ram_ack(score_ack),.ram_din(score_din)
 );
 heavyunit_hiscore_bus_arbiter arbiter(
  .clk,.reset(platform_reset),.pause_active,.memory_idle,.storage_drained,
  .cpu_req_valid,.cpu_req_io,.cpu_req_write,.cpu_wait_n,.cpu_req_addr,.cpu_req_data,
  .cpu_req_ready,.cpu_rsp_valid,.cpu_rsp_data,
  .board_req_valid,.board_req_io,.board_req_write,.board_req_addr,.board_req_data,
  .board_req_ready,.board_rsp_valid,.board_rsp_data,
  .score_req,.score_write,.score_addr,.score_dout,.score_ack,.score_din,
  .paused_quiet,.owned,.reset_blocked(arbiter_blocked),.fault(arbiter_fault)
 );
endmodule
