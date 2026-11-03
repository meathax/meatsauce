// SPDX-License-Identifier: GPL-3.0-or-later
// Forwarded inverted root: same h0/l1 DDIO primitive as pinned Template.
// reset is deliberately not a clock gate: the pin continues through reset,
// pause and download, matching the independent SDRAM pin fixture schedule.
// Physical pad-clock insertion and read/write margin still require native STA.
module madmotor_sdram_clock(input wire clk,reset,output wire outclk);
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) forwarded_clock (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk),
        .dataout(outclk), .aclr(1'b0), .aset(1'b0), .oe(1'b1),
        .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
endmodule
