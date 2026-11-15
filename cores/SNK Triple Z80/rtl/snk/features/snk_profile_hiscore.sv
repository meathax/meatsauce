// SPDX-License-Identifier: GPL-3.0-or-later
// Source-descriptor adapter candidate. Actual board readiness remains per-game work.
// HPS nvram files must be keyed by the canonical MRA setname (raw dump format).
module snk_profile_hiscore #(
 parameter MAX_CONFIG_BYTES=40,parameter MAX_DUMP_BYTES=248,parameter RETRY_CYCLES=256
)(
 input wire clk,reset,input wire [7:0] profile,
 input wire paused,autosave,OSD_STATUS,storage_error,
 input wire ioctl_upload,ioctl_download,ioctl_wr,
 input wire [24:0] ioctl_addr,input wire [7:0] ioctl_index,data_from_hps,
 output wire [7:0] data_to_hps,output reg ioctl_upload_req=0,
 output wire [7:0] ioctl_upload_index,output wire configured,pause_request,
 output wire hs_req,output reg hs_write=0,output reg [15:0] hs_addr=0,
 output reg [7:0] hs_wdata=0,input wire hs_ack,input wire [7:0] hs_rdata,
 output wire fault
);
 localparam integer CFG_COUNT_BITS=(MAX_CONFIG_BYTES<2) ? 1 : $clog2(MAX_CONFIG_BYTES+1);
 localparam integer DUMP_COUNT_BITS=(MAX_DUMP_BYTES<2) ? 1 : $clog2(MAX_DUMP_BYTES+1);
 localparam integer RETRY_BITS=(RETRY_CYCLES<1) ? 1 :
                               ((RETRY_CYCLES>65535) ? 16 : $clog2(RETRY_CYCLES+1));
 reg [7:0] current_profile=255;
 wire profile_changed=profile!=current_profile;
 wire game_loading=ioctl_download&&ioctl_index==0;
 wire cfg_transfer=ioctl_download&&ioctl_index==3;
 wire dump_transfer=ioctl_download&&ioctl_index==4;
 reg last_cfg=0,last_dump=0,last_osd=0;
 reg cfg_valid=0,cache_valid=0,cfg_bad=0,dump_bad=0,address_bad=0,storage_bad=0;
 reg [CFG_COUNT_BITS-1:0] cfg_count=0;
 reg [DUMP_COUNT_BITS-1:0] dump_count=0;
 reg [7:0] cfg[0:MAX_CONFIG_BYTES-1];
 reg [7:0] cache[0:MAX_DUMP_BYTES-1];
 wire [7:0] expected_byte;wire [8:0] expected_cfg,expected_dump;
 wire profile_supported,range_valid;
 snk_hiscore_contract contract(.profile(profile),.descriptor_addr(ioctl_addr[7:0]),
  .ram_addr(hs_addr),.descriptor_data(expected_byte),.descriptor_bytes(expected_cfg),
  .dump_bytes(expected_dump),.supported(profile_supported),.range_valid(range_valid));
 assign configured=cfg_valid&&profile_supported&&!cfg_bad&&!profile_changed&&!game_loading;
 assign ioctl_upload_index=8'd4;
 assign data_to_hps=configured&&cache_valid&&ioctl_addr<expected_dump ? cache[ioctl_addr[7:0]] : 8'hff;
 assign fault=cfg_bad||dump_bad||address_bad||storage_bad;
 localparam IDLE=0,CHECK_LAUNCH=1,CHECK_WAIT=2,COPY_LAUNCH=3,COPY_WAIT=4;
 reg [2:0] state=IDLE;
 reg request_pending=0,save_pending=0,restore_pending=0,restoring=0,last_reset=0;
 reg [5:0] cfg_cursor=16;
 reg check_last=0;
 // A cached pre-reset signature must become invalid before it can admit restore.
 reg restore_needs_invalid=0;
 reg [7:0] byte_cursor=0,cache_cursor=0;
 reg [RETRY_BITS-1:0] retry=0;
 // Quartus17 cannot map global RAM reads inside a function to physical read ports.
 wire [15:0] current_block_addr={cfg[cfg_cursor+2],cfg[cfg_cursor+3]};
 wire [7:0] block_length=cfg[cfg_cursor+4];
 wire [7:0] signature=cfg[cfg_cursor+(check_last ? 6 : 5)];
 // hs_req waits one clock after request_pending (hs_addr is stable by then) and uses a registered range check,
 // so the contract decode no longer sits in the same cycle as the shared-RAM ack/cache load enable (96MHz).
 reg range_valid_q=0,request_pending_d=0;
 always @(posedge clk) begin range_valid_q<=range_valid;request_pending_d<=request_pending; end
 assign hs_req=request_pending&&request_pending_d&&configured&&!reset&&!cfg_transfer&&!dump_transfer&&range_valid_q;
 assign pause_request=configured&&!reset&&(state!=IDLE||request_pending);

 always @(posedge clk) begin
  current_profile<=profile;last_cfg<=cfg_transfer;last_dump<=dump_transfer;
  last_osd<=OSD_STATUS;last_reset<=reset;
  if(profile_changed||game_loading)begin
   cfg_valid<=0;cache_valid<=0;cfg_bad<=0;dump_bad<=0;address_bad<=0;storage_bad<=0;
   cfg_count<=0;dump_count<=0;save_pending<=0;restore_pending<=0;restore_needs_invalid<=1;
   ioctl_upload_req<=0;request_pending<=0;state<=IDLE;retry<=0;
  end else begin
   if(cfg_transfer)begin
    request_pending<=0;state<=IDLE;save_pending<=0;restore_pending<=0;
    ioctl_upload_req<=0;cache_valid<=0;cfg_valid<=0;
    if(!last_cfg)begin cfg_count<=0;cfg_bad<=0;dump_bad<=0;address_bad<=0;end
    if(ioctl_wr)begin
     if(profile_supported&&ioctl_addr<expected_cfg&&ioctl_addr<MAX_CONFIG_BYTES&&
       ioctl_addr==(last_cfg ? cfg_count : 9'd0)&&data_from_hps==expected_byte)begin
      cfg[ioctl_addr[5:0]]<=data_from_hps;
      cfg_count<=(last_cfg ? cfg_count : {CFG_COUNT_BITS{1'b0}})+1'b1;
     end else cfg_bad<=1;
    end
   end
   if(last_cfg&&!cfg_transfer)cfg_valid<=cfg_count==expected_cfg&&!cfg_bad&&profile_supported;
   if(dump_transfer)begin
    request_pending<=0;state<=IDLE;ioctl_upload_req<=0;cache_valid<=0;restore_pending<=0;
    if(!last_dump)begin dump_count<=0;dump_bad<=0;end
    if(ioctl_wr)begin
     if(configured&&ioctl_addr<expected_dump&&ioctl_addr<MAX_DUMP_BYTES&&ioctl_addr==(last_dump ? dump_count : 9'd0))begin
      cache[ioctl_addr[7:0]]<=data_from_hps;dump_count<=(last_dump ? dump_count : {DUMP_COUNT_BITS{1'b0}})+1'b1;
     end else dump_bad<=1;
    end
   end
   if(last_dump&&!dump_transfer)begin
    cache_valid<=dump_count==expected_dump&&!dump_bad&&configured;
    restore_pending<=dump_count==expected_dump&&!dump_bad&&configured;
    if(dump_count!=expected_dump)dump_bad<=1;
   end
   if(storage_error)begin ioctl_upload_req<=0;storage_bad<=1;end
   if(ioctl_upload&&ioctl_index==4)ioctl_upload_req<=0;
   if(OSD_STATUS&&!last_osd&&configured)save_pending<=1;
   if(reset)begin
    request_pending<=0;state<=IDLE;retry<=0;
    if(!last_reset&&cache_valid)restore_pending<=1;
    restore_needs_invalid<=1;
   end else if(!cfg_transfer&&!dump_transfer&&configured)begin
    if(retry!=0)retry<=retry-1'b1;
    case(state)
     IDLE:if((restore_needs_invalid||restore_pending||(save_pending&&!ioctl_upload&&!ioctl_upload_req))&&retry==0)begin
      cfg_cursor<=16;check_last<=0;restoring<=restore_pending;state<=CHECK_LAUNCH;
     end
     CHECK_LAUNCH:if(paused)begin
      hs_addr<=current_block_addr+(check_last ? block_length-1'b1 : 16'd0);
      hs_write<=0;hs_wdata<=0;request_pending<=1;state<=CHECK_WAIT;
     end
     CHECK_WAIT:if(hs_req&&hs_ack)begin
      request_pending<=0;
      if(hs_rdata!=signature)begin
       restore_needs_invalid<=0;
       state<=IDLE;retry<=RETRY_CYCLES;
      end
      else if(!check_last)begin check_last<=1;state<=CHECK_LAUNCH;end
      else if(cfg_cursor+8<expected_cfg)begin cfg_cursor<=cfg_cursor+8;check_last<=0;state<=CHECK_LAUNCH;end
      else if(restore_needs_invalid)begin state<=IDLE;retry<=RETRY_CYCLES;end
      else begin cfg_cursor<=16;byte_cursor<=0;cache_cursor<=0;state<=COPY_LAUNCH;end
     end
     COPY_LAUNCH:if(paused)begin
      hs_addr<=current_block_addr+byte_cursor;hs_write<=restoring;
      hs_wdata<=restoring ? cache[cache_cursor] : 0;request_pending<=1;state<=COPY_WAIT;
     end
     COPY_WAIT:if(hs_req&&hs_ack)begin
      request_pending<=0;
      if(!restoring)cache[cache_cursor]<=hs_rdata;
      if(cache_cursor+9'd1==expected_dump)begin
       state<=IDLE;cache_valid<=1;
       if(restoring)restore_pending<=0;
       else begin save_pending<=0;if(autosave&&!storage_error)ioctl_upload_req<=1;end
      end else begin
       cache_cursor<=cache_cursor+1'b1;
       if(byte_cursor+1'b1==block_length)begin cfg_cursor<=cfg_cursor+8;byte_cursor<=0;end
       else byte_cursor<=byte_cursor+1'b1;
       state<=COPY_LAUNCH;
      end
     end
     default:begin state<=IDLE;request_pending<=0;end
    endcase
    if(request_pending&&!range_valid)begin address_bad<=1;request_pending<=0;state<=IDLE;save_pending<=0;restore_pending<=0;end
   end
  end
 end
`ifndef SYNTHESIS
 reg held=0;reg [15:0] held_addr=0;reg [7:0] held_data=0;reg held_write=0;
 always @(posedge clk)begin
  if(hs_req)assert(paused&&configured&&range_valid);
  if(held&&!reset&&!profile_changed&&!game_loading&&!cfg_transfer&&!dump_transfer)
   assert(hs_req&&hs_addr==held_addr&&hs_wdata==held_data&&hs_write==held_write);
  held<=hs_req&&!hs_ack;held_addr<=hs_addr;held_data<=hs_wdata;held_write<=hs_write;
 end
`endif
endmodule
