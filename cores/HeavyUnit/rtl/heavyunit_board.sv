// SPDX-License-Identifier: GPL-3.0-or-later
// P2 board shell. CPU transactions come from the simulation driver for now;
// the same ports will be driven by the real Z80 adapters in P3.
// clk is the proposed 48 MHz master, not an assertion of native CRT timing.
module heavyunit_board (
    input logic clk, reset,
    input logic soft_reset,
    input logic rom_loaded, backend_ready,
    output logic ram_ready, game_ready, game_reset, memory_idle,
    output logic cpu_cen, ym_cen,
    input logic mermaid_sub_release,
    output logic sub_reset,
    input logic [2:0] cpu_req_valid,
    output logic [2:0] cpu_req_ready,
    input logic [2:0] cpu_req_io, cpu_req_write,
    input logic [47:0] cpu_req_addr,
    input logic [23:0] cpu_req_data,
    output logic [2:0] cpu_rsp_valid,
    output logic [23:0] cpu_rsp_data,
    output logic rom_req_valid,
    input logic rom_req_ready,
    output logic [21:0] rom_req_addr,
    input logic rom_rsp_valid,
    input logic [7:0] rom_rsp_data,
    output logic [2:0] main_bank,
    output logic [1:0] sub_bank, sound_bank,
    output logic [7:0] sub_control, scroll_x, scroll_y,
    input logic [1:0] mermaid_input_select, mermaid_dip_select,
    input logic [7:0] system_inputs_n, player1_inputs_n, player2_inputs_n,
    input logic [7:0] dsw1, dsw2,
    output logic [7:0] mermaid_p2_ext, mermaid_p3_ext,
    output logic [7:0] mermaid_command,
    output logic mermaid_command_pending,
    input logic mermaid_command_ack, mermaid_response_write,
    input logic [7:0] mermaid_response_data,
    output logic mermaid_response_pending,
    input logic main_event_64, main_event_240, main_irq_ack, sub_vblank,
    input logic ym_irq,
    output logic main_irq,
    output logic [7:0] main_vector,
    output logic sub_irq, sub_nmi, sound_irq, sound_nmi,
    output logic ym_req_valid,
    input logic ym_req_ready,
    output logic ym_req_write, ym_req_addr,
    output logic [7:0] ym_req_data,
    input logic ym_rsp_valid,
    input logic [7:0] ym_rsp_data,
    input logic [8:0] object_addr,
    output logic [63:0] object_data,
    input logic [9:0] tile_addr,
    output logic [7:0] tile_code, tile_attr,
    input logic [8:0] palette_addr,
    output logic [7:0] palette_low, palette_ext
);
    logic mem_req_valid, mem_req_ready, mem_req_write, mem_rsp_valid;
    logic [1:0] mem_req_cpu;
    logic [15:0] mem_req_addr;
    logic [7:0] mem_req_data, mem_rsp_data;
    logic sub_nmi_request, sub_irq_ack;
    logic [3:0] divider;
    logic [2:0] enabled_requests;

    assign game_ready = ram_ready && rom_loaded && backend_ready && !reset && !soft_reset;
    assign game_reset = !game_ready;
    assign sub_reset = game_reset || !mermaid_sub_release;
    assign enabled_requests = cpu_req_valid & {1'b1,~sub_reset,1'b1};
    assign cpu_cen = divider[2:0] == 3'd7 && game_ready;
    assign ym_cen = divider == 4'd15 && game_ready;
    always_ff @(posedge clk) begin
        if (game_reset) divider <= 4'd0;
        else divider <= divider + 4'd1;
    end

    heavyunit_bus bus (
        .clk, .reset(game_reset), .cpu_req_valid(enabled_requests),
        .cpu_req_ready, .cpu_req_io, .cpu_req_write, .cpu_req_addr,
        .cpu_req_data, .cpu_rsp_valid, .cpu_rsp_data,
        .mem_req_valid, .mem_req_ready, .mem_req_cpu, .mem_req_write,
        .mem_req_addr, .mem_req_data, .mem_rsp_valid, .mem_rsp_data,
        .main_bank, .sub_bank, .sound_bank, .sub_control, .scroll_x, .scroll_y,
        .sub_nmi_request, .sub_irq_ack, .mermaid_command,
        .mermaid_command_pending, .mermaid_command_ack,
        .mermaid_response_write, .mermaid_response_data,
        .mermaid_response_pending, .sound_nmi, .ym_req_valid,
        .ym_req_ready, .ym_req_write, .ym_req_addr, .ym_req_data,
        .ym_rsp_valid, .ym_rsp_data
    );
    heavyunit_memory memory (
        .clk, .reset, .init_done(ram_ready), .idle(memory_idle), .req_valid(mem_req_valid),
        .req_ready(mem_req_ready), .req_cpu(mem_req_cpu),
        .req_write(mem_req_write), .req_addr(mem_req_addr), .req_data(mem_req_data),
        .main_bank, .sub_bank, .sound_bank, .rsp_valid(mem_rsp_valid),
        .rsp_data(mem_rsp_data), .rom_req_valid, .rom_req_ready,
        .rom_req_addr, .rom_rsp_valid, .rom_rsp_data,
        .object_addr, .object_data, .tile_addr, .tile_code, .tile_attr,
        .palette_addr, .palette_low, .palette_ext
    );
    heavyunit_inputs inputs (
        .input_select(mermaid_input_select), .dip_select(mermaid_dip_select),
        .system_inputs_n, .player1_inputs_n, .player2_inputs_n, .dsw1, .dsw2,
        .command_pending(mermaid_command_pending),
        .response_pending(mermaid_response_pending),
        .p2_external(mermaid_p2_ext), .p3_external(mermaid_p3_ext)
    );
    heavyunit_irq irq (
        .clk, .reset(game_reset), .main_event_64, .main_event_240,
        .main_ack(main_irq_ack), .sub_vblank, .sub_ack(sub_irq_ack),
        .sub_reset, .sub_nmi_request, .cpu_cen, .ym_irq,
        .main_irq, .main_vector, .sub_irq, .sub_nmi, .sound_irq
    );
endmodule
