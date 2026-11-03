// SPDX-License-Identifier: GPL-3.0-or-later
// Game/controller stay at48MHz. A related PHY-only output forwards the clock
// with a quarter-period offset; no game logic moves to the PHY output.
module spy_pll(input wire refclk,reset,output wire clk,clk_sdram,locked);
    wire [1:0] clocks;
    altera_pll #(.reference_clock_frequency("50.0 MHz"),.operation_mode("direct"),
        .number_of_clocks(2),.output_clock_frequency0("48.000000 MHz"),
        .phase_shift0("0 ps"),.duty_cycle0(50),
        .output_clock_frequency1("48.000000 MHz"),.phase_shift1("5208 ps"),.duty_cycle1(50),
        .pll_type("General"),.pll_subtype("General"))
    u_pll(.refclk(refclk),.rst(reset),.outclk(clocks),.locked(locked),.fbclk(1'b0),.fboutclk());
    assign clk=clocks[0];assign clk_sdram=clocks[1];
endmodule
