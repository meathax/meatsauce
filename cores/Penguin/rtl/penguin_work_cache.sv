// SPDX-License-Identifier: GPL-3.0-or-later
// Staged8KiB direct read cache; all writes remain backend-ACKed write-through.
module penguin_work_cache #(parameter integer INDEX_BITS=10)(
 input logic clk,reset,invalidate,
 input logic [17:0] cpu_addr,input logic cpu_req,cpu_write,
 input logic [15:0] cpu_data,input logic [1:0] cpu_be,
 output logic [15:0] cpu_dout,output logic cpu_ack,
 output logic [17:0] backend_addr,output logic backend_req,backend_write,
 output logic [15:0] backend_data,output logic [1:0] backend_be,
 input logic [15:0] backend_dout,input logic backend_ack,
 output logic [31:0] read_hits,read_misses,write_hits,writes,fill_words,
 output wire init_busy
);
 localparam integer LINES=1<<INDEX_BITS,TAG_BITS=16-INDEX_BITS,STORE_BITS=64+TAG_BITS;
 typedef enum logic [1:0]{IDLE,LOOKUP,FILL,WAIT_WRITE} state_t;
 state_t state;
 wire [0:0] valid_mask;
 wire valid_ready=!init_busy&&!invalidate;
 logic [17:0] address;logic phase,write_request,write_hit,fill_poison;
 logic [15:0] write_data;logic [1:0] write_be,fill_select;
 logic [63:0] fill_data;
 wire [INDEX_BITS-1:0] index=address[INDEX_BITS+1:2];
 wire [TAG_BITS-1:0] tag=address[17:INDEX_BITS+2];
 wire read_enable=state==IDLE&&cpu_req!=cpu_ack&&valid_ready;
 wire [STORE_BITS-1:0] line_q;
 wire hit=valid_mask[0]&&line_q[STORE_BITS-1:64]==tag;
 wire [63:0] completed_line={backend_dout,fill_data[47:0]};
 logic [63:0] merged_line;
 always_comb begin
  merged_line=line_q[63:0];
  if(write_be[1])merged_line[address[1:0]*16+8+:8]=write_data[15:8];
  if(write_be[0])merged_line[address[1:0]*16+:8]=write_data[7:0];
 end
 wire fill_complete=state==FILL&&backend_req==backend_ack&&fill_select==3;
 wire write_complete=state==WAIT_WRITE&&backend_req==backend_ack;
 wire store_write=!reset&&(fill_complete||(write_complete&&write_hit&&write_be!=0));
 penguin_cache_store #(.WIDTH(STORE_BITS),.ADDRESS_BITS(INDEX_BITS)) data_store(
  .clk,.read_enable,.read_address(cpu_addr[INDEX_BITS+1:2]),.q(line_q),
  .write_enable(store_write),.write_address(index),.data({tag,fill_complete?completed_line:merged_line}));
 wire valid_set=!reset&&!invalidate&&!fill_poison&&fill_complete;
 penguin_cache_valid #(.WIDTH(1),.ADDRESS_BITS(INDEX_BITS)) valid_store(
  .clk,.reset,.invalidate,.read_enable,.read_address(cpu_addr[INDEX_BITS+1:2]),.q(valid_mask),.busy(init_busy),
  .write_enable(valid_set),.write_address(index),.data(1'b1));
 always_ff @(posedge clk)begin
  if(reset)begin
   state<=IDLE;cpu_dout<=0;cpu_ack<=0;backend_addr<=0;backend_req<=0;
   backend_write<=0;backend_data<=0;backend_be<=0;
   address<=0;phase<=0;write_request<=0;write_hit<=0;write_data<=0;write_be<=0;
   fill_select<=0;fill_data<=0;fill_poison<=0;
   read_hits<=0;read_misses<=0;write_hits<=0;writes<=0;fill_words<=0;
  end else begin
   if(invalidate)fill_poison<=1;
`ifndef SYNTHESIS
   if(state!=IDLE&&(cpu_req!=phase||cpu_addr!=address||cpu_write!=write_request||cpu_data!=write_data||cpu_be!=write_be))
    $fatal(1,"Work cache pending frontend payload changed");
`endif
   case(state)
    IDLE:if(cpu_req!=cpu_ack&&valid_ready)begin
     address<=cpu_addr;phase<=cpu_req;write_request<=cpu_write;write_data<=cpu_data;write_be<=cpu_be;state<=LOOKUP;
    end
    LOOKUP:if(write_request)begin
     write_hit<=hit&&!invalidate;backend_addr<=address;backend_write<=1;
     backend_data<=write_data;backend_be<=write_be;backend_req<=~backend_req;
     writes<=writes+1'b1;if(hit&&!invalidate)write_hits<=write_hits+1'b1;state<=WAIT_WRITE;
    end else if(hit&&!invalidate)begin
     cpu_dout<=line_q[address[1:0]*16+:16];cpu_ack<=phase;read_hits<=read_hits+1'b1;state<=IDLE;
    end else begin
     backend_addr<={address[17:2],2'b00};backend_write<=0;backend_data<=0;backend_be<=0;
     backend_req<=~backend_req;fill_select<=0;fill_data<=0;fill_poison<=invalidate;
     read_misses<=read_misses+1'b1;state<=FILL;
    end
    FILL:if(backend_req==backend_ack)begin
     fill_words<=fill_words+1'b1;
     if(fill_select==3)begin
      cpu_dout<=completed_line[address[1:0]*16+:16];cpu_ack<=phase;state<=IDLE;
     end else begin
      fill_data[fill_select*16+:16]<=backend_dout;fill_select<=fill_select+1'b1;
      backend_addr<=backend_addr+18'd1;backend_req<=~backend_req;
     end
    end
    WAIT_WRITE:if(backend_req==backend_ack)begin cpu_ack<=phase;state<=IDLE;end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
