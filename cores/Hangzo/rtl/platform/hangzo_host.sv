// SPDX-License-Identifier: GPL-3.0-or-later
// clk_sys-side HPS consumer. Does not generate clocks or physical memory pins.
module hangzo_host #(
    parameter [24:0] ROM_BYTES=25'h0c00000
)(
    input wire clk,platform_reset,memory_ready,menu_pause,
    input wire [31:0] joystick_0,joystick_1,
    input wire [10:0] ps2_key,
    input wire ioctl_download,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_address,
    input wire [7:0] ioctl_data,
    output wire ioctl_wait,
    output wire memory_request,
    output wire [23:1] memory_word_address,
    output wire [15:0] memory_write_data,
    input wire memory_ack,
    output wire [15:0] player_inputs,dips,
    output wire [7:0] dips3,
    output wire [2:0] coin_service,
    output wire pause,game_hold,rom_valid,rom_fault,
    output wire game_id,profile_changed,profile_fault,
    output wire [24:0] bytes_received,
    output wire [23:0] words_written
);
    wire pause_request,rom_busy,loader_fault,profile_hold;
    reg cabinet_pause;
    // Preserve DIP/key state across game resets and ROM downloads. The caller
    // supplies platform initialization reset here, not the download-held reset.
    hangzo_platform_io cabinet(
        .clk(clk),.reset(platform_reset),.joystick_0(joystick_0),.joystick_1(joystick_1),.ps2_key(ps2_key),
        .dip_write(ioctl_wr && ioctl_index==16'd254),.dip_address(ioctl_address),.dip_data(ioctl_data),
        .player_inputs(player_inputs),.dips(dips),.dips3(dips3),.coin_service(coin_service),
        .pause_toggle_request(pause_request));
    always @(posedge clk)begin
        if(platform_reset)cabinet_pause<=0;
        else if(pause_request)cabinet_pause<=~cabinet_pause;
    end
    assign pause=menu_pause||cabinet_pause;
    // A request level for the later game reset sequencer, not a memory reset.
    assign game_hold=platform_reset||!rom_valid||rom_busy||profile_hold;
    assign rom_fault=loader_fault||profile_fault;
    hangzo_game_profile profile(
        .clk,.reset(platform_reset),.ioctl_download,.ioctl_wr,.ioctl_index,
        .ioctl_address,.ioctl_data,.rom_valid,.rom_busy,.rom_fault(loader_fault),
        .game_id,.profile_changed,.profile_fault,.game_hold(profile_hold),
        .work_ram_base(),.work_ram_last());
    hangzo_rom_loader #(.ROM_BYTES(ROM_BYTES)) loader(
        .clk(clk),.reset(platform_reset),.memory_ready(memory_ready),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),
        .ioctl_address(ioctl_address),.ioctl_data(ioctl_data),.ioctl_wait(ioctl_wait),
        .memory_request(memory_request),.memory_word_address(memory_word_address),.memory_write_data(memory_write_data),
        .memory_ack(memory_ack),.rom_valid(rom_valid),.fault(loader_fault),.busy(rom_busy),.accepted_byte(),
        .bytes_received(bytes_received),.words_written(words_written));
endmodule
