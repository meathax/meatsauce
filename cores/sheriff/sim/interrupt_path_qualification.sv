// SPDX-License-Identifier: GPL-3.0-or-later
module interrupt_path_qualification(
 input wire clk,diagnostic_clear,sample_ce,inte,status_inta,
 input wire joined,counter_reset,counter_ce,
 input wire [7:0] manual_vertical,
 input wire manual_vb,
 output wire irq,intr,intd,request_rise,
 output wire [7:0] interrupt_data,raw_vertical,
 output wire vb,h_active,h_carry,
 output wire [3:0] phase_4i,upper_4j
);
 reg [3:0] low_counter;
 wire [7:0] vertical;
 wire vertical_blank;
 assign phase_4i=low_counter;
 always @(posedge clk) begin
  if(counter_reset) low_counter<=0;
  else if(counter_ce) low_counter<=low_counter+1'b1;
 end
 n8080_horizontal_counter hc(.clk(clk),.reset(counter_reset),.ce_counter(counter_ce),
  .phase_4i(low_counter),.upper_4j(upper_4j),.h_active(h_active),.hb(),.terminal_carry(h_carry));
 n8080_vertical_counter vc(.clk(clk),.reset(counter_reset),.ce_counter(counter_ce),
  .horizontal_active(h_active),.horizontal_carry(h_carry),.vertical(vertical),.vb(vertical_blank));
 assign raw_vertical=joined?vertical:manual_vertical;
 assign vb=joined?vertical_blank:manual_vb;
 n8080_interrupt_path ip(.clk(clk),.diagnostic_clear(diagnostic_clear),.sample_ce(sample_ce),.hold_irq(1'b0),
  .raw_vertical(raw_vertical),.vb(vb),.inte(inte),.status_inta(status_inta),
  .irq(irq),.intr(intr),.intd(intd),.interrupt_data(interrupt_data),.request_rise(request_rise));
endmodule
