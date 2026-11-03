// SPDX-License-Identifier: GPL-3.0-or-later
// Dedicated clock forwarding: SDRAM rising edge is falling clk_source; PLL source -90 degrees makes it clk_sys+90 degrees.
// The simulator branch is the ideal DDIO truth table, not a fitted margin model.
module thunderjaws_sdram_clock(input wire clk_source,output wire sdram_clock);
`ifdef ALTERA_RESERVED_QIS
 altddio_out #(.width(1),.power_up_high("OFF"),.oe_reg("UNREGISTERED"),
  .extend_oe_disable("OFF"),.invert_output("OFF"),.lpm_hint("UNUSED"),.lpm_type("altddio_out")) forward_clock(
  .aclr(1'b0),.aset(1'b0),.datain_h(1'b0),.datain_l(1'b1),.outclock(clk_source),.outclocken(1'b1),
  .oe(1'b1),.sclr(1'b0),.sset(1'b0),.dataout(sdram_clock),.oe_out());
`else
 assign sdram_clock=~clk_source;
`endif
endmodule
