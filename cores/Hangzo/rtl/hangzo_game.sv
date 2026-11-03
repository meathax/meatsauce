// SPDX-License-Identifier: GPL-3.0-or-later
// Framework-free game graph. Pixel cadence, IRQ VBlank and ROM storage are
// supplied by the thin platform. Physical raster remains provisional.
`timescale 1ns/1ns
module hangzo_game #(parameter HISCORE_SUPPORTED=0, SCHMEISER_SUPPORTED=0) (
    input wire game_id,
    input wire clk,reset,pause,pixel_ce,hs,vs,hblank,video_vblank,irq_vblank,frame_odd,flip,
    input wire [8:0] hpos,vpos,
    input wire [15:0] player_inputs,dips,
    input wire [7:0] dips3,
    input wire [2:0] coin_service,
    output wire rom_request,
    output wire [19:1] rom_address,
    input wire rom_ready,
    input wire [15:0] rom_data,
    output wire [3:0] tile_request,tile16,
    output wire [18:0] tile_address0,tile_address1,tile_address2,tile_address3,
    input wire [31:0] tile_data0,tile_data1,tile_data2,tile_data3,
    input wire [3:0] tile_ready,
    output wire sprite_request,
    output wire [20:0] sprite_address,
    input wire [31:0] sprite_data,
    input wire sprite_ready,
    output wire rgb_ce,
    output wire [23:0] rgb,
    output wire hblank_out,vblank_out,hs_out,vs_out,
    output wire [7:0] sound_data,
    output wire sound_write,
    input wire audio_sample_ce,
    output wire sound_program_request,
    output wire [15:0] sound_program_address,
    input wire [7:0] sound_program_data,
    input wire sound_program_ready,
    output wire [18:0] oki1_address,oki2_address,
    input wire [7:0] oki1_data,oki2_data,
    input wire oki1_ready,oki2_ready,
    output wire signed [15:0] audio_left,audio_right,
    output wire audio_sample,
    output wire [20:0] sound_bus_address,
    output wire [7:0] sound_bus_data,
    output wire sound_bus_write,sound_bus_accepted,sound_command_read,
    output wire bus_accepted,bus_write,
    output wire [23:0] bus_address,
    output wire [1:0] bus_byte_enable,
    output wire [15:0] bus_write_data,bus_read_data,
    output wire [2:0] bus_function_code,
    output wire phase1,phase2,halted,irq_pending,
    output wire sprite_copy,palette_copy,sprite_busy,palette_busy,
    input wire hiscore_pause_request,hiscore_request,hiscore_write,
    input wire [14:0] hiscore_byte_address,
    input wire [7:0] hiscore_write_data,
    output wire hiscore_paused,hiscore_initialized,hiscore_ack,hiscore_fault,
    output wire [7:0] hiscore_read_data
`ifdef VERILATOR
    ,output wire [11:0] debug_cpu_credit,
    output wire [63:0] debug_cpu_ticks,debug_cpu_pairs,debug_cpu_dropped
`endif
);
    wire video_request,video_write,video_ready,sprite_copy_ready,palette_copy_ready;
    wire [3:0] video_region;
    wire [11:0] video_offset;
    wire [1:0] video_byte_enable;
    wire [15:0] video_write_data,video_read_data,priority_control;
    hangzo_sound u_sound (
        .clk(clk),.reset(reset),.pause(pause),.sample_ce(audio_sample_ce),
        .command(sound_data),.command_write(sound_write),
        .program_request(sound_program_request),.program_address(sound_program_address),
        .program_data(sound_program_data),.program_ready(sound_program_ready),
        .oki1_address(oki1_address),.oki2_address(oki2_address),
        .oki1_data(oki1_data),.oki2_data(oki2_data),.oki1_ready(oki1_ready),.oki2_ready(oki2_ready),
        .left(audio_left),.right(audio_right),.sample(audio_sample),
        .bus_address(sound_bus_address),.bus_write_data(sound_bus_data),.bus_read_data(),
        .bus_read(),.bus_write(sound_bus_write),.bus_accepted(sound_bus_accepted),
        .command_pending(),.command_read(sound_command_read),.chip_reset_out(),.debug_enables());
    hangzo_main #(.HISCORE_SUPPORTED(HISCORE_SUPPORTED),.SCHMEISER_SUPPORTED(SCHMEISER_SUPPORTED)) u_main (
        .game_id(game_id),
        .hiscore_pause_request(hiscore_pause_request),.hiscore_request(hiscore_request),.hiscore_write(hiscore_write),
        .hiscore_byte_address(hiscore_byte_address),.hiscore_write_data(hiscore_write_data),
        .hiscore_paused(hiscore_paused),.hiscore_initialized(hiscore_initialized),
        .hiscore_ack(hiscore_ack),.hiscore_fault(hiscore_fault),.hiscore_read_data(hiscore_read_data),
`ifdef VERILATOR
        .debug_cpu_credit(debug_cpu_credit),.debug_cpu_ticks(debug_cpu_ticks),
        .debug_cpu_pairs(debug_cpu_pairs),.debug_cpu_dropped(debug_cpu_dropped),
`endif
        .clk(clk),.reset(reset),.pause(pause),.vblank(irq_vblank),.player_inputs(player_inputs),.dips(dips),
        .dips3(dips3),.coin_service(coin_service),.rom_request(rom_request),.rom_address(rom_address),
        .rom_ready(rom_ready),.rom_data(rom_data),.video_request(video_request),.video_region(video_region),
        .video_offset(video_offset),.video_write(video_write),.video_byte_enable(video_byte_enable),
        .video_write_data(video_write_data),.video_ready(video_ready),.video_read_data(video_read_data),
        .sprite_copy_ready(sprite_copy_ready),.palette_copy_ready(palette_copy_ready),
        .sprite_copy(sprite_copy),.palette_copy(palette_copy),.priority_control(priority_control),
        .sound_data(sound_data),.sound_write(sound_write),.bus_accepted(bus_accepted),.bus_write(bus_write),
        .bus_address(bus_address),.bus_byte_enable(bus_byte_enable),.bus_write_data(bus_write_data),
        .bus_read_data(bus_read_data),.bus_function_code(bus_function_code),.phase1(phase1),.phase2(phase2),
        .halted(halted),.irq_pending(irq_pending));
    hangzo_video u_video (
        .clk(clk),.reset(reset),.pixel_ce(pixel_ce),.hs(hs),.vs(vs),.hblank(hblank),.vblank(video_vblank),
        .flip(flip),.frame_odd(frame_odd),.hpos(hpos),.vpos(vpos),
        .select(video_request),.write(video_write),.region(video_region),.offset(video_offset),
        .write_data(video_write_data),.byte_enable(video_byte_enable),.ready(video_ready),.read_data(video_read_data),
        .sprite_copy(sprite_copy),.palette_copy(palette_copy),.sprite_copy_ready(sprite_copy_ready),.palette_copy_ready(palette_copy_ready),
        .sprite_busy(sprite_busy),.palette_busy(palette_busy),.sprite_valid(),.palette_valid(),.priority_control(priority_control[2:0]),
        .rom_request(tile_request),.tile16(tile16),.rom_address0(tile_address0),.rom_address1(tile_address1),
        .rom_address2(tile_address2),.rom_address3(tile_address3),
        .rom_data0(tile_data0),.rom_data1(tile_data1),.rom_data2(tile_data2),.rom_data3(tile_data3),.rom_ready(tile_ready),
        .sprite_request(sprite_request),.sprite_address(sprite_address),.sprite_data(sprite_data),.sprite_ready(sprite_ready),
        .rgb_ce(rgb_ce),.rgb(rgb),.hblank_out(hblank_out),.vblank_out(vblank_out),.hs_out(hs_out),.vs_out(vs_out),
        .layers(),.sprite_pen(),.pen());
endmodule
