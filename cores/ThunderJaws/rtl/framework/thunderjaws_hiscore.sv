// SPDX-License-Identifier: GPL-3.0-or-later
// Standard Hiscores_MiSTer engine (declaration order and explicit protocol power-up state) with real RAM completion feedback.
// Keep restore held until this reset epoch's CPU-written signature is ready.
module thunderjaws_hiscore (
 input wire clk_sys,game_reset,rom_loading,signature_ready,paused,autosave,osd_status,v_sync,
 input wire ioctl_upload,ioctl_download,ioctl_wr,
 input wire [24:0] ioctl_addr,
 input wire [7:0] ioctl_index,ioctl_data,
 output wire upload_request,configured,pause_request,
 output wire [7:0] upload_data,
 output wire ram_read,ram_write,
 output wire [23:0] ram_address,
 output wire [7:0] ram_write_data,
 input wire [7:0] ram_read_data,
 input wire ram_data_ready
);
 hiscore #(.HS_ADDRESSWIDTH(24),.HS_SCOREWIDTH(7),.CFG_ADDRESSWIDTH(1),.CFG_LENGTHWIDTH(1)) engine(
  .clk(clk_sys),.reset(game_reset || rom_loading || !signature_ready),.paused(paused),.autosave(autosave && signature_ready),
  .OSD_STATUS(osd_status && signature_ready),.v_sync(v_sync),
  .ioctl_upload(ioctl_upload),.ioctl_upload_req(upload_request),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
  .ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),.data_from_hps(ioctl_data),.data_to_hps(upload_data),
  .data_ready(ram_data_ready),.data_from_ram(ram_read_data),.ram_address(ram_address),.data_to_ram(ram_write_data),
  .ram_write(ram_write),.ram_read(ram_read),.pause_cpu(pause_request),.configured(configured));
endmodule
