// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Daikaiju no Gyakushu MiSTer core contributors

`default_nettype none

module a74_palette_prom (
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        ce_pixel,
    input  logic        pixel_valid_in,
    input  logic [8:0]  palette_index,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    output logic [7:0]  red,
    output logic [7:0]  green,
    output logic [7:0]  blue,
    output logic        pixel_valid_out
);

    // A74 has three 0x400-byte RGB PROMs. MAME loads the first 0x200 bytes
    // of each chip and ignores the second half. WIDE=1 presents each
    // 16-bit transfer as two adjacent bytes at the even byte offset ioctl_addr;
    // the lookup uses PROM bytes 0-511.
    // One independent write per byte lane; async MLAB reads preserve the CE
    // sampling contract, including a simultaneous WIDE write/read collision.
    wire [9:0] next_byte = {1'b0,ioctl_addr[8:0]} + 10'd1;
    wire download = ioctl_wr && ioctl_addr[26:9] == 0;
    wire [7:0] even_address = ioctl_addr[0] ? next_byte[8:1] : ioctl_addr[8:1];
    wire [7:0] even_data = {4'd0,ioctl_addr[0] ? ioctl_dout[11:8] : ioctl_dout[3:0]};
    wire [7:0] odd_data = {4'd0,ioctl_addr[0] ? ioctl_dout[3:0] : ioctl_dout[11:8]};
    wire even_write = download && (!ioctl_addr[0] || !next_byte[9]);
    wire [7:0] red_even_q, red_odd_q, green_even_q, green_odd_q, blue_even_q, blue_odd_q;
    a74_live_byte_cache red_even(.clk(clk_sys),.write_enable(even_write && ioctl_index==16'd5),.write_address(even_address),.write_data(even_data),.read_address(palette_index[8:1]),.read_data(red_even_q));
    a74_live_byte_cache red_odd(.clk(clk_sys),.write_enable(download && ioctl_index==16'd5),.write_address(ioctl_addr[8:1]),.write_data(odd_data),.read_address(palette_index[8:1]),.read_data(red_odd_q));
    a74_live_byte_cache green_even(.clk(clk_sys),.write_enable(even_write && ioctl_index==16'd6),.write_address(even_address),.write_data(even_data),.read_address(palette_index[8:1]),.read_data(green_even_q));
    a74_live_byte_cache green_odd(.clk(clk_sys),.write_enable(download && ioctl_index==16'd6),.write_address(ioctl_addr[8:1]),.write_data(odd_data),.read_address(palette_index[8:1]),.read_data(green_odd_q));
    a74_live_byte_cache blue_even(.clk(clk_sys),.write_enable(even_write && ioctl_index==16'd7),.write_address(even_address),.write_data(even_data),.read_address(palette_index[8:1]),.read_data(blue_even_q));
    a74_live_byte_cache blue_odd(.clk(clk_sys),.write_enable(download && ioctl_index==16'd7),.write_address(ioctl_addr[8:1]),.write_data(odd_data),.read_address(palette_index[8:1]),.read_data(blue_odd_q));
    wire [3:0] red_value = palette_index[0] ? red_odd_q[3:0] : red_even_q[3:0];
    wire [3:0] green_value = palette_index[0] ? green_odd_q[3:0] : green_even_q[3:0];
    wire [3:0] blue_value = palette_index[0] ? blue_odd_q[3:0] : blue_even_q[3:0];

    // MAME 0.289 emupal.cpp RGB_444_PROMS resistor weights.
    function automatic [7:0] prom_level(input [3:0] bits);
        prom_level = (bits[0] ? 8'd14 : 8'd0) +
                     (bits[1] ? 8'd31 : 8'd0) +
                     (bits[2] ? 8'd67 : 8'd0) +
                     (bits[3] ? 8'd143 : 8'd0);
    endfunction

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            red <= 8'd0;
            green <= 8'd0;
            blue <= 8'd0;
            pixel_valid_out <= 1'b0;
        end else if (ce_pixel) begin
            red <= prom_level(red_value);
            green <= prom_level(green_value);
            blue <= prom_level(blue_value);
            pixel_valid_out <= pixel_valid_in;
        end
    end

endmodule

`default_nettype wire
