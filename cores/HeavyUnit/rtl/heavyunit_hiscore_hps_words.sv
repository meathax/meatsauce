// SPDX-License-Identifier: GPL-3.0-or-later
// Complete-file download staging and immutable pre-advertisement upload cache.
module heavyunit_hiscore_hps_words (
 input logic clk, reset,
 input logic host_download,host_upload,host_wr,host_rd,
 input logic [15:0] host_index,host_dout,
 input logic [26:0] host_addr,
 output logic [15:0] host_din,
 output wire host_wait,selected,
 input logic upload_prepare,
 output logic upload_transfer_complete=0,
 output logic [5:0] transferred_bytes=0,
 output wire upload_ready,drained,reset_blocked,
 output logic protocol_error=0,
 output logic [3:0] error_code=0,
 output wire byte_download,byte_upload,
 output logic byte_wr=0,
 output wire [15:0] byte_index,
 output logic [24:0] byte_addr=0,
 output logic [7:0] byte_dout=0,
 input logic [7:0] byte_din,
 output logic [5:0] accepted_bytes=0,cached_bytes=0,
 output logic [5:0] committed_bytes=0
);
 logic [15:0] download_words[0:19];
 logic [15:0] upload_words[0:19];
 logic receiving=0,download_last=0,upload_last=0,reset_pending=0,upload_owned=0;
 logic invalid_file=0,committing=0,commit_gap=0;
 logic [15:0] file_index=0;
 logic [5:0] file_length=0,commit_pos=0;
 logic cache_valid=0;
 // On-disk table (last validated restore or completed save): served when
 // MiSTer Main uploads without a core request, so it rewrites the same file.
 logic restored_valid=0;
 logic upload_valid=0;
 logic [26:0] upload_start_addr=0;
 typedef enum logic [2:0] {F_IDLE,F_ADDRESS,F_WAIT0,F_WAIT1,F_SAMPLE} fetch_t;
 fetch_t fetch=F_IDLE;
 logic [5:0] fetch_pos=0;
 wire good_addr=!host_addr[0] && host_addr[26:25]==0;
 assign selected=host_index==16'd3 || host_index==16'd4;
 assign byte_download=committing;
 assign byte_upload=fetch!=F_IDLE || (host_upload && host_index==16'd4 && cache_valid && !committing && !receiving);
 assign byte_index=committing?file_index:(byte_upload?16'd4:16'hffff);
 assign host_wait=committing || fetch!=F_IDLE;
 assign drained=!receiving && !committing && fetch==F_IDLE && !(host_upload&&selected);
 assign reset_blocked=!drained;
 assign upload_ready=upload_prepare && cache_valid && !receiving && !committing &&
                     fetch==F_IDLE && !reset_pending && !reset && !protocol_error;

 always_ff @(posedge clk) begin
  byte_wr<=0;upload_transfer_complete<=0;
  download_last<=host_download;
  upload_last<=host_upload;
  // HPS samples DIN at its data strobe; RD arrives after that sample. Cache
  // selection tracks address a cycle ahead, with no upload wait assumption.
  if(cache_valid && host_index==16'd4 && good_addr && host_addr<27'd40)
   host_din<=upload_words[host_addr[5:1]];
  else if(restored_valid && host_index==16'd4 && good_addr && host_addr<27'd40)
   host_din<=download_words[host_addr[5:1]];
  else host_din<=0;

  if(reset && (committing || (host_upload&&selected)))reset_pending<=1;
  if((reset||reset_pending) && !committing && !(host_upload&&selected))begin
   receiving<=0;invalid_file<=0;cache_valid<=0;fetch<=F_IDLE;
   accepted_bytes<=0;cached_bytes<=0;committed_bytes<=0;
   protocol_error<=0;error_code<=0;reset_pending<=0;upload_owned<=0;restored_valid<=0;
   upload_valid<=0;transferred_bytes<=0;
   // Do not reinterpret an already-active aborted download as a fresh file.
   download_last<=host_download;upload_last<=host_upload;
  end else begin
   if(!upload_prepare && !host_upload && fetch==F_IDLE)begin cache_valid<=0;cached_bytes<=0;end
   // Errors describe one host transfer; clear them once the host is idle.
   if(protocol_error && !host_download && !host_upload && !receiving && !committing && fetch==F_IDLE)begin
    protocol_error<=0;invalid_file<=0;
   end
   if(host_download&&!download_last&&selected&&!reset&&!reset_pending)begin
    if(committing || fetch!=F_IDLE || upload_prepare || host_upload || protocol_error || host_addr!=0)begin
     protocol_error<=1;error_code<=4'd1;
    end else begin
     receiving<=1;file_index<=host_index;
     file_length <= (host_index==16'd3) ? 6'd24 : 6'd40;accepted_bytes<=0;
     invalid_file<=0;
    end
   end
   if(receiving && host_download && host_index!=file_index)begin
    invalid_file<=1;protocol_error<=1;error_code<=4'd2;
   end
   if(receiving && host_wr && !invalid_file)begin
    if(host_index!=file_index || !good_addr || host_addr!={21'd0,accepted_bytes} || accepted_bytes>=file_length)begin
     invalid_file<=1;protocol_error<=1;error_code<=4'd3;
    end else begin
     download_words[accepted_bytes[5:1]]<=host_dout;
     accepted_bytes<=accepted_bytes+6'd2;
    end
   end
   if(receiving&&!host_download)begin
    receiving<=0;
    if(!invalid_file && accepted_bytes==file_length && host_index==file_index && !protocol_error)begin
     committing<=1;commit_gap<=0;commit_pos<=0;committed_bytes<=0;
     byte_addr<=0;byte_dout<=download_words[0][7:0];
    end else begin protocol_error<=1;error_code<=4'd4;end
   end
   // Deliver only validated complete files. A reset during delivery drains
   // this entire file before clearing state, avoiding a donor false completion.
   if(committing)begin
    if(commit_gap)begin committing<=0;commit_gap<=0;restored_valid<=file_index==16'd4;end
    else begin
     byte_addr<={19'd0,commit_pos};
     byte_dout<=commit_pos[0]?download_words[commit_pos[5:1]][15:8]:download_words[commit_pos[5:1]][7:0];
     byte_wr<=1;committed_bytes<=committed_bytes+6'd1;
     if(commit_pos+6'd1==file_length)commit_gap<=1;
     else commit_pos<=commit_pos+6'd1;
    end
   end
   // The adapter's sticky save_pending freezes donor data until explicit
   // full host-transfer completion. Prime all40 bytes before advertising.
   if(upload_prepare && !cache_valid && fetch==F_IDLE && !receiving && !committing && !host_download && !reset && !reset_pending && !protocol_error)begin
    fetch<=F_ADDRESS;fetch_pos<=0;cached_bytes<=0;
   end
   case(fetch)
    F_IDLE:;
    F_ADDRESS:begin byte_addr<={19'd0,fetch_pos};fetch<=F_WAIT0;end
    F_WAIT0:fetch<=F_WAIT1;
    F_WAIT1:fetch<=F_SAMPLE;
    F_SAMPLE:begin
     if(fetch_pos[0])upload_words[fetch_pos[5:1]][15:8]<=byte_din;
     else upload_words[fetch_pos[5:1]][7:0]<=byte_din;
     cached_bytes<=cached_bytes+6'd1;
     if(fetch_pos==6'd39)begin fetch<=F_IDLE;cache_valid<=1;end
     else begin fetch_pos<=fetch_pos+6'd1;fetch<=F_ADDRESS;end
    end
    default:fetch<=F_IDLE;
   endcase
   if(host_upload&&!upload_last&&selected)begin
    upload_owned<=1;
    upload_start_addr<=host_addr;transferred_bytes<=0;
    upload_valid<=host_index==16'd4 && upload_ready && host_addr==0;
    if(host_index!=16'd4 || !good_addr || host_addr>=27'd40 || receiving || committing)begin
     protocol_error<=1;error_code<=4'd5;
    end
   end
   // FIO53 startup also raises RD. Exclude it: ownership was not yet latched.
   // FIO54 raises RD after sampling DIN and incrementing WIDE address by two.
   if(host_upload && upload_owned && host_rd)begin
    if(host_index!=16'd4 || !good_addr || transferred_bytes>=6'd40 ||
       host_addr!=upload_start_addr+{21'd0,transferred_bytes}+27'd2)begin
     upload_valid<=0;protocol_error<=1;error_code<=4'd8;
    end else transferred_bytes<=transferred_bytes+6'd2;
   end
   if(upload_last && !host_upload && upload_owned)begin
    upload_transfer_complete<=upload_valid && transferred_bytes==6'd40 &&
      host_index==16'd4 && !protocol_error && !reset && !reset_pending && !host_download;
    // A completed save is now the on-disk table: later unsolicited host
    // uploads rewrite exactly this content, never an older restore.
    if(upload_valid && transferred_bytes==6'd40 && host_index==16'd4 && !protocol_error && !reset && !reset_pending && !host_download)begin
     for(integer i=0;i<20;i=i+1)download_words[i]<=upload_words[i];
     restored_valid<=1;
    end
    upload_owned<=0;upload_valid<=0;
   end
   if(host_upload&&upload_owned&&host_index!=16'd4)begin
    upload_valid<=0;protocol_error<=1;error_code<=4'd7;
   end
   if(host_upload&&host_download)upload_valid<=0;
   if(host_upload&&host_rd&&selected && (host_index!=16'd4 || !good_addr || host_addr>27'd40))begin
    protocol_error<=1;error_code<=4'd6;
   end
  end
 end
endmodule
