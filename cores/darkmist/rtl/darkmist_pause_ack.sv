// SPDX-License-Identifier: GPL-3.0-or-later
// Both board CPUs and YM use !request on their clock enables. Three settled
// edges let outstanding once-only bus effects retire before SRAM ownership.
module darkmist_pause_ack(input wire clk,reset,request,output wire paused);
    reg [2:0] settled=0;
    always @(posedge clk)
        if(reset || !request) settled<=0;
        else settled<={settled[1:0],1'b1};
    assign paused=request && &settled && !reset;
endmodule
