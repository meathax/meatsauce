// SPDX-License-Identifier: BSD-3-Clause
// Source rectangle sampled by gs_tc0610_pcb for one register set, so the
// source pass renders only that area (as the MAME-mode window does).
// The mapper reads u = r0*256 + r2*x + r4*y (1/4096 px, x=X+PX, y=Y+PY) for
// visible X 0..319, Y 0..231. About the centre X=160,Y=116 every pixel lies
// within C +/- R, with C = r0*256 + r2*(160+PX) + r4*(116+PY) and
// R = 160|r2| + 116|r4| (likewise v from r1/r3/r5). The 24-bit accumulator
// wraps at +/-2^23: when C +/- R stays inside that range no pixel wraps and
// the bounding box is exact (plus MARGIN); otherwise the full plane is used.
// One shared multiplier, two clocks per term, about 25 clocks per frame.
module gs_tc0610_pcb_window #(
    parameter integer PX=67, PY=22,
    parameter integer SX0=40, SX1=446, SY0=0, SY1=400, MARGIN=2
)(
    input wire clk,reset,start,
    input wire [111:0] regs, // {r7,r5,r4,r3,r2,r1,r0}
    output wire busy,
    output reg enable,
    output reg [8:0] x0,x1,y0,y1
);
    localparam integer UB_OFFSET=15-PX+96, VB_OFFSET=-67-PY+84;
    localparam integer KXI=160+PX, KYI=116+PY;
    localparam [8:0] KC=9'd256, KX=KXI[8:0], KY=KYI[8:0];
    localparam signed [15:0] UB_OFF=UB_OFFSET[15:0], VB_OFF=VB_OFFSET[15:0], PAD=MARGIN[15:0];
    localparam signed [15:0] X_LOW=SX0[15:0], X_HIGH=SX1[15:0]-16'sd1, Y_LOW=SY0[15:0], Y_HIGH=SY1[15:0]-16'sd1;
    localparam signed [27:0] WRAP_LO=-28'sd8388608, WRAP_HI=28'sd8388608;
    reg signed [15:0] r0,r1,r2,r3,r4,r5;
    reg ordinary;
    reg [3:0] step;
    reg phase,running,finish;
    reg signed [27:0] acc,cu,ru,cv;
    reg signed [26:0] product;
    assign busy=running || finish;
    function automatic signed [16:0] mag(input signed [15:0] value);
        mag=value[15] ? -{value[15],value} : {1'b0,value};
    endfunction
    // Term list: Cu = r0*256 + r2*KX + r4*KY, Ru = |r2|*160 + |r4|*116, then v.
    reg signed [16:0] operand;
    reg [8:0] factor;
    always @* begin
        case(step)
        4'd0: begin operand={r0[15],r0}; factor=KC; end
        4'd1: begin operand={r2[15],r2}; factor=ordinary ? 9'd215 : KX[8:0]; end
        4'd2: begin operand={r4[15],r4}; factor=ordinary ? 9'd137 : KY[8:0]; end
        4'd3: begin operand=mag(r2); factor=9'd160; end
        4'd4: begin operand=mag(r4); factor=9'd116; end
        4'd5: begin operand={r1[15],r1}; factor=KC; end
        4'd6: begin operand={r3[15],r3}; factor=ordinary ? 9'd215 : KX[8:0]; end
        4'd7: begin operand={r5[15],r5}; factor=ordinary ? 9'd137 : KY[8:0]; end
        4'd8: begin operand=mag(r3); factor=9'd160; end
        default: begin operand=mag(r5); factor=9'd116; end
        endcase
    end
    // Convert a centre/reach pair into a clipped inclusive texel range.
    function automatic [18:0] span(input signed [27:0] centre, input signed [27:0] reach,
                                   input signed [15:0] offset, input signed [15:0] low, input signed [15:0] last_allowed);
        reg signed [27:0] wrapped,lo,hi;
        reg signed [15:0] first,last;
        begin
            wrapped={{4{centre[23]}},centre[23:0]};
            lo=wrapped-reach; hi=wrapped+reach;
            first=$signed(lo[27:12])+offset-PAD; last=$signed(hi[27:12])+offset+PAD;
            if(first<low) first=low;
            if(last>last_allowed) last=last_allowed;
            if(first>last) begin first=low; last=low; end
            span={lo>=WRAP_LO && hi<WRAP_HI,first[8:0],last[8:0]};
        end
    endfunction
    reg [18:0] span_u,span_v;
    always @* begin
        span_u=span(cu,ru,ordinary ? 16'sd56 : UB_OFF,X_LOW,X_HIGH);
        span_v=span(cv,acc,ordinary ? -16'sd4 : VB_OFF,Y_LOW,Y_HIGH);
    end
    always @(posedge clk) begin
        if(start) begin
            ordinary<=regs[111:96]==0;
            r0<=regs[15:0];r1<=regs[31:16];r2<=regs[47:32];r3<=regs[63:48];
            r4<=regs[111:96]!=0 ? regs[79:64] : -regs[63:48];
            r5<=regs[111:96]!=0 ? regs[95:80] : regs[47:32];
            step<=0;phase<=0;acc<=0;running<=1;finish<=0;
        end else if(running) begin
            if(!phase) begin
                product<=operand*$signed({1'b0,factor});
                phase<=1;
            end else begin
                phase<=0;
                case(step)
                4'd2: begin cu<=acc+product; acc<=0; end
                4'd4: begin ru<=acc+product; acc<=0; end
                4'd7: begin cv<=acc+product; acc<=0; end
                default: acc<=acc+product;
                endcase
                if(step==4'd9) begin running<=0;finish<=1; end
                else step<=step+1'b1;
            end
        end else if(finish) begin
            finish<=0;
            enable<=span_u[18] && span_v[18];
            x0<=span_u[17:9];x1<=span_u[8:0];y0<=span_v[17:9];y1<=span_v[8:0];
        end
        if(reset) begin
            running<=0;finish<=0;phase<=0;step<=0;acc<=0;cu<=0;ru<=0;cv<=0;product<=0;
            enable<=0;x0<=0;x1<=0;y0<=0;y1<=0;r0<=0;r1<=0;r2<=0;r3<=0;r4<=0;r5<=0;
        end
    end
endmodule
