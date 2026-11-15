// SPDX-License-Identifier: GPL-3.0-or-later
// Staged candidate bridge around the unmodified Irem/JimmyStones donor.
// Shared RAM offset0190..01B7, initialized endpoints00/50. No HPS integration.
module heavyunit_hiscore #(parameter integer PASSIVE_INIT_WITNESS=0) (
 input logic clk,reset,v_sync,paused,osd_open,autosave,
 // Passive native startup witness, already observed on completed CPU writes.
 input logic initialization_witness,
 input logic ioctl_upload,ioctl_download,ioctl_wr,
 input logic [15:0] ioctl_index,input logic [24:0] ioctl_addr,
 input logic [7:0] ioctl_dout,output wire [7:0] ioctl_din,
 output wire ioctl_upload_req,output wire configured,
 // Validated complete host transfer; stock Main exposes no file-save result.
 input logic transfer_complete,transfer_failed,
 output logic save_pending=0,output wire reset_blocked,
 output wire pause_request,output logic table_initialized=0,
 output logic ram_req=0,ram_write=0,
 output logic [12:0] ram_addr=0,output logic [7:0] ram_dout=0,
 input logic ram_ack,input logic [7:0] ram_din,
 output logic fault=0
);
 wire valid_index=ioctl_index==16'd3||ioctl_index==16'd4;
 wire donor_pause,donor_read,donor_write,donor_upload_req;
 wire [12:0] donor_addr;wire [7:0] donor_data;
 logic data_ready=0;logic [7:0] data_from_ram=0;
 logic donor_osd=0,osd_last=0,osd_pending=0,upload_req_last=0;
 logic endpoint_start=0;
 logic restore_pending=0,download_last=0,restore_wrote=0;
 logic [5:0] restore_writes=0;
 // A restored file whose name bytes are not printable ASCII (for example a
 // zero-filled .nvm) is not a game table: records are score[3],scene[2],
 // name[3]. Drop its RAM writes so the game's own default table survives.
 logic file_valid=1;
 wire [5:0] file_byte=ioctl_addr[5:0];
 wire name_byte=ioctl_addr<25'd40 && (file_byte[2:0]>=3'd5);
  // The pristine donor also restores its cached file after a warm reset,
  // without a new host download. Defer every donor RAM operation and pause
  // until ordinary CPU startup has produced this generation's witness.
  wire defer_restore=PASSIVE_INIT_WITNESS!=0 && !table_initialized;
 typedef enum logic [2:0] {S_IDLE,S_PAUSE,S_FIRST,S_LAST,S_HANDOFF} sig_t;
 sig_t sig=S_IDLE;
 typedef enum logic [1:0] {B_IDLE,B_ACK,B_RELEASE,B_GAP} bridge_t;
 bridge_t bridge=B_IDLE;
 logic bridge_signature=0,sig_response=0;
 logic [7:0] sig_data=0;
 // The WIDE bridge publishes only complete validated files. Queued cached
 // restores may survive/rearm through reset; active RAM work must drain first.
 wire restore_active=restore_pending &&
     ((donor_pause&&!defer_restore)||ram_req||bridge!=B_IDLE);
 hiscore #(.HS_ADDRESSWIDTH(13),.HS_SCOREWIDTH(6),
 .HS_CONFIGINDEX(3),.HS_DUMPINDEX(4),.CFG_ADDRESSWIDTH(1),.CFG_LENGTHWIDTH(1))
 u_hiscore(.clk(clk),.paused(paused),.reset(reset),.autosave(autosave),
 .ioctl_upload(ioctl_upload&&valid_index),
 .ioctl_download(ioctl_download&&valid_index),
 .ioctl_wr(ioctl_wr&&valid_index),.ioctl_addr(ioctl_addr),
 .ioctl_index(valid_index?ioctl_index[7:0]:8'hff),
 .ioctl_upload_req(donor_upload_req),.data_ready(data_ready),
 .OSD_STATUS(donor_osd),.v_sync(v_sync),.data_from_hps(ioctl_dout),
 .data_from_ram(data_from_ram),.ram_address(donor_addr),
 .data_to_hps(ioctl_din),.data_to_ram(donor_data),
 .ram_write(donor_write),.ram_read(donor_read),
 .ram_intent_read(),.ram_intent_write(),.pause_cpu(donor_pause),
 .configured(configured));
 assign pause_request=(donor_pause&&!defer_restore)||sig!=S_IDLE||ram_req||fault;
 assign ioctl_upload_req=save_pending;
 assign reset_blocked=pause_request||save_pending||restore_active||
                      (ioctl_download&&valid_index);
 always_ff @(posedge clk) begin
  data_ready<=0;sig_response<=0;donor_osd<=0;
  osd_last<=osd_open;
  download_last<=ioctl_download&&ioctl_index==16'd4;
  upload_req_last<=donor_upload_req;
  if(donor_upload_req&&!upload_req_last)save_pending<=1;
  if(transfer_complete&&!transfer_failed)save_pending<=0;
  // Failure intentionally retains the pending request and donor buffer.
  if(transfer_failed&&save_pending)save_pending<=1;
  if(ioctl_download&&ioctl_index==16'd4&&!download_last)file_valid<=1;
  if(ioctl_download&&ioctl_index==16'd4&&ioctl_wr&&name_byte&&
     (ioctl_dout<8'h20||ioctl_dout>8'h7e))file_valid<=0;
  if(download_last&&!ioctl_download)begin
   restore_pending<=1;restore_writes<=0;restore_wrote<=0;
  end
  if(restore_pending&&restore_wrote&&!donor_pause&&bridge==B_IDLE)
   restore_pending<=0;
  if(initialization_witness)table_initialized<=1;
  if(reset)begin
   sig<=S_IDLE;osd_pending<=0;bridge<=B_IDLE;ram_req<=0;
   table_initialized<=0;endpoint_start<=0;fault<=0;
  end else begin
   if(osd_open&&!osd_last)osd_pending<=1;
   case(sig)
     S_IDLE:if(osd_pending&&configured&&(PASSIVE_INIT_WITNESS==0||table_initialized)&&!donor_pause&&!restore_pending&&
              !save_pending&&!ioctl_upload&&bridge==B_IDLE)begin
     osd_pending<=0;
     if(table_initialized)begin donor_osd<=1;sig<=S_HANDOFF;end
     else sig<=S_PAUSE;
    end
    S_PAUSE:if(paused)sig<=S_FIRST;
    S_FIRST:if(sig_response)begin
     if(sig_data==8'h00)sig<=S_LAST;
     else begin sig<=S_IDLE;table_initialized<=0;end
    end
    S_LAST:if(sig_response)begin
     if(sig_data==8'h50)begin donor_osd<=1;sig<=S_HANDOFF;end
     else begin sig<=S_IDLE;table_initialized<=0;end
    end
    // Keep ownership continuously asserted until the donor takes it.
    S_HANDOFF:if(donor_pause)sig<=S_IDLE;
    default:sig<=S_IDLE;
   endcase
   case(bridge)
    B_IDLE:if(paused&&!fault)begin
     if(sig==S_FIRST||sig==S_LAST)begin
      ram_req<=1;ram_write<=0;
      ram_addr<=sig==S_FIRST?13'h190:13'h1b7;
      bridge_signature<=1;bridge<=B_ACK;
     end else if(sig==S_IDLE&&!defer_restore&&(donor_read||donor_write))begin
      if(donor_addr<13'h190||donor_addr>13'h1b7||
         (donor_write&&!table_initialized))fault<=1;
      else if(donor_write&&restore_pending&&!file_valid)begin
       data_ready<=1;bridge<=B_RELEASE;bridge_signature<=0;
       restore_writes<=restore_writes+6'd1;
       if(restore_writes==6'd39)restore_wrote<=1;
      end else begin
       ram_req<=1;ram_write<=donor_write;ram_addr<=donor_addr;
       ram_dout<=donor_data;bridge_signature<=0;bridge<=B_ACK;
      end
     end
    end
    B_ACK:if(ram_ack)begin
     ram_req<=0;bridge<=B_RELEASE;
     if(!ram_write)begin
      if(ram_addr==13'h190)endpoint_start<=ram_din==8'h00;
      // Initialization is a per-reset-generation witness. A legitimate
      // changed score can alter a byte that was a cold-init sentinel.
      if(ram_addr==13'h1b7&&!table_initialized)
       table_initialized<=endpoint_start&&ram_din==8'h50;
     end
     if(bridge_signature)begin sig_response<=1;sig_data<=ram_din;end
     else begin
      data_ready<=1;data_from_ram<=ram_din;
      if(ram_write&&restore_pending)begin
       restore_writes<=restore_writes+6'd1;
       if(restore_writes==6'd39)restore_wrote<=1;
      end
     end
    end
    B_RELEASE:if(bridge_signature||(!donor_read&&!donor_write))bridge<=B_GAP;
    B_GAP:bridge<=B_IDLE;
    default:bridge<=B_IDLE;
   endcase
  end
 end
endmodule
