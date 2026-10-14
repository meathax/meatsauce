// license:BSD-3-Clause
// copyright-holders:Nicola Salmoria, David Haywood
// 315-5179 decryption tables translated from MAME's segacrp2_device.cpp.
module segacrp2_315_5179(
 input logic [14:0] address,
 input logic [7:0] encrypted,
 input logic opcode_fetch,
 output logic [7:0] decrypted
);
 localparam logic [1023:0] XOR_TABLE=1024'h4105005054114540040151551014414500045451154044010555501411454004015155104441050050541115404401055550144145000454511510444105005014414500045411154044010555501411454004015115104441050050541115404401055510144145000454511510444105005014114540040151551014414500;
 localparam logic [511:0] SWAP_TABLE=512'h754206431753206431753206421753206421753206421753106421753106421786431fdba86421fdba86421fdba86421fdb986421fdb986421fdb986420fdb98;
 localparam logic [287:0] PERMUTATION_BITS=288'hd10d02c84c22c149909828b08328165a0584530506434194132426886116ca01a20b40a6;

 logic [5:0] row;
 logic [6:0] entry;
 logic [3:0] permutation;
 logic [7:0] xor_mask;
 logic [2:0] source0,source1,source2,source3;
 logic [7:0] permuted;
 integer table_offset;

 always_comb begin
  // MAME selects a pair of tables from A14,A12,A9,A6,A3,A0; even is M1.
  row={address[14],address[12],address[9],address[6],address[3],address[0]};
  entry={row,~opcode_fetch};
  table_offset=integer'(entry)*4;
  permutation=SWAP_TABLE[table_offset +: 4];
  xor_mask=XOR_TABLE[integer'(entry)*8 +: 8];
  table_offset=integer'(permutation)*12;
  source0=PERMUTATION_BITS[table_offset +: 3];
  source1=PERMUTATION_BITS[table_offset+3 +: 3];
  source2=PERMUTATION_BITS[table_offset+6 +: 3];
  source3=PERMUTATION_BITS[table_offset+9 +: 3];
  permuted={encrypted[7],encrypted[source0],encrypted[5],encrypted[source1],
            encrypted[3],encrypted[source2],encrypted[1],encrypted[source3]};
  decrypted=permuted^xor_mask;
 end
endmodule
