// SPDX-License-Identifier: GPL-3.0-or-later
module color_latch_qualification (
 input wire clk, reset, ce_xtal, ce_counter,
 input wire [3:0] d,
 output wire [3:0] phase_4i, upper_4j, q, q_n,
 output wire capture_ce, h_active
);
 n8080_memory_phases phase(.clk(clk),.reset(reset),.ce_xtal(ce_xtal),
  .raw_cas_n(),.raw_ras_n(),.comadr_n(),.hread_n(),.phase_4i(phase_4i),.delay_4a());
 n8080_horizontal_counter horizontal(.clk(clk),.reset(reset),.ce_counter(ce_counter),
  .phase_4i(phase_4i),.upper_4j(upper_4j),.h_active(h_active),.hb(),.terminal_carry());
 // 4J QD rises at 7->8. Both the counter and latch use the same master
 // edge; this pre-edge expression introduces no divided/generated clock.
 assign capture_ce = ce_counter && phase_4i == 4'd15 && upper_4j == 4'd7;
 n8080_color_latch latch(.clk(clk),.clear_n(!reset),.ce_capture(capture_ce),
  .d(d),.q(q),.q_n(q_n));
endmodule
