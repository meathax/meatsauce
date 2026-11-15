// SPDX-License-Identifier: GPL-3.0-or-later
// Private coherent canonical AY pair. Raw serial debug retains pinned JT49 timing.
// One source clock/8 event snapshots all six mode+4-bit indices PRE CPU-write.
// SOURCE E bundle held in cores; tone commit E+13, immutable index capture E+14.
// E+15..20 dispatch; E+16..21 collect; E+21 publish atomic vector.
// Reset aborts work. Physical SOURCE event spacing192; raw baseCE every24.
module snk_timed_ay_pair(input clk,reset,ay_ce,input[3:0]addr0,addr1,
 input write0,write1,input[7:0]data,output[10:0]audio_unsigned,output audio_sample,
 output reg signed[23:0]channel0_A,channel0_B,channel0_C,channel1_A,channel1_B,channel1_C,
 output reg signed[24:0]chip0_normal,chip1_normal,output signed[25:0]audio_normal,
 output reg normal_valid);
 wire[9:0]raw0,raw1;wire[14:0]indices0,indices1;wire event0,event1;wire indicesReady0,indicesReady1;
 snk_timed_jt49 #(.COMP(0)) ay0(.rst_n(!reset),.clk(clk),.clk_en(ay_ce),
 .addr(addr0),.cs_n(!write0),.wr_n(!write0),.din(data),.sel(1'b1),
 .dout(),.sound(raw0),.A(),.B(),.C(),.sample(audio_sample),
 .IOA_in(8'hff),.IOB_in(8'hff),.IOA_out(),.IOB_out(),.IOA_oe(),.IOB_oe(),
 .event_indices(indices0),.sample_event(event0),.indices_ready(indicesReady0));
 snk_timed_jt49 #(.COMP(0)) ay1(.rst_n(!reset),.clk(clk),.clk_en(ay_ce),
 .addr(addr1),.cs_n(!write1),.wr_n(!write1),.din(data),.sel(1'b1),
 .dout(),.sound(raw1),.A(),.B(),.C(),.sample(),
 .IOA_in(8'hff),.IOB_in(8'hff),.IOA_out(),.IOB_out(),.IOA_oe(),.IOB_oe(),
 .event_indices(indices1),.sample_event(event1),.indices_ready(indicesReady1));
 assign audio_unsigned={1'b0,raw0}+{1'b0,raw1};
 assign audio_normal={chip0_normal[24],chip0_normal}+{chip1_normal[24],chip1_normal};
 reg[29:0]snapshot;reg active,response;reg[2:0]dispatch,response_slot;
 wire[4:0]lookup_index=snapshot[dispatch*5+:5];wire signed[23:0]lookup_value;
 // Exactly one 32x24 registered normalized table in this pair.
 snk_timed_ay_normal_exp lut(.clk(clk),.level({lookup_index[3:0],1'b0}),
  .env_mode(lookup_index[4]),.dout(lookup_value));
 reg signed[23:0]pending[0:5];reg signed[24:0]sum0,sum1;
 always @(posedge clk or posedge reset)
  if(reset)begin
   snapshot<=0;active<=0;response<=0;dispatch<=0;response_slot<=0;
   sum0<=0;sum1<=0;chip0_normal<=0;chip1_normal<=0;normal_valid<=0;
   channel0_A<=0;channel0_B<=0;channel0_C<=0;channel1_A<=0;channel1_B<=0;channel1_C<=0;
   for(integer i=0;i<6;i=i+1)pending[i]<=0;
  end else begin
   normal_valid<=0;
   response<=active&&dispatch<6;
   if(active&&dispatch<6)begin response_slot<=dispatch;dispatch<=dispatch+1'b1;end
   if(response)begin
    pending[response_slot]<=lookup_value;
    if(response_slot<3)sum0<=sum0+{lookup_value[23],lookup_value};
    else sum1<=sum1+{lookup_value[23],lookup_value};
    if(response_slot==5)begin
     channel0_A<=pending[0];channel0_B<=pending[1];channel0_C<=pending[2];
     channel1_A<=pending[3];channel1_B<=pending[4];channel1_C<=lookup_value;
     chip0_normal<=sum0;chip1_normal<=sum1+{lookup_value[23],lookup_value};
     normal_valid<=1;active<=0;
    end
   end
   if(indicesReady0&&indicesReady1)begin snapshot<={indices1,indices0};dispatch<=0;active<=1;sum0<=0;sum1<=0;end
  end
endmodule
