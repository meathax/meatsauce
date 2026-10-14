// SPDX-License-Identifier: GPL-3.0-or-later
// Diagnostic composition only. Source CLK9=HREAD_n=!4I_QD.
// CE samples settled pre-edge PROM pins; physical propagation is not modeled.
module color_clock_qualification(
 input wire clk,clear_n,ce_counter,flip_latched,
 input wire [3:0] prom_pins,
 input wire [7:0] rd,
 output reg [3:0] phase_4i,
 output wire [3:0] upper_4j,
 output wire [7:0] raw_vertical,
 output wire [4:0] hbyte,
 output wire [7:0] v_pio,
 output wire [9:0] prom_address,
 output wire ce_color,hread_n,hb,vb,video_bit,serializer_load,
 output wire [3:0] latch_q,latch_q_n,
 output wire [2:0] pnp_on
);
 wire h_active,carry;
 always @(posedge clk) begin
  if(!clear_n) phase_4i<=0;
  else if(ce_counter) phase_4i<=phase_4i+1'b1;
 end
 n8080_horizontal_counter horizontal(.clk(clk),.reset(!clear_n),
  .ce_counter(ce_counter),.phase_4i(phase_4i),.upper_4j(upper_4j),
  .h_active(h_active),.hb(hb),.terminal_carry(carry));
 n8080_vertical_counter vertical(.clk(clk),.reset(!clear_n),
  .ce_counter(ce_counter),.horizontal_active(h_active),
  .horizontal_carry(carry),.vertical(raw_vertical),.vb(vb));
 assign hbyte={upper_4j,!phase_4i[3]} ^ {5{flip_latched}};
 assign v_pio=raw_vertical ^ {8{flip_latched}};
 assign prom_address={v_pio[7:3],hbyte};
 assign hread_n=!phase_4i[3];
 assign ce_color=ce_counter && (&phase_4i); // raw QD falling, no4J condition
 wire [7:0] serializer_q;
 n8080_video_path serializer(.clk(clk),.ce_counter(ce_counter),
  .clear_n(clear_n),.phase_4i(phase_4i[2:0]),.hb(hb),.vb(vb),
  .flip_latched(flip_latched),.serial_right(1'b0),.serial_left(1'b0),
  .rd(rd),.video_bit(video_bit),.load_mode(serializer_load),
  .register_q(serializer_q));
 wire mux_select,mux_strobe;
 wire [2:0] mux_n,nand_n;
 n8080_color_path color(.clk(clk),.clear_n(clear_n),.ce_capture(ce_color),
  .prom_pins(prom_pins),.color_mode(2'd0),.color_data(3'd0),
  .video_bit(video_bit),.latch_q(latch_q),.latch_q_n(latch_q_n),
  .mux_select(mux_select),.mux_strobe(mux_strobe),.mux_n(mux_n),
  .nand_n(nand_n),.pnp_on(pnp_on));
endmodule
