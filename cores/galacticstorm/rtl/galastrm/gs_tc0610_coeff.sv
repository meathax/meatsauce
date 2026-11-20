// SPDX-License-Identifier: BSD-3-Clause
// MAME 0.289 galastrm.cpp:437-438 coefficient setup.
// zcs = pxx / 2^20, zsn = pyx / (25*2^15), rounded binary32.
// Only setup arithmetic; vertices/extents and texture execution are separate.
module gs_tc0610_coeff (
    input wire clk,reset,query,
    output wire query_ready,
    input wire signed [15:0] rzx,rzy,
    output reg valid,
    input wire ready,
    output reg empty,
    output reg [20:0] zx,zy,
    output reg [31:0] zcs,zsn
);
    localparam IDLE=0,LAUNCH=1,WAIT_NORM=2,DIVIDE=3,ROUND_SN=4,FINISH=5;
    reg [2:0] state;
    reg signed [15:0] saved_x,saved_y;
    wire norm_ready,norm_valid,norm_empty;
    wire [20:0] norm_zx,norm_zy;
    wire signed [31:0] norm_pxx,norm_pyx;
    reg negative_sn;
    reg [7:0] exponent_sn;
    reg [28:0] numerator;
    reg [23:0] quotient;
    reg [4:0] remainder,divide_step;
    function automatic [4:0] lead22(input [21:0] n);
        integer i;
        begin lead22=0;for(i=0;i<22;i=i+1) if(n[i]) lead22=i[4:0];end
    endfunction
    function automatic [31:0] pow2_float(input signed [21:0] n);
        reg [21:0] magnitude;
        reg [31:0] shifted;
        reg [4:0] p;
        reg [7:0] exponent;
        begin
            magnitude=n[21] ? -n : n;
            p=lead22(magnitude);shifted={10'b0,magnitude}<<(23-p);exponent=p+8'd107;
            pow2_float=n==0 ? 32'b0 : {n[21],exponent,shifted[22:0]};
        end
    endfunction
    // Norm's products are bounded by radius*4096 plus one signed-16 step:
    // |pxx|<1081344, |pyx|<851968, so signed 22 bits retain every result.
    wire [21:0] py_magnitude=norm_pyx[21] ? -norm_pyx[21:0] : norm_pyx[21:0];
    wire [4:0] py_lead=lead22(py_magnitude);
    wire [31:0] py_normalized={10'b0,py_magnitude}<<(21-py_lead);
    wire signed [6:0] py_exponent=$signed({2'b0,py_lead})-
        (py_normalized>=32'd3276800 ? 7'sd19 : 7'sd20);
    wire [5:0] trial_remainder={remainder,numerator[28]};
    wire [24:0] rounded_quotient={1'b0,quotient}+({remainder,1'b0}>6'd25 ? 25'd1 : 25'd0);
    assign query_ready=state==IDLE && !valid;
    gs_tc0610_norm normalizer(
        .clk(clk),.reset(reset),.query(state==LAUNCH),.query_ready(norm_ready),
        .rzx(saved_x),.rzy(saved_y),.valid(norm_valid),.ready(state==WAIT_NORM),
        .empty(norm_empty),.zx(norm_zx),.zy(norm_zy),.pxx(norm_pxx),.pyx(norm_pyx)
    );
    always @(posedge clk) begin
        if(valid && ready) valid<=0;
        case(state)
        IDLE: if(query && query_ready) begin saved_x<=rzx;saved_y<=rzy;state<=LAUNCH;end
        LAUNCH: if(norm_ready) state<=WAIT_NORM;
        WAIT_NORM: if(norm_valid) begin
            empty<=norm_empty;zx<=norm_zx;zy<=norm_zy;zcs<=pow2_float(norm_pxx[21:0]);
            if(py_magnitude==0) begin zsn<=0;state<=FINISH;end
            else begin
                negative_sn<=norm_pyx[31];exponent_sn<=$signed(8'd127)+py_exponent;
                numerator<=py_magnitude<<(7'sd8-py_exponent);
                quotient<=0;remainder<=0;divide_step<=0;state<=DIVIDE;
            end
        end
        DIVIDE: begin
            numerator<={numerator[27:0],1'b0};
            if(trial_remainder>=25) begin
                remainder<=trial_remainder-6'd25;quotient<={quotient[22:0],1'b1};
            end else begin remainder<=trial_remainder[4:0];quotient<={quotient[22:0],1'b0};end
            if(divide_step==28) state<=ROUND_SN;
            else divide_step<=divide_step+1'b1;
        end
        ROUND_SN: begin
            if(rounded_quotient[24]) zsn<={negative_sn,exponent_sn+8'd1,23'b0};
            else zsn<={negative_sn,exponent_sn,rounded_quotient[22:0]};
            state<=FINISH;
        end
        FINISH: begin valid<=1;state<=IDLE;end
        endcase
        if(reset) begin
            state<=IDLE;valid<=0;empty<=1;zx<=0;zy<=0;zcs<=0;zsn<=0;
            saved_x<=0;saved_y<=0;negative_sn<=0;exponent_sn<=0;numerator<=0;
            quotient<=0;remainder<=0;divide_step<=0;
        end
    end
endmodule
