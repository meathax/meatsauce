// SPDX-License-Identifier: GPL-3.0-or-later
// Park on a completed CPU transition; physical raster/sync remain running.
module osman_pause (
    input wire clk, reset, request, cpu_at_boundary,
    output reg paused
);
    always @(posedge clk) begin
        if (reset || !request) paused <= 1'b0;
        else if (cpu_at_boundary) paused <= 1'b1;
    end
endmodule
