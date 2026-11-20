// SPDX-License-Identifier: BSD-3-Clause
// Native ES5505 normalization and float32 (percent/32)*0.18 route gain.
// One multiplier serves all eight lanes. AUX retains native float precision;
// FX1/FX2/DRY are truncated to signed16 exactly at the native ESP boundary.
module gs_audio_input(
    input wire clk,reset,req,input wire [159:0] channels,
    input wire [6:0] gain_l,gain_r,
    output reg ack,valid,output wire busy,
    output reg [127:0] serial_input,output reg [31:0] aux_l,aux_r
);
    `include "gs_audio_float.svh"
    `include "gs_audio_gain_table.svh"
    localparam IDLE=0,SELECT=1,MULTIPLY=2,ROUND=3,ROUND_WAIT=4,STORE=5,OUTPUT=6;
    reg [2:0] state=IDLE,lane;
    reg seen=0,sign;
    reg [159:0] saved_channels;
    reg [6:0] saved_l,saved_r;
    reg [19:0] magnitude;
    reg [31:0] coefficient,value;
    reg [43:0] product;
    wire norm_valid;
    wire [31:0] norm_value;
    gs_audio_pack_pipe #(.MW(44)) normalizer(.clk(clk),.reset(reset),.req(state==ROUND),.sign(sign),
        .magnitude(product),.base($signed({1'b0,coefficient[30:23]})-11'sd169),.valid(norm_valid),.value(norm_value));
    wire signed [19:0] raw=saved_channels[20*lane +:20];
    assign busy=state!=IDLE;
    always @(posedge clk)begin
        ack<=0;valid<=0;if(!req)seen<=0;
        case(state)
        IDLE:if(req && !seen)begin saved_channels<=channels;saved_l<=gain_l;saved_r<=gain_r;seen<=1;ack<=1;lane<=0;state<=SELECT;end
        SELECT:begin magnitude<=raw[19] ? -raw:raw;sign<=raw[19];coefficient<=gs_audio_gain(lane[0] ? saved_r:saved_l);state<=MULTIPLY;end
        MULTIPLY:begin product<=coefficient==0 ? 44'd0:magnitude*{1'b1,coefficient[22:0]};state<=ROUND;end
        ROUND:state<=ROUND_WAIT;
        ROUND_WAIT:if(norm_valid)begin value<=norm_value;state<=STORE;end
        STORE:begin
            serial_input[16*lane +:16]<=gs_audio_pcm(value);
            if(lane==0)aux_l<=value;if(lane==1)aux_r<=value;
            if(lane==7)state<=OUTPUT;else begin lane<=lane+1'b1;state<=SELECT;end
        end
        OUTPUT:begin valid<=1;state<=IDLE;end
        endcase
        if(reset)begin state<=IDLE;seen<=0;ack<=0;valid<=0;serial_input<=0;aux_l<=0;aux_r<=0;lane<=0;end
    end
endmodule
