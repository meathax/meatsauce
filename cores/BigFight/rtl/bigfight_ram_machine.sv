// Synthesizable board, sound, mapped work RAM and ordered program ROM service.
module bigfight_ram_machine (
    input wire cyclwarr_i,
    input wire hs_access,
    input wire hs_write,
    input wire [15:0] hs_address,
    input wire [7:0] hs_wdata,
    output wire [7:0] hs_rdata,

    input wire pause_req,
    output wire pause_ack,
    input logic clk_sys,reset,cold_start,
    input logic [7:0] service_i,p1_i,p2_i,p3_i,p4_i,dsw1_i,dsw2_i,dsw3_i,
    output logic mem_valid,mem_req,mem_wr,mem_cpu,mem_uds_n,mem_lds_n,
    output logic [23:1] mem_address,
    output logic [15:0] mem_din,
    output logic mem_ready,
    output logic [15:0] mem_dout,
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
    output wire                oki_ce1_tick_o,
    input logic load_mode,
    output logic rom_reset_o,rom_req,rom_master,
    input logic rom_ready,
    output logic [19:0] rom_word_address,
    input logic rom_rsp_valid,
    output logic rom_rsp_ready,
    input logic [15:0] rom_rsp_data,
    input  logic         load_valid,
    input  logic [2:0]   load_bank,
    input  logic [14:0]  load_word_address,
    input  logic [15:0]  load_data,
    input  logic         load_uds_n,
    input  logic         load_lds_n,
    output logic         load_ready,

    input  logic         vram_req,
    output logic         vram_req_ready,
    input  logic         vram_bank /* verilator public_flat_rd */,
    input  logic [14:0]  vram_word_address /* verilator public_flat_rd */,
    output logic         vram_rsp_valid,
    input  logic         vram_rsp_ready,
    output logic [15:0]  vram_rsp_data /* verilator public_flat_rd */,

    input  logic         sprite_req,
    output logic         sprite_req_ready,
    input  logic [12:0]  sprite_word_address,
    output logic         sprite_rsp_valid,
    input  logic         sprite_rsp_ready,
    output logic [15:0]  sprite_rsp_data,

    input  logic         palette_req,
    output logic         palette_req_ready,
    input  logic [12:0]  palette_word_address,
    output logic         palette_rsp_valid,
    input  logic         palette_rsp_ready,
    output logic [15:0]  palette_rsp_data,

    input  logic         object_req,
    output logic         object_req_ready,
    input  logic [7:0]   object_word_address,
    output logic         object_rsp_valid,
    input  logic         object_rsp_ready,
    output logic [15:0]  object_rsp_data
);

    logic ram_selected,ram_ready,program_selected,program_ready;
    logic [15:0] ram_data,program_data;
`ifdef BIGFIGHT_CPU_RECOVERY
    logic [1:0] program_owner;
    wire cpu_owner_main = !mem_cpu;
`endif
    assign rom_reset_o=cold_start || load_mode;
    bigfight_machine machine(.pause_req(pause_req), .pause_ack(pause_ack), .reset(reset || load_mode),.*);
    bigfight_work_ram work_ram(
        .hs_access(hs_access), .hs_write(hs_write), .hs_address(hs_address),
        .hs_wdata(hs_wdata), .hs_rdata(hs_rdata),
        .hs_grant(pause_ack),
        .cold_reset(cold_start),.cpu_valid(mem_valid),.cpu_owner_main(!mem_cpu),
        .cpu_wr(mem_wr),.cpu_uds_n(mem_uds_n),.cpu_lds_n(mem_lds_n),
        .cpu_address(mem_address),.cpu_wdata(mem_din),
        .cpu_selected(ram_selected),.cpu_ready(ram_ready),.cpu_rdata(ram_data),.*
    );
    bigfight_program_rom program_rom(
        .cold_reset(rom_reset_o),.cpu_valid(mem_valid && !load_mode),.cpu_wr(mem_wr),
        .cpu_address(mem_address),.cpu_selected(program_selected),
        .cpu_ready(program_ready),.cpu_rdata(program_data),.*
    );
    assign mem_ready=!load_mode && (ram_selected ? ram_ready : program_selected ? program_ready : 1'b0);
    assign mem_dout=ram_selected ? ram_data : program_selected ? program_data : 16'hffff;
endmodule
