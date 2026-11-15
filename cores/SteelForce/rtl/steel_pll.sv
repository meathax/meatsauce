// One 45.6 MHz board logic clock; the second output only clocks the SDRAM pin.
// outclk1 phase is set from fitted SDRAM pad timing (see SteelForce.sdc and
// docs/reference/agent-quartus-fit-20261013.md): the SDRAM_CLK pad clock reaches the pin
// about 4.3 ns later than the clk_sys register clock (DDIO + output buffer), so 5482 ps
// here is about 9.7 ns at the pins. Window over the 4 timing models with the registered
// DQ output-enable / DQM in steel_sdram_chip.sv is about 4.8 .. 5.9 ns. The step is
// VCO/8 = 109.65 ps; values off that grid (5200, 5400) are illegal for altera_pll.
// Hierarchy emu|pll|pll_inst|altera_pll_i matches the template sys_top.sdc
// clock-group filter; keep the instance names.
module steel_pll_core(input wire refclk,output wire clk,ram_clk,locked);
    altera_pll #(
        .fractional_vco_multiplier("false"),.reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),.number_of_clocks(2),
        .output_clock_frequency0("45.600000 MHz"),.phase_shift0("0 ps"),.duty_cycle0(50),
        .output_clock_frequency1("45.600000 MHz"),.phase_shift1("5482 ps"),.duty_cycle1(50),
        .pll_type("General"),.pll_subtype("General")
    ) altera_pll_i(.refclk(refclk),.rst(1'b0),.outclk({ram_clk,clk}),.locked(locked),.fboutclk(),.fbclk(1'b0));
endmodule

module steel_pll(input wire refclk,output wire clk,ram_clk,locked);
    steel_pll_core pll_inst(.refclk(refclk),.clk(clk),.ram_clk(ram_clk),.locked(locked));
endmodule
