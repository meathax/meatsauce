// SPDX-License-Identifier: GPL-3.0-or-later
// Intended 50MHz reference -> common 56MHz system/video root. The pixel
// counter lives in hangzo_raster; never connect the vendor 7MHz clock output.
// SDRAM output1 is a project-owned 8929ps phase candidate, derived from
// independent CAS2 edge/flight proof; final pad-relative STA remains required.
module hangzo_clock (
    input wire refclk_50,pll_reset,
    output wire clk_sys,clk_video,locked,clk_sdram
);
    wire shared_root;
    pll_0002 pll (
        .refclk(refclk_50),.rst(pll_reset),.outclk_0(shared_root),
        .outclk_1(clk_sdram),.outclk_2(),.outclk_3(),.outclk_4(),.outclk_5(),.locked(locked)
    );
    assign clk_sys=shared_root;
    assign clk_video=shared_root;
endmodule
