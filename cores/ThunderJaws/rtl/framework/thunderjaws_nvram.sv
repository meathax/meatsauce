// SPDX-License-Identifier: GPL-3.0-or-later
// Main_MiSTer exposes one arcade NVRAM index/size. Index4 therefore carries one
// versioned2164-byte image:16-byte TJNV header,2048 EEPROM bytes,100 hiscore bytes.
// Complete downloads stage before application. Uploads use an immutable paused
// snapshot; accepting the standard hiscore payload is separate from HPS completion.
module thunderjaws_nvram (
 input wire clk_sys,init_reset,osd_status,autosave,paused,can_restore,
 input wire ioctl_download,ioctl_upload,ioctl_wr,
 input wire [15:0] ioctl_index,
 input wire [26:0] ioctl_addr,
 input wire [7:0] ioctl_data,
 output wire ioctl_wait,
 output reg upload_request,
 output wire [7:0] upload_data,
 output wire pause_request,
 output reg restore,load_we,
 output wire restore_pending,
 output reg [10:0] load_address,
 output reg [7:0] load_data,
 output wire [10:0] dump_address,
 input wire [7:0] dump_data,
 input wire eeprom_modified,
 output reg dirty,storage_error,
 input wire hs_upload_request,hs_pause_request,hs_configured,signature_ready,
 input wire [7:0] hs_upload_data,
 output wire hs_upload,hs_download,hs_wr,
 output wire [24:0] hs_address,
 output wire [7:0] hs_index,hs_data
);
 localparam FILE_BYTES=2164,EP_BASE=16,HS_BASE=2064;
 localparam IDLE=0,WAIT_HS=1,SAVE_PAUSE=2,EP_SAVE_PRIME=3,EP_SAVE_COPY=4,
  HS_SAVE_PRIME=5,HS_SAVE_COPY=6,SAVE_READY=7,RESTORE_WAIT=8,
  EP_RESTORE_PRIME=9,EP_RESTORE_COPY=10,HS_RESTORE_PRIME=11,HS_RESTORE_WRITE=12,
  HS_RESTORE_END=13,RESTORE_DONE=14;
 reg [3:0] state;
 reg [10:0] cursor;
 reg [7:0] ep_shadow[0:2047],hs_shadow[0:127];
 reg [7:0] ep_q,hs_q;
 reg [127:0] rx_header;
 reg [12:0] rx_count;
 reg rx_error,last_receive,last_osd,last_upload,terminal_seen,hs_seen,hs_valid,received_hs;
 reg [31:0] write_epoch,snapshot_epoch;
 reg hs_read_primed;
 wire receiving=ioctl_download && ioctl_index==4;
 wire rx_start=receiving && !last_receive;
 wire rx_end=!receiving && last_receive;
 wire [12:0] expected_address=rx_start ? 13'd0 : rx_count;
 wire capture=receiving && ioctl_wr && (state==IDLE || state==SAVE_READY);
 wire rx_ep=capture && ioctl_addr>=EP_BASE && ioctl_addr<HS_BASE;
 wire rx_hs=capture && ioctl_addr>=HS_BASE && ioctl_addr<FILE_BYTES;
 wire ep_we=rx_ep || state==EP_SAVE_COPY;
 wire hs_we=rx_hs || state==HS_SAVE_COPY;
 wire [10:0] ep_wa=rx_ep ? 11'(ioctl_addr-EP_BASE) : cursor;
 wire [6:0] hs_wa=rx_hs ? 7'(ioctl_addr-HS_BASE) : cursor[6:0];
 wire [7:0] ep_wd=rx_ep ? ioctl_data : dump_data;
 wire [7:0] hs_wd=rx_hs ? ioctl_data : hs_upload_data;
 wire restoring_ep=state==EP_RESTORE_PRIME || state==EP_RESTORE_COPY;
 wire restoring_hs=state==HS_RESTORE_PRIME || state==HS_RESTORE_WRITE || state==HS_RESTORE_END;
 wire saving_hs=state==HS_SAVE_PRIME || state==HS_SAVE_COPY;
 wire [10:0] ep_ra=restoring_ep ? cursor : 11'(ioctl_addr-EP_BASE);
 wire [6:0] hs_ra=restoring_hs ? cursor[6:0] : 7'(ioctl_addr-HS_BASE);
 always @(posedge clk_sys)begin
  if(ep_we)ep_shadow[ep_wa]<=ep_wd;
  if(hs_we)hs_shadow[hs_wa]<=hs_wd;
  ep_q<=ep_shadow[ep_ra];hs_q<=hs_shadow[hs_ra];
 end
 assign dump_address=cursor;
 assign restore_pending=state==RESTORE_WAIT || restore;
 // HPS_BUS wait stalls all commands, so assert it only during a blocked download.
 assign ioctl_wait=receiving && state!=IDLE && state!=SAVE_READY;
 assign pause_request=state==SAVE_PAUSE || state==EP_SAVE_PRIME || state==EP_SAVE_COPY || saving_hs || state==RESTORE_WAIT || restore;
 assign hs_upload=saving_hs;
 assign hs_download=restoring_hs || (ioctl_download && ioctl_index==3 && !ioctl_wait);
 assign hs_wr=state==HS_RESTORE_WRITE || (ioctl_download && ioctl_index==3 && ioctl_wr && !ioctl_wait);
 assign hs_index=(saving_hs || restoring_hs) ? 8'd4 : ioctl_index[7:0];
 assign hs_address=(saving_hs || restoring_hs) ? {14'd0,cursor} : ioctl_addr[24:0];
 assign hs_data=restoring_hs ? hs_q : ioctl_data;
 function automatic [7:0] header_byte(input [3:0] a,input score_valid);
 begin case(a)
  0:header_byte=8'h54;1:header_byte=8'h4a;2:header_byte=8'h4e;3:header_byte=8'h56;
  4:header_byte=1;5:header_byte=score_valid ? 3 : 1;default:header_byte=0;
 endcase end endfunction
 assign upload_data=ioctl_addr<16 ? header_byte(ioctl_addr[3:0],hs_valid) :
  ioctl_addr<HS_BASE ? ep_q : ioctl_addr<FILE_BYTES ? (hs_valid ? hs_q : 8'd0) : 8'd0;
 wire header_valid=rx_header[127:96]==32'h544a4e56 && rx_header[95:88]==1 &&
  rx_header[80] && (rx_header[87:80]&8'hfc)==0 && rx_header[79:0]==0;
 always @(posedge clk_sys)begin
  load_we<=0;
  if(init_reset)begin
   state<=IDLE;cursor<=0;upload_request<=0;restore<=0;load_address<=0;load_data<=0;
   dirty<=0;storage_error<=0;rx_header<=0;rx_count<=0;rx_error<=0;
   last_receive<=0;last_osd<=0;last_upload<=0;terminal_seen<=0;hs_seen<=0;hs_valid<=0;received_hs<=0;
   write_epoch<=0;snapshot_epoch<=0;hs_read_primed<=0;
  end else begin
   last_receive<=receiving;last_osd<=osd_status;last_upload<=ioctl_upload && ioctl_index==4;
   if(eeprom_modified)begin dirty<=1;write_epoch<=write_epoch+1;end
   if(rx_start)begin rx_count<=0;rx_error<=0;rx_header<=0;storage_error<=0;upload_request<=0;end
   if(capture)begin
    if(ioctl_addr!=expected_address || ioctl_addr>=FILE_BYTES)rx_error<=1;
    rx_count<=expected_address+1;
    if(ioctl_addr<16)rx_header[7'd127-{ioctl_addr[3:0],3'b000}-:8]<=ioctl_data;
   end
   if(ioctl_upload && ioctl_index==4 && ioctl_addr>=FILE_BYTES-1 && ioctl_addr<=FILE_BYTES)terminal_seen<=1;
   if(rx_end)begin
    if(rx_count==FILE_BYTES && !rx_error && header_valid)begin
     received_hs<=rx_header[81];state<=RESTORE_WAIT;
    end else begin storage_error<=1;state<=IDLE;end
   end else case(state)
    IDLE:if(!receiving && ((osd_status && !last_osd) || hs_upload_request))begin
     hs_seen<=hs_pause_request;
     if(autosave && hs_configured && signature_ready)state<=WAIT_HS;
     else state<=SAVE_PAUSE;
    end
    WAIT_HS:begin
     if(hs_pause_request)hs_seen<=1;
     if(hs_seen && !hs_pause_request)begin hs_valid<=1;state<=SAVE_PAUSE;end
    end
    SAVE_PAUSE:if(paused)begin cursor<=0;snapshot_epoch<=write_epoch;state<=EP_SAVE_PRIME;end
    EP_SAVE_PRIME:state<=EP_SAVE_COPY;
    EP_SAVE_COPY:if(cursor==2047)begin
     cursor<=0;
     if(hs_valid)begin hs_read_primed<=0;state<=HS_SAVE_PRIME;end
     else begin upload_request<=1;terminal_seen<=0;state<=SAVE_READY;end
    end else begin cursor<=cursor+1;state<=EP_SAVE_PRIME;end
    // Standard engine registers ioctl_addr into data_addr before its RAM read.
    HS_SAVE_PRIME:if(hs_read_primed)state<=HS_SAVE_COPY;else hs_read_primed<=1;
    HS_SAVE_COPY:begin
     hs_read_primed<=0;
     if(cursor==99)begin upload_request<=1;terminal_seen<=0;state<=SAVE_READY;end
     else begin cursor<=cursor+1;state<=HS_SAVE_PRIME;end
    end
    SAVE_READY:begin
     if(rx_start)state<=IDLE;
     else if(last_upload && !(ioctl_upload && ioctl_index==4))begin
      if(terminal_seen)begin
       upload_request<=0;
       if(write_epoch==snapshot_epoch && !eeprom_modified)dirty<=0;
       state<=IDLE;
      end
     end
    end
    RESTORE_WAIT:if(can_restore && paused)begin restore<=1;cursor<=0;state<=EP_RESTORE_PRIME;end
    EP_RESTORE_PRIME:state<=EP_RESTORE_COPY;
    EP_RESTORE_COPY:begin
     load_we<=1;load_address<=cursor;load_data<=ep_q;
     if(cursor==2047)begin
      cursor<=0;if(received_hs)state<=HS_RESTORE_PRIME;else state<=RESTORE_DONE;
     end else begin cursor<=cursor+1;state<=EP_RESTORE_PRIME;end
    end
    HS_RESTORE_PRIME:state<=HS_RESTORE_WRITE;
    HS_RESTORE_WRITE:if(cursor==99)state<=HS_RESTORE_END;
     else begin cursor<=cursor+1;state<=HS_RESTORE_PRIME;end
    HS_RESTORE_END:state<=RESTORE_DONE;
    RESTORE_DONE:begin restore<=0;hs_valid<=received_hs;dirty<=0;state<=IDLE;end
   endcase
  end
 end
endmodule
