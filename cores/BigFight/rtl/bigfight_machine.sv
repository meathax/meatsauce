// Board-level composition; ROM/RAM ports remain explicit synchronous interfaces.
module bigfight_machine (
    input wire cyclwarr_i,
    input wire pause_req,
    output wire pause_ack,
    input logic clk_sys,reset,cold_start,
    input logic [7:0] service_i,p1_i,p2_i,p3_i,p4_i,dsw1_i,dsw2_i,dsw3_i,
    output logic mem_valid,mem_req,mem_wr,mem_cpu,mem_uds_n,mem_lds_n,
    output logic [23:1] mem_address,
    output logic [15:0] mem_din,
    input logic mem_ready,
    input logic [15:0] mem_dout,
    output logic ce_pixel,hblank,vblank,line_start,frame_start,vblank_start,
    output logic [8:0] x,y,
    output logic [63:0] video_config,
    output logic [15:0] tile_bank,mixing_control,
    output logic [511:0] crtc_regs,
    output logic [7:0] sound_command,
    output logic sound_command_strobe,slave_halt,
    output logic [1:0] coin_outputs,
    output logic main_unmapped,sub_unmapped,
    output logic [23:1] main_addr,sub_addr,
    output logic main_as_n,sub_as_n,
    output logic [2:0] main_fc,sub_fc,
    output logic main_iack,sub_iack,
    output logic trace_req,trace_cpu,trace_wr,trace_uds_n,trace_lds_n,
    output logic [23:1] trace_address,
    output logic [15:0] trace_din,trace_dout,

    // Main-CPU command write event; accepted without backpressure outside reset.
    output wire               command_ready_o,
    output wire               command_pending_o,
    output wire               command_overwrite_o,

    // The Z80 program region is supplied by synchronous clk_sys memory.
    output wire               audio_rom_req_o,
    output wire        [15:0] audio_rom_addr_o,
    input  wire               audio_rom_ready_i,
    input  wire               audio_rom_valid_i,
    input  wire        [7:0]  audio_rom_data_i,

    // OKI sample region is a one-outstanding, ordered response port.
    output wire               oki_rom_req_o,
    output wire        [17:0] oki_rom_addr_o,
    input  wire               oki_rom_ready_i,
    input  wire               oki_rom_valid_i,
    input  wire        [7:0]  oki_rom_data_i,

    // Framework performs final saturation. These are signed, held 18-bit values.
    output logic signed [17:0] audio_left_o,
    output logic signed [17:0] audio_right_o,
    output logic               audio_sample_valid_o,

    // Timing/service observability. Counters saturate rather than wrap.
    output logic        [31:0] z80_wait_ce_count_o,
    output logic        [31:0] audio_rom_wait_ce_count_o,
    output logic        [31:0] oki_missed_ce1_count_o,
    output logic               z80_wait_seen_o,
    output logic               oki_timing_degraded_o,

    // Observation-only enables for tests/integration diagnostics; never use as clocks.
    output wire                ce4_tick_o,
    output wire                ym_ce2_tick_o,
    output wire                oki_ce1_tick_o
`ifdef BIGFIGHT_CPU_RECOVERY
    ,input logic [1:0]         program_owner
`endif
);
    bigfight_board board(.pause_req(pause_req), .pause_ack(pause_ack), .*);
    bigfight_sound sound(
        .clk_sys_i(clk_sys), .reset_i(reset || cold_start),
        .command_valid_i(sound_command_strobe), .command_data_i(sound_command), .*
    );
endmodule
