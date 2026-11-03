// SPDX-License-Identifier: GPL-3.0-or-later
// Production game + cached ROM fabric. SDRAM controller/pins remain downstream.
module madmotor_game_rom #(
    parameter integer SYS_HZ=48000000
)(

    input logic bandit,
    input tri0 [31:0] joystick_0,joystick_1,
    input tri0 [15:0] right_stick_0,right_stick_1,
    output wire [23:0] rgb24,
    input logic clk,reset,pause,
    input logic [15:0] controls,dips,
    input logic [2:0] coins_n,
    input logic audio_load_we,
    input logic [1:0] audio_load_region,
    input logic [17:0] audio_load_addr,
    input logic [7:0] audio_load_data,
    input logic mcu_rom_we,
    input logic [11:0] mcu_rom_addr,
    input logic [7:0] mcu_rom_data,
    output wire signed [15:0] audio_left,audio_right,
    output wire audio_sample_ce,audio_clipped,
    output wire [20:0] debug_sound_address,
    output wire [7:0] debug_sound_data,
    output wire debug_sound_write,
    output wire mem_req,
    output wire [23:0] mem_addr,
    input logic [63:0] mem_data,
    input logic mem_ok,
    output wire [3:0] red,green,blue,
    output wire hs,vs,hblank,vblank,pixel_valid,
    output wire [8:0] pixel_x,pixel_y,
    output wire [7:0] sound_latch,
    output wire sound_irq,halted,
    output wire [23:0] debug_address,
    output wire debug_request,debug_read,debug_write,
    output wire [15:0] debug_write_data,debug_read_data,
    output wire [1:0] debug_byte_enable
`ifdef VERILATOR
    ,output wire [11:0] debug_cpu_credit,
    output wire [31:0] debug_cpu_ticks,debug_cpu_pairs,debug_cpu_dropped,
    output wire debug_mcu_irq5,debug_mcu_cen,
    output wire [31:0] debug_video_planes,
    output wire [9:0] debug_video_palette_index,
    output wire [15:0] debug_priority_word
`endif
);
    wire main_cs,main_ok,sprite_cs,sprite_ok;
    wire [17:0] main_addr,sprite_addr;
    wire [15:0] main_data;
    wire [31:0] sprite_data,tile_data [3];
    wire [16:0] tile_addr [3];
    wire [2:0] tile_cs,tile_ok;
    madmotor_rom_bridge roms(.*);
    madmotor_game #(.SYS_HZ(SYS_HZ)) game(
        .bandit(bandit),.joystick_0(joystick_0),.joystick_1(joystick_1),
        .right_stick_0(right_stick_0),.right_stick_1(right_stick_1),.rgb24(rgb24),
        .clk(clk),.reset(reset),.pause(pause),.controls(controls),.dips(dips),.coins_n(coins_n),
        .audio_load_we(audio_load_we),.audio_load_region(audio_load_region),
        .audio_load_addr(audio_load_addr),.audio_load_data(audio_load_data),
        .mcu_rom_we(mcu_rom_we),.mcu_rom_addr(mcu_rom_addr),.mcu_rom_data(mcu_rom_data),
        .audio_left(audio_left),.audio_right(audio_right),.audio_sample_ce(audio_sample_ce),.audio_clipped(audio_clipped),
        .debug_sound_address(debug_sound_address),.debug_sound_data(debug_sound_data),.debug_sound_write(debug_sound_write),
        .main_cs(main_cs),.main_addr(main_addr),.main_data(main_data),.main_ok(main_ok),
        .tile_cs(tile_cs),.tile_addr(tile_addr),.tile_data(tile_data),.tile_ok(tile_ok),
        .sprite_cs(sprite_cs),.sprite_addr(sprite_addr),.sprite_data(sprite_data),.sprite_ok(sprite_ok),
        .red(red),.green(green),.blue(blue),.hs(hs),.vs(vs),.hblank(hblank),.vblank(vblank),
        .pixel_valid(pixel_valid),.pixel_x(pixel_x),.pixel_y(pixel_y),.sound_latch(sound_latch),.sound_irq(sound_irq),
        .halted(halted),.debug_address(debug_address),.debug_request(debug_request),.debug_read(debug_read),
        .debug_write(debug_write),.debug_write_data(debug_write_data),.debug_read_data(debug_read_data),.debug_byte_enable(debug_byte_enable)
`ifdef VERILATOR
        ,.debug_cpu_credit(debug_cpu_credit),.debug_cpu_ticks(debug_cpu_ticks),
        .debug_cpu_pairs(debug_cpu_pairs),.debug_cpu_dropped(debug_cpu_dropped),
        .debug_mcu_irq5(debug_mcu_irq5),.debug_mcu_cen(debug_mcu_cen),
        .debug_video_planes(debug_video_planes),.debug_video_palette_index(debug_video_palette_index),
        .debug_priority_word(debug_priority_word)
`endif
    );
endmodule
