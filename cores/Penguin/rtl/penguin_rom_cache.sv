// SPDX-License-Identifier: GPL-3.0-or-later
// Staged32KiB four-way cache; exact LRU, persistent toggles, no RAM reset.
module penguin_rom_cache #(parameter integer INDEX_BITS=10)(
 input logic clk,reset,invalidate,
 input logic [20:0] cpu_addr,input logic cpu_req,
 output logic [15:0] cpu_dout,output logic cpu_ack,
 output logic [20:0] backend_addr,output logic backend_req,
 input logic [15:0] backend_dout,input logic backend_ack,
 output logic [31:0] cache_hits,cache_misses,fill_words,
 output wire init_busy
);
 localparam integer SETS=1<<INDEX_BITS,TAG_BITS=18-INDEX_BITS,STORE_BITS=64+TAG_BITS;
 typedef enum logic [1:0]{IDLE,LOOKUP,FILL} state_t;
 state_t state;
 wire [3:0] valid_mask;
 wire valid_ready=!init_busy&&!invalidate;
 logic [20:0] address;logic phase,fill_poison;
 logic [1:0] fill_select,fill_way;
 logic [63:0] fill_data;
 wire [INDEX_BITS-1:0] index=address[INDEX_BITS+2:3];
 wire [INDEX_BITS-1:0] read_index=cpu_addr[INDEX_BITS+2:3];
 wire [TAG_BITS-1:0] tag=address[20:INDEX_BITS+3];
 wire read_enable=state==IDLE&&cpu_req!=cpu_ack&&valid_ready;
 wire fill_complete=state==FILL&&backend_req==backend_ack;
 wire store_write=!reset&&fill_complete&&fill_select==3;
 wire [63:0] completed_line={backend_dout,fill_data[47:0]};
 wire [STORE_BITS-1:0] line_q[0:3];
 wire [5:0] recency_q;
 logic [3:0] hit_mask;
 logic hit,all_valid;logic [1:0] hit_way,replacement_way;
 logic victim_found;
 // Pair bit AB means A newer than B:01,02,03,12,13,23.
 // Touching every filled way defines all pairs before every way can be valid.
 // This exactly implements timestamp LRU without resetting the metadata RAM.
 function automatic [5:0] touch(input logic[5:0] old,input logic[1:0] way);
  begin touch=old;case(way)
   0:touch[2:0]=3'b111;
   1:begin touch[0]=0;touch[3]=1;touch[4]=1;end
   2:begin touch[1]=0;touch[3]=0;touch[5]=1;end
   3:begin touch[2]=0;touch[4]=0;touch[5]=0;end
  endcase end
 endfunction
 always_comb begin
  hit_mask=0;hit=0;hit_way=0;all_valid=1;
  for(integer w=0;w<4;w++)begin
   hit_mask[w]=valid_mask[w]&&(line_q[w][STORE_BITS-1:64]==tag);
   if(hit_mask[w])begin hit=1;hit_way=2'(w);end
   all_valid=all_valid&&valid_mask[w];
  end
  replacement_way=0;victim_found=0;
  for(integer w=0;w<4;w++)if(!valid_mask[w]&&!victim_found)begin replacement_way=2'(w);victim_found=1;end
  if(all_valid)begin
   if(!recency_q[0]&&!recency_q[1]&&!recency_q[2])begin replacement_way=0;victim_found=1;end
   else if(recency_q[0]&&!recency_q[3]&&!recency_q[4])begin replacement_way=1;victim_found=1;end
   else if(recency_q[1]&&recency_q[3]&&!recency_q[5])begin replacement_way=2;victim_found=1;end
   else if(recency_q[2]&&recency_q[4]&&recency_q[5])begin replacement_way=3;victim_found=1;end
  end
 end
 wire touch_hit=state==LOOKUP&&hit&&!invalidate;
 wire recency_write=!reset&&(touch_hit||store_write);
 wire [5:0] recency_data=touch(recency_q,touch_hit?hit_way:fill_way);
  genvar gway;
  generate
  for(gway=0;gway<4;gway=gway+1)begin:ways
  localparam integer WAY_NUMBER=gway;
  wire [STORE_BITS-1:0] way_q;
  assign line_q[WAY_NUMBER]=way_q;
  penguin_cache_store #(.WIDTH(STORE_BITS),.ADDRESS_BITS(INDEX_BITS)) data_store(
   .clk,.read_enable,.read_address(read_index),.q(way_q),
   .write_enable(store_write&&fill_way==WAY_NUMBER),.write_address(index),.data({tag,completed_line}));
  end
  endgenerate
 penguin_cache_store #(.WIDTH(6),.ADDRESS_BITS(INDEX_BITS)) recency_store(
  .clk,.read_enable,.read_address(read_index),.q(recency_q),
  .write_enable(recency_write),.write_address(index),.data(recency_data));
 wire valid_set=!reset&&!invalidate&&!fill_poison&&store_write;
 penguin_cache_valid #(.WIDTH(4),.ADDRESS_BITS(INDEX_BITS)) valid_store(
  .clk,.reset,.invalidate,.read_enable,.read_address(read_index),.q(valid_mask),.busy(init_busy),
  .write_enable(valid_set),.write_address(index),.data(valid_mask|(4'b0001<<fill_way)));
 always_ff @(posedge clk)begin
  if(reset)begin
   state<=IDLE;
   cpu_dout<=0;cpu_ack<=0;backend_addr<=0;backend_req<=0;
   address<=0;phase<=0;fill_select<=0;fill_data<=0;fill_way<=0;fill_poison<=0;
   cache_hits<=0;cache_misses<=0;fill_words<=0;
  end else begin
   if(invalidate)fill_poison<=1;
`ifndef SYNTHESIS
   if(state!=IDLE&&(cpu_req!=phase||cpu_addr!=address))$fatal(1,"ROM cache pending payload changed");
   if(state==LOOKUP&&!$onehot0(hit_mask))$fatal(1,"ROM cache duplicate valid tag");
   if(state==LOOKUP&&!hit&&all_valid&&!victim_found)$fatal(1,"ROM LRU undefined/inconsistent");
`endif
   case(state)
    IDLE:if(cpu_req!=cpu_ack&&valid_ready)begin address<=cpu_addr;phase<=cpu_req;state<=LOOKUP;end
    LOOKUP:if(hit&&!invalidate)begin
     cpu_dout<=line_q[hit_way][address[2:1]*16+:16];cpu_ack<=phase;
     cache_hits<=cache_hits+1'b1;state<=IDLE;
    end else begin
     fill_way<=replacement_way;fill_select<=0;fill_data<=0;fill_poison<=invalidate;
     backend_addr<={address[20:3],3'b000};backend_req<=~backend_req;
     cache_misses<=cache_misses+1'b1;state<=FILL;
    end
    FILL:if(backend_req==backend_ack)begin
     fill_words<=fill_words+1'b1;
     if(fill_select==3)begin
      cpu_dout<=completed_line[address[2:1]*16+:16];cpu_ack<=phase;state<=IDLE;
     end else begin
      fill_data[fill_select*16+:16]<=backend_dout;fill_select<=fill_select+1'b1;
      backend_addr<=backend_addr+21'd2;backend_req<=~backend_req;
     end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
