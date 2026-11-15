// SPDX-License-Identifier: GPL-3.0-or-later
// Decode the four OSD choices into the existing JTFRAME rotation interface.
// All inputs must already be in clk_sys; frame_start is one clock pulse at VS.
module arblst_rotation (
    input wire clk, reset, frame_start,
    input wire [1:0] requested_mode,
    input wire pcb_dip_flip, dipflip_xor,
    output reg [1:0] mode = 2'd0,
    output wire [1:0] rotate,
    output wire native_180,
    output wire framebuffer_flip,
    output wire quarter_turn,
    output wire swap_aspect
);
    // Normal, 90 CW, 90 CCW, 180. Preserve the donor's compensation for
    // the CPU-controlled X1-001 flip when choosing a quarter-turn direction.
    always @(posedge clk) begin
        if (reset) mode <= 2'd0;
        else if (frame_start) mode <= requested_mode;
    end
    assign quarter_turn = mode == 2'd1 || mode == 2'd2;
    assign native_180 = mode == 2'd3;
    assign rotate = {((mode == 2'd2) ^ pcb_dip_flip ^ dipflip_xor), quarter_turn};
    // Native 180 has already flipped sprites AND tiles; never flip twice.
    assign framebuffer_flip = 1'b0;
    assign swap_aspect = quarter_turn;
endmodule
