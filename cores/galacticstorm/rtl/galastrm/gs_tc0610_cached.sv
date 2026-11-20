// SPDX-License-Identifier: BSD-3-Clause
// Affine renderer plus native indexed tile cache. External 64-bit read beats.
// pcb_mode selects the PCB-fitted full-register mapper instead of MAME's
// rotation/zoom rasterizer; the choice is latched per render.
module gs_tc0610_cached #(parameter STREAM_FILL=0)(
    input wire clk,reset,query,
    output wire query_ready,
    input wire signed [15:0] rzx,rzy,
    input wire pcb_mode,
    input wire [111:0] pcb_regs,
    output wire done,
    output wire mem_req,
    output wire [15:0] mem_addr,
    input wire mem_ack,
    input wire [63:0] mem_rdata,
    input wire mem_line_valid,
    input wire [2:0] mem_line_word,
    input wire [63:0] mem_line_data,
    output wire pixel_valid,
    input wire pixel_ready,
    output wire [8:0] pixel_y,pixel_x,
    output wire [15:0] pixel_index
);
    wire core_ready,cache_idle,tex_req,tex_ack;
    wire [17:0] tex_addr;
    wire [15:0] tex_data;
    wire mame_ready,mame_done,mame_req,mame_valid,pcb_ready,pcb_done,pcb_req,pcb_valid;
    wire [17:0] mame_addr,pcb_addr;
    wire [8:0] mame_y,mame_x,pcb_y,pcb_x;
    wire [15:0] mame_index,pcb_index;
    reg use_pcb;
    wire start=query && cache_idle && core_ready;
    always @(posedge clk) begin
        if(start) use_pcb<=pcb_mode;
        if(reset) use_pcb<=0;
    end
    assign core_ready=mame_ready && pcb_ready;
    assign query_ready=core_ready && cache_idle;
    assign done=mame_done || pcb_done;
    assign tex_req=use_pcb ? pcb_req : mame_req;
    assign tex_addr=use_pcb ? pcb_addr : mame_addr;
    assign pixel_valid=use_pcb ? pcb_valid : mame_valid;
    assign pixel_y=use_pcb ? pcb_y : mame_y;
    assign pixel_x=use_pcb ? pcb_x : mame_x;
    assign pixel_index=use_pcb ? pcb_index : mame_index;
    gs_tc0610 core(
        .clk(clk),.reset(reset),.query(start && !pcb_mode),.query_ready(mame_ready),
        .rzx(rzx),.rzy(rzy),.done(mame_done),.mem_req(mame_req),.mem_addr(mame_addr),
        .mem_ack(tex_ack && !use_pcb),.mem_rdata(tex_data),
        .pixel_valid(mame_valid),.pixel_ready(pixel_ready && !use_pcb),.pixel_y(mame_y),.pixel_x(mame_x),.pixel_index(mame_index));
    gs_tc0610_pcb pcb(
        .clk(clk),.reset(reset),.query(start && pcb_mode),.query_ready(pcb_ready),
        .regs(pcb_regs),.done(pcb_done),.mem_req(pcb_req),.mem_addr(pcb_addr),
        .mem_ack(tex_ack && use_pcb),.mem_rdata(tex_data),
        .pixel_valid(pcb_valid),.pixel_ready(pixel_ready && use_pcb),.pixel_y(pcb_y),.pixel_x(pcb_x),.pixel_index(pcb_index));
    gs_tc0610_cache #(.STREAM_FILL(STREAM_FILL),.PIPELINED_PIXELS(1)) cache(
        .clk(clk),.reset(reset),.invalidate(query && query_ready),.idle(cache_idle),
        .pixel_req(tex_req),.stream_pixels(use_pcb),.pixel_addr(tex_addr),.pixel_ack(tex_ack),.pixel_rdata(tex_data),
        .mem_req(mem_req),.mem_addr(mem_addr),.mem_ack(mem_ack),.mem_rdata(mem_rdata),
        .mem_line_valid(mem_line_valid),.mem_line_word(mem_line_word),.mem_line_data(mem_line_data));
endmodule
