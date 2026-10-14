// SPDX-License-Identifier: GPL-3.0-or-later
// Connected Bandido sheets33/34. Physical pin levels, not asserted dump bytes.
// Exact Sheriff revision, electrical timing and CRT amplitude remain open.
module n8080_color_path (
 input wire clk, clear_n, ce_capture,
 input wire [3:0] prom_pins, // O1(14),O2(13),O3(12),O4(11)
 input wire [1:0] color_mode, // OUT6 Q4,Q3 -> 4C B3,A13
 input wire [2:0] color_data, // OUT6 Q2,Q1,Q0 -> 3D A11,A5,A2
 input wire video_bit,
 output wire [3:0] latch_q, latch_q_n,
 output wire mux_select, mux_strobe,
 output wire [2:0] mux_n, nand_n, pnp_on // bits R,G,B
);
 wire [3:0] y_n = ~(4'b0001 << color_mode);
 // Sheet34 4F NAND3 returns to3K D2(5), not mux red A.
 wire conditioned_d2 = !(prom_pins[3] && y_n[2]);
 wire [3:0] d = {prom_pins[0],prom_pins[2],conditioned_d2,prom_pins[1]};
 n8080_color_latch latch(.clk(clk),.clear_n(clear_n),.ce_capture(ce_capture),
  .d(d),.q(latch_q),.q_n(latch_q_n));
 // nQ4(14)->1B(3), nQ1(3)->2B(6), nQ3(11)->3B(10).
 wire [2:0] b = {latch_q_n[2],latch_q_n[0],latch_q_n[3]};
 // Sheet33 4E4/5 are both Y3_n, output6 -> ST15.
 assign mux_strobe = !(y_n[3] && y_n[3]);
 wire mode12 = !(y_n[2] && y_n[1]); // 4E output3 -> 4F12
 wire control_n = !(mode12 && latch_q_n[1]); // held nQ2 ->4F13
 assign mux_select = !(control_n && y_n[0]); // 4F11 ->4E10; Y0_n ->4E9
 // TI SDLS058: inverted selected data; ST high forces all outputs H.
 assign mux_n = mux_strobe ? 3'b111 : ~(mux_select ? b : color_data);
 assign nand_n = ~(mux_n & {3{video_bit}});
 assign pnp_on = ~nand_n; // low base drive: ideal PNP conduction, not CRT voltage
endmodule
