// SPDX-License-Identifier: BSD-3-Clause
// Source arithmetic: MAME0.289 ay8910.cpp1086..1104 and ay8910.h263..284.
// copyright-holders: Couriersud. Private isolated proposal, not integrated JT49 replacement.
module snk_timed_primary_noise(input clk,rst_n,cen,input[4:0]period,output wire noise,output wire event_noise);
 reg[4:0]count;reg prescale;reg[16:0]rng;
 wire[5:0]advanced={1'b0,count}+6'd1;
 assign noise=rng[0];
 wire[16:0]event_rng=(advanced>={1'b0,period}&&prescale)?{rng[0]^rng[3],rng[16:1]}:rng;
 assign event_noise=event_rng[0];
 always @(posedge clk,negedge rst_n)
  if(!rst_n)begin count<=0;prescale<=0;rng<=17'd1;end
  else if(cen)begin
   if(advanced>={1'b0,period})begin
    count<=0;prescale<=~prescale;
    if(prescale)rng<={rng[0]^rng[3],rng[16:1]};
   end else count<=advanced[4:0];
  end
endmodule
