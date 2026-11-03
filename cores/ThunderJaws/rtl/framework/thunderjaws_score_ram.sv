// SPDX-License-Identifier: GPL-3.0-or-later
// Standard hiscore byte requests borrow the existing CPU VRAM port only after
// both CPUs acknowledge a drained pause. A held vendor request produces exactly
// one accepted operation and one data_ready edge, including delayed RAM replies.
module thunderjaws_score_ram (
 input wire clk_sys,init_reset,game_reset,paused,
 input wire score_read,score_write,
 input wire [23:0] score_address,
 input wire [7:0] score_write_data,
 output reg [7:0] score_read_data,
 output reg data_ready,feature_error,
 output wire busy,
 output wire request_valid,
 input wire request_ready,
 output reg [14:0] request_address,
 output reg request_read,
 output reg [1:0] request_lanes,
 output reg [15:0] request_data,
 input wire response_valid,
 input wire [15:0] response_data,
 input wire cpu_write,
 input wire [14:0] cpu_address,
 input wire [1:0] cpu_lanes,
 input wire [15:0] cpu_data,
 output wire signature_ready
);
 localparam IDLE=0,ISSUE=1,REPLY=2,DROP=3;
 reg [1:0] state;reg odd;
 reg seen_bad,first_good,last_good;
 assign signature_ready=seen_bad && first_good && last_good && !game_reset;
 always @(posedge clk_sys)begin
  if(init_reset || game_reset)begin seen_bad<=0;first_good<=0;last_good<=0;end
  else if(cpu_write)begin
   if(cpu_address==15'h7ece && cpu_lanes[1])begin
    first_good<=cpu_data[15:8]==0;if(cpu_data[15:8]!=0)seen_bad<=1;
   end
   if(cpu_address==15'h7eff && cpu_lanes[0])begin
    last_good<=cpu_data[7:0]==8'h95;if(cpu_data[7:0]!=8'h95)seen_bad<=1;
   end
  end
 end
 assign busy=state!=IDLE;
 assign request_valid=!init_reset && state==ISSUE && paused;
 always @(posedge clk_sys)begin
  data_ready<=0;
  if(init_reset)begin state<=IDLE;feature_error<=0;score_read_data<=0;odd<=0;
   request_address<=0;request_read<=1;request_lanes<=0;request_data<=0;
  end else case(state)
   IDLE:if(score_read || score_write)begin
    if(score_read && score_write || score_address<24'h3ffd9c || score_address>24'h3ffdff)begin
     feature_error<=1;state<=DROP;
    end else begin
     request_address<=score_address[15:1];request_read<=!score_write;
     request_lanes<=score_address[0] ? 2'b01 : 2'b10;
     request_data<={score_write_data,score_write_data};odd<=score_address[0];state<=ISSUE;
    end
   end
   ISSUE:if(paused && request_ready)state<=REPLY;
   REPLY:if(response_valid)begin
    score_read_data<=odd ? response_data[7:0] : response_data[15:8];data_ready<=1;state<=DROP;
   end
   DROP:if(!score_read && !score_write)state<=IDLE;
  endcase
 end
endmodule
