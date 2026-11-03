// SPDX-License-Identifier: GPL-3.0-or-later
// One synchronous read port and independent write port; contents never reset.
module penguin_cache_store #(parameter integer WIDTH=72, ADDRESS_BITS=10)(
 input logic clk,read_enable,write_enable,
 input logic [ADDRESS_BITS-1:0] read_address,write_address,
 input logic [WIDTH-1:0] data,
 output wire [WIDTH-1:0] q
);
`ifdef SYNTHESIS
 altsyncram #(.operation_mode("DUAL_PORT"),.width_a(WIDTH),.widthad_a(ADDRESS_BITS),
  .numwords_a(1<<ADDRESS_BITS),.width_b(WIDTH),.widthad_b(ADDRESS_BITS),
  .numwords_b(1<<ADDRESS_BITS),.width_byteena_a(1),.width_byteena_b(1),
  .address_reg_b("CLOCK1"),.outdata_reg_b("UNREGISTERED"),
  .power_up_uninitialized("TRUE"),.read_during_write_mode_mixed_ports("OLD_DATA"),
  .intended_device_family("Cyclone V"),.ram_block_type("M10K")) store(
  .clock0(clk),.clock1(clk),.address_a(write_address),.address_b(read_address),
  .data_a(data),.data_b({WIDTH{1'b0}}),.wren_a(write_enable),.wren_b(1'b0),
  .byteena_a(1'b1),.byteena_b(1'b1),.rden_b(read_enable),.q_b(q),.q_a());
`else
 logic [WIDTH-1:0] memory[0:(1<<ADDRESS_BITS)-1];
 logic [WIDTH-1:0] result;
 always_ff @(posedge clk)begin
  if(write_enable)memory[write_address]<=data;
  if(read_enable)result<=memory[read_address];
 end
 assign q=result;
`endif
endmodule
