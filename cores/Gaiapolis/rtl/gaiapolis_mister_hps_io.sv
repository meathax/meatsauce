// SPDX-License-Identifier: GPL-3.0-or-later
// Compatibility boundary for the pinned JTFRAME platform and official template.
// The protocol is the pinned official implementation with a legal PS2 register
// scope adaptation. sys/hps_io.sv itself remains byte-for-byte unchanged.
module gaiapolis_mister_hps_io #(
    parameter CONF_STR="Gaiapolis;;",PS2DIV=32,WIDE=0,BLKSZ=1
)(
    input logic clk_sys,
    inout wire [45:0] HPS_BUS,
    output wire [1:0] buttons,
    output wire [63:0] status,
    output wire [63:0] status_extra,
    input wire [15:0] status_menumask,
    inout wire [21:0] gamma_bus,
    output wire direct_video,forced_scandoubler,
    input wire video_rotated,
    output wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,
    output wire [26:0] ioctl_addr,
    output wire [(WIDE?15:7):0] ioctl_dout,
    input wire [(WIDE?15:7):0] ioctl_din,
    output wire [15:0] ioctl_index,
    input wire ioctl_wait,
    input wire ioctl_upload_req,
    input wire [31:0] sd_lba[1],
    input wire [5:0] sd_blk_cnt[1],
    input wire sd_rd,sd_wr,
    output wire sd_ack,
    output wire [7:0] sd_buff_addr,
    output wire [(WIDE?15:7):0] sd_buff_dout,
    input wire [(WIDE?15:7):0] sd_buff_din[1],
    output wire sd_buff_wr,img_mounted,img_readonly,
    output wire [63:0] img_size,
    input wire [5:0] joy_raw,
    output wire [15:0] joystick_0,joystick_1,joystick_2,joystick_3,
    output wire [15:0] joystick_l_analog_0,joystick_l_analog_1,joystick_l_analog_2,joystick_l_analog_3,
    output wire [15:0] joystick_r_analog_0,joystick_r_analog_1,joystick_r_analog_2,joystick_r_analog_3,
    output wire ps2_kbd_clk_out,ps2_kbd_data_out,
    output wire [7:0] paddle_0,paddle_1,paddle_2,paddle_3,
    output wire [8:0] spinner_0,spinner_1,spinner_2,spinner_3,
    output wire [10:0] ps2_key,
    output wire [24:0] ps2_mouse,
    output wire [15:0] ps2_mouse_ext,
    output wire [64:0] RTC,
    output wire [31:0] TIMESTAMP,
    output wire [31:0] ioctl_file_ext
);
    wire [127:0] status_wide;
    wire [31:0] joy0_wide,joy1_wide,joy2_wide,joy3_wide;
    wire [32:0] timestamp_wide;
    wire [(WIDE?12:13):0] sd_address_wide;
    wire [35:0] ext_bus;
    assign ext_bus[32]=1'b0;
    assign ext_bus[15:0]=16'd0;
    assign status=status_wide[63:0];
    assign status_extra=status_wide[127:64];
    assign joystick_0=joy0_wide[15:0],joystick_1=joy1_wide[15:0];
    assign joystick_2=joy2_wide[15:0],joystick_3=joy3_wide[15:0];
    assign TIMESTAMP=timestamp_wide[31:0];
    assign sd_buff_addr=sd_address_wide[7:0];
    // joy_raw was an older HPS DB15 feedback extension. Actual DB15 game
    // input still traverses the unchanged jtframe_joymux in the platform.
    gaiapolis_mister_official_hps_io #(.CONF_STR(CONF_STR),.CONF_STR_BRAM(1),.PS2DIV(PS2DIV),.WIDE(WIDE),.BLKSZ(BLKSZ),.VDNUM(1)) u_official(
        .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(ext_bus),
        .buttons(buttons),.status(status_wide),.status_in(128'd0),.status_set(1'b0),
        .status_menumask(status_menumask),.gamma_bus(gamma_bus),
        .direct_video(direct_video),.forced_scandoubler(forced_scandoubler),
        .video_rotated(video_rotated),.new_vmode(1'b0),.info_req(1'b0),.info(8'd0),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),
        .ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),.ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),.ioctl_din(ioctl_din),.ioctl_index(ioctl_index),
        .ioctl_wait(ioctl_wait),.ioctl_upload_req(ioctl_upload_req),.ioctl_upload_index(8'd2),
        .ioctl_file_ext(ioctl_file_ext),
        .sd_lba(sd_lba),.sd_blk_cnt(sd_blk_cnt),.sd_rd(sd_rd),.sd_wr(sd_wr),.sd_ack(sd_ack),
        .sd_buff_addr(sd_address_wide),.sd_buff_dout(sd_buff_dout),.sd_buff_din(sd_buff_din),
        .sd_buff_wr(sd_buff_wr),.img_mounted(img_mounted),.img_readonly(img_readonly),.img_size(img_size),
        .joystick_0(joy0_wide),.joystick_1(joy1_wide),.joystick_2(joy2_wide),.joystick_3(joy3_wide),
        .joystick_4(),.joystick_5(),
        .joystick_l_analog_0(joystick_l_analog_0),.joystick_l_analog_1(joystick_l_analog_1),
        .joystick_l_analog_2(joystick_l_analog_2),.joystick_l_analog_3(joystick_l_analog_3),
        .joystick_l_analog_4(),.joystick_l_analog_5(),
        .joystick_r_analog_0(joystick_r_analog_0),.joystick_r_analog_1(joystick_r_analog_1),
        .joystick_r_analog_2(joystick_r_analog_2),.joystick_r_analog_3(joystick_r_analog_3),
        .joystick_r_analog_4(),.joystick_r_analog_5(),
        .joystick_0_rumble(16'd0),.joystick_1_rumble(16'd0),.joystick_2_rumble(16'd0),
        .joystick_3_rumble(16'd0),.joystick_4_rumble(16'd0),.joystick_5_rumble(16'd0),
        .ps2_kbd_clk_out(ps2_kbd_clk_out),.ps2_kbd_data_out(ps2_kbd_data_out),
        .ps2_kbd_clk_in(1'b1),.ps2_kbd_data_in(1'b1),
        .ps2_kbd_led_status(3'd0),.ps2_kbd_led_use(3'd0),
        .ps2_mouse_clk_out(),.ps2_mouse_data_out(),.ps2_mouse_clk_in(1'b1),.ps2_mouse_data_in(1'b1),
        .ps2_key(ps2_key),.ps2_mouse(ps2_mouse),.ps2_mouse_ext(ps2_mouse_ext),
        .paddle_0(paddle_0),.paddle_1(paddle_1),.paddle_2(paddle_2),.paddle_3(paddle_3),.paddle_4(),.paddle_5(),
        .spinner_0(spinner_0),.spinner_1(spinner_1),.spinner_2(spinner_2),.spinner_3(spinner_3),.spinner_4(),.spinner_5(),
        .RTC(RTC),.TIMESTAMP(timestamp_wide),.sdram_sz(),.uart_mode(),.uart_speed()
    );
endmodule
