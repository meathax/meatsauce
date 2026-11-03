// SPDX-License-Identifier: GPL-3.0-or-later
module fb100a_input (
    input  wire        clk_sys,
    input  wire        reset_async,
    input  wire        osd_status,
    input  wire [31:0] joystick_0,
    input  wire [31:0] joystick_1,
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [15:0] ioctl_index,
    input  wire [26:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    output wire [7:0]  mame_buttons,
    output wire [7:0]  mame_joys,
    output wire [7:0]  dip1,
    output wire [7:0]  dip2,
    output wire        pause_cpu
);
    // MAME reads BUTTONS as coin 1/2, unknown, start 1P/2P, unknown, Jump 1P/2P.
    // MiSTer joystick bits are active-high; the FB-100A ports are active-low.
    assign mame_buttons = {
        ~joystick_1[4], ~joystick_0[4], 1'b1, ~joystick_1[10],
        ~joystick_0[10], 1'b1, ~joystick_1[11], ~joystick_0[11]
    };

    // MAME JOYS bit order: P1 L/R, P2 L/R, P1 U/D, P2 U/D.
    assign mame_joys = ~{
        joystick_1[2], joystick_1[3], joystick_0[2], joystick_0[3],
        joystick_1[0], joystick_1[1], joystick_0[0], joystick_0[1]
    };

    // MRA's DIP word is downloaded at ioctl index 254, byte 0 = DSW1.
    reg [7:0] mra_dip1 = 8'h00;
    always @(posedge clk_sys) begin
        if (ioctl_download && ioctl_wr && ioctl_index == 16'd254 && ioctl_addr == 27'd0)
            mra_dip1 <= ioctl_dout;
    end
    assign dip1 = mra_dip1;
    assign dip2 = 8'h00;

    wire pause_request_async = osd_status | joystick_0[12] | joystick_1[12];
    (* ASYNC_REG = "TRUE" *) reg pause_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg pause_sync = 1'b0;
    always @(posedge clk_sys or posedge reset_async) begin
        if (reset_async) begin
            pause_meta <= 1'b0;
            pause_sync <= 1'b0;
        end else begin
            pause_meta <= pause_request_async;
            pause_sync <= pause_meta;
        end
    end
    assign pause_cpu = pause_sync;
endmodule
