// SPDX-License-Identifier: GPL-3.0-or-later
// One master clock; pulse-preserving queued rotation writes and read ownership.
module heavyunit_ddr_owner #(parameter integer ROT_FIFO_DEPTH=64)(
 input logic clk,reset,load_claim,rotation_quiescent,
 output wire load_grant,rotation_pause,drained,
 input logic load_rd,
 input logic [28:0] load_addr,
 input logic [7:0] load_burstcnt,
 output wire load_busy,load_data_ready,
 output wire [63:0] load_data,
 input logic rotate_we,
 input logic [28:0] rotate_addr,
 input logic [63:0] rotate_data,
 input logic [7:0] rotate_be,
 output wire rotate_busy,
 input logic ram_busy,ram_data_ready,
 input logic [63:0] ram_data,
 output wire ram_rd,ram_we,
 output wire [28:0] ram_addr,
 output wire [7:0] ram_burstcnt,ram_be,
 output wire [63:0] ram_writedata,
 output logic protocol_error=0,
 output logic [31:0] queued_writes=0,accepted_writes=0,accepted_reads=0,
 output wire [$clog2(ROT_FIFO_DEPTH+1)-1:0] queue_level
);
 localparam integer PW=$clog2(ROT_FIFO_DEPTH),CW=$clog2(ROT_FIFO_DEPTH+1);
 logic [28:0] addresses[0:ROT_FIFO_DEPTH-1];
 logic [63:0] values[0:ROT_FIFO_DEPTH-1];
 logic [7:0] masks[0:ROT_FIFO_DEPTH-1];
 logic [PW-1:0] head=0,tail=0;
 logic [CW-1:0] count=0;
 logic owner_load=0,read_pending=0,reset_pending=0;
 wire pop=!owner_load&&count!=0&&!ram_busy&&!reset&&!reset_pending;
 wire push=rotate_we&&!reset&&!reset_pending;
 wire accepted_read=ram_rd&&!ram_busy;
 assign queue_level=count;
 assign load_grant=owner_load;
 assign rotation_pause=load_claim||owner_load;
 assign rotate_busy=count>=ROT_FIFO_DEPTH-2;
 assign drained=count==0&&!read_pending&&!owner_load;
 assign load_busy=!owner_load||ram_busy||read_pending||reset||reset_pending;
 assign load_data_ready=owner_load&&read_pending&&ram_data_ready;
 assign load_data=ram_data;
 assign ram_rd=owner_load&&load_rd&&!read_pending&&!reset&&!reset_pending;
 assign ram_we=!owner_load&&count!=0&&!reset&&!reset_pending;
 assign ram_addr=owner_load?load_addr:addresses[head];
 assign ram_burstcnt=owner_load?load_burstcnt:8'd1;
 assign ram_be=owner_load?8'hff:masks[head];
 assign ram_writedata=owner_load?64'd0:values[head];
 always_ff @(posedge clk)begin
  if(reset&&read_pending)reset_pending<=1;
  if((reset||reset_pending)&&!read_pending)begin
   owner_load<=0;head<=0;tail<=0;count<=0;reset_pending<=0;protocol_error<=0;
   queued_writes<=0;accepted_writes<=0;accepted_reads<=0;
  end else begin
   if(push)begin
    if(count==ROT_FIFO_DEPTH&&!pop)protocol_error<=1;
    else begin addresses[tail]<=rotate_addr;values[tail]<=rotate_data;masks[tail]<=rotate_be;tail<=tail+1'b1;queued_writes<=queued_writes+1;end
   end
   if(pop)begin head<=head+1'b1;accepted_writes<=accepted_writes+1;end
   if(push&&(count!=ROT_FIFO_DEPTH||pop)&&!pop)count<=count+1'b1;
   else if(pop&&!push)count<=count-1'b1;
   if(!owner_load&&load_claim&&rotation_quiescent&&count==0&&!rotate_we)owner_load<=1;
   if(owner_load&&!load_claim&&!read_pending&&!load_rd)owner_load<=0;
   if(accepted_read)begin read_pending<=1;accepted_reads<=accepted_reads+1;end
   if(ram_data_ready)begin
    if(read_pending)read_pending<=0;
    else protocol_error<=1;
   end
   if(owner_load&&rotate_we)protocol_error<=1;
  end
 end
endmodule
