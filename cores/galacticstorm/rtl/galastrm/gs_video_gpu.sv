// SPDX-License-Identifier: BSD-3-Clause
module gs_video_gpu #(parameter PRESENT_15K=0,parameter RASTER_RESET_Y=0,parameter CURRENT_TEXT=0,parameter ROM_RESET_SEPARATE=0,parameter FLIP_SUPPORT=0,parameter LINE_WRITES=0)(
    input wire clk,reset,rom_reset,screen_flip,
    output wire initialized,
    input wire cut,cpu_bus_idle,
    output wire cut_ready,cut_ack,
    input wire cpu_req,cpu_write,
    input wire [24:0] cpu_addr,
    input wire [15:0] cpu_wdata,
    input wire [1:0] cpu_bytes,
    input wire cpu_write_line,input wire [63:0] cpu_wline,
    output wire cpu_mapped,cpu_ack,
    output wire [15:0] cpu_rdata,
    input wire query,bank,
    output wire query_ready,
    input wire [383:0] controls,
    input wire [127:0] scn_controls,
    input wire current_restart,
    input wire signed [15:0] rzx,rzy,
    input wire affine_pcb,
    input wire [111:0] affine_regs,
    output reg done,done_bank,
    output wire [1:0] presentable,
    output wire supported,overflow,
    output wire scp_rom_req,
    output wire [20:0] scp_rom_addr,
    output wire scp_rom_ack,
    output wire [63:0] scp_rom_rdata,
    output wire sprite_rom_req,
    output wire [21:0] sprite_rom_addr,
    output wire sprite_rom_ack,sprite_rom_rvalid,
    output wire [63:0] sprite_rom_rdata,
    output wire map_req,
    output wire [17:0] map_word_addr,
    output wire map_ack,
    output wire [15:0] map_rdata,
    output wire arena_req,arena_write,arena_wide,
    output wire [19:0] arena_addr,
    output wire [63:0] arena_wdata,
    output wire arena_ack,
    output wire [63:0] arena_rdata,
    input wire display_start,display_bank,visible_pixel_ce,raster_run,
    output wire native_frame_cut,native_visible_ce,
    output wire native_pixel_ce,output wire [8:0] native_x,native_y,
    output wire scan_valid,scan_underflow,scan_busy,
    output wire [15:0] scan_index,
    input wire host_req,host_write,
    input wire [24:0] host_addr,
    input wire [15:0] host_wdata,
    input wire [1:0] host_bytes,
    input wire host_write_line,input wire [63:0] host_wline,
    output wire host_ack,
    output wire [15:0] host_rdata,
    output wire [63:0] host_rline,
    inout wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nCS,SDRAM_nWE,
    output wire SDRAM_nRAS,SDRAM_nCAS,SDRAM_CKE,SDRAM_CLK,
    input wire DDRAM_BUSY,
    output wire [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input wire [63:0] DDRAM_DOUT,
    input wire DDRAM_DOUT_READY,
    output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,
    output wire [7:0] DDRAM_BE,
    output wire DDRAM_WE,
    output wire surface_req,surface_write,
    output wire [24:0] surface_addr,
    output wire [63:0] surface_wdata,
    output wire [7:0] surface_bytes,
    output wire surface_ack,
    output wire [63:0] surface_rdata
);
    wire display_req,scan_bank,display_ack;
    wire [15:0] display_addr;
    wire [14:0] display_ordinal;
    wire [63:0] display_data;
    wire [3:0] rom_ack;
    gs_sdram #(.CACHE_RESET_SEPARATE(ROM_RESET_SEPARATE),.WRITE_LINES(LINE_WRITES)) roms(
        .clk(clk),.reset(ROM_RESET_SEPARATE ? rom_reset : reset),.cache_reset(reset),.req({map_req,sprite_rom_req,scp_rom_req,host_req}),
        .cpu_write(host_write),.cpu_addr(host_addr),.cpu_wdata(host_wdata),.cpu_bytes(host_bytes),.cpu_write_line(host_write_line),.cpu_wline(host_wline),
        .scp_addr(scp_rom_addr),.sprite_addr(sprite_rom_addr),.map_word_addr(map_word_addr),
        .ack(rom_ack),.cpu_rdata(host_rdata),.cpu_rline(host_rline),.scp_rdata(scp_rom_rdata),.sprite_rdata(sprite_rom_rdata),.sprite_rvalid(sprite_rom_rvalid),.map_rdata(map_rdata),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS),.SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE),.SDRAM_CLK(SDRAM_CLK));
    assign host_ack=rom_ack[0];
    assign scp_rom_ack=rom_ack[1];
    assign sprite_rom_ack=rom_ack[2];
    assign map_ack=rom_ack[3];
    wire memory_req,memory_write,memory_ack,memory_busy;
    wire surface_line,memory_line,line_valid;
    wire [2:0] line_word;
    wire [63:0] line_data;
    wire [24:0] memory_addr;
    wire [63:0] memory_wdata,memory_rdata,client_rdata;
    wire [7:0] memory_bytes;
    wire [1:0] client_ack;
    wire [2:0] arena_lane=arena_addr[2:0];
    wire [63:0] arena_word=arena_wdata<<(arena_lane*8);
    wire [7:0] arena_bytes=(arena_wide?8'hff:8'h0f)<<arena_lane;
    gs_memory_arb2 #(.STREAM_LINES(CURRENT_TEXT),.DIRECT_GRANT(1),.COMBINATIONAL_GRANT(1)) clients(
        .clk(clk),.reset(reset),.req({arena_req,surface_req}),.write({arena_write,surface_write}),
        .line_read({1'b0,surface_line}),.mem_line_read(memory_line),
        .urgent0(surface_line || (surface_req && !surface_write && surface_addr[24:20]==5'h13)),
        .addr({(25'h1500000+{5'b0,arena_addr[19:3],3'b0}),surface_addr}),
        .wdata({arena_word,surface_wdata}),.bytes({arena_bytes,surface_bytes}),
        .ack(client_ack),.rdata(client_rdata),.mem_req(memory_req),.mem_write(memory_write),
        .mem_addr(memory_addr),.mem_wdata(memory_wdata),.mem_bytes(memory_bytes),
        .mem_ack(memory_ack),.mem_busy(memory_busy),.mem_rdata(memory_rdata));
    assign surface_ack=client_ack[0];
    assign surface_rdata=client_rdata;
    assign arena_ack=client_ack[1];
    assign arena_rdata=client_rdata>>(arena_lane*8);
    // Preserve the 16 KiB graphics working set; put tags in synchronous RAM.
    gs_ddr_surface #(.CACHE_BITS(6),.TAG_RAM(1),.TAG_M10K(1),.STREAM_LINES(CURRENT_TEXT),.FAST_RETIRE(1)) memory(
        .clk(clk),.reset(reset),.req(memory_req),.write(memory_write),.addr(memory_addr),
        .stream_line(memory_line),.line_valid(line_valid),.line_word(line_word),.line_data(line_data),
        .wdata(memory_wdata),.bytes(memory_bytes),.ack(memory_ack),.rdata(memory_rdata),.busy(memory_busy),
        .DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT),.DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE));
    wire native_ce,native_visible;
    reg display_enabled;
    gs_raster #(.PRESENT_15K(PRESENT_15K),.RESET_Y(RASTER_RESET_Y)) raster(
        .clk(clk),.reset(reset || !raster_run),.pixel_ce(native_ce),.x(native_x),.y(native_y),
        .visible(native_visible),.frame_cut(native_frame_cut),.frame_start());
    always @(posedge clk) begin
        if(display_start) display_enabled<=1;
        if(reset || !raster_run) display_enabled<=0;
    end
    assign native_visible_ce=native_ce && native_visible && display_enabled;
    assign native_pixel_ce=native_ce;
    // Base and overlay fetches share DDR with both rendering actors. Buffer
    // more than a visible line so a long outstanding producer read cannot
    // consume all scanout headroom before its two-plane refill completes.
    gs_indexed_scanout #(.FIFO_BITS(7),.FLIP_SUPPORT(FLIP_SUPPORT)) scanout(
        .clk(clk),.reset(reset),.start(display_start),.bank(display_bank),.flip(screen_flip),.pixel_ce(raster_run?native_visible_ce:visible_pixel_ce),
        .pixel_valid(scan_valid),.pixel_index(scan_index),.underflow(scan_underflow),.busy(scan_busy),
        .mem_req(display_req),.mem_bank(scan_bank),.mem_addr(display_addr),.mem_ordinal(display_ordinal),
        .mem_ack(display_ack),.mem_data(display_data));
    wire shadow_req,shadow_write,shadow_ack,shadow_idle,shadow_cut_ready;
    wire [24:0] shadow_addr;wire [15:0] shadow_data,shadow_reply;wire [1:0] shadow_bytes;
    gs_cpu_write_lines #(.ENABLE(LINE_WRITES)) shadow_batches(
        .clk(clk),.reset(reset),.up_req(cpu_req),.up_write(cpu_write),.up_addr(cpu_addr),
        .up_wdata(cpu_wdata),.up_bytes(cpu_bytes),.up_write_line(cpu_write_line),.up_wline(cpu_wline),
        .up_ack(cpu_ack),.up_rdata(cpu_rdata),.idle(shadow_idle),
        .down_req(shadow_req),.down_write(shadow_write),.down_addr(shadow_addr),
        .down_wdata(shadow_data),.down_bytes(shadow_bytes),.down_ack(shadow_ack),.down_rdata(shadow_reply));
    assign cut_ready=shadow_cut_ready && shadow_idle;
    gs_gpu_rotate #(.CURRENT_TEXT(CURRENT_TEXT)) gpu(
        .clk(clk),
        .surface_line(surface_line),.line_valid(line_valid),.line_word(line_word),.line_data(line_data),
        .reset(reset),
        .initialized(initialized),
        .cut(cut && shadow_idle),
        .cpu_bus_idle(cpu_bus_idle && shadow_idle),
        .cut_ready(shadow_cut_ready),
        .cut_ack(cut_ack),
        .cpu_req(shadow_req),
        .cpu_write(shadow_write),
        .cpu_addr(shadow_addr),
        .cpu_wdata(shadow_data),
        .cpu_bytes(shadow_bytes),
        .cpu_mapped(cpu_mapped),
        .cpu_ack(shadow_ack),
        .cpu_rdata(shadow_reply),
        .query(query),
        .bank(bank),
        .query_ready(query_ready),
        .controls(controls),.scn_controls(scn_controls),.current_restart(current_restart),
        .rzx(rzx),
        .rzy(rzy),
        .affine_pcb(affine_pcb),
        .affine_regs(affine_regs),
        .done(done),
        .done_bank(done_bank),
        .presentable(presentable),
        .supported(supported),
        .overflow(overflow),
        .scp_rom_req(scp_rom_req),
        .scp_rom_addr(scp_rom_addr),
        .scp_rom_ack(scp_rom_ack),
        .scp_rom_rdata(scp_rom_rdata),
        .sprite_rom_req(sprite_rom_req),
        .sprite_rom_addr(sprite_rom_addr),
        .sprite_rom_ack(sprite_rom_ack),
        .sprite_rom_rvalid(sprite_rom_rvalid),
        .sprite_rom_rdata(sprite_rom_rdata),
        .map_req(map_req),
        .map_word_addr(map_word_addr),
        .map_ack(map_ack),
        .map_rdata(map_rdata),
        .arena_req(arena_req),
        .arena_write(arena_write),
        .arena_wide(arena_wide),
        .arena_addr(arena_addr),
        .arena_wdata(arena_wdata),
        .arena_ack(arena_ack),
        .arena_rdata(arena_rdata),
        .surface_req(surface_req),
        .surface_write(surface_write),
        .surface_addr(surface_addr),
        .surface_wdata(surface_wdata),
        .surface_bytes(surface_bytes),
        .surface_ack(surface_ack),
        .surface_rdata(surface_rdata),
        .display_req(display_req),
        .display_bank(scan_bank),
        .display_active(scan_busy),
        .display_restart(display_start),
        .display_addr(display_addr),
        .display_ordinal(display_ordinal),
        .display_ack(display_ack),
        .display_data(display_data));
endmodule
