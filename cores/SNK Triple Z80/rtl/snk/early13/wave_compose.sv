// MAME marvins_screen_update order: BG, sprites(<split), FG, sprites(>=split), TX. Shadow = |0x200.
module wave_compose(
  input [8:0] bg_idx, fg_idx, tx_idx, input fg_opq, tx_opq,
  input [7:0] lo_c, hi_c, input lo_s, hi_s,
  output [9:0] idx);
  wire [9:0] a = lo_c[7] ? {3'b0, lo_c[6:0]} : {1'b0, bg_idx};
  wire [9:0] b = lo_s ? (a | 10'h200) : a;
  wire [9:0] c = fg_opq ? {1'b0, fg_idx} : b;
  wire [9:0] d = hi_c[7] ? {3'b0, hi_c[6:0]} : c;
  wire [9:0] e = hi_s ? (d | 10'h200) : d;
  assign idx = tx_opq ? {1'b0, tx_idx} : e;
endmodule
