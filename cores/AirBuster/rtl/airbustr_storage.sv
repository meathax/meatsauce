// SPDX-License-Identifier: GPL-3.0-or-later
// Actual P2 storage path: ioctl image -> acknowledged SDRAM + Mermaid BRAM.
// Game clients are blocked until the final write and every old read drain.
module airbustr_storage (
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
    input logic [17:0] oki_rom_addr,
    input logic oki_rom_req,
    output logic oki_rom_ok,
    output logic [7:0] oki_rom_data,
    input logic [16:0] main_rom_addr,
    output logic [7:0] main_rom_data,
    input logic [16:0] sub_rom_addr,
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
    // The program-cache backend and the OKI sample fetcher share SDRAM ch1
    // (one outstanding read). OKI has a fixed sample deadline; it has priority
    // over new CPU requests. A stalled offer retains its owner/address. OKI keeps one 32-bit
    // line and reports rom_ok when it covers the requested byte.
    logic port_valid, port_owner_oki, port_busy, port_rsp_valid;
    logic [21:0] port_addr;
    logic [31:0] port_line;
    logic [15:0] oki_tag;
    logic [31:0] oki_line;
    logic oki_line_valid;
    logic grant_held,grant_oki;
    logic [21:0] grant_addr;
    logic [15:0] grant_tag;
    wire oki_hit = oki_line_valid && oki_tag == oki_rom_addr[17:2];
    wire oki_need = oki_rom_req && rom_loaded && !oki_hit && !port_busy;
    assign oki_rom_ok = oki_hit;
    assign oki_rom_data = oki_line[8*oki_rom_addr[1:0] +: 8];
    wire selected_oki = grant_held ? grant_oki : oki_need;
    assign port_valid = grant_held || cpu_req_valid || oki_need;
    assign port_addr = grant_held ? grant_addr :
        selected_oki ? 22'h060000 + {4'd0,oki_rom_addr[17:2],2'b00} : cpu_req_addr;
    assign cpu_req_ready = cpu_ready && rom_loaded && !port_busy && !selected_oki;
    assign cpu_rsp_valid = port_rsp_valid && !port_owner_oki;
    assign cpu_rsp_line_data = port_line;
    always_ff @(posedge clk) begin
        if (reset || transfer_active) begin
            port_busy <= 0; port_owner_oki <= 0; oki_line_valid <= 0; oki_tag <= 0; oki_line <= 0;
            grant_held <= 0; grant_oki <= 0; grant_addr <= 0; grant_tag <= 0;
        end else begin
            if (!port_busy && port_valid && cpu_ready && rom_loaded) begin
                port_busy <= 1; port_owner_oki <= selected_oki; grant_held <= 0;
                if (selected_oki) begin
                    oki_tag <= grant_held ? grant_tag : oki_rom_addr[17:2];
                    // The replacement tag cannot validate bytes from the old line.
                    oki_line_valid <= 0;
                end
            end else if (!port_busy && port_valid && rom_loaded && !grant_held) begin
                grant_held <= 1; grant_oki <= selected_oki; grant_addr <= port_addr;
                grant_tag <= oki_rom_addr[17:2];
            end else if (port_busy && port_rsp_valid) begin
                port_busy <= 0;
                if (port_owner_oki) begin oki_line <= port_line; oki_line_valid <= 1; end
            end
        end
    end
    assign object_req_ready = object_ready && rom_loaded;
    assign tile_req_ready = tile_ready && rom_loaded;

    airbustr_loader loader (
        .clk, .reset, .ioctl_download, .ioctl_wr, .ioctl_index, .ioctl_addr,
        .ioctl_dout, .ioctl_wait, .selected_set, .loaded_set, .initialized, .drained,
        .transfer_active, .rom_loaded, .error_code, .load_req_valid, .load_req_ready,
        .load_req_addr, .load_req_data, .load_req_be, .load_rsp_valid,
        .main_rom_addr, .main_rom_data, .sub_rom_addr, .sub_rom_data
    );
    airbustr_sdram backend (
        .clk, .reset, .download_active(transfer_active), .initialized, .drained,
        .cpu_req_valid(port_valid && rom_loaded && !port_busy), .cpu_req_ready(cpu_ready),
        .cpu_req_addr({3'd0,port_addr}), .cpu_rsp_valid(port_rsp_valid), .cpu_rsp_data, .cpu_rsp_line_data(port_line),
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
