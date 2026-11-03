// SPDX-License-Identifier: GPL-3.0-or-later
// Rohga/Hangzo 2048-entry interleaved {unused,B}/{G,R} palette.
// Register the pen across both synchronous reads. Input pixel CE spacing >=8
// fabric clocks; RGB, blanking and sync emerge together four clocks later.
`timescale 1ns/1ns
module hangzo_palette #(parameter SOURCE_FILE="") (
    input wire clk, reset,
    input wire select, write,
    input wire [11:0] address,
    input wire [15:0] write_data,
    input wire [1:0] byte_enable,
    output wire ready,
    output wire [15:0] read_data,
    input wire copy_request,
    output wire copy_ready, busy, copy_done, display_valid,
    input wire pixel_ce,
    input wire [10:0] pen,
    input wire hblank, vblank, hs, vs,
    output reg rgb_ce,
    output reg [23:0] rgb,
    output reg hblank_out, vblank_out, hs_out, vs_out
);
    reg [11:0] display_address;
    wire [15:0] display_data;
    hangzo_buffered_ram #(.AW(12),.SOURCE_FILE(SOURCE_FILE)) u_ram (
        .clk(clk),.reset(reset),.select(select),.write(write),.address(address),
        .write_data(write_data),.byte_enable(byte_enable),.ready(ready),.read_data(read_data),
        .copy_request(copy_request),.publish(1'b0),.copy_ready(copy_ready),.busy(busy),.copy_done(copy_done),
        .display_valid(display_valid),.display_address(display_address),.display_data(display_data));
    reg [2:0] phase;
    reg [10:0] held_pen;
    reg [7:0] blue;
    reg held_hblank, held_vblank, held_hs, held_vs, held_valid;
    always @(posedge clk) begin
        if (reset) begin
            phase <= 0;
            display_address <= 0;
            held_pen <= 0;
            blue <= 0;
            rgb_ce <= 0;
            rgb <= 0;
            hblank_out <= 1;
            vblank_out <= 1;
            hs_out <= 1;
            vs_out <= 1;
            held_hblank <= 1;
            held_vblank <= 1;
            held_hs <= 1;
            held_vs <= 1;
            held_valid <= 0;
        end else begin
            rgb_ce <= 0;
            if (pixel_ce) begin
                held_pen <= pen;
                display_address <= {pen,1'b0};
                held_hblank <= hblank;
                held_vblank <= vblank;
                held_hs <= hs;
                held_vs <= vs;
                held_valid <= display_valid;
                phase <= 1;
            end else if (phase != 0) begin
                phase <= phase + 3'd1;
                if (phase==2) begin
                    blue <= display_data[7:0];
                    display_address <= {held_pen,1'b1};
                end
                if (phase==4) begin
                    phase <= 0;
                    rgb <= (held_valid && !held_hblank && !held_vblank) ?
                        {display_data[7:0],display_data[15:8],blue} : 24'd0;
                    hblank_out <= held_hblank;
                    vblank_out <= held_vblank;
                    hs_out <= held_hs;
                    vs_out <= held_vs;
                    rgb_ce <= 1;
                end
            end
        end
    end
endmodule
