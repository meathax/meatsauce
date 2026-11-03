// SPDX-License-Identifier: GPL-3.0-or-later
// Actual game and downloadable storage, common to Quartus and Verilator.
module darkmist_system (
    input wire clk,clk_capture,reset,cpu_reset,pause,download,prog_we,display_flip,
    output wire paused,
    input wire hs_access,hs_we,
    input wire [11:0] hs_addr,
    input wire [7:0] hs_data,
    input wire [19:0] prog_addr,
    input wire [7:0] prog_data,
    output wire prog_wait,ready,loaded,load_error,game_reset,
    input wire [7:0] p1,p2,starts,dip1,dip2,unknown_inputs,
    input wire [1:0] coins,
    input wire [2:0] video_region,
    input wire [11:0] video_addr,debug_addr,
    output wire [7:0] video_data,debug_data,hardware_control,sprite_bank,
    output wire signed [15:0] audio_left,audio_right,
    output wire audio_sample,trace_main_write,trace_sound_write,trace_sound_io,
    output wire [15:0] trace_main_addr,trace_sound_addr,main_cpu_addr,sound_cpu_addr,
    output wire [7:0] trace_main_data,trace_sound_data,unknown_port40,unknown_port50,
    output wire [2:0] sound_irq_state,
    output wire sound_io_read,sound_irq_ack,sound_fetch,sound_bus_cen,
    output wire [7:0] sound_cpu_din,
    output wire ce_pixel,
    output wire [8:0] raster_x,
    output wire [7:0] raster_y,
    output wire [11:0] rgb,
    output wire pixel_ce,pixel_valid,
    output wire [8:0] pixel_x,
    output wire [7:0] pixel_y,
    output wire [15:0] underflow_lines,overrun_lines,maximum_line_clocks,
    output wire unknown_sprite_seen,video_protocol_error,
    inout wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nWE,SDRAM_nCAS,SDRAM_nRAS,SDRAM_nCS,SDRAM_CKE
);
    wire main_rom_req,main_rom_opcode,main_rom_valid;
    wire [16:0] main_rom_addr;
    wire [7:0] main_rom_data,sound_rom_data;
    wire sound_rom_req,sound_rom_external,sound_rom_valid;
    wire [14:0] sound_rom_addr,map_word_addr;
    wire map_req,map_fg,map_valid;
    wire [15:0] map_data,gfx_data;
    wire gfx_req,gfx_ack,gfx_valid,gfx_last,gfx_error,renderer_error;
    wire [1:0] gfx_region,clut_owner;
    wire [16:0] gfx_word_addr;
    wire [2:0] gfx_words;
    wire clut_we;
    wire [7:0] clut_addr,clut_data;
    assign game_reset=reset || cpu_reset || !loaded || !ready;
    assign video_protocol_error=renderer_error || gfx_error;
    darkmist_machine machine (.*,.reset(game_reset),.video_protocol_error(renderer_error));
    darkmist_storage storage (
        .clk(clk),.clk_capture(clk_capture),.reset(reset),.download(download),.prog_we(prog_we),.prog_addr(prog_addr),
        .prog_data(prog_data),.prog_wait(prog_wait),.ready(ready),.loaded(loaded),.load_error(load_error),
        .main_req(main_rom_req),.main_opcode(main_rom_opcode),.main_addr(main_rom_addr),
        .main_valid(main_rom_valid),.main_data(main_rom_data),
        .sound_req(sound_rom_req),.sound_external(sound_rom_external),.sound_addr(sound_rom_addr),
        .sound_valid(sound_rom_valid),.sound_data(sound_rom_data),
        .map_req(map_req),.map_fg(map_fg),.map_addr(map_word_addr),.map_valid(map_valid),.map_data(map_data),
        .gfx_req(gfx_req),.gfx_region(gfx_region),.gfx_addr(gfx_word_addr),.gfx_words(gfx_words),
        .gfx_ack(gfx_ack),.gfx_valid(gfx_valid),.gfx_last(gfx_last),.gfx_data(gfx_data),.gfx_error(gfx_error),
        .clut_we(clut_we),.clut_owner(clut_owner),.clut_addr(clut_addr),.clut_data(clut_data),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCS(SDRAM_nCS),.SDRAM_CKE(SDRAM_CKE)
    );
endmodule
