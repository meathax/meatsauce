// Tumble needs JTFRAME's 48/24/96 MHz clock set and phase-shifted SDRAM clock.
// This uses the matching Deco16 donor configuration; the Template PLL remains
// available and unchanged for template projects.
module tumble_pll(
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire outclk_4,
    output wire outclk_5,
    output wire locked
);
    tumble_pll_0002 pll_inst(
        .refclk   (refclk),
        .rst      (rst),
        .outclk_0 (outclk_0),
        .outclk_1 (outclk_1),
        .outclk_2 (outclk_2),
        .outclk_3 (outclk_3),
        .outclk_4 (outclk_4),
        .outclk_5 (outclk_5),
        .locked   (locked)
    );
endmodule
