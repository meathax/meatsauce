// SPDX-License-Identifier: BSD-3-Clause
// Native finite-normal float32 route sum. Operand ordering, sticky alignment,
// signed addition and rounded normalization occupy separate pipeline stages.
module gs_audio_add_pipe(
    input wire clk,reset,req,input wire [31:0] a,b,output wire valid,output wire [31:0] value
);
    reg [31:0] larger,smaller;
    reg v1,v2,v3,sign2,sign3,subtract2;
    reg [27:0] left2,right2;
    reg [28:0] magnitude3;
    reg signed [10:0] base2,base3;
    wire [7:0] distance=larger[30:23]-smaller[30:23];
    wire [27:0] small_value=smaller[30:23]==0 ? 0:{1'b0,1'b1,smaller[22:0],3'b000};
    wire [27:0] sticky_mask=(28'd1<<distance[4:0])-1'b1;
    wire [27:0] aligned=distance>=28 ? (small_value!=0):(small_value>>distance[4:0])|((small_value&sticky_mask)!=0);
    always @(posedge clk)begin
        v1<=req;v2<=v1;v3<=v2;
        larger<=a[30:0]>=b[30:0] ? a:b;smaller<=a[30:0]>=b[30:0] ? b:a;
        left2<=larger[30:23]==0 ? 0:{1'b0,1'b1,larger[22:0],3'b000};right2<=aligned;
        subtract2<=larger[31]!=smaller[31];sign2<=larger[31];base2<=$signed({1'b0,larger[30:23]})-11'sd153;
        magnitude3<=subtract2 ? {1'b0,left2}-{1'b0,right2}:{1'b0,left2}+{1'b0,right2};
        base3<=base2;sign3<=sign2;
        if(reset)begin v1<=0;v2<=0;v3<=0;end
    end
    gs_audio_pack_pipe #(.MW(29)) normalizer(.clk(clk),.reset(reset),.req(v3),.sign(sign3),.magnitude(magnitude3),.base(base3),.valid(valid),.value(value));
endmodule
