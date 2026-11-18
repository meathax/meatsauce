// One 48 MHz game clock; output 1 only forwards a phase shifted SDRAM clock.
module alpha68kn_pll(input wire refclk,rst, output wire clk_sys,clk_sdram,locked);
    wire [1:0] clocks;
    altera_pll #(
        .fractional_vco_multiplier("false"), .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"), .number_of_clocks(2),
        .output_clock_frequency0("48.0 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("48.0 MHz"), .phase_shift1("10416 ps"), .duty_cycle1(50),
        .pll_type("General"), .pll_subtype("General")
    ) pll (.refclk(refclk),.rst(rst),.outclk(clocks),.locked(locked),.fbclk(1'b0));
    assign clk_sys=clocks[0];
    assign clk_sdram=clocks[1];
endmodule
