/* SPDX-License-Identifier: GPL-3.0-or-later */
module jtblkpan_hiscore(
    input clk,reset,paused,autosave,osd_open,
    input download,upload,wr,
    input [26:0] ioctl_addr,
    input [15:0] ioctl_index,
    input [7:0] ioctl_dout,
    output [7:0] ioctl_din,
    output upload_req,pause_cpu,configured,ready,
    output [14:0] ram_addr,
    output [7:0] ram_data,
    input [7:0] ram_q,
    output ram_we
);
wire write_strobe,write_intent;
// Validate the complete namespace and address before narrowing donor ports.
wire valid_index=ioctl_index[15:8]==0;
wire valid_addr=ioctl_addr[26:25]==0;
hiscore #(.HS_ADDRESSWIDTH(15),.HS_SCOREWIDTH(8),.CFG_ADDRESSWIDTH(2),.CFG_LENGTHWIDTH(1)) u_controller(
    .clk(clk),.reset(reset),.paused(paused),.autosave(autosave),
    .ioctl_upload(upload && valid_index && valid_addr),
    .ioctl_download(download && valid_index && valid_addr),
    .ioctl_wr(wr),.ioctl_addr(ioctl_addr[24:0]),
    .ioctl_index(valid_index && valid_addr ? ioctl_index[7:0] : 8'hff),
    .ioctl_upload_req(upload_req),.OSD_STATUS(osd_open),
    .data_from_hps(ioctl_dout),.data_to_hps(ioctl_din),
    .data_from_ram(ram_q),.ram_address(ram_addr),.data_to_ram(ram_data),
    .ram_write(write_strobe),.ram_intent_read(),.ram_intent_write(write_intent),
    .pause_cpu(pause_cpu),.configured(configured),.ready(ready));
assign ram_we=write_strobe && write_intent && paused && !reset;
endmodule
