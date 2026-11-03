// SPDX-License-Identifier: GPL-3.0-or-later
// Host levels enter the game clock domain here. No game enables are changed.
module darkmist_host_controls (
    input  logic clk_game,
    input  logic async_reset,
    input  logic async_osd_status,
    output logic reset_game,
    output logic osd_game
);
    // Cyclone V power-up values also hold the game reset before its first clock.
    (* async_reg = "true" *) logic [1:0] reset_pipe;
    (* async_reg = "true" *) logic [1:0] osd_pipe;
    initial begin
        reset_pipe = 2'b11;
        osd_pipe = 2'b00;
    end

    always @(posedge clk_game or posedge async_reset) begin
        if (async_reset) reset_pipe <= 2'b11;
        else             reset_pipe <= {reset_pipe[0], 1'b0};
    end

    always @(posedge clk_game or posedge async_reset) begin
        if (async_reset)      osd_pipe <= 2'b00;
        else if (reset_game)  osd_pipe <= 2'b00;
        else                  osd_pipe <= {osd_pipe[0], async_osd_status};
    end

    assign reset_game = reset_pipe[1];
    assign osd_game = osd_pipe[1];
endmodule
