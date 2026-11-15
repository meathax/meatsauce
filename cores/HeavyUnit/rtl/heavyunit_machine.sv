// SPDX-License-Identifier: GPL-3.0-or-later
// One real 48 MHz game/storage composition. Power/PLL reset invalidates ROM;
// warm game reset preserves the image, firmware and work RAM. Any old ROM
// transaction drains before the CPU bus can accept the next generation.
module heavyunit_machine (
    input logic clk, reset,
    input logic soft_reset,
    output logic ram_ready, game_ready, game_reset, memory_idle,
    output logic cpu_cen, ym_cen,
    input logic mermaid_sub_release,
    output logic sub_reset,
    input logic [2:0] cpu_req_valid,
    input logic [2:0] cpu_rom_quiesce,
    output logic [2:0] cpu_rom_pending,
    output logic [2:0] cpu_req_ready,
    input logic [2:0] cpu_req_io, cpu_req_write,
    input logic [47:0] cpu_req_addr,
    input logic [23:0] cpu_req_data,
    output logic [2:0] cpu_rsp_valid,
    output logic [23:0] cpu_rsp_data,
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
    output logic [7:0] palette_low, palette_ext,
    input logic ioctl_download, ioctl_wr,
    input logic [7:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [15:0] ioctl_dout,
    output logic ioctl_wait,
    input logic [2:0] selected_set,
    output logic [2:0] loaded_set,
    output logic initialized, drained, transfer_active, rom_loaded,
    output logic [2:0] error_code,
    input logic object_req_valid,object_req_full_tile,
    output logic object_req_ready,
    input logic [21:0] object_req_addr,
    output logic object_rsp_valid,object_rsp_last,
    output logic [63:0] object_rsp_data,
    input logic tile_req_valid,
    output logic tile_req_ready,
    input logic [21:0] tile_req_addr,
    output logic tile_rsp_valid,
    output logic [63:0] tile_rsp_data,
    input logic [11:0] mermaid_addr,
    output logic [7:0] mermaid_data,
    input logic [15:0] dq_in,
    output logic [15:0] dq_out,
    output logic dq_oe,
    output logic [12:0] sdram_addr,
    output logic [1:0] sdram_bank,
    output logic sdram_dqml, sdram_dqmh,
    output logic sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas,
    output logic sdram_cke, sdram_clk
);
    logic rom_req_valid, rom_req_ready, rom_rsp_valid;
    logic [21:0] rom_req_addr;
    logic [7:0] rom_rsp_data;
    logic release_safe;
    logic [2:0] board_req_valid,board_req_ready,board_rsp_valid,cache_req_ready,cache_rsp_valid,rom_route;
    logic [23:0] board_rsp_data,cache_rsp_data;
    logic board_memory_idle,cache_cleared,cache_drained,previous_transfer_active;
    logic cache_backend_req_valid,cache_backend_req_ready,cache_backend_rsp_valid;
    logic [21:0] cache_backend_req_addr;
    logic [31:0] cache_backend_rsp_line_data;
    logic [95:0] cache_hit_count,cache_miss_count;
    logic [31:0] cache_refill_count,cache_stale_fill_drops,cache_cancel_count;
    logic [16:0] main_rom_addr;
    logic [15:0] sub_rom_addr;
    logic [7:0] main_rom_data,sub_rom_data;
    always_ff @(posedge clk) begin
        if(reset) previous_transfer_active<=0; else previous_transfer_active<=transfer_active;
    end
    always_comb begin
        for(integer i=0;i<3;i=i+1)
            rom_route[i]=!cpu_req_io[i] && !cpu_req_write[i] && cpu_req_addr[16*i+:16]<16'hc000;
    end
    assign board_req_valid=cpu_req_valid & ~rom_route;
    assign cpu_req_ready=(rom_route & cache_req_ready) | (~rom_route & board_req_ready);
    assign cpu_rsp_valid=board_rsp_valid | cache_rsp_valid;
    always_comb begin
        for(integer i=0;i<3;i=i+1)
            cpu_rsp_data[8*i+:8]=cache_rsp_valid[i] ? cache_rsp_data[8*i+:8] : board_rsp_data[8*i+:8];
    end
    assign memory_idle=board_memory_idle && cache_drained;
    // ROM reads never enter the serialized board path in this prototype.
    assign rom_req_ready=1'b0;
    assign rom_rsp_valid=1'b0;
    assign rom_rsp_data=8'hff;
    heavyunit_cpu_rom_cache cpu_rom_cache (
        .clk,.reset,.invalidate(transfer_active && !previous_transfer_active),
        .image_valid(rom_loaded && !transfer_active),.accept_enable(release_safe && !soft_reset),
        .cpu_quiesce(cpu_rom_quiesce),.cpu_req_valid(cpu_req_valid & rom_route),
        .cpu_req_ready(cache_req_ready),.cpu_req_addr,.cpu_rsp_valid(cache_rsp_valid),
        .cpu_rsp_data(cache_rsp_data),.cpu_pending(cpu_rom_pending),.main_bank,.sub_bank,.sound_bank,
        .backend_req_valid(cache_backend_req_valid),.backend_req_ready(cache_backend_req_ready),
        .backend_req_addr(cache_backend_req_addr),.backend_rsp_valid(cache_backend_rsp_valid),
        .backend_rsp_line_data(cache_backend_rsp_line_data),
        .main_rom_addr,.main_rom_data,.sub_rom_addr,.sub_rom_data,
        .cleared(cache_cleared),.drained(cache_drained),
        .hit_count(cache_hit_count),.miss_count(cache_miss_count),.refill_count(cache_refill_count),
        .stale_fill_drops(cache_stale_fill_drops),.cancel_count(cache_cancel_count)
    );
    always_ff @(posedge clk) begin
        if (reset || soft_reset || transfer_active || !rom_loaded)
            release_safe <= 1'b0;
        else if (initialized && drained && memory_idle && cache_cleared)
            release_safe <= 1'b1;
        // Latch release: normal ROM traffic must never assert game reset.
    end
    heavyunit_board board (
        .clk,
        .reset(reset || transfer_active),
        .soft_reset(soft_reset || !release_safe),
        .rom_loaded,
        .backend_ready(release_safe),
        .ram_ready,
        .game_ready,
        .game_reset,
        .memory_idle(board_memory_idle),
        .cpu_cen,
        .ym_cen,
        .mermaid_sub_release,
        .sub_reset,
        .cpu_req_valid(board_req_valid),
        .cpu_req_ready(board_req_ready),
        .cpu_req_io,
        .cpu_req_write,
        .cpu_req_addr,
        .cpu_req_data,
        .cpu_rsp_valid(board_rsp_valid),
        .cpu_rsp_data(board_rsp_data),
        .rom_req_valid,
        .rom_req_ready,
        .rom_req_addr,
        .rom_rsp_valid,
        .rom_rsp_data,
        .main_bank,
        .sub_bank,
        .sound_bank,
        .sub_control,
        .scroll_x,
        .scroll_y,
        .mermaid_input_select,
        .mermaid_dip_select,
        .system_inputs_n,
        .player1_inputs_n,
        .player2_inputs_n,
        .dsw1,
        .dsw2,
        .mermaid_p2_ext,
        .mermaid_p3_ext,
        .mermaid_command,
        .mermaid_command_pending,
        .mermaid_command_ack,
        .mermaid_response_write,
        .mermaid_response_data,
        .mermaid_response_pending,
        .main_event_64,
        .main_event_240,
        .main_irq_ack,
        .sub_vblank,
        .ym_irq,
        .main_irq,
        .main_vector,
        .sub_irq,
        .sub_nmi,
        .sound_irq,
        .sound_nmi,
        .ym_req_valid,
        .ym_req_ready,
        .ym_req_write,
        .ym_req_addr,
        .ym_req_data,
        .ym_rsp_valid,
        .ym_rsp_data,
        .object_addr,
        .object_data,
        .tile_addr,
        .tile_code,
        .tile_attr,
        .palette_addr,
        .palette_low,
        .palette_ext
    );
    heavyunit_storage storage (
        .clk,
        .reset,
        .ioctl_download,
        .ioctl_wr,
        .ioctl_index,
        .ioctl_addr,
        .ioctl_dout,
        .ioctl_wait,
        .selected_set,
        .loaded_set,
        .initialized,
        .drained,
        .transfer_active,
        .rom_loaded,
        .error_code,
        .object_req_full_tile,.object_rsp_last,
        .object_req_valid,
        .object_req_ready,
        .object_req_addr,
        .object_rsp_valid,
        .object_rsp_data,
        .tile_req_valid,
        .tile_req_ready,
        .tile_req_addr,
        .tile_rsp_valid,
        .tile_rsp_data,
        .mermaid_addr,
        .mermaid_data,
        .main_rom_addr,.main_rom_data,.sub_rom_addr,.sub_rom_data,
        .dq_in,
        .dq_out,
        .dq_oe,
        .sdram_addr,
        .sdram_bank,
        .sdram_dqml,
        .sdram_dqmh,
        .sdram_ncs,
        .sdram_nwe,
        .sdram_nras,
        .sdram_ncas,
        .sdram_cke,
        .sdram_clk,
        .cpu_req_valid(cache_backend_req_valid),
        .cpu_req_ready(cache_backend_req_ready),
        .cpu_req_addr(cache_backend_req_addr),
        .cpu_rsp_valid(cache_backend_rsp_valid),
        .cpu_rsp_data(),
        .cpu_rsp_line_data(cache_backend_rsp_line_data)
    );
endmodule
