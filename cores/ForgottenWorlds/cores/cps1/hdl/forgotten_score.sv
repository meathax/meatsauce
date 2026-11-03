// SPDX-License-Identifier: GPL-3.0-or-later
// Forgotten Worlds OSD-triggered score persistence (84 bytes).
//
// The MAME hiscore table for forgottn is two work-RAM ranges:
//   FFE142..FFE191 (80 bytes, table) and FFB2A0..FFB2A3 (4 bytes, top score),
// ready when FFE142==00, FFE191==20, FFB2A0==00 and FFB2A3==00.
// Work RAM lives in SDRAM slot 0, so the CPU is halted (and proven idle by
// forgotten_pause_grant) before this module borrows the slot.
//  * Opening the OSD captures both ranges when they are ready and asks HPS for
//    an upload (NVRAM index 2). The captured image also becomes the restore image.
//  * A downloaded file is restored once per reset epoch, after the same
//    readiness test, by briefly halting the CPU and writing both ranges.
module forgotten_score #(
 parameter integer POLL_BITS=23,      // ~87 ms at 96 MHz
 parameter integer WAIT_BITS=21,      // idle-bus grant timeout
 parameter integer UPLOAD_BITS=27     // give up waiting for HPS to start an upload
)(
 input wire clk, reset,
 input wire osd_status,
 input wire host_download, host_upload, host_ram, host_wr,
 input wire [26:0] host_addr,
 input wire [7:0] host_dout,
 output wire [7:0] host_din,
 input wire cpu_idle,
 output reg pause_request=0,
 output wire ram_owner,
 output reg ram_cs=0, ram_we=0,
 output wire [16:0] ram_addr,
 output reg [15:0] ram_din=0,
 input wire ram_ok,
 input wire [15:0] ram_dout,
 output reg upload_request=0
);
 localparam [5:0] LAST_WORD=6'd41;
 localparam [14:0] TABLE_WORD=15'h70A1, TOP_WORD=15'h5950;
 localparam [2:0] IDLE=0, WAIT=1, READ=2, WRITE=3, COPY=4, RELEASE=5;
 reg [2:0] state=IDLE;
 // f = restore/file image, c = last capture; hi byte = even address.
 reg [7:0] fhi[0:63], flo[0:63], chi[0:63], clo[0:63];
 reg [7:0] f_rhi=0, f_rlo=0, c_rhi=0, c_rlo=0, up_byte=0;
 (* async_reg = "true" *) reg osd_meta=0, osd_sync=0, idle_meta=0, idle_sync=0;
 reg osd_last=0, want_save=0, mode_restore=0, have_file=0, restored=0;
 reg dl_last_byte=0, dl_active_last=0, pending=0, upload_started=0;
 reg [5:0] idx=0;
 reg [2:0] step=0;
 reg [3:0] dwell=0;
 reg [POLL_BITS-1:0] poll_cnt=0;
 reg [WAIT_BITS-1:0] wait_cnt=0;
 reg [UPLOAD_BITS-1:0] upload_cnt=0;
 reg [3:0] rdy=0;
 reg capture_ok=0, poll_pulse=0;
 wire busy_host=host_download || host_upload;
 wire dl_active=host_download && host_ram;
 wire own_upload=pending && host_upload;
 wire ready=&rdy;
 assign ram_owner=(state==READ || state==WRITE) || (state==RELEASE && ram_cs);
 wire [14:0] word_addr=idx<6'd40 ? TABLE_WORD+{9'd0,idx} : TOP_WORD+{9'd0,idx-6'd40};
 assign ram_addr={2'b00,word_addr};
 assign host_din=own_upload ? up_byte : 8'h00;
 // File image: one write port shared by HPS download and capture copy.
 wire dl_write=dl_active && host_wr && host_addr<27'd84;
 wire copy_write=(state==COPY) && step==1;
 wire f_we_hi=copy_write || (dl_write && !host_addr[0]);
 wire f_we_lo=copy_write || (dl_write &&  host_addr[0]);
 wire [5:0] f_waddr=copy_write ? idx : host_addr[6:1];
 wire [7:0] f_wdhi=copy_write ? c_rhi : host_dout;
 wire [7:0] f_wdlo=copy_write ? c_rlo : host_dout;
 wire [5:0] f_raddr=idx;
 wire c_we=(state==READ) && step==3 && ram_ok;
 always @(posedge clk) begin
  if(f_we_hi) fhi[f_waddr]<=f_wdhi;
  if(f_we_lo) flo[f_waddr]<=f_wdlo;
  f_rhi<=fhi[f_raddr]; f_rlo<=flo[f_raddr];
  if(c_we) begin chi[idx]<=ram_dout[15:8]; clo[idx]<=ram_dout[7:0]; end
  c_rhi<=chi[(state==COPY) ? idx : host_addr[6:1]];
  c_rlo<=clo[(state==COPY) ? idx : host_addr[6:1]];
 end
 always @(posedge clk) up_byte<=host_addr[0] ? c_rlo : c_rhi;
 always @(posedge clk) begin
  osd_meta<=osd_status; osd_sync<=osd_meta; osd_last<=osd_sync;
  idle_meta<=cpu_idle; idle_sync<=idle_meta;
  upload_request<=0;
  poll_pulse<=0;
  if(dl_write && host_addr==27'd83) dl_last_byte<=1;
  dl_active_last<=dl_active;
  if(dl_active && !dl_active_last) dl_last_byte<=0;
  if(!dl_active && dl_active_last && dl_last_byte) begin have_file<=1;restored<=0;end
  // Upload bookkeeping: the captured image must stay stable until HPS reads it.
  if(pending) begin
   if(host_upload) upload_started<=1;
   upload_cnt<=upload_cnt+1'b1;
   if((upload_started && !host_upload) || (&upload_cnt)) begin pending<=0;upload_started<=0;end
  end
  if(reset) begin
   state<=IDLE; pause_request<=0; ram_cs<=0; ram_we<=0; want_save<=0; restored<=0;
   poll_cnt<=0; wait_cnt<=0; idx<=0; step<=0; dwell<=0; osd_meta<=0; osd_sync<=0; osd_last<=0;
   mode_restore<=0; capture_ok<=0; rdy<=0;
  end else begin
   if(osd_sync && !osd_last) want_save<=1;
   poll_cnt<=poll_cnt+1'b1;
   if(&poll_cnt) poll_pulse<=1;
   case(state)
    IDLE: begin
     idx<=0; step<=0; capture_ok<=0; wait_cnt<=0; rdy<=0;
     if(!busy_host && !pending) begin
      if(want_save) begin
       want_save<=0;
       if(!have_file || restored) begin mode_restore<=0; pause_request<=1; state<=WAIT; end
      end else if(have_file && !restored && poll_pulse) begin
       mode_restore<=1; pause_request<=1; state<=WAIT;
      end
     end
    end
    WAIT: begin
     wait_cnt<=wait_cnt+1'b1;
     if(busy_host || (&wait_cnt)) begin if(!mode_restore) want_save<=1; state<=RELEASE; dwell<=0; end
     else if(idle_sync) begin idx<=0; step<=0; rdy<=0; state<=READ; end
    end
    READ, WRITE: begin
     if(busy_host || !idle_sync) begin
      ram_cs<=0; ram_we<=0; if(!mode_restore) want_save<=1; state<=RELEASE; dwell<=0;
     end else case(step)
      0: step<=1;                                           // restore-word read-ahead settles
      1: begin ram_din<={f_rhi,f_rlo}; step<=2; end
      2: begin ram_cs<=1; ram_we<=(state==WRITE); step<=3; end
      3: if(ram_ok) begin
          if(state==READ) begin
           if(idx==6'd0)  rdy[0]<=ram_dout[15:8]==8'h00;
           if(idx==6'd39) rdy[1]<=ram_dout[7:0]==8'h20;
           if(idx==6'd40) rdy[2]<=ram_dout[15:8]==8'h00;
           if(idx==6'd41) rdy[3]<=ram_dout[7:0]==8'h00;
          end
          ram_cs<=0; ram_we<=0; dwell<=0; step<=4;
         end
      4: if(dwell==4'd3) begin
          dwell<=0; step<=0;
          if(idx==LAST_WORD) begin
           idx<=0;
           if(state==READ) begin
            if(mode_restore) state<=ready ? WRITE : RELEASE;  // wait until the game initialised its table
            else begin capture_ok<=ready; state<=ready ? COPY : RELEASE; end
           end else begin restored<=1; state<=RELEASE; end
          end else idx<=idx+1'b1;
         end else dwell<=dwell+1'b1;
      default: step<=0;
     endcase
    end
    COPY: begin // successful capture becomes the restore image (two clocks per word)
     step<=step+1'b1;
     if(step==1) begin
      step<=0;
      if(idx==LAST_WORD) begin idx<=0; have_file<=1; restored<=1; state<=RELEASE; dwell<=0; end
      else idx<=idx+1'b1;
     end
    end
    RELEASE: begin
     ram_cs<=0; ram_we<=0;
     if(dwell==4'd7) begin
      pause_request<=0; dwell<=0; state<=IDLE;
      if(capture_ok && !mode_restore) begin upload_request<=1; pending<=1; upload_started<=0; upload_cnt<=0; end
      capture_ok<=0;
     end else dwell<=dwell+1'b1;
    end
    default: state<=IDLE;
   endcase
  end
 end
endmodule
