// SPDX-License-Identifier: GPL-3.0-or-later
// WIDE host writes, byte CPU reads, one reset-free read edge.
module a74_wide_rom #(parameter AW=17, BYTES=98304)(
 input wire clk,write_enable,
 input wire [AW-1:0] write_address,read_address,
 input wire [15:0] write_data,
 output wire [7:0] read_data
);
 localparam WORDS=BYTES/2;
 reg [7:0] lo[0:WORDS-1],hi[0:WORDS-1];
 reg [7:0] lo_q,hi_q;reg odd_q;
 wire [AW-1:0] lo_write_index={1'b0,write_address[AW-1:1]}+write_address[0];
 always @(posedge clk)begin
  if(write_enable && write_address<BYTES && lo_write_index<WORDS)
   lo[lo_write_index[AW-2:0]]<=write_address[0]?write_data[15:8]:write_data[7:0];
  lo_q<=lo[read_address[AW-1:1]];
 end
 always @(posedge clk)begin
  if(write_enable && write_address<BYTES)
   hi[write_address[AW-1:1]]<=write_address[0]?write_data[7:0]:write_data[15:8];
  hi_q<=hi[read_address[AW-1:1]];
 end
 always @(posedge clk)odd_q<=read_address[0];
 assign read_data=odd_q?hi_q:lo_q;
endmodule
