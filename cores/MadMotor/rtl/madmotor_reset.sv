// SPDX-License-Identifier: GPL-3.0-or-later
// Asynchronous assertion, two destination-root edges for release.
// PLL lock and the external reset never directly release game state.
module madmotor_reset(input wire clk,async_reset,output wire sync_reset);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] release_pipe=2'b11;
    always @(posedge clk or posedge async_reset) begin
        if(async_reset)release_pipe<=2'b11;
        else release_pipe<={release_pipe[0],1'b0};
    end
    assign sync_reset=release_pipe[1];
endmodule
