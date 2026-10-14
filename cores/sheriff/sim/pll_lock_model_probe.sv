// SPDX-License-Identifier: GPL-2.0-or-later
// Minimal diagnostic for Preflight's mixed initial/combinational lock drivers.
// No board RTL or PLL frequency/phase is changed by this probe.
`timescale 1ps/1ps
module lock_model_original(output reg locked);
    reg reached=0;
    initial begin locked=0; #100000000; reached=1; end
    always @* locked=reached;
endmodule
module lock_model_single_driver(output reg locked);
    reg reached=0;
    initial begin #100000000; reached=1; end
    always @* locked=reached;
endmodule
module pll_lock_model_probe;
    reg clk=0;
    always #10000 clk=~clk;
    wire original_locked,fixed_locked;
    lock_model_original original(original_locked);
    lock_model_single_driver corrected(fixed_locked);
    reg [15:0] original_count=0,fixed_count=0;
    always @(posedge clk) begin
        if(original_locked) original_count<=original_count+1;
        if(fixed_locked) fixed_count<=fixed_count+1;
    end
    initial begin
        #201000000;
        $display("PLL_LOCK_PROBE original_count=%0d single_driver_count=%0d expected=5050",original_count,fixed_count);
        if(fixed_count!=5050) $fatal(1,"Single-driver lock model failed");
        $finish;
    end
endmodule
