// SPDX-License-Identifier: GPL-3.0-or-later
// SN76496 adaptation of JT89 register decoding by Jose Tejada Gomez (2017).
// GPL v3 or later, no warranty. Upstream retained at rtl/vendor/jt89.
// Timing/noise/defaults follow pinned MAME sn76496.cpp by Nicola Salmoria
// (BSD-3-Clause). See THIRD_PARTY_NOTICES.md and docs/audio.md.
module sn76496_jt89(
 input logic clk,reset,ce,write,
 input logic [7:0] data,
 output logic [14:0] sound,
 output logic [3:0] digital,
 output logic [16:0] noise_state
);
 logic [9:0] tone[0:2];
 logic [3:0] volume[0:3];
 logic [2:0] noise_mode,last_reg;
 logic [3:0] divider;
 logic [10:0] count[0:2];
 logic [11:0] noise_count,noise_period;
 logic noise_written;
 wire [2:0] reg_sel=data[7]?data[6:4]:last_reg;
 wire tick=ce&&divider==15;
 wire [10:0] tone2_period=tone[2]==0?11'd1024:{1'b0,tone[2]};
 function automatic [12:0] attenuation(input [3:0] v);
  case(v)
   0:attenuation=8191;1:attenuation=6506;2:attenuation=5168;3:attenuation=4105;
   4:attenuation=3260;5:attenuation=2590;6:attenuation=2057;7:attenuation=1634;
   8:attenuation=1298;9:attenuation=1031;10:attenuation=819;11:attenuation=650;
   12:attenuation=516;13:attenuation=410;14:attenuation=326;15:attenuation=0;
  endcase
 endfunction
 always_comb begin
  noise_period=!noise_written?12'd0:noise_mode[1:0]==3?{tone2_period,1'b0}:(12'd32<<noise_mode[1:0]);
  sound=0;
  for(integer i=0;i<4;i=i+1)if(digital[i])sound=sound+{2'd0,attenuation(volume[i])};
 end
 always_ff @(posedge clk)begin
  if(reset)begin
   divider<=0;last_reg<=0;noise_mode<=0;noise_state<=17'h10000;
   digital<=0;noise_count<=0;noise_written<=0;
   for(integer i=0;i<3;i=i+1)begin tone[i]<=0;count[i]<=0;end
   for(integer i=0;i<4;i=i+1)volume[i]<=0;
  end else begin
   if(ce)divider<=divider+4'd1;
   if(tick)begin
    for(integer i=0;i<3;i=i+1)begin
     if(count[i]<=1)begin count[i]<=tone[i]==0?11'd1024:{1'b0,tone[i]};digital[i]<=~digital[i];end
     else count[i]<=count[i]-11'd1;
    end
    if(noise_count<=1)begin
     noise_count<=noise_period;
     noise_state<={noise_state[2]^(noise_mode[2]&noise_state[3]),noise_state[16:1]};
     digital[3]<=noise_state[1];
    end else noise_count<=noise_count-12'd1;
   end
   if(write)begin
    last_reg<=reg_sel;
    case(reg_sel)
     0:if(data[7])tone[0][3:0]<=data[3:0];else tone[0][9:4]<=data[5:0];
     2:if(data[7])tone[1][3:0]<=data[3:0];else tone[1][9:4]<=data[5:0];
     4:if(data[7])tone[2][3:0]<=data[3:0];else tone[2][9:4]<=data[5:0];
     1:volume[0]<=data[3:0];3:volume[1]<=data[3:0];
     5:volume[2]<=data[3:0];7:volume[3]<=data[3:0];
     6:begin noise_mode<=data[2:0];noise_state<=17'h10000;noise_written<=1;end
     default:;
    endcase
   end
  end
 end
endmodule
