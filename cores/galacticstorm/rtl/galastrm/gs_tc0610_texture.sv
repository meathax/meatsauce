// SPDX-License-Identifier: BSD-3-Clause
// Galastrm source shader: signed 16.16 nearest texel and wrapping 32-bit adds.
// Held indexed-surface read port. A shared burst/cache adapter follows separately.
module gs_tc0610_texture(
    input wire clk,reset,extent_valid,
    output wire extent_ready,
    input wire [8:0] extent_y,
    input wire [9:0] start_x,stop_x,
    input wire signed [31:0] u,v,du,dv,
    output wire mem_req,
    output reg [17:0] mem_addr,
    input wire mem_ack,
    input wire [15:0] mem_rdata,
    output wire pixel_valid,
    input wire pixel_ready,
    output reg [8:0] pixel_y,
    output reg [8:0] pixel_x,
    output reg [15:0] pixel_index
);
    localparam IDLE=0,ADDRESS=1,FETCH=2,OUTPUT_PIXEL=3;
    reg [1:0] state;
    reg signed [31:0] current_u,current_v,step_u,step_v;
    reg [9:0] last_x;
    wire signed [31:0] texel_x={{16{current_u[31]}},current_u[31:16]};
    wire signed [31:0] texel_y={{16{current_v[31]}},current_v[31:16]};
    wire signed [31:0] linear_address=(texel_y<<<9)+texel_x;
    assign extent_ready=state==IDLE;
    assign mem_req=state==FETCH;
    assign pixel_valid=state==OUTPUT_PIXEL;
    always @(posedge clk) begin
        case(state)
        IDLE: if(extent_valid && extent_ready && start_x<stop_x) begin
            pixel_x<=start_x[8:0];pixel_y<=extent_y;last_x<=stop_x;
            current_u<=u;current_v<=v;step_u<=du;step_v<=dv;state<=ADDRESS;
        end
        ADDRESS: begin mem_addr<=linear_address[17:0];state<=FETCH;end
        FETCH: if(mem_ack) begin pixel_index<=mem_rdata;state<=OUTPUT_PIXEL;end
        OUTPUT_PIXEL: if(pixel_ready) begin
            if({1'b0,pixel_x}+10'd1>=last_x) state<=IDLE;
            else begin
                pixel_x<=pixel_x+1'b1;current_u<=current_u+step_u;current_v<=current_v+step_v;
                state<=ADDRESS;
            end
        end
        endcase
        if(reset) begin
            state<=IDLE;current_u<=0;current_v<=0;step_u<=0;step_v<=0;last_x<=0;
            mem_addr<=0;pixel_x<=0;pixel_y<=0;pixel_index<=0;
        end
    end
endmodule
