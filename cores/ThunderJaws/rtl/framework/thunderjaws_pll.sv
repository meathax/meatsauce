// Project-owned wrapper around the same Quartus altera_pll primitive.
// Fabric/video remain outclk0. outclk1=-T/4; DDIO inversion forwards +T/4.
module thunderjaws_pll(input wire refclk,rst,output wire outclk_0,outclk_1,locked);
 thunderjaws_pll_0002 pll_inst(.refclk(refclk),.rst(rst),.outclk_0(outclk_0),.outclk_1(outclk_1),.locked(locked));
endmodule
module thunderjaws_pll_0002(input wire refclk,rst,output wire outclk_0,outclk_1,locked);
 altera_pll #(.fractional_vco_multiplier("false"),.reference_clock_frequency("50.0 MHz"),
 .operation_mode("direct"),.number_of_clocks(2),
 .output_clock_frequency0("42.954545 MHz"),.phase_shift0("0 ps"),.duty_cycle0(50),
 .output_clock_frequency1("42.954545 MHz"),.phase_shift1("-5820 ps"),.duty_cycle1(50),
 .pll_type("General"),.pll_subtype("General")) altera_pll_i(
 .refclk(refclk),.rst(rst),.outclk({outclk_1,outclk_0}),.locked(locked),.fboutclk(),.fbclk(1'b0));
endmodule
