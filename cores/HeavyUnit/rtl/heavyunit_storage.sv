// SPDX-License-Identifier: GPL-3.0-or-later
// Actual P2 storage path: ioctl image -> acknowledged SDRAM + Mermaid BRAM.
// Game clients are blocked until the final write and every old read drain.
module heavyunit_storage (
    input logic clk, reset,
    input logic ioctl_download, ioctl_wr,
    input logic [7:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [15:0] ioctl_dout,
    output logic ioctl_wait,
    input logic [2:0] selected_set,
    output logic [2:0] loaded_set,
    output logic initialized, drained, transfer_active, rom_loaded,
    output logic [2:0] error_code,
    input logic cpu_req_valid,
    output logic cpu_req_ready,
    input logic [21:0] cpu_req_addr,
    output logic cpu_rsp_valid,
    output logic [7:0] cpu_rsp_data,
    output logic [31:0] cpu_rsp_line_data,
    input logic object_req_valid,
    input logic object_req_full_tile,
    output logic object_req_ready,
    input logic [21:0] object_req_addr,
    output logic object_rsp_valid,
    output logic object_rsp_last,
    output logic [63:0] object_rsp_data,
    input logic tile_req_valid,
    output logic tile_req_ready,
    input logic [21:0] tile_req_addr,
    output logic tile_rsp_valid,
    output logic [63:0] tile_rsp_data,
    input logic [11:0] mermaid_addr,
    output logic [7:0] mermaid_data,
    input logic [16:0] main_rom_addr,
    output logic [7:0] main_rom_data,
    input logic [15:0] sub_rom_addr,
    output logic [7:0] sub_rom_data,
    input logic [15:0] dq_in,
    output logic [15:0] dq_out,
    output logic dq_oe,
    output logic [12:0] sdram_addr,
    output logic [1:0] sdram_bank,
    output logic sdram_dqml, sdram_dqmh,
    output logic sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas,
    output logic sdram_cke, sdram_clk
);
    logic load_req_valid, load_req_ready, load_rsp_valid;
    logic [24:0] load_req_addr;
    logic [15:0] load_req_data;
    logic [1:0] load_req_be;
    logic cpu_ready, object_ready, tile_ready;
    assign cpu_req_ready = cpu_ready && rom_loaded;
    assign object_req_ready = object_ready && rom_loaded;
    assign tile_req_ready = tile_ready && rom_loaded;

    heavyunit_loader loader (
        .clk, .reset, .ioctl_download, .ioctl_wr, .ioctl_index, .ioctl_addr,
        .ioctl_dout, .ioctl_wait, .selected_set, .loaded_set, .initialized, .drained,
        .transfer_active, .rom_loaded, .error_code, .load_req_valid, .load_req_ready,
        .load_req_addr, .load_req_data, .load_req_be, .load_rsp_valid,
        .mermaid_addr, .mermaid_data,
        .main_rom_addr, .main_rom_data, .sub_rom_addr, .sub_rom_data
    );
    heavyunit_sdram backend (
        .clk, .reset, .download_active(transfer_active), .initialized, .drained,
        .cpu_req_valid(cpu_req_valid && rom_loaded), .cpu_req_ready(cpu_ready),
        .cpu_req_addr({3'd0,cpu_req_addr}), .cpu_rsp_valid, .cpu_rsp_data, .cpu_rsp_line_data,
        .object_req_full_tile, .object_rsp_last,
        .object_req_valid(object_req_valid && rom_loaded), .object_req_ready(object_ready),
        .object_req_addr({3'd0,object_req_addr}), .object_rsp_valid, .object_rsp_data,
        .tile_req_valid(tile_req_valid && rom_loaded), .tile_req_ready(tile_ready),
        .tile_req_addr({3'd0,tile_req_addr}), .tile_rsp_valid, .tile_rsp_data,
        .load_req_valid, .load_req_ready, .load_req_addr, .load_req_data, .load_req_be,
        .load_rsp_valid, .dq_in, .dq_out, .dq_oe, .sdram_addr, .sdram_bank,
        .sdram_dqml, .sdram_dqmh, .sdram_ncs, .sdram_nwe, .sdram_nras, .sdram_ncas,
        .sdram_cke, .sdram_clk
    );
endmodule
