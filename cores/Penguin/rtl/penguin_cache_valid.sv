// SPDX-License-Identifier: GPL-3.0-or-later
// Synchronous mask storage, deliberately separate from unreset data/tag RAM.
// Clear one set per clock at a reset/invalidation edge. Held reset/download
// does not restart the sweep. No caller may admit a lookup before busy falls.
module penguin_cache_valid #(parameter integer WIDTH=4, ADDRESS_BITS=10)(
 input logic clk,reset,invalidate,read_enable,write_enable,
 input logic [ADDRESS_BITS-1:0] read_address,write_address,
 input logic [WIDTH-1:0] data,
 output wire [WIDTH-1:0] q,
 output wire busy
);
 logic reset_seen=0,invalidate_seen=0,clearing=1;
 logic [ADDRESS_BITS-1:0] clear_address=0;
 logic [1:0] fence=0;
 wire restart=(reset&&!reset_seen)||(invalidate&&!invalidate_seen);
 wire memory_we=restart||clearing||(!busy&&!reset&&!invalidate&&write_enable);
 wire [ADDRESS_BITS-1:0] memory_address=restart?'0:(clearing?clear_address:write_address);
 wire [WIDTH-1:0] memory_data=(restart||clearing)?'0:data;
 wire read_ce=read_enable&&!busy&&!reset&&!invalidate;
 wire [WIDTH-1:0] stored_q;
 assign busy=clearing||(fence!=0)||restart;
 assign q=busy?'0:stored_q;
 always_ff @(posedge clk)begin
  reset_seen<=reset;invalidate_seen<=invalidate;
  if(restart)begin
   clear_address<=1;clearing<=1;fence<=0;
  end else if(clearing)begin
   if(&clear_address)begin clearing<=0;fence<=2;end
   else clear_address<=clear_address+1'b1;
  end else if(fence!=0)fence<=fence-1'b1;
 end
 // MLAB write inputs/control and read address are clocked. The two-clock
 // fence after the final clear covers the input-register/write update boundary.
 // A valid mask is only consumed after a subsequent synchronous lookup read.
`ifdef SYNTHESIS
 altdpram #(.width(WIDTH),.widthad(ADDRESS_BITS),.numwords(1<<ADDRESS_BITS),
  .ram_block_type("M10K"),.intended_device_family("Cyclone V"),
  .indata_reg("INCLOCK"),.wraddress_reg("INCLOCK"),.wrcontrol_reg("INCLOCK"),
  .rdaddress_reg("OUTCLOCK"),.rdcontrol_reg("OUTCLOCK"),.outdata_reg("UNREGISTERED"),
  .indata_aclr("OFF"),.wraddress_aclr("OFF"),.wrcontrol_aclr("OFF"),
  .rdaddress_aclr("OFF"),.rdcontrol_aclr("OFF"),.outdata_aclr("OFF"),.outdata_sclr("OFF"),
  .read_during_write_mode_mixed_ports("DONT_CARE")) storage(
  .inclock(clk),.inclocken(1'b1),.outclock(clk),.outclocken(read_ce),
  .wren(memory_we),.data(memory_data),.wraddress(memory_address),
  .rdaddress(read_address),.rden(1'b1),.q(stored_q),
  .aclr(1'b0),.sclr(1'b0),.wraddressstall(1'b0),.rdaddressstall(1'b0),.byteena(1'b1));
`else
 (* ramstyle="M10K" *) logic [WIDTH-1:0] memory[0:(1<<ADDRESS_BITS)-1];
 logic [WIDTH-1:0] result;
 always_ff @(posedge clk)begin
  if(memory_we)memory[memory_address]<=memory_data;
  if(read_ce)result<=memory[read_address];
 end
 assign stored_q=result;
`endif
endmodule
