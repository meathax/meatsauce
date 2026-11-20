// SPDX-License-Identifier: BSD-3-Clause
// Native pump gain and processed+AUX float32 sum. Four products share one
// pipelined normalizer and both channels share one pipelined adder; this avoids
// replicating the long alignment/rounding datapath for every route.
module gs_audio_output(
    input wire clk,reset,req,input wire signed [15:0] processed_l,processed_r,
    input wire [31:0] aux_l,aux_r,input wire [6:0] gain_l,gain_r,
    output reg ack,valid,output wire busy,output reg signed [15:0] pcm_l,pcm_r
);
    `include "gs_audio_float.svh"
    localparam IDLE=0,MULTIPLY=1,NORM_START=2,NORM_WAIT=3,ADD_START=4,ADD_WAIT=5,OUTPUT=6;
    reg [2:0] state=IDLE;
    reg seen=0;
    reg [31:0] saved_aux_l,saved_aux_r;
    reg [6:0] saved_gain_l,saved_gain_r;
    reg [22:0] processed_product_l,processed_product_r;
    reg [30:0] aux_product_l,aux_product_r;
    reg sign_l,sign_r,channel;
    reg [1:0] norm_index;
    reg [31:0] normalized[0:3];
    wire [15:0] abs_l=processed_l[15] ? -processed_l:processed_l;
    wire [15:0] abs_r=processed_r[15] ? -processed_r:processed_r;
    wire [30:0] norm_magnitude=norm_index==0 ? {8'b0,processed_product_l}:norm_index==1 ? {8'b0,processed_product_r}:norm_index==2 ? aux_product_l:aux_product_r;
    wire norm_sign=norm_index==0 ? sign_l:norm_index==1 ? sign_r:norm_index==2 ? saved_aux_l[31]:saved_aux_r[31];
    wire signed [10:0] norm_base=norm_index<2 ? -11'sd21:$signed({1'b0,(norm_index==2 ? saved_aux_l[30:23]:saved_aux_r[30:23])})-11'sd156;
    wire norm_valid,add_valid;
    wire [31:0] norm_value,add_value;
    gs_audio_pack_pipe #(.MW(31)) normalizer(.clk(clk),.reset(reset),.req(state==NORM_START),.sign(norm_sign),.magnitude(norm_magnitude),.base(norm_base),.valid(norm_valid),.value(norm_value));
    gs_audio_add_pipe adder(.clk(clk),.reset(reset),.req(state==ADD_START),.a(normalized[channel ? 1:0]),.b(normalized[channel ? 3:2]),.valid(add_valid),.value(add_value));
    assign busy=state!=IDLE;
    always @(posedge clk)begin
        ack<=0;valid<=0;if(!req)seen<=0;
        case(state)
        IDLE:if(req && !seen)begin
            saved_aux_l<=aux_l;saved_aux_r<=aux_r;saved_gain_l<=gain_l;saved_gain_r<=gain_r;
            processed_product_l<=abs_l*gain_l;processed_product_r<=abs_r*gain_r;
            sign_l<=processed_l[15];sign_r<=processed_r[15];seen<=1;ack<=1;state<=MULTIPLY;
        end
        MULTIPLY:begin
            aux_product_l<=(saved_aux_l[30:23]==0 ? 24'd0:{1'b1,saved_aux_l[22:0]})*saved_gain_l;
            aux_product_r<=(saved_aux_r[30:23]==0 ? 24'd0:{1'b1,saved_aux_r[22:0]})*saved_gain_r;
            norm_index<=0;channel<=0;state<=NORM_START;
        end
        NORM_START:state<=NORM_WAIT;
        NORM_WAIT:if(norm_valid)begin
            normalized[norm_index]<=norm_value;
            if(norm_index==3)state<=ADD_START;
            else begin norm_index<=norm_index+1'b1;state<=NORM_START;end
        end
        ADD_START:state<=ADD_WAIT;
        ADD_WAIT:if(add_valid)begin
            if(channel)begin pcm_r<=gs_audio_pcm(add_value);state<=OUTPUT;end
            else begin pcm_l<=gs_audio_pcm(add_value);channel<=1;state<=ADD_START;end
        end
        OUTPUT:begin valid<=1;state<=IDLE;end
        endcase
        if(reset)begin state<=IDLE;seen<=0;ack<=0;valid<=0;pcm_l<=0;pcm_r<=0;norm_index<=0;channel<=0;end
    end
endmodule
