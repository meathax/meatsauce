// SPDX-License-Identifier: BSD-3-Clause
// Primary source: MAME0.289 ay8910.cpp1113..1148 and ay8910.h243..260.
// copyright-holders: Couriersud. Private isolated AY16-step proposal, no integration.
// cen is chipclock/8. A coincident shape event follows due streamupdate; count retained.
module snk_timed_primary_envelope(input clk,rst_n,cen,restart,input[15:0]period,input[3:0]shape,
 output reg[3:0]level,output reg[3:0]event_level);
 reg[16:0]count;reg[3:0]step,attack;reg hold,alternate,holding;
 wire[16:0]threshold={period,1'b0};
 // Stream event is post-due, PRE-write. State restart below still has priority.
 always @*begin
  event_level=level;
  if(!holding && count+17'd1>=threshold)begin
   if(step!=0)event_level=(step-1'b1)^attack;
   else if(hold)event_level=alternate?~attack:attack;
   else event_level=alternate?(4'hf^~attack):(4'hf^attack);
  end
 end
 always @(posedge clk,negedge rst_n)
  if(!rst_n)begin count<=0;step<=15;attack<=0;hold<=1;alternate<=0;holding<=0;level<=15;end
  else begin
   if(cen&&!holding)begin
    if(count+17'd1>=threshold)begin
     count<=0;
     if(step!=0)begin step<=step-1'b1;level<=(step-1'b1)^attack;end
     else if(hold)begin
      holding<=1;step<=0;
      if(alternate)begin attack<=~attack;level<=~attack;end
      else level<=attack;
     end else begin
      step<=15;
      if(alternate)begin attack<=~attack;level<=15^~attack;end
      else level<=15^attack;
     end
    end else count<=count+1'b1;
   end
   if(restart)begin
    attack<=shape[2]?4'hf:4'h0;hold<=!shape[3]||shape[0];
    alternate<=shape[3]?shape[1]:shape[2];step<=15;holding<=0;
    level<=shape[2]?4'h0:4'hf;
   end
  end
endmodule
