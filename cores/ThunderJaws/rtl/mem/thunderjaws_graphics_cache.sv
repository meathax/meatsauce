// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from the pinned Batman row-pair ROM layout. A four-word SDRAM burst
// supplies both rows of all four planes. Raw target fetch address is {code,row}.
module thunderjaws_graphics_cache #(
 parameter integer INDEX_BITS=4,
 parameter [23:0] BASE_WORD=24'h090000
)(
 input wire clk_sys,init_reset,invalidate,fetch,
 input wire [17:0] address,
 output reg [31:0] data,
 output reg data_valid,late,
 output wire memory_valid,
 input wire memory_ready,
 output wire [23:0] memory_address,
 output wire [2:0] memory_length,
 input wire memory_response_valid,
 input wire [15:0] memory_response_data
);
 localparam LINES=1<<INDEX_BITS,TAG_BITS=17-INDEX_BITS;
 localparam IDLE=0,LOOKUP=1,ISSUE=2,FILL=3;
 reg [1:0] state,beat;
 reg [63:0] rows[0:LINES-1];
 reg [TAG_BITS-1:0] tags[0:LINES-1];reg [LINES-1:0] valid_lines;
 reg [17:0] held;
 reg [63:0] lookup_rows,fill_rows;
 reg [TAG_BITS-1:0] lookup_tag;
 reg lookup_valid,epoch,held_epoch,prior_invalidate;
 wire [INDEX_BITS-1:0] index=held[INDEX_BITS:1];
 wire [TAG_BITS-1:0] tag=held[17:INDEX_BITS+1];
 wire [63:0] completed={fill_rows[63:16],memory_response_data};
 function automatic [31:0] row_bytes(input [63:0] q,input odd);
 begin row_bytes=odd ? {q[55:48],q[39:32],q[23:16],q[7:0]} : {q[63:56],q[47:40],q[31:24],q[15:8]};end endfunction
 assign memory_valid=!init_reset && state==ISSUE;
 assign memory_address=BASE_WORD+{5'd0,held[17:1],2'b00};
 assign memory_length=3'd3;
 always @(posedge clk_sys)begin
  if(init_reset)begin state<=IDLE;valid_lines<=0;data_valid<=0;late<=0;epoch<=0;held_epoch<=0;prior_invalidate<=0;data<=0;beat<=0;end
  else begin
   prior_invalidate<=invalidate;
   if(invalidate)valid_lines<=0;
   if(invalidate && !prior_invalidate)epoch<=!epoch;
   if(fetch)begin
    data_valid<=0;
    if(state!=IDLE)late<=1;
    else begin
     held<=address;held_epoch<=epoch;lookup_rows<=rows[address[INDEX_BITS:1]];
     lookup_tag<=tags[address[INDEX_BITS:1]];lookup_valid<=valid_lines[address[INDEX_BITS:1]];state<=LOOKUP;
    end
   end
   case(state)
    LOOKUP:if(lookup_valid && lookup_tag==tag && held_epoch==epoch && !invalidate)begin
     data<=row_bytes(lookup_rows,held[0]);data_valid<=1;state<=IDLE;
    end else state<=ISSUE;
    ISSUE:if(memory_ready)begin beat<=0;state<=FILL;end
    FILL:if(memory_response_valid)begin
     fill_rows[63-beat*16-:16]<=memory_response_data;
     if(beat==3)begin
      rows[index]<=completed;tags[index]<=tag;
      if(held_epoch==epoch && !invalidate)valid_lines[index]<=1;
      data<=row_bytes(completed,held[0]);data_valid<=1;state<=IDLE;
     end else beat<=beat+1;
    end
   endcase
  end
 end
endmodule
