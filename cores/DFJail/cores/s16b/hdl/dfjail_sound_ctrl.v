module dfjail_sound_ctrl(
    input               clk,
    input               rst,
    input               cen_snd,
    input               irq_tick,
    input               misc_we,
    input               pcm_we,
    input       [ 7:0]  port_addr,
    input       [ 7:0]  data,
    output reg  [ 3:0]  bank,
    output reg          nmi_enable,
    output reg          nmi_pending,
    output reg  [ 3:0]  dac_low,
    output reg  [ 9:0]  dac_sample,
    output      [18:0]  bank_base,
    output              nmi_n,
    output signed [10:0] pcm
);
reg [9:0] dac_pending;

assign bank_base = 19'h10000 + {1'b0,bank[3],bank[2:0],14'd0};
assign nmi_n     = ~nmi_pending;
assign pcm       = $signed({1'b0,dac_sample}) - 11'sd512;

always @(posedge clk or posedge rst) begin
    if(rst) begin
        bank        <= 4'd0;
        nmi_enable  <= 1'b0;
        nmi_pending <= 1'b0;
        dac_low     <= 4'd0;
        dac_sample  <= 10'd0;
        dac_pending <= 10'd0;
    end else begin
        if(misc_we) begin
            bank       <= data[3:0];
            nmi_enable <= data[7:6] == 2'b00;
        end

        if(pcm_we && port_addr[7:2] == 6'b100000) begin
            case(port_addr[1:0])
                2'b00: begin dac_low <= data[5:2]; dac_pending <= {6'd0,data[5:2]}; end
                2'b01: begin
                    dac_pending <= dac_pending | {data[5:0],4'b0};
                    dac_sample <= dac_pending | {data[5:0],4'b0};
                end
                default: ;
            endcase
        end

        // Hold the timer NMI until the root-clocked Z80 samples it at cen_snd.
        if(irq_tick && nmi_enable)
            nmi_pending <= 1'b1;
        else if(cen_snd && nmi_pending)
            nmi_pending <= 1'b0;
    end
end

endmodule

// Clean DFJail mix. The previous analog-network model attenuated the YM
// by ~5x (gain 0.17 at 1 kHz) and low-passed it (-6 dB at 4 kHz, -12 dB
// at 8 kHz), which sounded quiet and muffled. This path keeps MAME's route
// levels (YM .43 per channel = 0.215 of the L+R sum, AD7533 .25 = pcm*16),
// adds 1.5x make-up gain, removes DC, smooths the 8 kHz DAC staircase with a
// 7.6 kHz one-pole filter and ends in a soft-knee limiter that can only
// approach full scale, so loud passages compress instead of clipping.
module dfjail_audio_mix #(
    parameter FRACW=17, FRACN=231, FRACM=60574,
    parameter signed [8:0] FM_K  = 9'sd82,   // 0.32 * 256 (0.215 * 1.5)
    parameter signed [6:0] PCM_K = 7'sd24    // 16 * 1.5
)(
    input clk, rst, mute,
    input dfjail_analog_reset,
    input signed [15:0] fm_l, fm_r,
    input signed [10:0] pcm,
    input [5:0] ch_en,
    input [7:0] gain,
    output sample,
    output reg signed [15:0] mixed,
    output reg peak,
    output reg [5:0] vu
);
wire unused_cen;
jtframe_frac_cen #(.WC(FRACW)) u_cen(
    .clk(clk), .n(FRACN[FRACW-1:0]), .m(FRACM[FRACW-1:0]),
    .cen({unused_cen,sample}), .cenb()
);
// Soft-knee limiter: linear up to KNEE, then four segments of length SEG
// with slopes 1/2, 1/4, 1/8, 1/16. Output never exceeds KNEE+15/16*SEG.
localparam signed [20:0] KNEE = 21'sd20000;
localparam signed [20:0] SEG  = 21'sd13618;
reg s0;
reg signed [16:0] fm_sum;
reg signed [25:0] fm_g;
reg signed [17:0] fm_s;
reg signed [17:0] pcm_g, pcm_lp;
reg signed [19:0] mix0;
reg signed [23:0] dc;
reg signed [19:0] hp;
reg signed [28:0] volume;
reg signed [20:0] y, a, u, c;
reg  [7:0] gain0, gain1;
reg mute0, mute1, mute2, mute3, mute4;
reg hard;
reg y_sign0, y_sign1, a_sign;
always @(posedge clk) begin
    if(rst) begin
        s0<=0; fm_sum<=0; fm_g<=0; fm_s<=0; pcm_g<=0; pcm_lp<=0; mix0<=0; dc<=0; hp<=0;
        volume<=0; y<=0; gain0<=0; gain1<=0; mute0<=1; mute1<=1; mute2<=1; mute3<=1; mute4<=1;
        mixed<=0; peak<=0; vu<=0; hard<=0; a<=0; u<=0; c<=0;
    end else begin
        s0 <= sample;
        gain0<=gain; gain1<=gain0;
        mute0<=mute; mute1<=mute0; mute2<=mute1; mute3<=mute2; mute4<=mute3;
        fm_sum <= ch_en[0] ? $signed({fm_l[15],fm_l}) + $signed({fm_r[15],fm_r}) : 17'sd0;
        fm_g   <= fm_sum * FM_K;
        fm_s   <= fm_g >>> 8;
        pcm_g  <= ch_en[1] ? $signed(pcm) * PCM_K : 18'sd0;
        if(s0) begin
            pcm_lp <= pcm_lp + ((pcm_g - pcm_lp) >>> 2);
            dc     <= dc + ((($signed({mix0[19],mix0}) <<< 4) - dc) >>> 12);
        end
        mix0   <= fm_s + pcm_lp;
        hp     <= mix0 - (dc >>> 4);
        volume <= hp * $signed({1'b0,gain1});
        y      <= volume >>> 7;
        // limiter, three registered steps
        a      <= y[20] ? -y : y;
        u      <= a - KNEE;
        if(u <= 0)            begin c <= a;                                              hard <= 0; end
        else if(u < SEG)      begin c <= KNEE + (u >>> 1);                               hard <= 0; end
        else if(u < 2*SEG)    begin c <= KNEE + (SEG>>>1) + ((u-SEG) >>> 2);             hard <= 0; end
        else if(u < 3*SEG)    begin c <= KNEE + (SEG>>>1) + (SEG>>>2) + ((u-2*SEG) >>> 3); hard <= 0; end
        else if(u < 4*SEG)    begin c <= KNEE + (SEG>>>1) + (SEG>>>2) + (SEG>>>3) + ((u-3*SEG) >>> 4); hard <= 0; end
        else                  begin c <= 21'sd32767;                                     hard <= 1; end
        if(mute4) mixed <= 0;
        else      mixed <= (a_sign ? -c : c);
        peak <= !mute4 && hard;
        vu <= {4'b0, ch_en[1] && pcm!=-11'sd512, ch_en[0] && (fm_l!=0 || fm_r!=0)};
    end
end
// sign must follow the limiter pipeline: a and c are two steps behind y
always @(posedge clk) begin
    if(rst) begin y_sign0<=0; y_sign1<=0; a_sign<=0; end
    else begin y_sign0 <= y[20]; y_sign1 <= y_sign0; a_sign <= y_sign1; end
end
endmodule

// Experimental linear RC path derived from MAME's System 16B analog circuit.
// It is not connected to the core and does not model op-amp startup/nonlinearity.
module dfjail_ym_rc_candidate(
 input clk,rst,sample192,
 input signed [15:0] fm_l,fm_r,
 output reg signed [18:0] fm_out,
 output reg valid
);
reg [1:0] div4;
reg v0,v1,v2,v3,v4;
reg signed [35:0] input_q,s0,s1,s2,s3,s4,d0,d1,d2,d3,d4;
wire signed [16:0] fm_sum=$signed({fm_l[15],fm_l})+$signed({fm_r[15],fm_r});
wire signed [36:0] e0=$signed({input_q[35],input_q})-$signed({s0[35],s0});
wire signed [36:0] e1=$signed({d0[35],d0})-$signed({s1[35],s1});
wire signed [36:0] e2=$signed({d1[35],d1})-$signed({s2[35],s2});
wire signed [36:0] e3=$signed({d2[35],d2})-$signed({s3[35],s3});
wire signed [36:0] e4=$signed({d3[35],d3})-$signed({s4[35],s4});
wire signed [61:0] p0=e0*25'sd16318979;
wire signed [61:0] p1=e1*25'sd3380;
wire signed [61:0] p2=e2*25'sd5152708;
wire signed [61:0] p3=e3*25'sd13274;
wire signed [61:0] p4=e4*25'sd343;
wire signed [35:0] n0=s0+(p0>>>24);
wire signed [35:0] n1=s1+(p1>>>24);
wire signed [35:0] n2=s2+(p2>>>24);
wire signed [35:0] n3=s3+(p3>>>24);
wire signed [35:0] n4=s4+(p4>>>24);
wire signed [60:0] output_product=d4*25'sd2956641;
always @(posedge clk)begin
 if(rst)begin
  div4<=0;v0<=0;v1<=0;v2<=0;v3<=0;v4<=0;valid<=0;fm_out<=0;
  input_q<=0;s0<=0;s1<=0;s2<=0;s3<=0;s4<=0;d0<=0;d1<=0;d2<=0;d3<=0;d4<=0;
 end else begin
  if(sample192)div4<=div4+1'b1;
  v0<=sample192 && div4==3;
  if(sample192 && div4==3)input_q<=$signed(fm_sum)<<<16;
  v1<=v0;v2<=v1;v3<=v2;v4<=v3;valid<=v4;
  if(v0)begin s0<=n0;d0<=n0;end
  if(v1)begin s1<=n1;d1<=d0-n1;end
  if(v2)begin s2<=n2;d2<=n2;end
  if(v3)begin s3<=n3;d3<=d2-n3;end
  if(v4)begin s4<=n4;d4<=d3-n4;end
  if(valid)fm_out<=-(output_product>>>40);
 end
end
endmodule
