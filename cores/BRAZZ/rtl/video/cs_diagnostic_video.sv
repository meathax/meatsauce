// SPDX-License-Identifier: GPL-3.0-or-later
// Visible bring-up raster, NOT game scanout. Native MAME geometry/rate.
// At SYSCLK=85.90908MHz, a fixed /12 produces 7.15909MHz (60.054442Hz).
// Porches here are diagnostic choices, not verified Crystal System sync pins.
module cs_diagnostic_video (
    input logic clk, reset,
    output logic ce_pix, frame_start, hblank, vblank, hsync, vsync,
    output logic [23:0] rgb,
    output logic [11:0] pixel_x, pixel_y
);
    logic [3:0] divider = 0;
    logic [8:0] x = 0, y = 0;
    // Reset blanks RGB, but never stops or retimes the raster.
    always_ff @(posedge clk) begin
        if (ce_pix) begin
            divider <= 0;
            if (x == 454) begin
                x <= 0;
                if (y == 261) y <= 0;
                else y <= y + 1'd1;
            end else x <= x + 1'd1;
        end else divider <= divider + 1'd1;
    end
    always_comb begin
        ce_pix = divider == 11;
        pixel_x = {3'd0,x}; pixel_y = {3'd0,y};
        frame_start = ce_pix && x == 0 && y == 0;
        hblank = x >= 320; vblank = y >= 240;
        hsync = !(x >= 344 && x < 376);
        vsync = !(y >= 244 && y < 247);
        // Magenta border distinguishes the incomplete wrapper from game output.
        rgb = (x < 4 || x >= 316 || y < 4 || y >= 236) ? 24'hff00ff :
              {x[7:0], y[7:0], 8'h40};
        if (reset || hblank || vblank) rgb = 0;
    end
endmodule
