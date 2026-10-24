// -----------------------------------------------------------------------------
// tms34010_cyclone_v_pll.sv
//
// Cyclone V clock wrapper for the DE10-Nano realization. The 50 MHz
// FPGA_CLK1 oscillator produces:
//   * 50 MHz core_clk_o; and
//   * 200 MHz bus_clk8x_o, yielding 25 MHz LCLK1/LCLK2 periods after the
//     local-bus engine's eight subphases.
//
// TMS34010_QUARTUS selects the Intel PLL primitive during the Quartus build.
// Portable lint/simulation deliberately bypasses the frequency conversion;
// clock-ratio behavior remains covered at the split pin-system boundary.
//
// Justification: Cyclone V derived clocks must come from a PLL rather than a
// fabric divider (HDL guideline 11 and assumption A0049).
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_cyclone_v_pll (
  input  logic ref_clk_i,
  input  logic pll_rst_i,
  output logic core_clk_o,
  output logic bus_clk8x_o,
  output logic locked_o
);

`ifdef TMS34010_QUARTUS
  logic [1:0] pll_clks;

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    // No external feedback path exists on this board-level wrapper. Direct
    // mode makes that intent explicit and prevents the fitter from guessing
    // a compensation target.
    .operation_mode("direct"),
    .number_of_clocks(2),
    .output_clock_frequency0("50.0 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("200.0 MHz"),
    .phase_shift1("0 ps"),
    .duty_cycle1(50),
    .pll_type("General"),
    .pll_subtype("General")
  ) u_pll (
    .refclk           (ref_clk_i),
    .refclk1          (1'b0),
    .fbclk            (1'b0),
    .rst              (pll_rst_i),
    .phase_en         (1'b0),
    .updn             (1'b0),
    .num_phase_shifts (3'b000),
    .scanclk          (1'b0),
    .cntsel           (5'b00000),
    .reconfig_to_pll  (64'b0),
    .extswitch        (1'b0),
    .adjpllin         (1'b0),
    .cclk             (1'b0),
    .outclk           (pll_clks),
    .fboutclk         (),
    .locked           (locked_o),
    .phase_done       (),
    .reconfig_from_pll(),
    .activeclk        (),
    .clkbad           (),
    .phout            (),
    .lvds_clk         (),
    .loaden           (),
    .extclk_out       (),
    .cascade_out      (),
    .zdbfbclk         ()
  );

  assign core_clk_o   = pll_clks[0];
  assign bus_clk8x_o  = pll_clks[1];
`else
  // Portable elaboration model only. Tests that need independent or
  // non-integer clock ratios instantiate tms34010_pin_system directly.
  assign core_clk_o  = ref_clk_i;
  assign bus_clk8x_o = ref_clk_i;
  assign locked_o    = !pll_rst_i;
`endif

endmodule : tms34010_cyclone_v_pll

`default_nettype wire
