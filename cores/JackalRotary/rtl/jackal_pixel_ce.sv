// SPDX-License-Identifier: GPL-3.0-or-later
// Native 6.144MHz pixels on the 49.152MHz game/video clock.
// Game reset and pause must not interrupt the raster's enable cadence.
module jackal_pixel_ce(input wire clk, output reg ce = 0);
    reg [2:0] div = 0;
    always @(posedge clk) begin
        div <= div + 3'd1;
        ce <= div == 0;
    end
endmodule
