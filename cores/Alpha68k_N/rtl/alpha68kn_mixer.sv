// MAME 0.289 nominal mono routes: YMFM SSG and legacy standalone AY differ.
// Inputs are donor numerical samples; physical analog calibration remains separate.
module alpha68kn_mixer (
    input wire clk,reset,
    input wire [7:0] profile,dac,
    input wire signed [15:0] fm,
    input wire [9:0] ym_psg,ay1_psg,ay2_psg,
    output reg signed [15:0] sample,
    output reg sample_ce,
    output reg [31:0] clipped_samples
);
    // Q16: FM route .30. YMFM SSG maps each channel u8 to [0,16382].
    // Standalone AY maps each channel u8 to [-.125,.375] of full scale,
    // matching build_single_table before MAME's frontend limiter.
    // PSG gains .30/.30/.60 (Kyros/Japan), .30/.30/.45 (Stingray); DAC .50.
    reg signed [39:0] fm_q,ym_q,ay1_q,ay2_q,dac_q;
    reg signed [39:0] pair0_q,pair1_q,dac_delay_q,mix_q;
    wire signed [39:0] pcm=mix_q >>> 16;
    reg [9:0] sample_div;
    always @(posedge clk) begin
        if(reset) begin
            fm_q<=0;ym_q<=0;ay1_q<=0;ay2_q<=0;dac_q<=0;
            pair0_q<=0;pair1_q<=0;dac_delay_q<=0;mix_q<=0;
            sample<=0;sample_ce<=0;sample_div<=0;clipped_samples<=0;
        end else begin
            fm_q <= $signed(fm) * 40'sd19661;
            ym_q <= $signed({1'b0,ym_psg}) * 40'sd1263071;
            ay1_q <= $signed({1'b0,ay1_psg}) * 40'sd1263226 - 40'sd241591910;
            ay2_q <= $signed({1'b0,ay2_psg}) *
                (profile==2 ? 40'sd1894839 : 40'sd2526451) -
                (profile==2 ? 40'sd362387866 : 40'sd483183821);
            dac_q <= ($signed({1'b0,dac})-40'sd128) * 40'sd8388608;
            pair0_q<=fm_q+ym_q;pair1_q<=ay1_q+ay2_q;dac_delay_q<=dac_q;
            mix_q<=pair0_q+pair1_q+dac_delay_q;
            sample_ce<=sample_div==999;
            sample_div<=sample_div==999 ? 0 : sample_div+1'b1;
            if(sample_div==999) begin
                if(pcm>32767) begin sample<=32767;clipped_samples<=clipped_samples+1'b1;end
                else if(pcm< -32768) begin sample<=-32768;clipped_samples<=clipped_samples+1'b1;end
                else sample<=pcm[15:0];
            end
        end
    end
endmodule
