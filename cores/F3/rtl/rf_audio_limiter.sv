// Output protection, not part of the emulated Ensoniq/MB87078 silicon.
// Shared Q16 gain preserves stereo balance. Exact peak bound, immediate
// necessary attack and ~1024-sample release. 35-clock processing latency;
// one queued sample absorbs close publications. No combinational divider.
module rf_audio_limiter(
 input wire clk,reset,in_valid,
 input wire signed [39:0] in_l,in_r,
 output reg signed [15:0] out_l,out_r,
 output reg overrun
);
 reg [1:0] state;
 reg [5:0] remaining;
 reg signed [39:0] sample_l,sample_r;
 reg [39:0] denominator;
 reg [40:0] remainder;
 reg [31:0] numerator,quotient;
 reg [16:0] gain,applied_gain;
 reg signed [57:0] product_l,product_r;
 reg pending;
 reg signed [39:0] pending_l,pending_r;
 wire signed [39:0] next_l=pending?pending_l:in_l;
 wire signed [39:0] next_r=pending?pending_r:in_r;
 wire [39:0] abs_l=next_l[39] ? (~next_l+40'd1) : next_l;
 wire [39:0] abs_r=next_r[39] ? (~next_r+40'd1) : next_r;
 wire [39:0] peak=abs_l>abs_r?abs_l:abs_r;
 wire [40:0] trial={remainder[39:0],numerator[31]};
 wire subtract=trial>={1'b0,denominator};
 wire [31:0] next_quotient={quotient[30:0],subtract};
 wire [16:0] release_step=(17'd65536-gain)>>10;
 wire [16:0] recovered=gain==65536?gain:gain+(release_step==0?17'd1:release_step);
 wire [16:0] ceiling=next_quotient>=65536?17'd65536:next_quotient[16:0];
 always @(posedge clk)begin
  if(reset)begin
   state<=0;remaining<=0;sample_l<=0;sample_r<=0;denominator<=30000;
   remainder<=0;numerator<=0;quotient<=0;gain<=65536;applied_gain<=65536;
   product_l<=0;product_r<=0;out_l<=0;out_r<=0;overrun<=0;
   pending<=0;pending_l<=0;pending_r<=0;
  end else begin
   if(state==0 && pending)pending<=0;
   if(in_valid && (state!=0 || pending))begin
    if(pending && state!=0)overrun<=1;
    else begin pending<=1;pending_l<=in_l;pending_r<=in_r;end
   end
   case(state)
    0:if(in_valid || pending)begin
       sample_l<=next_l;sample_r<=next_r;
       denominator<=peak<30000?40'd30000:peak;
       numerator<=32'd1966080000;quotient<=0;remainder<=0;
       remaining<=32;state<=1;
      end
    1:begin
       remainder<=subtract?trial-{1'b0,denominator}:trial;
       numerator<={numerator[30:0],1'b0};quotient<=next_quotient;
       remaining<=remaining-1'b1;
       if(remaining==1)begin
        applied_gain<=ceiling<recovered?ceiling:recovered;
        gain<=ceiling<recovered?ceiling:recovered;state<=2;
       end
      end
    2:begin
       product_l<=sample_l*$signed({1'b0,applied_gain});
       product_r<=sample_r*$signed({1'b0,applied_gain});state<=3;
      end
    3:begin out_l<=product_l>>>16;out_r<=product_r>>>16;state<=0;end
   endcase
  end
 end
endmodule
