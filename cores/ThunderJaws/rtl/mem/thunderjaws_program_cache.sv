// SPDX-License-Identifier: GPL-3.0-or-later
// Two immutable-ROM caches share the existing held CPU ROM boundary. Each
// miss reads an aligned eight-word SDRAM burst; data and tags have registered
// reads. Logical game reset cannot discard an accepted fill or its reply.
module thunderjaws_program_cache #(parameter integer INDEX_BITS=6) (
 input wire clk_sys,init_reset,invalidate,
 input wire request_valid,
 output wire request_ready,
 input wire request_owner,
 input wire [22:0] request_address,
 output reg response_valid,
 output reg [15:0] response_data,
 output wire memory_valid,
 input wire memory_ready,
 output wire [23:0] memory_address,
 output wire [2:0] memory_length,
 input wire memory_response_valid,
 input wire [15:0] memory_response_data,
 output reg [31:0] hits,misses
);
 localparam LINES=1<<(INDEX_BITS+1),TAG_BITS=20-INDEX_BITS;
 localparam IDLE=0,LOOKUP=1,ISSUE=2,FILL=3;
 reg [1:0] state;
 reg [15:0] data[0:LINES*8-1];
 reg [TAG_BITS-1:0] tags[0:LINES-1];
 reg [LINES-1:0] valid_lines;
 reg [INDEX_BITS:0] held_line;
 reg [22:0] held_address;
 reg held_owner,epoch,held_epoch,prior_invalidate;
 reg lookup_valid;
 reg [TAG_BITS-1:0] lookup_tag;
 reg [15:0] lookup_data,requested_word;
 reg [2:0] beat;
 wire [INDEX_BITS:0] incoming_line={request_owner,request_address[INDEX_BITS+2:3]};
 wire [TAG_BITS-1:0] held_tag=held_address[22:INDEX_BITS+3];
 assign request_ready=!init_reset && !invalidate && state==IDLE;
 assign memory_valid=!init_reset && state==ISSUE;
 assign memory_address={1'b0,held_address[22:3],3'b000}+(held_owner ? 24'h050000 : 24'd0);
 assign memory_length=3'd7;
 always @(posedge clk_sys)begin
  response_valid<=0;
  if(init_reset)begin
   state<=IDLE;valid_lines<=0;epoch<=0;held_epoch<=0;prior_invalidate<=0;
   hits<=0;misses<=0;response_data<=0;beat<=0;lookup_valid<=0;
  end else begin
   prior_invalidate<=invalidate;
   if(invalidate)valid_lines<=0;
   if(invalidate && !prior_invalidate)epoch<=!epoch;
   case(state)
    IDLE:if(request_valid && request_ready)begin
     held_line<=incoming_line;held_owner<=request_owner;held_address<=request_address;held_epoch<=epoch;
     lookup_valid<=valid_lines[incoming_line];lookup_tag<=tags[incoming_line];
     lookup_data<=data[{incoming_line,request_address[2:0]}];state<=LOOKUP;
    end
    LOOKUP:if(lookup_valid && lookup_tag==held_tag && held_epoch==epoch && !invalidate)begin
     response_data<=lookup_data;response_valid<=1;hits<=hits+1;state<=IDLE;
    end else begin misses<=misses+1;state<=ISSUE;end
    ISSUE:if(memory_ready)begin beat<=0;state<=FILL;end
    FILL:if(memory_response_valid)begin
     data[{held_line,beat}]<=memory_response_data;
     if(beat==held_address[2:0])requested_word<=memory_response_data;
     if(beat==7)begin
      tags[held_line]<=held_tag;
      if(held_epoch==epoch && !invalidate)valid_lines[held_line]<=1;
      response_data<=held_address[2:0]==7 ? memory_response_data : requested_word;
      response_valid<=1;state<=IDLE;
     end else beat<=beat+1;
    end
   endcase
  end
 end
endmodule
