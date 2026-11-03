`default_nettype none

// clk_video is the GSP VCLK: 4 MHz driver board, 6 MHz MultiSync, 5 MHz
// S.T.U.N. Runner (MAME stunrun_board: set_pixel_clock(5000000)).
module harddrivin_pll #(parameter bit COCKPIT = 0, parameter bit STUNRUN = 0) (
  input  logic refclk_i,
  input  logic rst_i,
  output logic clk_gsp_48_o,
  output logic clk_msp_50_o,
  output logic clk_100_o,
  output logic clk_100_sample_o,
  output logic clk_sdram_forward_o,
  output logic clk_dq_stage_o,
  output logic clk_video_6_o,
  output logic clk_pix40_o,
  output logic locked_o
);
`ifdef TMS34010_QUARTUS
  localparam int NCLK = STUNRUN ? 7 : 5;
  logic [NCLK-1:0] pll_clks;
  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("direct"),
    .number_of_clocks(NCLK),
    .output_clock_frequency0("48.0 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    // Stun Runner does not use the MSP. Reuse its PLL counter to forward a
    // phase-adjusted SDRAM clock; other boards retain the 50 MHz MSP clock.
    .output_clock_frequency1(STUNRUN ? "100.0 MHz" : "50.0 MHz"),
    .phase_shift1(STUNRUN ? "9167 ps" : "0 ps"),
    .duty_cycle1(50),
    .output_clock_frequency2("100.0 MHz"),
    // The inverted Stun Runner memory clock rises at approximately 6.5 ns,
    // after the late input sample. This puts the whole memory fabric on one
    // edge and removes the previous half-cycle handoff paths.
    .phase_shift2(STUNRUN ? "1563 ps" : "0 ps"),
    .duty_cycle2(50),
    .output_clock_frequency3(COCKPIT ? "4.0 MHz" : STUNRUN ? "5.0 MHz" : "6.0 MHz"),
    .phase_shift3("0 ps"),
    .duty_cycle3(50),
    // Sample returned SDRAM DQ inside the read eye (after tAC max + skew,
    // before the next beat's tOH min). 2813 ps = 27 VCO steps: STA with the
    // true (unrelaxed) hold check puts the edge inside the eye at both the
    // slow and fast corners. 4375 ps sat on the next beat at the fast corner.
    .output_clock_frequency4("100.0 MHz"),
    .phase_shift4(STUNRUN ? "2813 ps" : "8542 ps"),
    .duty_cycle4(50),
    // Stun Runner only: first read-data stage. Its capture edge is ~0.94 ns
    // later than the falling edge of the controller clock (1563 ps), giving the
    // DQ-input-cell to register hop more time across the die.
    .output_clock_frequency5("100.0 MHz"),
    .phase_shift5("2500 ps"),
    .duty_cycle5(50),
    // Stun Runner video output raster clock: exactly 4 clocks per 10 MHz dot.
    .output_clock_frequency6("40.0 MHz"),
    .phase_shift6("0 ps"),
    .duty_cycle6(50),
    .pll_type("General"),
    .pll_subtype("General")
  ) u_pll (
    .refclk(refclk_i), .refclk1(1'b0), .fbclk(1'b0), .rst(rst_i),
    .phase_en(1'b0), .updn(1'b0), .num_phase_shifts(3'b000),
    .scanclk(1'b0), .cntsel(5'b00000), .reconfig_to_pll(64'b0),
    .extswitch(1'b0), .adjpllin(1'b0), .cclk(1'b0),
    .outclk(pll_clks), .fboutclk(), .locked(locked_o), .phase_done(),
    .reconfig_from_pll(), .activeclk(), .clkbad(), .phout(),
    .lvds_clk(), .loaden(), .extclk_out(), .cascade_out(), .zdbfbclk()
  );
  assign clk_gsp_48_o = pll_clks[0];
  assign clk_msp_50_o = pll_clks[1];
  assign clk_100_o    = STUNRUN ? ~pll_clks[2] : pll_clks[2];
  assign clk_100_sample_o = STUNRUN ? pll_clks[4] : pll_clks[2];
  assign clk_sdram_forward_o = STUNRUN ? pll_clks[1] : ~pll_clks[2];
  generate
    if (STUNRUN) begin : g_dq_stage_clk
      assign clk_dq_stage_o = pll_clks[5];
    end else begin : g_no_dq_stage_clk
      assign clk_dq_stage_o = ~pll_clks[2];
    end
  endgenerate
  assign clk_video_6_o = pll_clks[3];
  assign clk_pix40_o = STUNRUN ? pll_clks[NCLK-1] : pll_clks[3];
`elsif HD_SIM_CLOCKS
  // Full-system simulation: the harness top drives the four PLL outputs.
  assign clk_gsp_48_o  = tb_stunrun.clk_48;
  assign clk_msp_50_o  = tb_stunrun.clk_50;
  assign clk_100_o     = tb_stunrun.clk_100;
  // The behavioral SDRAM model has no analog access delay.
  assign clk_100_sample_o = tb_stunrun.clk_100;
  assign clk_sdram_forward_o = ~tb_stunrun.clk_100;
  assign clk_dq_stage_o = ~tb_stunrun.clk_100;
  assign clk_video_6_o = tb_stunrun.clk_video;
  assign clk_pix40_o   = tb_stunrun.clk_100;
  assign locked_o      = tb_stunrun.pll_locked;
`else
  assign clk_gsp_48_o = refclk_i;
  assign clk_msp_50_o = refclk_i;
  assign clk_100_o    = STUNRUN ? ~refclk_i : refclk_i;
  assign clk_100_sample_o = refclk_i;
  assign clk_sdram_forward_o = STUNRUN ? refclk_i : ~refclk_i;
  assign clk_dq_stage_o = refclk_i;
  assign clk_video_6_o = refclk_i;
  assign clk_pix40_o = refclk_i;
  assign locked_o     = !rst_i;
`endif
endmodule

`default_nettype wire
