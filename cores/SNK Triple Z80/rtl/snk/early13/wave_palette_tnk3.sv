// PRIVATE: MAME snk_state::tnk3_palette (snk_v.cpp:31-58), used by marvins/vangrd2/madcrash
// (snk.cpp:4042/4102/4173). p0=prom[i], p1=prom[i+0x400], p2=prom[i+0x800] (low nibbles).
module wave_palette_tnk3(input [3:0] p0, p1, p2, output [7:0] r, g, b);
  function [7:0] w(input b0, b1, b2, b3);
    w = (b0 ? 8'h0e : 8'h00) + (b1 ? 8'h1f : 8'h00) + (b2 ? 8'h43 : 8'h00) + (b3 ? 8'h8f : 8'h00);
  endfunction
  assign r = w(p2[3], p0[1], p0[2], p0[3]);
  assign g = w(p2[2], p1[2], p1[3], p0[0]);
  assign b = w(p2[0], p2[1], p1[0], p1[1]);
endmodule
