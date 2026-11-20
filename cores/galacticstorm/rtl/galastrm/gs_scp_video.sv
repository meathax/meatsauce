// SPDX-License-Identifier: BSD-3-Clause
// SCP producer on the real shared snapshot read port and one held 64-bit ROM port.
module gs_scp_video #(parameter SPRITE_FIRST=0)(
    input wire cover_valid,cover_front,
    output wire probe_valid,cover_take,
    output wire [8:0] probe_x,probe_y,
    input wire clk,reset,
    output wire initialized,
    input wire cut,cpu_bus_idle,
    output wire cut_ready,cut_ack,
    input wire cpu_req,cpu_write,
    input wire [24:0] cpu_addr,
    input wire [15:0] cpu_wdata,
    input wire [1:0] cpu_bytes,
    output wire cpu_mapped,cpu_ack,
    output wire [15:0] cpu_rdata,
    input wire [4:0] aux_req,aux_wide,
    input wire [159:0] aux_addr,
    output wire [4:0] aux_ack,
    output wire [159:0] aux_rdata,
    input wire query,
    output wire query_ready,
    input wire [383:0] controls,
    // Optional source window: only TC0610-sampled texels need rendering.
    // window_enable=0 renders the complete 512x400 plane.
    input wire window_enable,
    input wire [8:0] window_x0,window_x1,window_y0,window_y1,
    input wire [1:0] sample_shift_x,sample_shift_y,
    input wire sample_rows_enable,sample_row_used,sample_row_ready,
    output wire [8:0] sample_y,
    output wire done,supported,
    output wire rom_req,
    output wire [20:0] rom_addr,
    input wire rom_ack,
    input wire [63:0] rom_rdata,
    output wire pixel_valid,
    input wire pixel_ready,
    output wire [8:0] pixel_x,pixel_y,
    output wire [15:0] pixel_index,
    output wire [3:0] pixel_priority
);
    wire [3:0] line_req,tile_req,lane_rom_req;
    wire [63:0] line_addr,tile_addr,line_data;
    wire [127:0] tile_data;
    wire [127:0] lane_rom_addr;
    wire [12:0] gpu_ack;
    wire [415:0] gpu_addr,gpu_data;
    assign gpu_addr[415:256]=aux_addr;
    assign aux_ack=gpu_ack[12:8];
    assign aux_rdata=gpu_data[415:256];
    wire [3:0] lane_rom_ack;
    reg [1:0] owner,next_owner;
    reg bus_req;
    reg [20:0] bus_addr;
    wire bus_ack;
    wire [63:0] bus_data;
    reg found;
    reg [1:0] selected;
    integer n,candidate;
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin: ports
        assign gpu_addr[lane*32 +: 32]={14'b0,2'd1,line_addr[lane*16 +: 16]};
        assign gpu_addr[(lane+4)*32 +: 32]={14'b0,2'd1,tile_addr[lane*16 +: 16]};
        assign line_data[lane*16 +: 16]=gpu_data[lane*32 +: 16];
        assign tile_data[lane*32 +: 32]=gpu_data[(lane+4)*32 +: 32];
        assign lane_rom_ack[lane]=bus_req && bus_ack && owner==lane;
    end endgenerate
    gs_video_ram memory(
        .clk(clk),.reset(reset),.initialized(initialized),
        .cut(cut),.cpu_bus_idle(cpu_bus_idle),.cut_ready(cut_ready),.cut_ack(cut_ack),
        .cpu_req(cpu_req),.cpu_write(cpu_write),.cpu_addr(cpu_addr),.cpu_wdata(cpu_wdata),
        .cpu_bytes(cpu_bytes),.cpu_mapped(cpu_mapped),.cpu_ack(cpu_ack),.cpu_rdata(cpu_rdata),
        .gpu_req({aux_req,tile_req,line_req}),.gpu_wide({aux_wide,4'b1111,4'b0}),.gpu_addr(gpu_addr),
        .gpu_ack(gpu_ack),.gpu_rdata(gpu_data));
    gs_scp_frame #(.WIDE_TILE(1),.PREFETCH(1),.SPRITE_FIRST(SPRITE_FIRST)) renderer(
        .cover_valid(cover_valid),.cover_front(cover_front),.probe_valid(probe_valid),
        .cover_take(cover_take),.probe_x(probe_x),.probe_y(probe_y),
        .clk(clk),.reset(reset),.query(query && initialized),.query_ready(query_ready),
        .controls(controls),.window_enable(window_enable),.window_x0(window_x0),.window_x1(window_x1),
        .window_y0(window_y0),.window_y1(window_y1),.done(done),.supported(supported),
        .sample_shift_x(sample_shift_x),.sample_shift_y(sample_shift_y),
        .sample_rows_enable(sample_rows_enable),.sample_row_used(sample_row_used),.sample_row_ready(sample_row_ready),.sample_y(sample_y),
        .line_mem_req(line_req),.line_mem_addr(line_addr),.line_mem_ack(gpu_ack[3:0]),.line_mem_rdata(line_data),
        .tile_mem_req(tile_req),.tile_mem_addr(tile_addr),.tile_mem_ack(gpu_ack[7:4]),.tile_mem_rdata(tile_data),
        .rom_req(lane_rom_req),.rom_addr(lane_rom_addr),.rom_ack(lane_rom_ack),.rom_rdata({4{bus_data}}),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .pixel_index(pixel_index),.pixel_priority(pixel_priority));
    always @* begin
        found=0;selected=0;
        for(n=0;n<4;n=n+1) begin
            candidate=(next_owner+n)&3;
            if(!found && lane_rom_req[candidate]) begin found=1;selected=candidate[1:0];end
        end
    end
    gs_rom64_cache cache(
        .clk(clk),.reset(reset),.req(bus_req),.address(bus_addr),.ack(bus_ack),.data(bus_data),
        .raw_req(rom_req),.raw_address(rom_addr),.raw_ack(rom_ack),.raw_data(rom_rdata));
    always @(posedge clk) begin
        if(bus_req) begin
            if(bus_ack) begin bus_req<=0;next_owner<=owner+1'b1;end
        end else if(found) begin
            owner<=selected;bus_addr<=lane_rom_addr[selected*32 +: 21];bus_req<=1;
        end
        if(reset) begin bus_req<=0;bus_addr<=0;owner<=0;next_owner<=0;end
    end
endmodule
