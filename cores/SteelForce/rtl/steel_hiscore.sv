// MiSTer byte-mode ioctl bridge to the unmodified Hiscores_MiSTer v14 donor.
// Configuration index 3 and saved scores index 4 must be supplied by the MRA.
module steel_hiscore(
    input wire clk, reset, image_reset, paused, osd_status,
    input wire ioctl_upload, ioctl_download, ioctl_wr,
    input wire [24:0] ioctl_addr,
    input wire [7:0] ioctl_index, ioctl_din,
    output wire [7:0] ioctl_dout,
    output wire ioctl_upload_req, configured, pause_cpu,
    output wire hs_en, hs_write,
    output wire [23:0] hs_addr,
    output wire [7:0] hs_din,
    input wire [7:0] hs_dout
);
    wire hs_read,donor_write;
    hiscore #(.HS_ADDRESSWIDTH(24),.HS_SCOREWIDTH(8),.CFG_ADDRESSWIDTH(2)) scores(
        .clk(clk),.reset(reset),.reload(image_reset),.paused(paused),.autosave(1'b1),
        .OSD_STATUS(osd_status),.ioctl_upload(ioctl_upload),.ioctl_upload_req(ioctl_upload_req),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),
        .data_from_hps(ioctl_din),.data_to_hps(ioctl_dout),.configured(configured),.pause_cpu(pause_cpu),
        .ram_address(hs_addr),.data_from_ram(hs_dout),.data_to_ram(hs_din),
        .ram_write(donor_write),.ram_intent_read(hs_read),.ram_intent_write());
    assign hs_write=donor_write && !image_reset;
    assign hs_en=!image_reset && (hs_read | donor_write);
endmodule
