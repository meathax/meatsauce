// SPDX-License-Identifier: GPL-3.0-or-later
// GGA register-derived bring-up timing; physical assumptions are in docs/CLOCK_PLAN.md.
module spinal_video_timing #(
    parameter integer PIXEL_DIV = 8,
    parameter integer HTOTAL = 472,
    parameter integer VTOTAL = 256,
    parameter integer HACTIVE = 352,
    parameter integer VACTIVE = 240,
    parameter integer HS_START = 395,
    parameter integer HS_END = 423,
    parameter integer VS_START = 242,
    parameter integer VS_END = 248
) (
    input  logic clk,
    // Cold reset only. Game reset, pause and memory busy must not reset the raster.
    input  logic cold_reset,
    output logic ce_pixel,
    output logic [8:0] x,
    output logic [8:0] y,
    output logic hs,
    output logic vs,
    output logic hblank,
    output logic vblank,
    output logic frame_start,
    output logic vblank_start
);
    localparam integer DIV_W = $clog2(PIXEL_DIV);
    logic [DIV_W-1:0] divider;

    // CE describes the current x/y tuple, consumed on the next rising clk edge.
    assign ce_pixel = !cold_reset && divider == DIV_W'(PIXEL_DIV-1);
    assign hs = x >= HS_START && x < HS_END;
    assign vs = y >= VS_START && y < VS_END;
    assign hblank = x >= HACTIVE;
    assign vblank = y >= VACTIVE;
    assign frame_start = ce_pixel && x == 0 && y == 0;
    assign vblank_start = ce_pixel && x == 0 && y == VACTIVE;

    always_ff @(posedge clk) begin
        if (cold_reset) begin
            divider <= '0;
            x <= '0;
            y <= '0;
        end else begin
            if (ce_pixel) begin
                divider <= '0;
                if (x == HTOTAL-1) begin
                    x <= '0;
                    if (y == VTOTAL-1) y <= '0;
                    else y <= y + 1'b1;
                end else x <= x + 1'b1;
            end else divider <= divider + 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (PIXEL_DIV >= 4 && PIXEL_DIV % 2 == 0);
        assert (0 < HACTIVE && HACTIVE <= HS_START && HS_START < HS_END && HS_END < HTOTAL);
        assert (0 < VACTIVE && VACTIVE <= VS_START && VS_START < VS_END && VS_END < VTOTAL);
        assert (HTOTAL <= 512 && VTOTAL <= 512);
    end
`endif
endmodule
