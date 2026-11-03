// SPDX-License-Identifier: GPL-3.0-or-later
// The pinned Template parser is the HPS protocol authority. Narrow FIO matches
// the verified byte-stream loader; no alternate parser or reduced index width.
module hangzo_hps_io #(
    parameter CONF_STR="Hangzo;;R[0],Reset;"
)(
    input wire clk,
    inout wire [45:0] HPS_BUS,
    inout wire [21:0] gamma_bus,
    input wire [15:0] menu_mask,
    input wire video_rotated,
    output wire [127:0] status,
    output wire [1:0] buttons,
    output wire [31:0] joystick_0,joystick_1,
    output wire [10:0] ps2_key,
    output wire forced_scandoubler,direct_video,
    output wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,
    output wire [15:0] ioctl_index,
    output wire [26:0] ioctl_address,
    output wire [7:0] ioctl_data,
    input wire ioctl_wait,
    input wire [7:0] ioctl_read_data,
    input wire upload_request,
    input wire [7:0] upload_index
);
    wire [35:0] extension;
    assign extension[32]=1'b0;
    assign extension[15:0]=16'd0;
    wire [31:0] unused_lba[1];
    wire [5:0] unused_blocks[1];
    wire [7:0] unused_sd_data[1];
    assign unused_lba[0]=0;
    assign unused_blocks[0]=0;
    assign unused_sd_data[0]=0;
    hps_io #(.CONF_STR(CONF_STR),.WIDE(0),.PS2DIV(0)) parser(
        .clk_sys(clk),.HPS_BUS(HPS_BUS),.EXT_BUS(extension),.gamma_bus(gamma_bus),
        .status(status),.status_in(128'd0),.status_set(1'b0),.status_menumask(menu_mask),
        .buttons(buttons),.joystick_0(joystick_0),.joystick_1(joystick_1),.ps2_key(ps2_key),
        .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),
        .video_rotated(video_rotated),.new_vmode(1'b0),.info_req(1'b0),.info(8'd0),
        .joystick_0_rumble(16'd0),.joystick_1_rumble(16'd0),.joystick_2_rumble(16'd0),
        .joystick_3_rumble(16'd0),.joystick_4_rumble(16'd0),.joystick_5_rumble(16'd0),
        .ps2_kbd_clk_in(1'b1),.ps2_kbd_data_in(1'b1),.ps2_mouse_clk_in(1'b1),.ps2_mouse_data_in(1'b1),
        .ps2_kbd_led_status(3'd0),.ps2_kbd_led_use(3'd0),
        .sd_lba(unused_lba),.sd_blk_cnt(unused_blocks),.sd_rd(1'b0),.sd_wr(1'b0),.sd_buff_din(unused_sd_data),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_address),.ioctl_dout(ioctl_data),
        .ioctl_wait(ioctl_wait),.ioctl_din(ioctl_read_data),
        .ioctl_upload_req(upload_request),.ioctl_upload_index(upload_index));
endmodule
