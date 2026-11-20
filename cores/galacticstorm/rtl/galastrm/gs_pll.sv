// SPDX-License-Identifier: BSD-3-Clause
// Approved common64MHz candidate. All aliases are the SAME PLL output net.
// Native PLL feasibility, pin timing and full-source qualification remain open.
module gs_pll(input wire clk_50,reset,
              output wire cpu_clk,ram_clk,dsp_clk,locked);
    wire [0:0] clocks;
    assign cpu_clk=clocks[0];
    assign ram_clk=clocks[0];
    assign dsp_clk=clocks[0];
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),.number_of_clocks(1),
        .output_clock_frequency0("64.000000 MHz"),
        .phase_shift0("0 ps"),.duty_cycle0(50),
        .pll_type("General"),.pll_subtype("General")
    ) pll_i(.refclk(clk_50),.rst(reset),.outclk(clocks),.locked(locked),
            .fbclk(1'b0),.fboutclk());
endmodule
