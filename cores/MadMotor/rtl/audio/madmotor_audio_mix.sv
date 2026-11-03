// SPDX-License-Identifier: GPL-3.0-or-later
// Exact MAME route arithmetic, pipelined without timing exceptions.
// Capture at sample_ce; publish the same signed/saturated result14clocks later.
module madmotor_audio_mix(
    input tri0 bandit,
    input logic clk, reset, sample_ce,
    input logic signed [15:0] opn,
    input logic signed [20:0] opm_left,opm_right,pcm1,pcm2, // Q4
    input logic [9:0] psg,
    output logic signed [15:0] left,right,
    output logic clipped,
    output wire sample_valid
);
    logic [14:0] valid;
    assign sample_valid=valid[14];
    logic signed [15:0] opn0;
    logic signed [20:0] opml0,opmr0,pcm10,pcm20;
    logic [9:0] psg0;
    logic signed [31:0] opn1,opml1,opmr1,pcm11,pcm21;
    logic [23:0] ssg_numerator1;
    logic [16:0] ssg_base2,ssg_quotient3;
    logic [9:0] ssg_sum2;
    logic signed [31:0] pair02,pair12,tail2,others3,weighted4;
    // For24-bit unsigned x=65536*a+256*b+c,
    // floor(x/255)=257*a+b+floor((a+b+c)/255). No reciprocal approximation.
    logic [36:0] divide_state [0:8]; // 5-bit remainder,32-bit dividend/quotient
    logic negative [0:8];
    // floor(floor(abs(weighted)/20)/16) == floor(abs(weighted)/320).
    wire [31:0] final_magnitude=divide_state[8][31:0]>>4;
    function automatic [36:0] divide_four(input [36:0] state);
        logic [4:0] remainder;
        logic [5:0] shifted,difference;
        logic [31:0] quotient;
        begin
            remainder=state[36:32];quotient=state[31:0];
            for(integer bit_index=0;bit_index<4;bit_index=bit_index+1) begin
                shifted={remainder,quotient[31]};
                quotient={quotient[30:0],1'b0};
                if(shifted>=6'd20) begin
                    difference=shifted-6'd20;remainder=difference[4:0];quotient[0]=1'b1;
                end else remainder=shifted[4:0];
            end
            divide_four={remainder,quotient};
        end
    endfunction
    always_ff @(posedge clk) begin
        if(reset) begin
            valid<=0;left<=0;right<=0;clipped<=0;
        end else begin
            valid<={valid[13:0],sample_ce};
            if(sample_ce) begin
                opn0<=opn;opml0<=opm_left;opmr0<=opm_right;
                pcm10<=pcm1;pcm20<=pcm2;psg0<=psg;
            end
            if(valid[0]) begin
                opn1<=opn0*(bandit?32'sd102:32'sd128);opml1<=opml0*(bandit?32'sd6:32'sd9);opmr1<=opmr0*(bandit?32'sd0:32'sd9);
                pcm11<=pcm10*(bandit?32'sd53:32'sd160);pcm21<=pcm20*(bandit?32'sd0:32'sd80);
                ssg_numerator1<={psg0,14'd0}-{13'd0,psg0,1'b0};
            end
            if(valid[1]) begin
                pair02<=opn1+opml1;pair12<=opmr1+pcm11;tail2<=pcm21;
                ssg_base2<={1'b0,ssg_numerator1[23:16],8'd0}
                    +{9'd0,ssg_numerator1[23:16]}+{9'd0,ssg_numerator1[15:8]};
                ssg_sum2<={2'd0,ssg_numerator1[23:16]}+{2'd0,ssg_numerator1[15:8]}+{2'd0,ssg_numerator1[7:0]};
            end
            if(valid[2]) begin
                others3<=pair02+pair12+tail2;
                ssg_quotient3<=ssg_base2+((ssg_sum2>=10'd765) ? 17'd3 : (ssg_sum2>=10'd510) ? 17'd2 : (ssg_sum2>=10'd255) ? 17'd1 : 17'd0);
            end
            if(valid[3]) weighted4<=others3+$signed({8'd0,ssg_quotient3,7'd0});
            if(valid[4]) begin
                divide_state[0]<={5'd0,(weighted4[31] ? (~$unsigned(weighted4)+32'd1) : $unsigned(weighted4))};
                negative[0]<=weighted4[31];
            end
            for(integer stage=0;stage<8;stage=stage+1) if(valid[5+stage]) begin
                divide_state[stage+1]<=divide_four(divide_state[stage]);
                negative[stage+1]<=negative[stage];
            end
            if(valid[13]) begin
                if(final_magnitude>(negative[8] ? 32'd32768 : 32'd32767)) begin
                    left<=negative[8] ? 16'sh8000 : 16'sh7fff;
                    right<=negative[8] ? 16'sh8000 : 16'sh7fff;
                    clipped<=1;
                end else begin
                    left<=negative[8] ? -final_magnitude[15:0] : final_magnitude[15:0];
                    right<=negative[8] ? -final_magnitude[15:0] : final_magnitude[15:0];
                    clipped<=0;
                end
            end
        end
    end
endmodule
