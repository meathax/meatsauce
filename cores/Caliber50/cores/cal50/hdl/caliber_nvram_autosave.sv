// SPDX-License-Identifier: GPL-3.0-or-later
// Snapshot JTFRAME's 4 KiB NVRAM while the game CPU has yielded its bus.
// HPS uploads the stable copy after the CPU is released.
module caliber_nvram_autosave(
 input wire clk, reset, osd_status, cpu_idle,
 input wire host_download, host_upload, host_ram, host_wr,
 input wire [26:0] host_addr,
 input wire [7:0] game_din,
 output wire [26:0] game_addr,
 output wire game_ram, game_wr,
 output wire [7:0] host_din,
 output reg pause_request=0, upload_request=0
);
 localparam IDLE=0, WAIT_CPU=1, CAPTURE=2, SETTLE=3;
 reg [1:0] state=IDLE;
 (* async_reg = "true" *) reg osd_meta=0,osd_sync=0;
 reg osd_last=0,wanted=0,pending=0,upload_started=0,success=0;
 reg [11:0] capture_addr=0;
 reg [3:0] dwell=0;
 (* ramstyle = "M10K" *) reg [7:0] image [0:4095];
 reg [7:0] image_q;
 wire busy_host=host_download || host_upload;
 wire capturing=state==CAPTURE && !busy_host && cpu_idle;
 wire own_upload=pending && host_upload;
 // JTFRAME registers ioctl_ram and may leave it asserted briefly after HPS
 // deasserts upload. Do not let that trailing cycle steal the live RAM.
 wire mask_upload_ram=pending && !host_download && (host_upload || upload_started);
 assign game_addr=capturing ? {15'd0,capture_addr} : host_addr;
 assign game_ram=capturing ? 1'b1 : mask_upload_ram ? 1'b0 : host_ram;
 assign game_wr=capturing ? 1'b0 : host_wr;
 assign host_din=own_upload ? image_q : game_din;
 always @(posedge clk) begin
  osd_meta<=osd_status;osd_sync<=osd_meta;osd_last<=osd_sync;
  image_q<=image[host_addr[11:0]];
  upload_request<=0;
  if(reset) begin
   state<=IDLE;pause_request<=0;wanted<=0;
   // A warm reset must not switch a live HPS upload away from its already
   // captured image. A pending request survives until that upload ends.
   if(pending && host_upload) upload_started<=1;
   else if(pending && upload_started && !host_upload) begin pending<=0;upload_started<=0;end
   capture_addr<=0;dwell<=0;success<=0;osd_meta<=0;osd_sync<=0;osd_last<=0;
  end else begin
   if(osd_sync && !osd_last) wanted<=1;
   if(pending && host_upload) upload_started<=1;
   if(pending && upload_started && !host_upload) begin pending<=0;upload_started<=0;end
   case(state)
    IDLE: if(wanted && !pending && !busy_host) begin
     wanted<=0;pause_request<=1;state<=WAIT_CPU;
    end
    WAIT_CPU: if(busy_host) begin wanted<=1;success<=0;dwell<=0;state<=SETTLE;end
              else if(cpu_idle) begin capture_addr<=0;dwell<=0;state<=CAPTURE;end
    CAPTURE: if(busy_host || !cpu_idle) begin wanted<=1;success<=0;dwell<=0;state<=SETTLE;end
             else if(dwell==7) begin
              image[capture_addr]<=game_din;dwell<=0;
              if(capture_addr==4095) begin success<=1;state<=SETTLE;end
              else capture_addr<=capture_addr+1'b1;
             end else dwell<=dwell+1'b1;
    SETTLE: if(!busy_host) begin
     if(dwell==7) begin
      pause_request<=0;state<=IDLE;dwell<=0;
      if(success) begin upload_request<=1;pending<=1;upload_started<=0;success<=0;end
     end else dwell<=dwell+1'b1;
    end else dwell<=0;
    default: begin state<=IDLE;pause_request<=0;end
   endcase
  end
 end
endmodule
