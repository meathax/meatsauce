// SPDX-License-Identifier: BSD-3-Clause
// Native sprite snapshot -> ordered external-memory band arena.
module gs_sprite_frame #(parameter SPLIT_PLANES=0,parameter WINDOW_CLIP=0)(
    input wire clk,reset,start,
    output wire start_ready,
    output reg busy,done,
    output wire overflow,
    output wire [14:0] descriptor_count,
    output wire [17:0] node_count,
    output wire sprite_mem_req,
    output wire [13:0] sprite_mem_addr,
    input wire sprite_mem_ack,
    input wire [31:0] sprite_mem_rdata,
    input wire window_enable,
    input wire [8:0] window_x0,window_x1,window_y0,window_y1,
    output wire map_req,
    output wire [17:0] map_word_addr,
    input wire map_ack,
    input wire [15:0] map_rdata,
    output wire arena_req,arena_write,arena_wide,
    output wire [19:0] arena_addr,
    output wire [63:0] arena_wdata,
    input wire arena_ack,
    input wire [63:0] arena_rdata,
    input wire query,
    input wire [5:0] query_band,
    input wire query_direct,
    output wire query_ready,query_done,
    output wire output_valid,
    input wire output_ready,
    output wire [63:0] output_descriptor
);
    localparam IDLE=0,WAIT_CLEAR=1,LAUNCH=2,SCAN=3,DRAIN=4,SEAL=5,FINISH=6;
    reg [2:0] state;
    wire scanner_busy,scanner_done,build_ready,sealed,store_query_ready,store_start_ready;
    assign query_ready=state==IDLE && store_query_ready;
    assign start_ready=state==IDLE && store_start_ready && !query;
    wire descriptor_valid,descriptor_ready;
    wire [14:0] code;
    wire [7:0] color;
    wire [1:0] sprite_priority;
    wire flipx,flipy;
    wire signed [11:0] x,y;
    wire [6:0] width,height;
    wire [63:0] descriptor={3'b0,height,width,y[9:0],x[9:0],flipy,flipx,sprite_priority,color,code};
    gs_sprite_scan #(.WINDOW_CLIP(WINDOW_CLIP)) scanner(
        .clk(clk),.reset(reset),.start(state==LAUNCH),.busy(scanner_busy),.done(scanner_done),
        .sprite_mem_req(sprite_mem_req),.sprite_mem_addr(sprite_mem_addr),
        .sprite_mem_ack(sprite_mem_ack),.sprite_mem_rdata(sprite_mem_rdata),
        .window_enable(window_enable),.window_x0(window_x0),.window_x1(window_x1),.window_y0(window_y0),.window_y1(window_y1),
        .map_req(map_req),.map_word_addr(map_word_addr),.map_ack(map_ack),.map_rdata(map_rdata),
        .descriptor_valid(descriptor_valid),.descriptor_ready(descriptor_ready),
        .record_index(),.chunk_index(),.code(code),.color(color),.sprite_priority(sprite_priority),
        .flipx(flipx),.flipy(flipy),.x(x),.y(y),.width(width),.height(height)
    );
    gs_sprite_bins #(.SPLIT_PLANES(SPLIT_PLANES)) candidate_store(
        .clk(clk),.reset(reset),.start(start && start_ready),.seal(state==SEAL),
        .start_ready(store_start_ready),
        .build_ready(build_ready),.sealed(sealed),.overflow(overflow),
        .descriptor_valid(descriptor_valid),.descriptor_ready(descriptor_ready),.descriptor(descriptor),
        .descriptor_count(descriptor_count),.node_count(node_count),
        .query(query && state==IDLE),.query_band(query_band),.query_direct(query_direct),.query_ready(store_query_ready),.query_done(query_done),
        .output_valid(output_valid),.output_ready(output_ready),.output_descriptor(output_descriptor),
        .mem_req(arena_req),.mem_write(arena_write),.mem_wide(arena_wide),.mem_addr(arena_addr),
        .mem_wdata(arena_wdata),.mem_ack(arena_ack),.mem_rdata(arena_rdata)
    );
    always @(posedge clk) begin
        done<=0;
        case(state)
        IDLE: if(start && start_ready) begin state<=WAIT_CLEAR;busy<=1;end
        WAIT_CLEAR: if(build_ready) state<=LAUNCH;
        LAUNCH: state<=SCAN;
        SCAN: if(scanner_done) state<=DRAIN;
        DRAIN: if(build_ready) state<=SEAL;
        SEAL: state<=FINISH;
        FINISH: if(sealed) begin busy<=0;done<=1;state<=IDLE;end
        endcase
        if(reset) begin state<=IDLE;busy<=0;done<=0;end
    end
endmodule
