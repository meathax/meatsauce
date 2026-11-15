// SPDX-License-Identifier: GPL-3.0-or-later
// One selected-set image, using the MiSTer WIDE=1 ioctl byte-address protocol.
// ROM index 0 only. Every word is acknowledged before another is accepted.
// The same image offsets feed SDRAM and the real Mermaid program BRAM.
module heavyunit_loader (
    input logic clk, reset,
    input logic ioctl_download, ioctl_wr,
    input logic [7:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [15:0] ioctl_dout,
    output logic ioctl_wait,
    input logic [2:0] selected_set,
    output logic [2:0] loaded_set,
    input logic initialized, drained,
    output logic transfer_active, rom_loaded,
    output logic [2:0] error_code,
    output logic load_req_valid,
    input logic load_req_ready,
    output logic [24:0] load_req_addr,
    output logic [15:0] load_req_data,
    output logic [1:0] load_req_be,
    input logic load_rsp_valid,
    input logic [11:0] mermaid_addr,
    output logic [7:0] mermaid_data,
    // Zero-wait program ROM copies for the main and sub Z80s (image offsets
    // 00000..1FFFF and 20000..2FFFF). Synchronous read, one master cycle.
    input logic [16:0] main_rom_addr,
    output logic [7:0] main_rom_data,
    input logic [15:0] sub_rom_addr,
    output logic [7:0] sub_rom_data
);
    localparam logic [24:0] IMAGE_BYTES = 25'h2c1000;
    logic downloading, previous_download, active, complete;
    logic pending, issued, accepting, starting;
    logic [24:0] next_addr;
    logic [15:0] mermaid_rom [0:2047];
    logic [15:0] mermaid_word;
    logic mermaid_high;

    assign downloading = ioctl_download && ioctl_index == 0;
    assign starting = downloading && !previous_download;
    assign transfer_active = active || downloading;
    assign rom_loaded = complete && !transfer_active && !reset;
    assign ioctl_wait = ioctl_index == 0 && (reset || pending || !initialized ||
        (error_code != 0 && !starting));
    assign accepting = downloading && ioctl_wr && !ioctl_wait && !reset;
    assign load_req_valid = pending && !issued && !reset;
    assign load_req_be = 2'b11;
    assign mermaid_data = mermaid_high ? mermaid_word[15:8] : mermaid_word[7:0];

    // No reset loop: a complete image supplies all 2048 firmware words before
    // execution is allowed. This is a synchronous read port, one master cycle.
    always_ff @(posedge clk) begin
        mermaid_word <= mermaid_rom[mermaid_addr[11:1]];
        mermaid_high <= mermaid_addr[0];
        if (accepting && ioctl_addr >= 27'h040000 && ioctl_addr < 27'h041000 &&
            ioctl_addr == {2'd0,(starting ? 25'd0 : next_addr)} && !ioctl_addr[0])
            mermaid_rom[ioctl_addr[11:1]] <= ioctl_dout;
    end

    (* ramstyle = "M10K" *) logic [15:0] main_rom [0:65535];
    (* ramstyle = "M10K" *) logic [15:0] sub_rom [0:32767];
    logic [15:0] main_word, sub_word;
    logic main_high, sub_high;
    wire image_write = accepting && ioctl_addr == {2'd0,(starting ? 25'd0 : next_addr)} && !ioctl_addr[0];
    assign main_rom_data = main_high ? main_word[15:8] : main_word[7:0];
    assign sub_rom_data = sub_high ? sub_word[15:8] : sub_word[7:0];
    always_ff @(posedge clk) begin
        main_word <= main_rom[main_rom_addr[16:1]];
        main_high <= main_rom_addr[0];
        if (image_write && ioctl_addr < 27'h020000)
            main_rom[ioctl_addr[16:1]] <= ioctl_dout;
    end
    always_ff @(posedge clk) begin
        sub_word <= sub_rom[sub_rom_addr[15:1]];
        sub_high <= sub_rom_addr[0];
        if (image_write && ioctl_addr >= 27'h020000 && ioctl_addr < 27'h030000)
            sub_rom[ioctl_addr[15:1]] <= ioctl_dout;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            previous_download <= 0; active <= 0; complete <= 0;
            pending <= 0; issued <= 0; next_addr <= 0;
            load_req_addr <= 0; load_req_data <= 0; loaded_set <= 0;
            error_code <= 0;
        end else begin
            previous_download <= downloading;
            if (pending && !issued && load_req_ready) issued <= 1'b1;
            if (pending && issued && load_rsp_valid) begin
                pending <= 1'b0; issued <= 1'b0;
            end
            if (starting) begin
                active <= 1'b1; complete <= 1'b0; next_addr <= 0;
                loaded_set <= selected_set;
                error_code <= selected_set < 5 ? 3'd0 : 3'd3;
            end
            if (accepting && (starting ? selected_set < 5 : error_code == 0)) begin
                if (ioctl_addr != {2'd0,(starting ? 25'd0 : next_addr)} ||
                    ioctl_addr[0] || (starting ? 25'd0 : next_addr) >= IMAGE_BYTES) begin
                    error_code <= 3'd1;
                end else begin
                    load_req_addr <= ioctl_addr[24:0];
                    load_req_data <= ioctl_dout;
                    next_addr <= (starting ? 25'd0 : next_addr) + 25'd2;
                    pending <= 1'b1; issued <= 1'b0;
                end
            end
            if (active && !downloading && !pending && drained) begin
                active <= 1'b0;
                if (next_addr == IMAGE_BYTES && error_code == 0) complete <= 1'b1;
                else if (error_code == 0) error_code <= 3'd2;
            end
        end
    end
endmodule
