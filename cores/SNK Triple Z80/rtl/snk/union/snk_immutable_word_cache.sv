// SPDX-License-Identifier: GPL-3.0-only
// Immutable ROM-word cache. Entries are populated only by an acknowledged
// backing-store read and discarded on reset or any accepted ROM download.
module snk_immutable_word_cache #(parameter ADDR_WIDTH=17,parameter INDEX_BITS=10)(
 input wire clk,invalidate,request,input wire [ADDR_WIDTH-1:0] read_addr,
 output wire hit,output wire [31:0] read_data,
 input wire fill,input wire [ADDR_WIDTH-1:0] fill_addr,input wire [31:0] fill_data
);
 localparam LINES=1<<INDEX_BITS;
 wire [INDEX_BITS-1:0] read_index=read_addr[INDEX_BITS-1:0]^(read_addr>>INDEX_BITS);
 wire [INDEX_BITS-1:0] fill_index=fill_addr[INDEX_BITS-1:0]^(fill_addr>>INDEX_BITS);
 (* ramstyle="M10K" *) reg [ADDR_WIDTH+31:0] entries[0:LINES-1];
 reg [LINES-1:0] valid;
 reg [ADDR_WIDTH+31:0] q_entry;
 reg q_valid;
 always @(posedge clk)begin
  q_entry<=entries[read_index];
  if(invalidate)begin valid<=0;q_valid<=0;end
  else begin
   q_valid<=valid[read_index];
   if(fill)begin entries[fill_index]<={fill_addr,fill_data};valid[fill_index]<=1'b1;end
  end
 end
 assign hit=request&&!invalidate&&q_valid&&q_entry[ADDR_WIDTH+31:32]==read_addr;
 assign read_data=q_entry[31:0];
endmodule
