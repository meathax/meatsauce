// SPDX-License-Identifier: GPL-3.0-or-later
// Physical SDRAM clock forwarding. Constants select INVERTED command master:
// low at its rising edge, high at its falling edge. PLL phase is unchanged.
// Native tests compile the actual Quartus17 altddio_out behavioral model.
module d8_sdram_clock(input wire clk_sdram,output wire SDRAM_CLK);
    altddio_out #(
        .extend_oe_disable("OFF"),.intended_device_family("Cyclone V"),
        .invert_output("OFF"),.lpm_hint("UNUSED"),.lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"),.power_up_high("OFF"),.width(1)
    ) forward_clock (
        .datain_h(1'b0),.datain_l(1'b1),.outclock(clk_sdram),
        .dataout(SDRAM_CLK),.oe_out(),.aclr(1'b0),.aset(1'b0),
        .oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0)
    );
endmodule
