// SPDX-License-Identifier: GPL-3.0-only
// Actual shared game/host plus pinned JTFRAME controller. No PLL/forwarded
// clock is selected here. Caller supplies explicit qualified memory settings.
// Like the Mad Motor board donor: user/game reset does not reset refresh.
// Controller reset invalidates the host image, independently of soft reset.
module hangzo_sdram_core #(
    parameter integer HF_CONFIG=-1, SHIFTED_CONFIG=-1, REFRESH_COMMANDS_CONFIG=-1,
    parameter HISCORE_SUPPORTED=0
)(
    input wire clk,reset,pixel_ce,hs,vs,hblank,video_vblank,irq_vblank,frame_odd,flip,
    input wire [8:0] hpos,vpos,
    output wire [15:0] player_inputs,dips,
    output wire [7:0] dips3,
    output wire [2:0] coin_service,
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
    output wire [7:0] hiscore_read_data,
    output wire selected_schmeiser
`ifdef VERILATOR
    ,output wire [11:0] debug_cpu_credit,
    output wire [63:0] debug_cpu_ticks,debug_cpu_pairs,debug_cpu_dropped
`endif

    ,input wire platform_reset,menu_pause,
    output wire memory_ready,
    input wire [31:0] joystick_0,joystick_1,
    input wire [10:0] ps2_key,
    input wire ioctl_download,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_address,
    input wire [7:0] ioctl_data,
    output wire ioctl_wait,download_request,
    output wire [23:1] download_word_address,
    output wire [15:0] download_write_data,
    output wire download_ack,
    output wire pause,host_game_hold,rom_valid,rom_fault,
    output wire [24:0] download_bytes_received,
    output wire [23:0] download_words_written,
    output wire [23:0] download_storage_address,main_storage_address,program_storage_address,
    output wire program_byte,
    output wire [23:0] oki1_storage_address,oki2_storage_address,
    output wire oki1_byte,oki2_byte,
    output wire [23:0] tile_storage_address0,tile_storage_address1,tile_storage_address2,tile_storage_address3,
    output wire [23:0] sprite_storage_address
    ,output wire memory_request,memory_response_ready,memory_read_reset,
    output wire [25:0] memory_byte_address,
    output wire memory_accept,memory_response,
    output wire [63:0] memory_data
    ,input wire controller_reset,refresh,
    output wire memory_fault,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    hangzo_shared_core #(.HISCORE_SUPPORTED(HISCORE_SUPPORTED)) core(
        .hiscore_pause_request(hiscore_pause_request),.hiscore_request(hiscore_request),.hiscore_write(hiscore_write),
        .hiscore_byte_address(hiscore_byte_address),.hiscore_write_data(hiscore_write_data),
        .hiscore_paused(hiscore_paused),.hiscore_initialized(hiscore_initialized),
        .hiscore_ack(hiscore_ack),.hiscore_fault(hiscore_fault),.hiscore_read_data(hiscore_read_data),
        .selected_schmeiser(selected_schmeiser),
        .clk(clk)
        ,.reset((reset || !memory_ready || memory_fault))
        ,.pixel_ce(pixel_ce)
        ,.hs(hs)
        ,.vs(vs)
        ,.hblank(hblank)
        ,.video_vblank(video_vblank)
        ,.irq_vblank(irq_vblank)
        ,.frame_odd(frame_odd)
        ,.flip(flip)
        ,.hpos(hpos)
        ,.vpos(vpos)
        ,.player_inputs(player_inputs)
        ,.dips(dips)
        ,.dips3(dips3)
        ,.coin_service(coin_service)
        ,.rom_request(rom_request)
        ,.rom_address(rom_address)
        ,.rom_ready(rom_ready)
        ,.rom_data(rom_data)
        ,.tile_request(tile_request)
        ,.tile16(tile16)
        ,.tile_address0(tile_address0)
        ,.tile_address1(tile_address1)
        ,.tile_address2(tile_address2)
        ,.tile_address3(tile_address3)
        ,.tile_data0(tile_data0)
        ,.tile_data1(tile_data1)
        ,.tile_data2(tile_data2)
        ,.tile_data3(tile_data3)
        ,.tile_ready(tile_ready)
        ,.sprite_request(sprite_request)
        ,.sprite_address(sprite_address)
        ,.sprite_data(sprite_data)
        ,.sprite_ready(sprite_ready)
        ,.rgb_ce(rgb_ce)
        ,.rgb(rgb)
        ,.hblank_out(hblank_out)
        ,.vblank_out(vblank_out)
        ,.hs_out(hs_out)
        ,.vs_out(vs_out)
        ,.sound_data(sound_data)
        ,.sound_write(sound_write)
        ,.audio_sample_ce(audio_sample_ce)
        ,.sound_program_request(sound_program_request)
        ,.sound_program_address(sound_program_address)
        ,.sound_program_data(sound_program_data)
        ,.sound_program_ready(sound_program_ready)
        ,.oki1_address(oki1_address)
        ,.oki2_address(oki2_address)
        ,.oki1_data(oki1_data)
        ,.oki2_data(oki2_data)
        ,.oki1_ready(oki1_ready)
        ,.oki2_ready(oki2_ready)
        ,.audio_left(audio_left)
        ,.audio_right(audio_right)
        ,.audio_sample(audio_sample)
        ,.sound_bus_address(sound_bus_address)
        ,.sound_bus_data(sound_bus_data)
        ,.sound_bus_write(sound_bus_write)
        ,.sound_bus_accepted(sound_bus_accepted)
        ,.sound_command_read(sound_command_read)
        ,.bus_accepted(bus_accepted)
        ,.bus_write(bus_write)
        ,.bus_address(bus_address)
        ,.bus_byte_enable(bus_byte_enable)
        ,.bus_write_data(bus_write_data)
        ,.bus_read_data(bus_read_data)
        ,.bus_function_code(bus_function_code)
        ,.phase1(phase1)
        ,.phase2(phase2)
        ,.halted(halted)
        ,.irq_pending(irq_pending)
        ,.sprite_copy(sprite_copy)
        ,.palette_copy(palette_copy)
        ,.sprite_busy(sprite_busy)
        ,.palette_busy(palette_busy)
        ,.platform_reset((platform_reset || controller_reset))
        ,.memory_ready(memory_ready)
        ,.menu_pause(menu_pause)
        ,.joystick_0(joystick_0)
        ,.joystick_1(joystick_1)
        ,.ps2_key(ps2_key)
        ,.ioctl_download(ioctl_download)
        ,.ioctl_wr(ioctl_wr)
        ,.ioctl_index(ioctl_index)
        ,.ioctl_address(ioctl_address)
        ,.ioctl_data(ioctl_data)
        ,.ioctl_wait(ioctl_wait)
        ,.download_request(download_request)
        ,.download_word_address(download_word_address)
        ,.download_write_data(download_write_data)
        ,.download_ack(download_ack)
        ,.pause(pause)
        ,.host_game_hold(host_game_hold)
        ,.rom_valid(rom_valid)
        ,.rom_fault(rom_fault)
        ,.download_bytes_received(download_bytes_received)
        ,.download_words_written(download_words_written)
        ,.download_storage_address(download_storage_address)
        ,.main_storage_address(main_storage_address)
        ,.program_storage_address(program_storage_address)
        ,.program_byte(program_byte)
        ,.oki1_storage_address(oki1_storage_address)
        ,.oki2_storage_address(oki2_storage_address)
        ,.oki1_byte(oki1_byte)
        ,.oki2_byte(oki2_byte)
        ,.tile_storage_address0(tile_storage_address0)
        ,.tile_storage_address1(tile_storage_address1)
        ,.tile_storage_address2(tile_storage_address2)
        ,.tile_storage_address3(tile_storage_address3)
        ,.sprite_storage_address(sprite_storage_address)
        ,.memory_request(memory_request)
        ,.memory_response_ready(memory_response_ready)
        ,.memory_read_reset(memory_read_reset)
        ,.memory_byte_address(memory_byte_address)
        ,.memory_accept(memory_accept)
        ,.memory_response(memory_response)
        ,.memory_data(memory_data)
`ifdef VERILATOR
        ,.debug_cpu_credit(debug_cpu_credit)
        ,.debug_cpu_ticks(debug_cpu_ticks)
        ,.debug_cpu_pairs(debug_cpu_pairs)
        ,.debug_cpu_dropped(debug_cpu_dropped)
`endif
    );
    wire programming=host_game_hold || !rom_valid || download_request;
    hangzo_sdram_memory #(.HF_CONFIG(HF_CONFIG),.SHIFTED_CONFIG(SHIFTED_CONFIG),
        .REFRESH_COMMANDS_CONFIG(REFRESH_COMMANDS_CONFIG)) memory(
        .clk(clk),.controller_reset(controller_reset),.programmer_mode(programming),
        .read_invalidate(memory_read_reset),.refresh(refresh),.initialized(memory_ready),
        .download_request(download_request),.download_storage_word(download_storage_address),
        .download_data(download_write_data),.download_ack(download_ack),
        .read_request(memory_request),.read_accept(memory_accept),.read_byte_address(memory_byte_address),
        .read_response(memory_response),.read_response_ready(memory_response_ready),.read_data(memory_data),.read_fault(memory_fault),
        .sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(sdram_din),
`endif
        .sdram_a(sdram_a),.sdram_ba(sdram_ba),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
        .sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),.sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke));
endmodule
