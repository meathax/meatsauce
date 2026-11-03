// SPDX-License-Identifier: GPL-3.0-or-later
// Standard Hiscores_MiSTer engine behind a completion-based RAM interface.
module d8_hiscore (
    input wire clk,reset,reset_all,paused,autosave,osd_open,
    input wire ioctl_download,ioctl_upload,ioctl_wr,
    input wire [26:0] ioctl_addr,
    input wire [15:0] ioctl_index,
    input wire [7:0] ioctl_dout,
    output wire [7:0] ioctl_din,
    output wire upload_req,configured,pause_cpu,
    output reg hs_req=0,
    output reg hs_we=0,
    output reg [15:0] hs_addr=0,
    output reg [7:0] hs_din=0,
    input wire hs_ack,
    input wire [7:0] hs_dout
);
    wire [15:0] ram_address;
    wire [7:0] data_to_ram;
    reg [7:0] response=0;
    wire ram_write,ram_read,write_intent;
    wire need=ram_read|ram_write;
    reg completed=0;
    wire same_tuple=hs_addr==ram_address && hs_we==ram_write &&
                    (!ram_write || hs_din==data_to_ram);
    wire engine_enable=!need || (completed && same_tuple);
    always @(posedge clk) begin
        if(reset_all || reset) begin
            hs_req<=0;completed<=0;response<=0;
        end else begin
            if(hs_req) begin
                if(hs_ack) begin hs_req<=0;completed<=1;response<=hs_dout;end
            end else if(!need) completed<=0;
            else if(!completed || !same_tuple) begin
                hs_req<=1;completed<=0;
                hs_addr<=ram_address;hs_we<=ram_write;hs_din<=data_to_ram;
            end
        end
    end
    d8_hiscore_engine #(.HS_ADDRESSWIDTH(16),.HS_SCOREWIDTH(12),
        .HS_CONFIGINDEX(3),.HS_DUMPINDEX(4),.CFG_ADDRESSWIDTH(4),.CFG_LENGTHWIDTH(2)) engine (
        .clk(clk),.enable(engine_enable),.reset_all(reset_all),.reset(reset),
        .restore_active(),.extract_active(),.paused(paused),.autosave(autosave),
        .ioctl_upload(ioctl_upload && ioctl_index==16'd4),.ioctl_upload_req(upload_req),
        .ioctl_download(ioctl_download && (ioctl_index==16'd3 || ioctl_index==16'd4)),
        .ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr[24:0]),.ioctl_index(ioctl_index[7:0]),
        .OSD_STATUS(osd_open),.data_from_hps(ioctl_dout),.data_from_ram(response),
        .ram_address(ram_address),.data_to_hps(ioctl_din),.data_to_ram(data_to_ram),
        .ram_write(ram_write),.ram_intent_read(ram_read),.ram_intent_write(write_intent),
        .pause_cpu(pause_cpu),.configured(configured)
    );
endmodule
