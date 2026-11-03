// SPDX-License-Identifier: GPL-3.0-or-later
// Cyclone V master clock: 50 MHz reference -> 48 MHz game/SDRAM clock.
// The platform video/audio clocks remain platform-owned.
module airbustr_pll(input wire refclk, rst, output wire clk, sdram_clk, locked);
    wire shifted_clock;
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(2),
        .output_clock_frequency0("48.000000 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("48.000000 MHz"),
        .phase_shift1("6250 ps"), .duty_cycle1(50),
        .pll_type("General"), .pll_subtype("General")
    ) pll_i (
        .rst(rst), .refclk(refclk), .outclk({shifted_clock,clk}), .locked(locked),
        .fboutclk(), .fbclk(1'b0)
    );
    // Only the external SDRAM pin uses this coherent phase. All game logic
    // remains on clk. Preserve the real DDIO/pin latency in TimeQuest.
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
