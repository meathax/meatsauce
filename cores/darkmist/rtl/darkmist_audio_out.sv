// Darkmist board audio output stage.
// The sound board output is one mono bridged channel (YM2151 -> YM3012 ->
// HB-4 summing stage -> VOL -> VR1 -> LA4460), so both HPS/MiSTer channels
// carry the same mono sum. Each DAC path into the summing node is 2.2 uF in
// series with 4.7 kohm, a first-order DC-blocking high-pass:
//   fc = 1/(2*pi*R*C) = 1/(2*pi*4.7e3*2.2e-6) = 15.39 Hz
// Discrete-time one-pole form (sample period T):
//   y[n] = a * (y[n-1] + m[n] - m[n-1]),  a = 1/(1 + 2*pi*fc*T)
// with T = 64/3579545 s (YM2151 phiM = 3.579545 MHz, sample rate phiM/64).
//   a = 1/(1 + 2*pi*15.39*64/3579545) = 0.99827408...
//   HPF_A = round(2^24 * a) = 16748260 (computed in Python; the value for the
//   exact R/C product, fc = 15.3922 Hz, would be 16748256).
// Low-pass stage: not resolved on the schematic, not implemented.
// Coefficient is Q0.24 unsigned. HPF state YS is signed 64-bit, y * 2^24
// (24 fractional bits), so truncation does not bias DC. The one-pole DC block
// (fs = 55.93 kHz, pole 0.99827) amplifies a per-sample integer truncation
// bias by about 1/(1-a) = 578, so the state keeps fractions.
// Output is rounded to nearest (+0.5 LSB before the >>> 24), then saturated to
// 16 bits. The state is not clipped.
module darkmist_audio_out #(parameter HPF_EN = 1, parameter [23:0] HPF_A = 24'd16748260) (
  input wire clk, input wire rst, input wire sample,
  input wire signed [15:0] left_in, input wire signed [15:0] right_in,
  output reg signed [15:0] mono_out);

  // Mono sum: 17-bit signed add, arithmetic shift right by one.
  wire signed [16:0] sum17 = $signed({left_in[15], left_in}) + $signed({right_in[15], right_in});
  wire signed [16:0] m17 = sum17 >>> 1;
  wire signed [39:0] m40 = {{23{m17[16]}}, m17};

  reg signed [63:0] YS = 0;      // y * 2^24
  reg signed [39:0] m_prev = 0;

  // HPF path: D = m - m_prev (integer), S = YS + D*2^24, YS_next = (HPF_A*S) >>> 24.
  wire signed [39:0] d40 = m40 - m_prev;
  wire signed [63:0] d64 = {{24{d40[39]}}, d40};
  wire signed [63:0] s64 = YS + (d64 <<< 24);
  wire signed [95:0] s96 = {{32{s64[63]}}, s64};
  wire signed [95:0] a96 = {72'd0, HPF_A};
  wire signed [95:0] p96 = a96 * s96;
  wire signed [95:0] hpf96 = p96 >>> 24;
  wire signed [63:0] hpf_next = hpf96[63:0];

  wire signed [63:0] m64_fx = {{24{m40[39]}}, m40} <<< 24;
  wire signed [63:0] ys_next = HPF_EN ? hpf_next : m64_fx;

  // Round to nearest integer: (YS_next + 2^23) >>> 24.
  wire signed [63:0] y_round = (ys_next + (64'sd1 <<< 23)) >>> 24;

  // Saturate to 16-bit output.
  wire signed [15:0] sat_out = (y_round > 64'sd32767)  ? 16'sd32767 :
                               (y_round < -64'sd32768) ? 16'sh8000 :
                               y_round[15:0];

  // One sample every878 game clocks; four registered arithmetic stages.
  // State/m_prev preserve the original discrete recurrence and integer rounding.
  reg [3:0] pending=0;
  reg signed [63:0] pipeline_sum=0;
  reg signed [63:0] pipeline_m0=0,pipeline_m1=0,pipeline_m2=0;
  reg signed [63:0] product_high=0;
  reg [55:0] product_low=0;
  reg signed [95:0] product_joined=0;
  wire signed [24:0] coefficient={1'b0,HPF_A};
  wire signed [63:0] high_operand={{32{pipeline_sum[63]}},pipeline_sum[63:32]};
  wire signed [95:0] high_term={{32{product_high[63]}},product_high} <<<32;
  wire signed [95:0] low_term={40'd0,product_low};
  wire signed [95:0] joined_hpf=product_joined >>>24;
  wire signed [63:0] result_state=HPF_EN ? joined_hpf[63:0] : pipeline_m2;
  wire signed [63:0] result_round=(result_state+(64'sd1<<<23))>>>24;
  wire signed [15:0] result_sat=(result_round>64'sd32767)?16'sd32767:
        (result_round< -64'sd32768)?16'sh8000:result_round[15:0];
  always @(posedge clk) begin
    if(rst)begin
      YS<=0;m_prev<=0;mono_out<=0;pending<=0;
      pipeline_sum<=0;pipeline_m0<=0;pipeline_m1<=0;pipeline_m2<=0;
      product_high<=0;product_low<=0;product_joined<=0;
    end else begin
      pending<={pending[2:0],sample};
      if(sample)begin pipeline_sum<=s64;pipeline_m0<=m64_fx;m_prev<=m40;end
      if(pending[0])begin
        product_high<=coefficient*high_operand;
        product_low<=HPF_A*pipeline_sum[31:0];
        pipeline_m1<=pipeline_m0;
      end
      if(pending[1])begin product_joined<=high_term+low_term;pipeline_m2<=pipeline_m1;end
      if(pending[2])begin YS<=result_state;mono_out<=result_sat;end
    end
  end
`ifndef SYNTHESIS
  always @(posedge clk)if(!rst && sample && |pending[2:0])
    $fatal(1,"Darkmist HPF source violated minimum four-clock sample interval");
`endif
endmodule
