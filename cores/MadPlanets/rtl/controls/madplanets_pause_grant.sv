// SPDX-License-Identifier: GPL-3.0-or-later
// Gate the existing CPU enable only at an idle bus, then let its four-stage
// input pipeline settle. Retry if a late bus cycle appears. On release allow
// synchronous RAM to reacquire its normal address before CPU enables resume.
module madplanets_pause_grant(
 input wire clk,reset,request,pulse_in,bus_idle,
 output wire cpu_enable,paused
);
 localparam RUN=0,SETTLE=1,HALTED=2,RELEASE=3;
 reg [1:0] state=RUN;
 reg [4:0] count=0;
 assign cpu_enable=pulse_in && state==RUN;
 assign paused=state==HALTED && bus_idle;
 always @(posedge clk)begin
  if(reset)begin state<=RUN;count<=0;end
  else case(state)
   RUN: if(request && bus_idle && !pulse_in)begin state<=SETTLE;count<=0;end
   SETTLE: if(!request || !bus_idle)begin state<=RUN;count<=0;end
           else if(count==15)begin state<=HALTED;count<=0;end else count<=count+1'b1;
   HALTED: if(!bus_idle)begin state<=RUN;count<=0;end
           else if(!request)begin state<=RELEASE;count<=0;end
   RELEASE: if(request)begin state<=SETTLE;count<=0;end
            else if(count==7)begin state<=RUN;count<=0;end else count<=count+1'b1;
  endcase
 end
endmodule
