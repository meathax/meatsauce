// SPDX-License-Identifier: GPL-3.0-or-later
// Complete native game datapath. MiSTer ROM arbitration/OSD/outputs wrap this unit.
module darkmist_machine #(
    parameter [7:0] INITIAL_RASTER_Y = 8'd240
) (
    input wire clk,reset,pause,display_flip,
    output wire paused,
    input wire hs_access,hs_we,
    input wire [11:0] hs_addr,
    input wire [7:0] hs_data,
    input wire [7:0] p1,p2,starts,dip1,dip2,unknown_inputs,
    input wire [1:0] coins,
    output wire main_rom_req,main_rom_opcode,
    output wire [16:0] main_rom_addr,
    input wire main_rom_valid,
    input wire [7:0] main_rom_data,
    output wire sound_rom_req,sound_rom_external,
    output wire [14:0] sound_rom_addr,
    input wire sound_rom_valid,
    input wire [7:0] sound_rom_data,
    input wire [2:0] video_region,
    input wire [11:0] video_addr,debug_addr,
    output wire [7:0] video_data,debug_data,
    output wire [7:0] hardware_control,sprite_bank,
    output wire signed [15:0] audio_left,audio_right,
    output wire audio_sample,
    output wire trace_main_write,trace_sound_write,trace_sound_io,
    output wire [15:0] trace_main_addr,trace_sound_addr,
    output wire [7:0] trace_main_data,trace_sound_data,
    output wire [15:0] main_cpu_addr,sound_cpu_addr,
    output wire [2:0] sound_irq_state,
    output wire [7:0] unknown_port40,unknown_port50,
    output wire sound_io_read,sound_irq_ack,sound_fetch,sound_bus_cen,
    output wire [7:0] sound_cpu_din,
    output wire ce_pixel,
    output wire [8:0] raster_x,
    output wire [7:0] raster_y,
    output wire map_req,map_fg,
    output wire [14:0] map_word_addr,
    input wire map_valid,
    input wire [15:0] map_data,
    output wire gfx_req,
    output wire [1:0] gfx_region,
    output wire [16:0] gfx_word_addr,
    output wire [2:0] gfx_words,
    input wire gfx_ack,gfx_valid,gfx_last,
    input wire [15:0] gfx_data,
    input wire clut_we,
    input wire [1:0] clut_owner,
    input wire [7:0] clut_addr,clut_data,
    output wire [11:0] rgb,
    output wire pixel_ce,pixel_valid,
    output wire [8:0] pixel_x,
    output wire [7:0] pixel_y,
    output wire [15:0] underflow_lines,overrun_lines,maximum_line_clocks,
    output wire unknown_sprite_seen,video_protocol_error
);
    wire [6:0] sprite_index;
    wire [31:0] sprite_data;
    wire [9:0] text_index;
    wire [15:0] text_data;
    wire [7:0] color_index;
    wire [11:0] color_rgb;
    wire [15:0] bg_scroll_x,bg_scroll_y,fg_scroll_x,fg_scroll_y;
    darkmist_board #(.INITIAL_RASTER_Y(INITIAL_RASTER_Y)) board (
        .clk(clk),.reset(reset),.pause(pause),.paused(paused),
        .hs_access(hs_access),.hs_we(hs_we),.hs_addr(hs_addr),.hs_data(hs_data),.p1(p1),.p2(p2),.starts(starts),
        .dip1(dip1),.dip2(dip2),.unknown_inputs(unknown_inputs),.coins(coins),
        .main_rom_req(main_rom_req),.main_rom_opcode(main_rom_opcode),.main_rom_addr(main_rom_addr),
        .main_rom_valid(main_rom_valid),.main_rom_data(main_rom_data),
        .sound_rom_req(sound_rom_req),.sound_rom_external(sound_rom_external),.sound_rom_addr(sound_rom_addr),
        .sound_rom_valid(sound_rom_valid),.sound_rom_data(sound_rom_data),
        .video_region(video_region),.video_addr(video_addr),.debug_addr(debug_addr),
        .video_data(video_data),.debug_data(debug_data),.hardware_control(hardware_control),.sprite_bank(sprite_bank),
        .sprite_desc_index(sprite_index),.sprite_desc_data(sprite_data),
        .text_tile_index(text_index),.text_tile_data(text_data),.color_index(color_index),.color_rgb(color_rgb),
        .bg_scroll_x(bg_scroll_x),.bg_scroll_y(bg_scroll_y),.fg_scroll_x(fg_scroll_x),.fg_scroll_y(fg_scroll_y),
        .audio_left(audio_left),.audio_right(audio_right),.audio_sample(audio_sample),
        .trace_main_write(trace_main_write),.trace_sound_write(trace_sound_write),.trace_sound_io(trace_sound_io),
        .trace_main_addr(trace_main_addr),.trace_sound_addr(trace_sound_addr),
        .trace_main_data(trace_main_data),.trace_sound_data(trace_sound_data),
        .main_cpu_addr(main_cpu_addr),.sound_cpu_addr(sound_cpu_addr),.sound_irq_state(sound_irq_state),
        .unknown_port40(unknown_port40),.unknown_port50(unknown_port50),
        .sound_io_read(sound_io_read),.sound_irq_ack(sound_irq_ack),.sound_fetch(sound_fetch),
        .sound_bus_cen(sound_bus_cen),.sound_cpu_din(sound_cpu_din),
        .ce_pixel(ce_pixel),.raster_x(raster_x),.raster_y(raster_y)
    );
    darkmist_video video (
        .clk(clk),.reset(reset),.ce_pixel(ce_pixel),.display_flip(display_flip),.raster_x(raster_x),.raster_y(raster_y),
        .hardware_control(hardware_control),.sprite_bank(sprite_bank),
        .bg_scroll_x(bg_scroll_x),.bg_scroll_y(bg_scroll_y),.fg_scroll_x(fg_scroll_x),.fg_scroll_y(fg_scroll_y),
        .sprite_index(sprite_index),.sprite_data(sprite_data),.text_index(text_index),.text_data(text_data),
        .color_index(color_index),.color_rgb(color_rgb),
        .map_req(map_req),.map_fg(map_fg),.map_word_addr(map_word_addr),.map_valid(map_valid),.map_data(map_data),
        .gfx_req(gfx_req),.gfx_region(gfx_region),.gfx_word_addr(gfx_word_addr),.gfx_words(gfx_words),
        .gfx_ack(gfx_ack),.gfx_valid(gfx_valid),.gfx_last(gfx_last),.gfx_data(gfx_data),
        .clut_we(clut_we),.clut_owner(clut_owner),.clut_addr(clut_addr),.clut_data(clut_data),
        .rgb(rgb),.pixel_ce(pixel_ce),.pixel_valid(pixel_valid),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .underflow_lines(underflow_lines),.overrun_lines(overrun_lines),.maximum_line_clocks(maximum_line_clocks),
        .unknown_sprite_seen(unknown_sprite_seen),.protocol_error(video_protocol_error)
    );
endmodule
