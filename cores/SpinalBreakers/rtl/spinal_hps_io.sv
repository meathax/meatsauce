// SPDX-License-Identifier: GPL-3.0-or-later
// Native MiSTer transport boundary. The caller connects these signals to the
// machine and supplies its menu string; this module makes no SDRAM/PLL choices.
module spinal_hps_io #(parameter CONF_STR = "SpinalBreakers;;") (
    input wire clk,
    inout wire [45:0] HPS_BUS,
    inout wire [21:0] gamma_bus,
    output wire [127:0] status,
    output wire [31:0] joystick_0,joystick_1,
    output wire [1:0] buttons,
    output wire forced_scandoubler,direct_video,
    input wire video_rotated,new_vmode,input wire [15:0] status_menumask,
    output wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,
    output wire [15:0] ioctl_index,
    output wire [26:0] ioctl_addr,
    output wire [7:0] ioctl_data,
    input wire ioctl_wait,hiscore_upload_req,
    input wire [7:0] hiscore_ioctl_data
);
    tri [35:0] ext_bus;
    assign ext_bus[32]=1'b0;
    spinal_platform_hps_io #(.CONF_STR(CONF_STR),.WIDE(0),.PS2DIV(0)) transport (
        .clk_sys(clk),.HPS_BUS(HPS_BUS),.EXT_BUS(ext_bus),.gamma_bus(gamma_bus),
        .joystick_0(joystick_0),.joystick_1(joystick_1),.buttons(buttons),
        .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),
        .video_rotated(video_rotated),.new_vmode(new_vmode),
        .status(status),.status_in(128'b0),.status_set(1'b0),.status_menumask(status_menumask),
        .info_req(1'b0),.info(8'b0),.sd_rd(1'b0),.sd_wr(1'b0),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_data),.ioctl_wait(ioctl_wait),
        .ioctl_upload_req(hiscore_upload_req),.ioctl_upload_index(8'd4),.ioctl_din(hiscore_ioctl_data)
    );
endmodule
