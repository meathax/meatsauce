// Combined YM and startup circuit; source-derived fixed-point PWL approximation.
// One time-shared multiplier; no new clock. Physical circuit accuracy remains open.
module dfjail_ym_full(
 input clk,rst,sample48,
 input signed [15:0] fm_l,fm_r,
 output reg signed [18:0] pcm,
 output reg valid,overrun
);
localparam signed [39:0] V25=40'sd10737418240, VLOW=40'sd3221225472,
 VHIGH=40'sd48318382080, V10=40'sd42949672960,
 SPEECH=40'sd9786115036;
reg [4:0] state;
reg signed [16:0] fm_latched;
reg signed [39:0] target_v;
reg signed [39:0] ref_v,inp,cap,speech_cap,out_v,minus,hp1,hp2;
reg signed [39:0] trial,next_out,minus_acc,d1,d2;
reg rail_active;
wire signed [39:0] vin=inp<VLOW ? VLOW : (inp>VHIGH ? VHIGH : inp);
reg signed [39:0] pwl_x,pwl_y;
reg signed [25:0] pwl_slope;
always @* begin
 pwl_x=-40'sd34359738368;pwl_y=40'sd489794906;pwl_slope=0;
    if(trial < -40'sd25769803776) begin pwl_x=-40'sd34359738368; pwl_y=40'sd489794906; pwl_slope=26'sd61116; end
    else if(trial < -40'sd17179869184) begin pwl_x=-40'sd25769803776; pwl_y=40'sd521086060; pwl_slope=26'sd85257; end
    else if(trial < -40'sd12884901888) begin pwl_x=-40'sd17179869184; pwl_y=40'sd564737862; pwl_slope=26'sd119215; end
    else if(trial < -40'sd8589934592) begin pwl_x=-40'sd12884901888; pwl_y=40'sd595256835; pwl_slope=26'sd164405; end
    else if(trial < -40'sd6442450944) begin pwl_x=-40'sd8589934592; pwl_y=40'sd637344597; pwl_slope=26'sd226263; end
    else if(trial < -40'sd4294967296) begin pwl_x=-40'sd6442450944; pwl_y=40'sd666306218; pwl_slope=26'sd305188; end
    else if(trial < -40'sd3221225472) begin pwl_x=-40'sd4294967296; pwl_y=40'sd705370245; pwl_slope=26'sd407886; end
    else if(trial < -40'sd2147483648) begin pwl_x=-40'sd3221225472; pwl_y=40'sd731474933; pwl_slope=26'sd529605; end
    else if(trial < -40'sd1288490189) begin pwl_x=-40'sd2147483648; pwl_y=40'sd765369669; pwl_slope=26'sd719207; end
    else if(trial < -40'sd644245094) begin pwl_x=-40'sd1288490189; pwl_y=40'sd802193060; pwl_slope=26'sd990163; end
    else if(trial < 40'sd0) begin pwl_x=-40'sd644245094; pwl_y=40'sd840215323; pwl_slope=26'sd1459037; end
    else if(trial < 40'sd429496730) begin pwl_x=40'sd0; pwl_y=40'sd896242354; pwl_slope=26'sd2311929; end
    else if(trial < 40'sd858993459) begin pwl_x=40'sd429496730; pwl_y=40'sd955427738; pwl_slope=26'sd4140871; end
    else if(trial < 40'sd1288490189) begin pwl_x=40'sd858993459; pwl_y=40'sd1061434039; pwl_slope=26'sd9711919; end
    else if(trial < 40'sd1717986918) begin pwl_x=40'sd1288490189; pwl_y=40'sd1310059166; pwl_slope=26'sd15955954; end
end
// Register the shared circuit MAC result. Independent terms are scheduled
// around its one-cycle latency; the accepted-sample and valid slots stay0/16.
reg signed [39:0] mul_a;
reg signed [25:0] mul_b;
wire signed [65:0] product=$signed(mul_a)*$signed(mul_b);
reg signed [65:0] product_pipe;
wire signed [39:0] q24=$signed(product_pipe)>>>24;

// HP work overlaps circuit states9..15. Every subtraction/addition remains
// signed40-bit modulo arithmetic, with the original post-product shifts.
reg signed [39:0] hp_operand,hp1_next,hp2_next,d1_next;
reg signed [14:0] hp_coef;
wire signed [65:0] hp_product=$signed(hp_operand)*$signed(hp_coef);
reg signed [65:0] hp_product_pipe;
wire signed [39:0] hp_q24=$signed(hp_product_pipe)>>>24;
wire signed [65:0] pcm_product=$signed(d2)*26'sd26859;
wire signed [39:0] shaped_next = trial>=40'sd1717986918 ?
    (trial>V10 ? V10 : trial) :
    (trial < -40'sd34359738368 ? 40'sd489794906 : pwl_y+q24);
wire shaped_rail = trial<40'sd1717986918 || trial>V10;
always @* begin
 mul_a=0;mul_b=0;
 case(state)
  1:begin mul_a={{23{fm_latched[16]}},fm_latched};mul_b=26'sd14090;end
  2:begin mul_a=V25-ref_v;mul_b=26'sd1487;end
  3:begin mul_a=target_v-inp;mul_b=26'sd16318979;end
  4:begin mul_a=ref_v-SPEECH+speech_cap;mul_b=26'sd24194814;end
  5:begin mul_a=out_v-minus;mul_b=26'sd11624508;end
  6:begin mul_a=ref_v-vin+cap;mul_b=26'sd10303339;end
  7:begin mul_a=vin-cap;mul_b=26'sd3371236;end
  8:begin mul_a=trial-pwl_x;mul_b=pwl_slope;end
  9:begin mul_a=SPEECH-speech_cap;mul_b=26'sd7916503;end
 10:begin mul_a=next_out;mul_b=26'sd5489477;end
 11:begin mul_a=out_v-minus;mul_b=26'sd3803520;end
 13:begin mul_a=vin-cap-minus;mul_b=26'sd3380;end
 14:begin mul_a=SPEECH-speech_cap-minus;mul_b=26'sd15872;end
 endcase
end
always @(posedge clk) begin
 if(rst)begin
  state<=0;fm_latched<=0;target_v<=0;ref_v<=0;inp<=0;cap<=0;speech_cap<=0;out_v<=0;minus<=0;hp1<=0;hp2<=0;
  trial<=0;next_out<=0;minus_acc<=0;d1<=0;d2<=0;rail_active<=0;pcm<=0;valid<=0;overrun<=0;
  product_pipe<=0;hp_operand<=0;hp_coef<=0;hp_product_pipe<=0;hp1_next<=0;hp2_next<=0;d1_next<=0;
 end else begin
  product_pipe<=product;
  valid<=0;
  if(sample48 && state!=0)overrun<=1;
  case(state)
   0:if(sample48)begin fm_latched<=$signed({fm_l[15],fm_l})+$signed({fm_r[15],fm_r});state<=1;end
   1:state<=2;
   2:begin target_v<=V25+$signed(product_pipe);state<=3;end
   3:begin ref_v<=ref_v+q24;state<=4;end
   4:begin inp<=inp+q24;state<=5;end
   // Quantized terms are independent; their signed40-bit additions commute.
   5:begin trial<=ref_v+q24;state<=6;end
   6:begin trial<=trial+q24;state<=7;end
   7:begin trial<=trial+q24;state<=8;end
   8:begin minus_acc<=q24;state<=9;end
   9:begin
      next_out<=shaped_next;rail_active<=shaped_rail;
      hp_operand<=shaped_next-hp1;hp_coef<=15'sd13274;state<=10;
     end
  10:begin minus_acc<=minus_acc+q24;hp_product_pipe<=hp_product;state<=11;end
  11:begin minus_acc<=minus_acc+q24;hp1_next<=hp1+hp_q24;state<=12;end
  12:begin
      minus<=rail_active ? minus_acc-q24 : ref_v;
      d1_next<=next_out-hp1_next;
      hp_operand<=next_out-hp1_next-hp2;hp_coef<=15'sd343;state<=13;
     end
  13:begin hp_product_pipe<=hp_product;state<=14;end
  14:begin cap<=cap+q24;hp1<=hp1_next;d1<=d1_next;hp2_next<=hp2+hp_q24;state<=15;end
  15:begin speech_cap<=speech_cap+q24;out_v<=next_out;hp2<=hp2_next;d2<=d1_next-hp2_next;state<=16;end
  16:begin pcm<=$signed(pcm_product)>>>32;valid<=1;state<=0;end
   default:state<=0;
  endcase
 end
end
endmodule
