// SPDX-License-Identifier: BSD-3-Clause
// Bounded normalization for MAME 0.289 galastrm.cpp:422-438.
// Binary search reproduces the source's rounded binary32 square/add threshold
// at radii 256/200; it replaces up to 1048576 iterative normalization steps.
// Outputs are integer loop counts/products, not complete affine coordinates.
module gs_tc0610_norm (
    input wire clk,reset,query,
    output wire query_ready,
    input wire signed [15:0] rzx,rzy,
    output reg valid,
    input wire ready,
    output reg empty,
    output reg [20:0] zx,zy,
    output reg signed [31:0] pxx,pyx
);
    localparam IDLE=0,SEARCH=1,PRODUCT_A=2,PRODUCT_B=3,SQUARE_A=4,SQUARE_B=5,
               ROUND_A=6,ROUND_B=7,ADD=8,TEST=9,
               LAST_PRODUCT_A=10,LAST_PRODUCT_B=11,FINISH=12,
               ROUND_LOAD_A=13,ROUND_LOAD_B=14;
    reg [3:0] state;
    reg phase_y,negative_a,negative_b,early_reached;
    reg [16:0] abs_a,abs_b;
    reg [20:0] low,high,mid;
    reg [37:0] product_a,product_b;
    reg [43:0] square_a,square_b,rounded_a,rounded_b,sum;
    reg [43:0] round_input;
    wire [37:0] limit=phase_y ? 38'd819200 : 38'd1048576;
    wire [43:0] squared_limit=phase_y ? 44'd671088640000 : 44'd1099511627776;
    function automatic [43:0] round24(input [43:0] n);
        integer i,shift;
        reg [20:0] step,low_mask,bias;
        reg [43:0] rounded_integer;
        begin
            shift=0;
            for(i=24;i<44;i=i+1) if(n[i]) shift=i-23;
            if(shift==0) round24=n;
            else begin
                // RNE: add half an ULP, minus one for an even retained bit,
                // then clear the discarded bits. Only the low 20 bits vary.
                step=21'd1<<shift;
                low_mask=step-1'b1;
                bias=n[shift] ? (step>>1) : (step>>1)-1'b1;
                rounded_integer=n+{23'b0,bias};
                round24=rounded_integer & ~{23'b0,low_mask};
            end
        end
    endfunction
    // One exact unsigned multiply and one binary32 rounding unit are shared
    // across the two components. Every original intermediate remains latched;
    // the additional setup cycles change no search decision or rounded value.
    wire product_a_cycle=state==PRODUCT_A || state==LAST_PRODUCT_A;
    wire product_b_cycle=state==PRODUCT_B || state==LAST_PRODUCT_B;
    wire [20:0] multiply_a=product_a_cycle ? {4'b0,abs_a} :
        product_b_cycle ? {4'b0,abs_b} :
        state==SQUARE_A ? product_a[20:0] : product_b[20:0];
    wire [20:0] multiply_b=(product_a_cycle || product_b_cycle) ? mid : multiply_a;
    wire [41:0] multiplied=multiply_a*multiply_b;
    wire [43:0] rounded=round24(round_input);
    assign query_ready=state==IDLE && !valid;
    always @(posedge clk) begin
        if(valid && ready) valid<=0;
        case(state)
        IDLE: if(query && query_ready) begin
            abs_a<=rzx[15] ? -$signed({rzx[15],rzx}) : {1'b0,rzx};
            abs_b<=rzy[15] ? -$signed({rzy[15],rzy}) : {1'b0,rzy};
            negative_a<=rzx[15];negative_b<=rzy[15];phase_y<=0;
            low<=0;high<=21'd1048576;empty<=rzx==0 && rzy==0;
            if(rzx==0 && rzy==0) begin zx<=0;zy<=0;pxx<=0;pyx<=0;valid<=1;end
            else state<=SEARCH;
        end
        SEARCH: if(low==high) begin mid<=low;state<=LAST_PRODUCT_A;end
                else begin mid<=low+((high-low)>>1);state<=PRODUCT_A;end
        PRODUCT_A: begin product_a<=multiplied[37:0];state<=PRODUCT_B;end
        PRODUCT_B: begin
            product_b<=multiplied[37:0];state<=SQUARE_A;
        end
        SQUARE_A: begin
            early_reached<=product_a>=limit || product_b>=limit;
            // If a component exceeds the radius the threshold is already true.
            // Otherwise the low 21 bits are exact, including before /4096.
            square_a<={2'b0,multiplied};state<=SQUARE_B;
        end
        SQUARE_B: begin square_b<={2'b0,multiplied};state<=ROUND_LOAD_A;end
        ROUND_LOAD_A: begin round_input<=square_a;state<=ROUND_A;end
        ROUND_A: begin rounded_a<=rounded;state<=ROUND_LOAD_B;end
        ROUND_LOAD_B: begin round_input<=square_b;state<=ROUND_B;end
        ROUND_B: begin rounded_b<=rounded;state<=ADD;end
        ADD: begin sum<=rounded_a+rounded_b;state<=TEST;end
        TEST: begin
            // Both squared thresholds are exactly representable binary32 with
            // an even significand. Their preceding float is 65536 integer
            // units lower, so the nearest/even midpoint is threshold-32768.
            if(early_reached || sum>=squared_limit-44'd32768) high<=mid;
            else low<=mid+1'b1;
            state<=SEARCH;
        end
        LAST_PRODUCT_A: begin product_a<=multiplied[37:0];state<=LAST_PRODUCT_B;end
        LAST_PRODUCT_B: begin product_b<=multiplied[37:0];state<=FINISH;end
        FINISH: if(!phase_y) begin
            zx<=mid;pxx<=negative_a ? -$signed(product_a[31:0]) : $signed(product_a[31:0]);
            phase_y<=1;low<=0;high<=21'd819200;state<=SEARCH;
        end else begin
            zy<=mid;pyx<=negative_b ? $signed(product_b[31:0]) : -$signed(product_b[31:0]);
            valid<=1;state<=IDLE;
        end
        endcase
        if(reset) begin
            state<=IDLE;valid<=0;empty<=1;zx<=0;zy<=0;pxx<=0;pyx<=0;
            phase_y<=0;negative_a<=0;negative_b<=0;early_reached<=0;
            abs_a<=0;abs_b<=0;low<=0;high<=0;mid<=0;
            product_a<=0;product_b<=0;square_a<=0;square_b<=0;rounded_a<=0;rounded_b<=0;sum<=0;round_input<=0;
        end
    end
endmodule
