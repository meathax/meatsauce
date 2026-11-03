// SPDX-License-Identifier: GPL-3.0-or-later
// Air Buster board: CPU bus arbitration, RAM map, I/O latches and interrupts.
// clk is the 48 MHz master; CPU/sound enables are integer divisions of it.
module airbustr_board (
    input logic clk, reset,
    input logic soft_reset,
    input logic rom_loaded, backend_ready, calc1_present, wd_freeze,
    input logic [27:0] wd_limit,          // watchdog period in clk cycles (3 s = 144e6)
    output logic wd_reset,
    output logic ram_ready, game_ready, game_reset, memory_idle,
    output logic cpu_cen,
    input logic [2:0] cpu_req_valid,
    output logic [2:0] cpu_req_ready,
    input logic [2:0] cpu_req_io, cpu_req_write,
    input logic [47:0] cpu_req_addr,
    input logic [23:0] cpu_req_data,
    output logic [2:0] cpu_rsp_valid,
    output logic [23:0] cpu_rsp_data,
    output logic [2:0] main_bank, sub_bank, sound_bank,
    output logic [7:0] sub_control,
    output logic [7:0] scroll_x0, scroll_y0, scroll_x1, scroll_y1, scroll_high_n,
    output logic [3:0] coin_outputs,
    input logic [7:0] system_inputs_n, player1_inputs_n, player2_inputs_n,
    input logic main_event_64, main_event_240, main_irq_ack, sub_irq_ack, sub_vblank,
    input logic ym_irq,
    output logic main_irq,
    output logic [7:0] main_vector,
    output logic sub_irq, sub_nmi, sound_irq, sound_nmi,
    output logic snd_req_valid,
    input logic snd_req_ready,
    output logic snd_req_oki, snd_req_write, snd_req_addr,
    output logic [7:0] snd_req_data,
    input logic snd_rsp_valid,
    input logic [7:0] snd_rsp_data,
    input logic [8:0] object_addr,
    output logic [63:0] object_data,
    input logic [9:0] bg_tile_addr, fg_tile_addr,
    output logic [7:0] bg_tile_code, bg_tile_attr, fg_tile_code, fg_tile_attr,
    input logic [9:0] palette_addr,
    output logic [15:0] palette_data
);
    logic mem_req_valid, mem_req_ready, mem_req_write, mem_rsp_valid;
    logic [1:0] mem_req_cpu;
    logic [15:0] mem_req_addr;
    logic [7:0] mem_req_data, mem_rsp_data;
    logic sub_nmi_request, wd_kick;
    logic [2:0] divider;
    logic [27:0] wd_count;
    logic [10:0] wd_hold;

    // CALC1 watchdog (airbustr.cpp:803, MAME guess 3 s; kicked by reading
    // CALC1 register 0). Power-on code waits at 37E4 for this reset. A
    // watchdog reset is a soft reset: CPUs, latches, chips and Pandora restart
    // and sprite RAM is cleared (kaneko_pandora device_reset); work RAM stays.
    assign wd_reset = wd_hold != 0;
    always_ff @(posedge clk) begin
        if (reset || soft_reset) begin wd_count <= 0; wd_hold <= 0; end
        else begin
            if (wd_hold != 0) wd_hold <= wd_hold - 11'd1;
            if (wd_kick || wd_hold != 0 || !calc1_present) wd_count <= 0;
            else if (game_ready && !wd_freeze) begin
                if (wd_count >= wd_limit) begin wd_count <= 0; wd_hold <= 11'd1100; end
                else wd_count <= wd_count + 28'd1;
            end
        end
    end
    assign game_ready = ram_ready && rom_loaded && backend_ready && !reset && !soft_reset && !wd_reset;
    assign game_reset = !game_ready;
    assign cpu_cen = divider == 3'd7 && game_ready;
    always_ff @(posedge clk) begin
        if (game_reset) divider <= 3'd0;
        else divider <= divider + 3'd1;
    end

    airbustr_bus bus (
        .clk, .reset(game_reset), .cpu_req_valid,
        .cpu_req_ready, .cpu_req_io, .cpu_req_write, .cpu_req_addr,
        .cpu_req_data, .cpu_rsp_valid, .cpu_rsp_data,
        .mem_req_valid, .mem_req_ready, .mem_req_cpu, .mem_req_write,
        .mem_req_addr, .mem_req_data, .mem_rsp_valid, .mem_rsp_data,
        .system_inputs_n, .player1_inputs_n, .player2_inputs_n,
        .main_bank, .sub_bank, .sound_bank, .sub_control,
        .scroll_x0, .scroll_y0, .scroll_x1, .scroll_y1, .scroll_high_n, .coin_outputs,
        .sub_nmi_request, .sound_nmi,
        .snd_req_valid, .snd_req_ready, .snd_req_oki, .snd_req_write, .snd_req_addr,
        .snd_req_data, .snd_rsp_valid, .snd_rsp_data
    );
    airbustr_memory memory (
        .clk, .reset, .calc1_present, .clear_objects(wd_reset), .init_done(ram_ready), .idle(memory_idle),
        .req_valid(mem_req_valid), .req_ready(mem_req_ready), .req_cpu(mem_req_cpu),
        .req_write(mem_req_write), .req_addr(mem_req_addr), .req_data(mem_req_data),
        .rsp_valid(mem_rsp_valid), .rsp_data(mem_rsp_data), .calc1_watchdog(wd_kick),
        .object_addr, .object_data, .bg_tile_addr, .bg_tile_code, .bg_tile_attr,
        .fg_tile_addr, .fg_tile_code, .fg_tile_attr, .palette_addr, .palette_data
    );
    airbustr_irq irq (
        .clk, .reset(game_reset), .main_event_64, .main_event_240,
        .main_ack(main_irq_ack), .sub_vblank, .sub_ack(sub_irq_ack),
        .sub_nmi_request, .cpu_cen, .ym_irq,
        .main_irq, .main_vector, .sub_irq, .sub_nmi, .sound_irq
    );
endmodule
