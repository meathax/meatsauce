// DECO222 / C10707 opcode bitswap: 7,5,6,4,3,2,1,0
// From MAME deco222.cpp mi_decrypt::read_sync

module deco222_bitswap_unit(
  input  [7:0] din,
  output [7:0] dout
);
  assign dout = {din[7], din[5], din[6], din[4], din[3], din[2], din[1], din[0]};
endmodule
