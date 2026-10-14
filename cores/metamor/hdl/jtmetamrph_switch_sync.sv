// Metamorphic Force board-mode switch synchronizers.
// SPDX-License-Identifier: GPL-2.0-or-later
module jtmetamrph_switch_sync (
    input wire clk,
    input wire [3:0] switches,
    output wire [3:0] stable_switches
);
    // Only meta_ff receives an asynchronous pin. The second stage is timed.
    (* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [3:0] meta_ff = 4'b0000;
    (* preserve *) reg [3:0] sync_ff = 4'b0000;
    always @(posedge clk) begin
        meta_ff <= switches;
        sync_ff <= meta_ff;
    end
    assign stable_switches = sync_ff;
endmodule
