// SPDX-License-Identifier: GPL-3.0-or-later
// Common cold epoch: assert even if the PLL root has stopped; release only
// after two root edges. Game/menu/download resets must not enter this path.
module hangzo_clock_reset (
    input wire clk,pll_locked,cold_reset,
    output wire system_reset
);
    wire asynchronous_reset=cold_reset || !pll_locked;
    // Quartus17 spelling also used by the pinned Template sysmem resets.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] release_pipe=2'b11;
    always @(posedge clk or posedge asynchronous_reset) begin
        if(asynchronous_reset)release_pipe<=2'b11;
        else release_pipe<={release_pipe[0],1'b0};
    end
    // Keep raw asynchronous deassertion off the core reset pins. The final
    // stage asserts asynchronously and releases only on clk edges.
    assign system_reset=release_pipe[1];
endmodule
