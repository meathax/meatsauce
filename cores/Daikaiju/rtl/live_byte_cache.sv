// SPDX-License-Identifier: GPL-3.0-or-later
// Preserve an immediately visible byte write while using physical MLAB RAM.
module a74_live_byte_cache #(parameter AW=8, POISON_RDW=0, INIT_ZERO=0)(
 input wire clk,write_enable,
 input wire [AW-1:0] write_address,read_address,
 input wire [7:0] write_data,
 output wire [7:0] read_data
);
 (* ramstyle="MLAB, no_rw_check" *) reg [7:0] mem[0:(1<<AW)-1];
 generate if(INIT_ZERO)begin:init_memory
  integer page,byte_index;
  initial for(page=0;page<(1<<AW);page=page+256)
   for(byte_index=0;byte_index<256;byte_index=byte_index+1)
    if(page+byte_index<(1<<AW))mem[page+byte_index]=0;
 end endgenerate
 reg pending_valid=0,recent_valid=0;
 reg [AW-1:0] pending_address,recent_address;
 reg [7:0] pending_data,recent_data;
 always @(posedge clk)begin
  pending_valid<=write_enable;recent_valid<=pending_valid;
  if(write_enable)begin pending_address<=write_address;pending_data<=write_data;end
  if(pending_valid)begin
   mem[pending_address]<=pending_data;
   recent_address<=pending_address;recent_data<=pending_data;
  end
 end
 // The committing entry covers the physical read-during-write uncertainty
 // for a full cycle; the newer pending entry has priority, including bursts
 // repeatedly targeting one address. Neither accepted writes nor retirement
 // depend on a game reset or pixel enable.
 wire committing=recent_valid && recent_address==read_address;
 wire [7:0] raw_data=(POISON_RDW && committing)?8'hxx:mem[read_address];
 assign read_data=(pending_valid && pending_address==read_address)?pending_data:
                  committing?recent_data:raw_data;
endmodule
