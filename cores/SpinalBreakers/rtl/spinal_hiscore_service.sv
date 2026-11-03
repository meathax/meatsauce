// SPDX-License-Identifier: GPL-3.0-or-later
// Adapter for the unmodified standard MiSTer high-score controller.
module spinal_hiscore_service (
    input logic clk,reset,paused,autosave,osd_status,v_sync,
    input logic ioctl_upload,ioctl_download,ioctl_wr,
    input logic [15:0] ioctl_index,input logic [24:0] ioctl_addr,input logic [7:0] ioctl_data,
    output wire ioctl_upload_req,output wire [7:0] ioctl_read_data,output wire configured,
    output wire pause_request,score_request,score_write,output wire [23:0] score_address,
    output wire [7:0] score_data_out,input logic [7:0] score_data_in,input logic score_ready
);
    wire read_strobe,write_strobe;
    assign score_request=read_strobe || write_strobe;
    assign score_write=write_strobe;
    // Never alias a 16-bit index to the donor's 8-bit high-score namespace.
    wire hs_download=ioctl_download && ioctl_index[15:8]==0;
    wire hs_upload=ioctl_upload && ioctl_index[15:8]==0;
    // Each supported profile has a 140-byte score image, within 256 bytes.
    hiscore #(.HS_ADDRESSWIDTH(24),.HS_SCOREWIDTH(8),.HS_CONFIGINDEX(3),.HS_DUMPINDEX(4)) controller(
        .clk(clk),.paused(paused),.reset(reset),.autosave(autosave),.ioctl_upload(hs_upload),
        .data_ready(score_ready),.ioctl_upload_req(ioctl_upload_req),.ioctl_download(hs_download),.ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index[7:0]),.OSD_STATUS(osd_status),.v_sync(v_sync),
        .data_from_hps(ioctl_data),.data_from_ram(score_data_in),.ram_address(score_address),.data_to_hps(ioctl_read_data),
        .data_to_ram(score_data_out),.ram_write(write_strobe),.ram_read(read_strobe),.ram_intent_read(),.ram_intent_write(),
        .pause_cpu(pause_request),.configured(configured));
endmodule
