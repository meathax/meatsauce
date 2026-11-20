// SPDX-License-Identifier: BSD-3-Clause
// PCB-fitted TC0610 mapping: every visible output pixel reads source texel
//   u = r0/16 + (r2*x + r4*y)/4096,  v = r1/16 + (r3*x + r5*y)/4096
// with x=X+PX, y=Y+PY (X,Y visible coordinates). Accumulators are 24-bit in
// 1/4096-pixel units, so register words wrap like 16-bit r0/r1. Identity
// registers (-240,1072,4096,0,0,4096) map each pixel to itself.
// r7==0 selects the ordinary rotation matrix [r2,-r3;r3,r2], not bypass.
// Its register-space pivot (215,137) corresponds to visible centre (160,116).
// Constants come from fitting PCB footage (build/rot_cmp/fit, fit B, k=16).
// Pixels whose texel lies outside the source window are index 0.
module gs_tc0610_pcb #(
    parameter integer PX=67, PY=22,
    parameter integer SX0=40, SX1=446, SY0=0, SY1=400
)(
    input wire clk,reset,query,
    output wire query_ready,
    input wire [111:0] regs, // {r7,r5,r4,r3,r2,r1,r0}
    output reg done,
    output wire mem_req,
    output reg [17:0] mem_addr,
    input wire mem_ack,
    input wire [15:0] mem_rdata,
    output wire pixel_valid,
    input wire pixel_ready,
    output reg [8:0] pixel_y,pixel_x,
    output reg [15:0] pixel_index
);
    localparam IDLE=0,SETUP=1,FETCH=3,DRAIN=4;
    reg output_valid;
    reg [8:0] walk_x,walk_y;
    localparam integer UB_OFFSET=15-PX+96, VB_OFFSET=-67-PY+84;
    reg [2:0] state;
    reg signed [15:0] r0,r1,r2,r3,r4,r5;
    reg ordinary;
    reg [23:0] u,v,u_row,v_row;
    wire signed [11:0] u_int=u[23:12],v_int=v[23:12];
    localparam signed [12:0] UB_OFF=UB_OFFSET[12:0],VB_OFF=VB_OFFSET[12:0];
    localparam signed [12:0] WX0=SX0[12:0],WX1=SX1[12:0],WY0=SY0[12:0],WY1=SY1[12:0];
    wire signed [12:0] ub={u_int[11],u_int}+(ordinary ? 13'sd56 : UB_OFF);
    wire signed [12:0] vb={v_int[11],v_int}+(ordinary ? -13'sd4 : VB_OFF);
    wire in_window=ub>=WX0 && ub<WX1 && vb>=WY0 && vb<WY1;
    wire signed [23:0] px_s=ordinary ? 24'sd55 : PX[23:0],py_s=ordinary ? 24'sd21 : PY[23:0];
    wire signed [23:0] u_origin=$signed({r0,8'b0})+r2*px_s+r4*py_s;
    wire signed [23:0] v_origin=$signed({r1,8'b0})+r3*px_s+r5*py_s;
    wire [23:0] u_next_row=u_row+{{8{r4[15]}},r4},v_next_row=v_row+{{8{r5[15]}},r5};
    assign query_ready=state==IDLE;
    // Coordinates remain held through arbitrary memory stalls. Decode the
    // registered accumulators directly, without a CALC clock for every pixel.
    always @* mem_addr={vb[8:0],ub[8:0]};
    wire output_room=!output_valid || pixel_ready;
    assign mem_req=state==FETCH && output_room && in_window;
    assign pixel_valid=output_valid;
    always @(posedge clk) begin
        done<=0;
        if(output_valid && pixel_ready) output_valid<=0;
        case(state)
        IDLE: if(query) begin
            ordinary<=regs[111:96]==0;
            r0<=regs[15:0];r1<=regs[31:16];r2<=regs[47:32];r3<=regs[63:48];
            r4<=regs[111:96]!=0 ? regs[79:64] : -regs[63:48];
            r5<=regs[111:96]!=0 ? regs[95:80] : regs[47:32];
            state<=SETUP;
        end
        SETUP: begin
            u_row<=u_origin;v_row<=v_origin;u<=u_origin;v<=v_origin;
            walk_x<=96;walk_y<=84;state<=FETCH;
        end
        // One elastic output slot lets the next cached texel arrive on the
        // same edge that retires the previous pixel. Misses retain coordinates.
        FETCH: if(output_room && (!in_window || mem_ack)) begin
            output_valid<=1;pixel_x<=walk_x;pixel_y<=walk_y;
            pixel_index<=in_window ? mem_rdata:16'b0;
            if(walk_x==415) begin
                walk_x<=96;
                if(walk_y==315) state<=DRAIN;
                else begin
                    walk_y<=walk_y+1'b1;
                    u_row<=u_next_row;v_row<=v_next_row;u<=u_next_row;v<=v_next_row;
                end
            end else begin
                walk_x<=walk_x+1'b1;
                u<=u+{{8{r2[15]}},r2};v<=v+{{8{r3[15]}},r3};
            end
        end
        DRAIN: if(output_valid && pixel_ready) begin done<=1;state<=IDLE;end
        endcase
        if(reset) begin
            state<=IDLE;done<=0;output_valid<=0;walk_x<=96;walk_y<=84;pixel_x<=96;pixel_y<=84;pixel_index<=0;ordinary<=0;
            u<=0;v<=0;u_row<=0;v_row<=0;r0<=0;r1<=0;r2<=0;r3<=0;r4<=0;r5<=0;
        end
    end
endmodule
