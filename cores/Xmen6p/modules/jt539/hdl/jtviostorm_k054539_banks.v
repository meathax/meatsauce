// Native 054539 six-bank accumulation and output retirement.
// SiliconRE c926ce92fdebd7613c8712b42c45a059d63548e0:
// SRA[4,5,8,9,10,11] capture E,F,D,C,B,A (hdl1761..1805).
// S10/S11 LOADSR and AH95 output reset: SDF16825/16830/29829/31670.
// Qualified native counter trace uses the count BEFORE its master-edge
// increment: E13,F15,D21,C23,B25,A27; LOAD72; clear73. D is then C-1;
// after the edge the raw count has incremented and delayed count is old C.
// Parent selects the stable gain packet for the current native group:
// g0/1=loop212/213, g2..9=real0..7, g10/11=external210/211.
// Products already include all gain truncation and ACCE ceil-halving.
//
// contribution and bank_values share this low-to-high lane convention:
// {send_f,send_e,wet_right,wet_left,dry_right,dry_left}.
// The four published words represent the D/B/C/A serializer snapshots.
// E/F shadows capture with them, independently of D0 output mute.
module jtviostorm_k054539_banks (
    input                   clk,
    input                   rst,
    input                   cen,
    input                   slot_tick,
    input       [8:0]       sample_cnt,
    input                   output_enable,
    input       [95:0]      contribution,
    input                   contribution_valid,
    output reg signed [15:0] dry_left,
    output reg signed [15:0] dry_right,
    output reg signed [15:0] wet_left,
    output reg signed [15:0] wet_right,
    output reg signed [15:0] send_e,
    output reg signed [15:0] send_f,
    output reg              sample_valid,
    output reg              underrun_pulse,
    output reg              underrun,
    output      [95:0]      bank_values
);

reg signed [15:0] acc_a,acc_b,acc_c,acc_d,acc_e,acc_f;
wire service=cen && slot_tick;
wire load=service && sample_cnt==9'd72;
wire clear=service && sample_cnt==9'd73;
wire capture=sample_cnt[4:0]==5'd13 || sample_cnt[4:0]==5'd15 ||
             sample_cnt[4:0]==5'd21 || sample_cnt[4:0]==5'd23 ||
             sample_cnt[4:0]==5'd25 || sample_cnt[4:0]==5'd27;
assign bank_values={acc_f,acc_e,acc_a,acc_c,acc_b,acc_d};

// D0 resets the output PISOs, rather than any accumulator or E/F shadow.
// Re-enabling halfway through a word holds zero until its next native load.
wire serializer_reset=rst || !output_enable;
always @(posedge clk or posedge serializer_reset) begin
    if(serializer_reset) begin
        dry_left<=0;dry_right<=0;wet_left<=0;wet_right<=0;
    end else if(load) begin
        dry_left<=acc_d;dry_right<=acc_b;
        wet_left<=acc_c;wet_right<=acc_a;
    end
end

always @(posedge clk) begin
    if(rst) begin
        acc_a<=0;acc_b<=0;acc_c<=0;acc_d<=0;acc_e<=0;acc_f<=0;
        send_e<=0;send_f<=0;sample_valid<=0;
        underrun_pulse<=0;underrun<=0;
    end else begin
        sample_valid<=0;
        underrun_pulse<=0;
        if(load) begin
            // The snapshot precedes the next-clock six-bank clear.
            send_e<=acc_e;send_f<=acc_f;sample_valid<=1;
        end
        if(clear) begin
            acc_a<=0;acc_b<=0;acc_c<=0;acc_d<=0;acc_e<=0;acc_f<=0;
        end else if(service && capture) begin
            if(!contribution_valid) begin
                // Missing stage contributes zero and is observable once per
                // native bank strobe, without replay on a held slot.
                underrun_pulse<=1;underrun<=1;
            end else case(sample_cnt[4:0])
                5'd13: acc_e<=acc_e+$signed(contribution[79:64]);
                5'd15: acc_f<=acc_f+$signed(contribution[95:80]);
                5'd21: acc_d<=acc_d+$signed(contribution[15:0]);
                5'd23: acc_c<=acc_c+$signed(contribution[47:32]);
                5'd25: acc_b<=acc_b+$signed(contribution[31:16]);
                5'd27: acc_a<=acc_a+$signed(contribution[63:48]);
                default: begin end
            endcase
        end
    end
end
endmodule
