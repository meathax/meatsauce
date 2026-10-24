// -----------------------------------------------------------------------------
// tms34010_cyclone_v_video_pll.sv
//
// Independent DE10-Nano video-clock wrapper. FPGA_CLK2_50 produces a 50 MHz
// internal VCLK and a 180-degree-shifted 50 MHz physical VIDEO_VCLK. The
// phase-shifted PLL output avoids implementing clock inversion in fabric and
// makes the physical falling edge coincide with the internal active edge.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_cyclone_v_video_pll (
  input  logic ref_clk_i,
  input  logic pll_rst_i,
  output logic video_clk_o,
  output logic video_pin_clk_o,
  output logic locked_o
);

`ifdef TMS34010_QUARTUS
  logic [1:0] pll_clks;

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    // The two clocks are direct phase-related outputs; neither compensates
    // an external feedback path.
    .operation_mode("direct"),
    .number_of_clocks(2),
    .output_clock_frequency0("50.0 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("50.0 MHz"),
    .phase_shift1("10000 ps"),
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

  assign video_clk_o      = pll_clks[0];
  assign video_pin_clk_o  = pll_clks[1];
`else
  // Portable elaboration model only; the real phase relation is checked by
  // TimeQuest in the Quartus realization task.
  assign video_clk_o      = ref_clk_i;
  assign video_pin_clk_o  = !ref_clk_i;
  assign locked_o         = !pll_rst_i;
`endif

endmodule : tms34010_cyclone_v_video_pll

`default_nettype wire
