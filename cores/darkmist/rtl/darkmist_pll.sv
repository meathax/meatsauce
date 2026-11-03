// SPDX-License-Identifier: GPL-3.0-or-later
// 48.8336 MHz: 400x256 raster with CE8 gives the measured 59.611-Hz PCB refresh;
// SDRAM phase kept at 90 degrees. Requested fixture clock. Actual fitted frequency/jitter and SDRAM phase/I/O
// slack must be recorded; this clock choice is not a PCB measurement.
module darkmist_pll (
    input wire refclk,
    output wire clk_game,clk_sdram,locked
);
    wire [1:0] clocks;
    assign clk_game=clocks[0];assign clk_sdram=clocks[1];
    altera_pll #(
        .fractional_vco_multiplier("true"),.reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),.number_of_clocks(2),
        .output_clock_frequency0("48.833600 MHz"),.phase_shift0("0 ps"),.duty_cycle0(50),
        .output_clock_frequency1("48.833600 MHz"),.phase_shift1("5119 ps"),.duty_cycle1(50),
        .pll_type("General"),.pll_subtype("General")
    ) pll_i (.refclk(refclk),.rst(1'b0),.outclk(clocks),.locked(locked),.fboutclk(),.fbclk(1'b0));
endmodule
