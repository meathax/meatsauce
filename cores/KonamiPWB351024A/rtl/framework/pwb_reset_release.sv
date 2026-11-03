// SPDX-License-Identifier: GPL-3.0-or-later
// Reset assertion is immediate; release requires two edges of the receiving clock.
module pwb_reset_release(input wire clk, input wire async_reset, output wire reset);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] release_pipe = 2'b11;
    always @(posedge clk or posedge async_reset) begin
        if(async_reset) release_pipe <= 2'b11;
        else release_pipe <= {release_pipe[0],1'b0};
    end
    assign reset=release_pipe[1];
endmodule
