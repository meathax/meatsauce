// SPDX-License-Identifier: GPL-3.0-or-later
// Game, ROM cache and real SDRAM controller. Platform PLL/forwarded clock,
// HPS stream routing and display features are connected by the MiSTer wrapper.
module madmotor_board #(
    parameter integer SYS_HZ=48000000
)(

    input tri0 bandit,
    input tri0 [31:0] joystick_0,joystick_1,
    input tri0 [15:0] right_stick_0,right_stick_1,
    output wire [23:0] rgb24,
    input wire clk,reset,soft_reset,rom_loaded,pause,
    input wire [15:0] controls,dips,
    input wire [2:0] coins_n,
    input wire load_mode,load_req,
    input wire [23:0] load_addr,
    input wire [15:0] load_data,
    input wire [1:0] load_mask,
    output wire load_ok,initializing,
    input wire audio_load_we,
    input wire [1:0] audio_load_region,
    input wire [17:0] audio_load_addr,
    input wire [7:0] audio_load_data,
    input wire mcu_rom_we,
    input wire [11:0] mcu_rom_addr,
    input wire [7:0] mcu_rom_data,
    output wire signed [15:0] audio_left,audio_right,
    output wire audio_sample_ce,audio_clipped,
    output wire [20:0] debug_sound_address,
    output wire [7:0] debug_sound_data,
    output wire debug_sound_write,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke,
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
    output wire [31:0] debug_cpu_ticks,debug_cpu_pairs,debug_cpu_dropped
`endif
);
    wire game_reset_request=reset||soft_reset||!rom_loaded||initializing||load_mode;
    wire game_reset;
    // Keep the combinational ready/load decode off downstream reset release.
    // Assertion remains immediate; release needs two destination-root edges.
    madmotor_reset game_reset_release(
        .clk(clk),.async_reset(game_reset_request),.sync_reset(game_reset));
    wire mem_req,mem_ok;
    wire [23:0] mem_addr;
    wire [63:0] mem_data;
    madmotor_game_rom #(.SYS_HZ(SYS_HZ)) game(.reset(game_reset),.*);
    // host_reset cancels/drains pending reads; it does not restart SDRAM's
    // initialization or halt refresh while the user pauses/resets/downloads.
    // Preserve the original immediate cancellation and initialization contract.
    madmotor_sdram #(.SYS_HZ(SYS_HZ)) memory(.host_reset(game_reset_request),.*);
endmodule
