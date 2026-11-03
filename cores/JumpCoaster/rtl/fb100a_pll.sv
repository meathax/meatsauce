// SPDX-License-Identifier: GPL-3.0-or-later
module fb100a_pll (
    input wire refclk,
    input wire rst,
    output wire clk_sys,
    output wire clk_video,
    output wire locked
);
    assign clk_video = clk_sys;
    pll_0002 pll (
        .refclk(refclk), .rst(rst), .outclk_0(clk_sys), .locked(locked),
        .reconfig_to_pll(64'd0), .reconfig_from_pll()
    );
endmodule
