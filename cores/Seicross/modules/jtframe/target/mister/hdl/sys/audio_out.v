// Atomic source-clock configuration, committed in the audio domain.
module audio_out #(parameter CLK_RATE=24576000)(
 input wire reset,clk_cfg,cfg_ready,clk,sample_rate,
 input wire [31:0] flt_rate, input wire [39:0] cx,
 input wire [7:0] cx0,cx1,cx2, input wire [23:0] cy0,cy1,cy2,
 input wire [4:0] att, input wire [1:0] mix, input wire is_signed,
 input wire [15:0] core_l,core_r,alsa_l,alsa_r,
 output wire i2s_bclk,i2s_lrclk,i2s_data,spdif,dac_l,dac_r
);
wire [176:0] cfg_audio;
wire cfg_valid;
wire sample_rate_a,is_signed_a;
wire [31:0] flt_rate_a;
wire [39:0] cx_a;
wire [7:0] cx0_a,cx1_a,cx2_a;
wire [23:0] cy0_a,cy1_a,cy2_a;
wire [4:0] att_a;
wire [1:0] mix_a;
assign {sample_rate_a,flt_rate_a,cx_a,cx0_a,cx1_a,cx2_a,cy0_a,cy1_a,cy2_a,att_a,mix_a,is_signed_a}=cfg_audio;
seicro_audio_cdc #(.WIDTH(177)) u_cfg_cdc(
 .reset(reset),.src_valid(cfg_ready),.src_clk(clk_cfg),.dst_clk(clk),
 .src_sample({sample_rate,flt_rate,cx,cx0,cx1,cx2,cy0,cy1,cy2,att,mix,is_signed}),
 .dst_sample(cfg_audio),.dst_valid(cfg_valid));
seicro_template_audio_out #(.CLK_RATE(CLK_RATE)) sink(
 .reset(~cfg_valid),.clk(clk),.sample_rate(sample_rate_a),
 .flt_rate(flt_rate_a),.cx(cx_a),.cx0(cx0_a),.cx1(cx1_a),.cx2(cx2_a),
 .cy0(cy0_a),.cy1(cy1_a),.cy2(cy2_a),.att(att_a),.mix(mix_a),.is_signed(is_signed_a),
 .core_l(core_l),.core_r(core_r),.alsa_l(alsa_l),.alsa_r(alsa_r),
 .i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data),.spdif(spdif),.dac_l(dac_l),.dac_r(dac_r));
endmodule
