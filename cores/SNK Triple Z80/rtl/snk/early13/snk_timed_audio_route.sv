// SPDX-License-Identifier: GPL-3.0-or-later
// PIPELINED exact route: signed N=7*AY_Q23+6*(Wave_PCM<<8).
// |N|<2^29; truncate(N/5120)=sign(N)*floor((|N|>>10)/5).
// Accept E; magnitude E+1; four constant /5 stages E+2..5; publish E+6.
// One bundle/edge throughput. Reset or changed/unsupported profile flushes all stages.
// Caller mutes pause and stops source CE. Pre-pause bundles complete into held PCM.
module snk_timed_audio_route(
 input wire clk,reset,input wire[7:0]profile,
 input wire signed[25:0]ay_pair_q23,input wire ay_response_valid,
 input wire signed[15:0]wave_pcm,input wire wave_response_valid,
 output reg signed[15:0]mono_pcm,output reg sample_valid
);
 wire supported=profile<=8'd5,use_wave=profile<=8'd2;
 reg[7:0]seen_profile=8'hff;
 reg signed[25:0]held_ay_q23=0;reg signed[15:0]held_wave=0;
 reg ay_ready=0,wave_ready=0;
 wire signed[31:0]ay_next=ay_response_valid?{{6{ay_pair_q23[25]}},ay_pair_q23}:{{6{held_ay_q23[25]}},held_ay_q23};
 wire signed[15:0]wave_next=wave_response_valid?wave_pcm:held_wave;
 wire signed[31:0]wave_q23=use_wave?({{16{wave_next[15]}},wave_next}<<<8):32'sd0;
 wire signed[31:0]numerator=((ay_next<<<3)-ay_next)+((wave_q23<<<2)+(wave_q23<<<1));
 wire accept=(ay_response_valid||(use_wave&&wave_response_valid))&&(ay_ready||ay_response_valid)&&(!use_wave||wave_ready||wave_response_valid);
 reg signed[31:0]n0;wire[31:0]absolute_n=n0[31]?-n0:n0;
 reg[18:0]m1,m2,m3,m4;reg sign1,sign2,sign3,sign4,sign5;
 reg[21:0]q2,q3,q4,q5;reg[5:0]valid_pipe;
 function automatic[21:0]divide_segment(input[18:0]n,input[21:0]previous,input integer hi,lo);
  reg[18:0]quotient;reg[2:0]remainder;reg[3:0]wide;integer bitno;
  begin
   quotient=previous[21:3];remainder=previous[2:0];
   for(bitno=hi;bitno>=lo;bitno=bitno-1)begin
    wide={remainder,n[bitno]};
    if(wide>=4'd5)begin remainder=wide-4'd5;quotient[bitno]=1;end
    else begin remainder=wide[2:0];quotient[bitno]=0;end
   end
   divide_segment={quotient,remainder};
  end
 endfunction
 wire signed[31:0]unsigned_result={13'd0,q5[21:3]};
 wire signed[31:0]signed_result=sign5?-unsigned_result:unsigned_result;
 always @(posedge clk)begin
  seen_profile<=profile;sample_valid<=0;
  if(reset||!supported||profile!=seen_profile)begin
   held_ay_q23<=0;held_wave<=0;ay_ready<=0;wave_ready<=0;
   mono_pcm<=0;valid_pipe<=0;n0<=0;m1<=0;m2<=0;m3<=0;m4<=0;
   sign1<=0;sign2<=0;sign3<=0;sign4<=0;sign5<=0;q2<=0;q3<=0;q4<=0;q5<=0;
  end else begin
   if(ay_response_valid)begin held_ay_q23<=ay_pair_q23;ay_ready<=1;end
   if(use_wave&&wave_response_valid)begin held_wave<=wave_pcm;wave_ready<=1;end
   valid_pipe<={valid_pipe[4:0],accept};if(accept)n0<=numerator;
   m1<=absolute_n[28:10];sign1<=n0[31];
   m2<=m1;q2<=divide_segment(m1,22'd0,18,14);sign2<=sign1;
   m3<=m2;q3<=divide_segment(m2,q2,13,9);sign3<=sign2;
   m4<=m3;q4<=divide_segment(m3,q3,8,4);sign4<=sign3;
   q5<=divide_segment(m4,q4,3,0);sign5<=sign4;
   if(valid_pipe[5])begin
    if(signed_result>32'sd32767)mono_pcm<=16'sh7fff;
    else if(signed_result< -32'sd32768)mono_pcm<=16'sh8000;
    else mono_pcm<=signed_result[15:0];sample_valid<=1;
   end
  end
 end
endmodule
