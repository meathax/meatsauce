// SPDX-License-Identifier: GPL-3.0-or-later
// Cyclone V master clocks from the 50 MHz reference (all integer-related, one PLL):
//   clk    = 47.95395 MHz  game/video clock = 6 x 7.99233 MHz pixel; 512x260 raster -> 60.038 Hz, the refresh measured on
//                          real PCB footage relative to the 12 MHz CPU/OKI crystal (clock_plan.json).  The 68000 (12 MHz)
//                          and OKI (1 MHz) keep their exact PCB rates through n/m fractional enables (ah_cpu_ce, ah_sound).
//   clk96  = 95.9079 MHz   SDRAM controller clock (2 x clk, rising edges aligned)
//   SDRAM_CLK pin    = clk96 phase-shifted by SDRAM_PHASE through a DDIO output cell
// Fractional VCO (no integer M/N/C within 40 ppm); counters chosen by Quartus.  Platform video/audio PLLs stay in sys/.
// SDRAM_PHASE is the first-fit value (0 ps: STA relation T for both the output and input directions, no multicycle needed; -2500 ps would need an explicit setup-2 edge proof);
// qualify it with the board-delay envelope in AH.sdc and the actual fitted I/O timing before release.
module ah_pll #(parameter SDRAM_PHASE = "4948 ps")(
    input  wire refclk, rst,
    output wire clk, clk96, sdram_clk, locked
);
    // Phase 0 ps: the forwarded pin clock is the same PLL counter as clk96 (a separate identical counter is merged away by Quartus).
    wire shifted_clock;
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(3),
        .output_clock_frequency0("47.953950 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("95.907900 MHz"), .phase_shift1("0 ps"), .duty_cycle1(50),
        .output_clock_frequency2("95.907900 MHz"), .phase_shift2(SDRAM_PHASE), .duty_cycle2(50),
        .pll_type("General"), .pll_subtype("General")
    ) pll_i (
        .rst(rst), .refclk(refclk), .outclk({shifted_clock, clk96, clk}), .locked(locked),
        .fboutclk(), .fbclk(1'b0)
    );
    // Only the external SDRAM pin uses the shifted clock; all logic stays on clk / clk96.
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) forward_sdram (
        .datain_h(1'b1), .datain_l(1'b0), .outclock(shifted_clock),
        .dataout(sdram_clk), .aclr(1'b0), .aset(1'b0), .oe(1'b1),
        .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
endmodule
