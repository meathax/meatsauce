// SPDX-License-Identifier: BSD-3-Clause
// Primary MAME0.289 AY tone arithmetic; source inputs captured at cen event E.
// No fitted phase or arbitrary period cap. Reachable count<=4094, advanced<=4095.
// E latch; E+1..12 one restoring bit/edge; E+13 quotient parity/remainder commit.
// Physical caller source spacing192 edges; next raw consumer baseCE E+23.
module snk_timed_primary_tone(input clk,rst_n,cen,input[11:0]period,
 output reg tone,output reg tone_valid);
 reg[11:0]count,bits_left,remainder,captured_period;
 reg[12:0]divisor;reg[3:0]remaining;reg busy,phase_seed;
 wire[11:0]effective_period=period==0?12'd1:period;
 wire[12:0]shifted={remainder,bits_left[11]};
 wire[12:0]reduced=shifted>=divisor?shifted-divisor:shifted;
 wire odd={1'b0,remainder}>={1'b0,captured_period};
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   count<=0;tone<=0;tone_valid<=0;bits_left<=0;remainder<=0;
   captured_period<=1;divisor<=2;remaining<=0;busy<=0;phase_seed<=0;
  end else begin
   tone_valid<=0;
   if(cen)begin
    bits_left<=count+12'd1;captured_period<=effective_period;
    divisor<={effective_period,1'b0};remainder<=0;remaining<=12;
    phase_seed<=tone;busy<=1;
   end else if(busy)begin
    if(remaining!=0)begin
     remainder<=reduced[11:0];bits_left<={bits_left[10:0],1'b0};remaining<=remaining-1'b1;
    end else begin
     count<=odd?remainder-captured_period:remainder;
     tone<=phase_seed^odd;tone_valid<=1;busy<=0;
    end
   end
  end
`ifndef SYNTHESIS
 // synthesis translate_off
 always @(posedge clk)if(rst_n&&cen&&busy)$fatal(1,"TONE_SOURCE_OVERRUN: physical clock/8 due spacing violated");
 // synthesis translate_on
`endif
endmodule
