// SPDX-License-Identifier: GPL-3.0-or-later
// Heavy Barrel high-score persistence for the SDRAM-resident 68000 work RAM.
// Native table (MAME hiscore.dat hbarrel): 88 bytes at FFBE78, ready when the
// first byte is 00 and the last byte is 26. Save: when the OSD opens, halt the
// CPU, read the 44 words through the CPU's own RAM slot, resume, then ask HPS
// to upload the 88-byte image (MRA nvram index 2). Restore: after a downloaded
// image exists and the game has finished initialising the table (observed from
// committed CPU writes, then re-verified by reading under a halted CPU), write
// the image back once per reset epoch.
module heavybarrel_score_engine #(
 parameter integer CLOCK_HZ=48000000,
 parameter [12:0] BASE=13'h1f3c,      // RAM word index of FFBE78
 parameter integer WORDS=44,
 parameter [7:0] FIRST_VALUE=8'h00,
 parameter [7:0] LAST_VALUE=8'h26,
 parameter integer QUIET_MS=40
)(
 input wire clk,reset,
 input wire osd_status,
 // committed main-CPU RAM writes (sysram only)
 input wire commit,sysram,uds_n,lds_n,
 input wire [12:0] word,
 input wire [15:0] cpu_dout,
 // HPS NVRAM stream (ioctl_ram marks either direction)
 input wire host_busy,host_wr,
 input wire [25:0] host_addr,
 input wire [7:0] host_dout,
 output wire [7:0] host_din,
 output reg upload_request=0,
 // CPU halt handshake
 output reg pause_request=0,
 input wire granted,
 // Takes the CPU's SDRAM RAM slot while active
 output reg active=0,
 output reg ram_cs=0,ram_we=0,
 output reg [15:1] ram_addr=0,
 output reg [15:0] ram_din=0,
 input wire ram_ok,
 input wire [15:0] ram_data
);
 localparam integer MS_DIV=CLOCK_HZ/1000;
 localparam integer MS_W=MS_DIV<2 ? 1 : $clog2(MS_DIV);
 reg [MS_W-1:0] ms_count=0;
 wire tick_ms=ms_count==MS_DIV-1;
 always @(posedge clk) begin
  if(tick_ms) ms_count<=0;
  else ms_count<=ms_count+1'b1;
 end

 // ---- image memory: two byte lanes, synchronous read ----
 (* ramstyle = "M10K" *) reg [7:0] img_hi [0:63];
 (* ramstyle = "M10K" *) reg [7:0] img_lo [0:63];
 reg [7:0] rd_hi=0,rd_lo=0;
 reg [5:0] eng_idx=0;
 reg eng_save_wr=0;
 reg [5:0] save_idx=0;
 reg [15:0] eng_save_data=0;
 wire host_wr_ok=host_busy && host_wr && host_addr<26'd88;
 wire [5:0] w_addr=host_wr_ok ? host_addr[6:1] : save_idx;
 wire w_hi=host_wr_ok ? !host_addr[0] : eng_save_wr;
 wire w_lo=host_wr_ok ? host_addr[0] : eng_save_wr;
 wire [7:0] w_dhi=host_wr_ok ? host_dout : eng_save_data[15:8];
 wire [7:0] w_dlo=host_wr_ok ? host_dout : eng_save_data[7:0];
 wire [5:0] r_addr=host_busy ? host_addr[6:1] : eng_idx;
 always @(posedge clk) begin
  if(w_hi) img_hi[w_addr]<=w_dhi;
  if(w_lo) img_lo[w_addr]<=w_dlo;
  rd_hi<=img_hi[r_addr];
  rd_lo<=img_lo[r_addr];
 end
 reg host_a0=0;
 always @(posedge clk) host_a0<=host_addr[0];
 assign host_din=host_busy ? (host_a0 ? rd_lo : rd_hi) : 8'h00;

 // ---- download validation: exactly 88 sequential bytes ----
 reg image_valid=0,dl_seen=0,dl_bad=0,host_busy_d=0;
 reg [7:0] dl_next=0;
 // ---- engine state ----
 localparam [3:0] S_IDLE=0,S_GRANT=1,S_CHKA=2,S_CHKB=3,S_XFER=4,S_SETTLE=5,S_END=6,S_COOL=7;
 reg [3:0] state=S_IDLE;
 reg op_restore=0,ok_result=0;
 reg [1:0] acc=0; // 0 idle, 1 wait ok, 2 gap
 reg [2:0] gap=0,cool=0;
 reg acc_done=0,req=0,req_we=0;
 reg [12:0] req_word=0;
 reg [15:0] req_data=0;
 reg [15:0] acc_data=0;
 reg [3:0] stretch=0;
 reg first_ok=0,last_ok=0,restored=0,wanted=0,up_pending=0,up_started=0;
 reg [7:0] quiet_ms=0;
 reg [7:0] timeout_ms=0;
 reg [10:0] up_ms=0;
 reg [1:0] osd_sync=0;
 reg osd_last=0;
 (* async_reg = "true" *) reg osd_meta=0;
 reg [1:0] settle=0;
 wire in_range=word>=BASE && word<=BASE+WORDS-1;
 wire restore_pending=image_valid && !restored;
 wire restore_ready=restore_pending && first_ok && last_ok && quiet_ms>=QUIET_MS;
 wire idle_ok=!host_busy && !up_pending && state==S_IDLE && !reset;


 always @(posedge clk) begin
  osd_meta<=osd_status;osd_sync<={osd_sync[0],osd_meta};osd_last<=osd_sync[1];
  req<=0;
  host_busy_d<=host_busy;
  eng_save_wr<=0;
  if(stretch!=0) stretch<=stretch-1'b1;
  upload_request<=stretch!=0;
  // HPS download capture (independent of game reset)
  if(host_busy && host_wr) begin
   if(!dl_seen) begin dl_seen<=1;dl_bad<=0;dl_next<=0;image_valid<=0; end
   if(host_addr>=26'd88 || (dl_seen && host_addr[7:0]!=dl_next) || (!dl_seen && host_addr!=0)) dl_bad<=1;
   dl_next<=(dl_seen ? dl_next : 8'd0)+8'd1;
  end
  if(!host_busy && host_busy_d && dl_seen) begin
   dl_seen<=0;
   image_valid<=!dl_bad && dl_next==8'd88;
  end
  // HPS upload ownership: wait for HPS to take the image or give up after 2 s.
  if(tick_ms && up_pending) up_ms<=up_ms+1'b1;
  if(up_pending && host_busy) up_started<=1;
  if(up_pending && ((up_started && !host_busy) || up_ms==11'd2000)) begin up_pending<=0;up_started<=0;up_ms<=0; end

  if(tick_ms && quiet_ms!=8'hff) quiet_ms<=quiet_ms+1'b1;

  if(reset) begin
   if(state==S_XFER && !op_restore) image_valid<=0;
   state<=S_IDLE;pause_request<=0;active<=0;cool<=0;
   first_ok<=0;last_ok<=0;restored<=0;wanted<=0;quiet_ms<=0;timeout_ms<=0;op_restore<=0;ok_result<=0;
  end else begin
   // snoop table initialisation
   if(commit && sysram && in_range && (!uds_n || !lds_n)) begin
    quiet_ms<=0;
    if(word==BASE && !uds_n) first_ok<=cpu_dout[15:8]==FIRST_VALUE;
    if(word==BASE+WORDS-1 && !lds_n) last_ok<=cpu_dout[7:0]==LAST_VALUE;
   end
   if(osd_sync[1] && !osd_last) wanted<=1;

   case(state)
    S_IDLE: begin
     timeout_ms<=0;
     if(idle_ok) begin
      if(restore_ready) begin op_restore<=1;pause_request<=1;state<=S_GRANT; end
      else if(wanted) begin
       wanted<=0;
       if(!restore_pending) begin op_restore<=0;pause_request<=1;state<=S_GRANT; end
      end
     end
    end
    S_GRANT: begin
     if(host_busy) begin pause_request<=0;state<=S_IDLE; if(!op_restore) wanted<=1; end
     else if(granted) begin
      active<=1;ok_result<=0;
      req<=1;req_we<=0;req_word<=BASE;req_data<=16'd0;state<=S_CHKA;
     end else if(tick_ms) begin
      if(timeout_ms==8'd100) begin pause_request<=0;state<=S_IDLE;quiet_ms<=0; if(!op_restore) wanted<=1; end
      else timeout_ms<=timeout_ms+1'b1;
     end
    end
    S_CHKA: if(acc_done) begin
     if(acc_data[15:8]==FIRST_VALUE) begin req<=1;req_we<=0;req_word<=BASE+WORDS-1;req_data<=16'd0;state<=S_CHKB; end
     else begin ok_result<=0;state<=S_END; end
    end
    S_CHKB: if(acc_done) begin
     if(acc_data[7:0]==LAST_VALUE) begin
      eng_idx<=0;settle<=0;state<=S_SETTLE;
     end else begin ok_result<=0;state<=S_END; end
    end
    S_SETTLE: begin
     // eng_idx addresses the image read port; allow its two-cycle latency
     if(settle==2'd2) begin
      settle<=0;state<=S_XFER;
      req<=1;req_word<=BASE+eng_idx;
      if(op_restore) begin req_we<=1;req_data<={rd_hi,rd_lo}; end
      else begin req_we<=0;req_data<=16'd0; end
     end else settle<=settle+1'b1;
    end
    S_XFER: begin
     if(host_busy) begin ok_result<=0;state<=S_END; if(!op_restore) image_valid<=0; end
     else if(acc_done) begin
      if(!op_restore) begin eng_save_data<=acc_data;eng_save_wr<=1;save_idx<=eng_idx; end
      if(eng_idx==WORDS-1) begin ok_result<=1;state<=S_END; end
      else begin eng_idx<=eng_idx+1'b1;settle<=0;state<=S_SETTLE; end
     end
    end
    S_END: if(acc==0) begin
     active<=0;
     if(ok_result && op_restore) restored<=1;
     if(!ok_result && op_restore) begin first_ok<=0;last_ok<=0;quiet_ms<=0; end
     if(ok_result && !op_restore) begin image_valid<=1;stretch<=4'd8;up_pending<=1;up_started<=0;up_ms<=0; end
     state<=S_COOL;cool<=0;
    end
    S_COOL: begin
     // CPU resumes only after the slot is back under CPU control
     pause_request<=0;
     if(cool==3'd3) state<=S_IDLE; else cool<=cool+1'b1;
    end
    default: state<=S_IDLE;
   endcase
  end
 end

 // One RAM-slot access at a time: raise cs, wait for ok, drop cs, wait for ok low.
 always @(posedge clk) begin
  acc_done<=0;
  if(reset) begin acc<=0;ram_cs<=0;ram_we<=0;gap<=0; end
  else case(acc)
   2'd0: if(req) begin
     ram_we<=req_we;ram_addr<={2'b00,req_word};ram_din<=req_data;ram_cs<=1;acc<=2'd1;
    end
   2'd1: if(ram_ok) begin acc_data<=ram_data;ram_cs<=0;ram_we<=0;acc<=2'd2;gap<=0; end
   2'd2: if(!ram_ok) begin
     if(gap==3'd3) begin acc<=2'd0;acc_done<=1; end
     else gap<=gap+1'b1;
    end else gap<=0;
   default: acc<=0;
  endcase
 end
endmodule
