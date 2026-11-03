// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
// Approved provisional raster; not a reconstruction of the FB-100A timing PROMs.
module fb100a_timing (
    input  wire       clk_sys,
    input  wire       reset_video,
    output wire       ce_pixel,
    output wire       ce_cpu,
    output wire       ce_ay,
    output reg  [8:0]  x = 9'd0,
    output reg  [7:0]  y = 8'd0,
    output wire       hblank,
    output wire       vblank,
    output wire       hs,
    output wire       vs
);
    // No game-reset, pause, OSD or memory-stall input can change this cadence.
    reg [4:0] divider = 5'd0;
    always @(posedge clk_sys) divider <= divider + 5'd1;
    assign ce_pixel = (divider[2:0] == 3'd0);
    assign ce_cpu = (divider[3:0] == 4'd0);
    assign ce_ay = (divider == 5'd0);

    always @(posedge clk_sys) begin
        if (reset_video) begin
            x <= 9'd0;
            y <= 8'd0;
        end else if (ce_pixel) begin
            if (x == 9'd399) begin
                x <= 9'd0;
                y <= y + 8'd1;
            end else x <= x + 9'd1;
        end
    end

    assign hblank = (x >= 9'd256);
    assign vblank = (y < 8'd16) || (y >= 8'd240);
    assign hs = !((x >= 9'd288) && (x < 9'd320));
    assign vs = !((y >= 8'd248) && (y < 8'd252));
endmodule
