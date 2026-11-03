// SPDX-License-Identifier: GPL-3.0-or-later
// Raw MAME0.289 ThunderJaws raster:456x262, active336x240.
// Native startup probe proves V240 at time0; source screen.cpp gives H0.
// This cursor follows the existing fixed /6 CE. No game reset/pause can stop it.
// Events indicate ENTERING a line on the CE edge (not the pixel being left).
// Electrical sync timing and output pipeline are separate integration work.
module thunderjaws_raster (
    input wire clk_sys,init_reset,ce_pixel,
    output reg [8:0] hpos,vpos,
    output wire hblank,vblank,visible,
    output wire line_start,frame_zero,vblank_start,
    output wire [8:0] line_number
);
    assign hblank=hpos>=9'd336;
    assign vblank=vpos>=9'd240;
    assign visible=!hblank && !vblank;
    assign line_start=!init_reset && ce_pixel && hpos==9'd455;
    assign line_number=vpos==9'd261 ? 9'd0 : vpos+9'd1;
    assign frame_zero=line_start && vpos==9'd261;
    assign vblank_start=line_start && vpos==9'd239;
    always @(posedge clk_sys)begin
        if(init_reset)begin hpos<=0;vpos<=9'd240;end
        else if(ce_pixel)begin
            if(hpos==9'd455)begin hpos<=0;vpos<=line_number;end
            else hpos<=hpos+9'd1;
        end
    end
endmodule
