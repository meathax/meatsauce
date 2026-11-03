// SPDX-License-Identifier: GPL-3.0-or-later
// Q8 read period: 16 clocks (4096) = one 6.25 MHz pixel of the 400x258 raster at 100 MHz; hsize steps are 0.25 clock.
module penguin_platform_crt_clock(input logic clk,reset,hs_ref,input logic signed [4:0] hsize,output logic ce);
    logic hs_d=0;logic [15:0] phase=0;
    wire signed [15:0] period=16'sd4096+($signed(hsize)*16'sd64);
    always_ff @(posedge clk)begin
        ce<=0;hs_d<=hs_ref;
        if(reset || (hs_ref&&!hs_d))phase<=0;
        else if(phase+16'd256>=period)begin phase<=phase+16'd256-period;ce<=1;end
        else phase<=phase+16'd256;
    end
endmodule
