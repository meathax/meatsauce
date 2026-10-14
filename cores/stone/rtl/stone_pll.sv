// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// clk_vid is 5x the 6.666667 MHz pixel clock and exactly 1/3 of the 100 MHz
// fabric clock (VCO 400 MHz / 12), so framework paths between clk_sys and
// CLK_VIDEO get a full 10 ns cycle; a 3.75:1 ratio left them 2.5 ns.
module stone_pll(input wire refclk,reset,output wire clk,vclk,sdram_clk,clk_vid,locked);
 wire [3:0] clocks;
 altera_pll #(.fractional_vco_multiplier("false"),.reference_clock_frequency("50.0 MHz"),
 .operation_mode("direct"),.number_of_clocks(4),.output_clock_frequency0("100.0 MHz"),.phase_shift0("0 ps"),.duty_cycle0(50),
 .output_clock_frequency1("100.0 MHz"),.phase_shift1("5625 ps"),.duty_cycle1(50),
 .output_clock_frequency2("6.666667 MHz"),.phase_shift2("0 ps"),.duty_cycle2(50),
 .output_clock_frequency3("33.333333 MHz"),.phase_shift3("0 ps"),.duty_cycle3(50),.pll_type("General"),.pll_subtype("General")) pll(
 .refclk(refclk),.refclk1(1'b0),.fbclk(1'b0),.rst(reset),.phase_en(1'b0),.updn(1'b0),.num_phase_shifts(3'd0),.scanclk(1'b0),.cntsel(5'd0),.reconfig_to_pll(64'd0),.extswitch(1'b0),.adjpllin(1'b0),.cclk(1'b0),.outclk(clocks),.locked(locked));
 assign clk=clocks[0];assign sdram_clk=clocks[1];assign vclk=clocks[2];assign clk_vid=clocks[3];
endmodule
`default_nettype wire
