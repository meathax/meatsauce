// SPDX-License-Identifier: GPL-3.0-or-later
//
// MiSTer index-8 persistence bridge for the SSV battery-backed SDRAM window.
// The bridge owns one byte-enabled SDRAM write client and one 16-bit read
// client.  Arbitration against the ROM loader/core is intentionally external.
`timescale 1ns/1ps

module ssv_nvram_bridge #(
    parameter int SDR_AW = 26,
    parameter logic [SDR_AW:0] NVRAM_BASE = 27'h0460000
) (
    input  logic                    clk,
    input  logic                    rst,

    // Descriptor mode: 0=disabled, 1=2 KiB, 2=64 KiB.  Mode 3 is invalid
    // and is isolated in the same way as mode 0.
    input  logic [1:0]              nvram_size_mode,
    // Pulsed after an accepted index-1 descriptor has been committed and its
    // decoded mode is stable.
    input  logic                    cfg_commit,
    output logic                    init_busy,
    output logic                    init_done,

    // Pulse once for each completed CPU write to the descriptor NVRAM window.
    input  logic                    modified,
    output logic                    dirty,

    // MiSTer file interface.  This core uses the narrow (8-bit) hps_io mode.
    input  logic                    ioctl_download,
    input  logic                    ioctl_upload,
    input  logic                    ioctl_wr,
    input  logic                    ioctl_rd,
    input  logic [15:0]             ioctl_index,
    input  logic [26:0]             ioctl_addr,
    input  logic [7:0]              ioctl_dout,
    output logic [7:0]              ioctl_din,
    output logic                    ioctl_wait,
    output logic                    ioctl_upload_req,

    input  logic                    sdr_ready,

    // Shared controller write port.  Addresses are 16-bit word addresses,
    // matching rtl/mem/sdram.sv wr_addr[SDR_AW:1].
    output logic                    sdr_wr_req,
    output logic [SDR_AW:1]         sdr_wr_addr,
    output logic [15:0]             sdr_wr_din,
    output logic [1:0]              sdr_wr_be,
    input  logic                    sdr_wr_ack,

    // Dedicated 16-bit read client, suitable for an otherwise-free p3 port.
    output logic                    sdr_rd_req,
    output logic [SDR_AW:1]         sdr_rd_addr,
    input  logic [15:0]             sdr_rd_dout,
    input  logic                    sdr_rd_ack
);

function automatic logic [26:0] size_bytes(input logic [1:0] mode);
    case (mode)
        2'd1: size_bytes = 27'd2048;
        2'd2: size_bytes = 27'd65536;
        default: size_bytes = 27'd0;
    endcase
endfunction

wire [26:0] nvram_bytes = size_bytes(nvram_size_mode);
wire        enabled      = (nvram_bytes != 0);
wire        index_8      = (ioctl_index == 16'd8);
wire        addr_in_range = enabled && (ioctl_addr < nvram_bytes);
wire        download_selected = ioctl_download && index_8 && enabled;
wire        upload_selected   = ioctl_upload   && index_8 && enabled;
wire        download_byte = download_selected && ioctl_wr && addr_in_range;
wire        upload_byte   = upload_selected && addr_in_range;

wire [SDR_AW:1] selected_word_addr =
    NVRAM_BASE[SDR_AW:1] + ioctl_addr[SDR_AW:1];

// -------------------------------------------------------------------------
// Cold init and download share one writer.  Each descriptor load first writes
// MAME's DEFAULT_ALL_0 image across exactly 2 KiB or 64 KiB.  A later index-8
// persisted download overwrites that baseline byte by byte.
// -------------------------------------------------------------------------
logic [14:0] zero_word_index;
logic [15:0] zero_word_count;
logic        zero_active;
logic        wr_is_zero;

always_ff @(posedge clk) begin
    if (rst) begin
        sdr_wr_req  <= 1'b0;
        sdr_wr_addr <= '0;
        sdr_wr_din  <= 16'h0000;
        sdr_wr_be   <= 2'b00;
        zero_word_index <= 15'd0;
        zero_word_count <= 16'd0;
        zero_active <= 1'b0;
        wr_is_zero  <= 1'b0;
        init_busy   <= 1'b0;
        init_done   <= 1'b1;
    end
    else begin
        if (sdr_wr_req && sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;

            if (wr_is_zero) begin
                if ({1'b0, zero_word_index} + 16'd1 >= zero_word_count) begin
                    zero_active <= 1'b0;
                    init_busy   <= 1'b0;
                    init_done   <= 1'b1;
                end
                else begin
                    zero_word_index <= zero_word_index + 15'd1;
                end
            end
        end

        if (cfg_commit) begin
            sdr_wr_req      <= 1'b0;
            zero_word_index <= 15'd0;
            wr_is_zero      <= 1'b0;
            init_done       <= 1'b0;
            case (nvram_size_mode)
                2'd1: begin
                    zero_word_count <= 16'd1024;
                    zero_active     <= 1'b1;
                    init_busy       <= 1'b1;
                end
                2'd2: begin
                    zero_word_count <= 16'd32768;
                    zero_active     <= 1'b1;
                    init_busy       <= 1'b1;
                end
                default: begin
                    zero_word_count <= 16'd0;
                    zero_active     <= 1'b0;
                    init_busy       <= 1'b0;
                    init_done       <= 1'b1;
                end
            endcase
        end
        else if (zero_active && sdr_ready && !sdr_wr_req) begin
            sdr_wr_req  <= 1'b1;
            sdr_wr_addr <= NVRAM_BASE[SDR_AW:1] + zero_word_index;
            sdr_wr_din  <= 16'h0000;
            sdr_wr_be   <= 2'b11;
            wr_is_zero  <= 1'b1;
        end

        else if (download_byte && !init_busy && sdr_ready && !sdr_wr_req) begin
            sdr_wr_req  <= 1'b1;
            sdr_wr_addr <= selected_word_addr;
            sdr_wr_din  <= {ioctl_dout, ioctl_dout};
            sdr_wr_be   <= ioctl_addr[0] ? 2'b10 : 2'b01;
            wr_is_zero  <= 1'b0;
        end
    end
end

// -------------------------------------------------------------------------
// Upload: prefetch the current ioctl_addr through a 16-bit SDRAM read port.
// ioctl_wait remains asserted until data for that exact byte address is
// latched.  This is important because hps_io increments ioctl_addr at the same
// edge that it pulses ioctl_rd for the consumed byte.
// -------------------------------------------------------------------------
logic [26:0] rd_byte_addr;
logic        rd_byte_lane;
logic [7:0]  rd_byte_data;
logic        rd_valid;

wire upload_data_ready = rd_valid && (rd_byte_addr == ioctl_addr);

always_ff @(posedge clk) begin
    if (rst) begin
        sdr_rd_req  <= 1'b0;
        sdr_rd_addr <= '0;
        rd_byte_addr <= '0;
        rd_byte_lane <= 1'b0;
        rd_byte_data <= 8'h00;
        rd_valid     <= 1'b0;
    end
    else begin
        if (!upload_selected)
            rd_valid <= 1'b0;

        if (ioctl_rd && upload_selected && upload_data_ready)
            rd_valid <= 1'b0;

        if (sdr_rd_req && sdr_rd_ack) begin
            sdr_rd_req <= 1'b0;
            if (upload_byte && (rd_byte_addr == ioctl_addr)) begin
                rd_byte_data <= rd_byte_lane
                    ? sdr_rd_dout[15:8] : sdr_rd_dout[7:0];
                rd_valid <= 1'b1;
            end
            else begin
                rd_valid <= 1'b0;
            end
        end

        if (upload_byte && !init_busy && sdr_ready &&
            !sdr_rd_req && !upload_data_ready) begin
            sdr_rd_req   <= 1'b1;
            sdr_rd_addr  <= selected_word_addr;
            rd_byte_addr <= ioctl_addr;
            rd_byte_lane <= ioctl_addr[0];
            rd_valid     <= 1'b0;
        end
    end
end

always_comb begin
    ioctl_din = 8'h00;
    if (upload_byte && upload_data_ready)
        ioctl_din = rd_byte_data;

    // Out-of-range and disabled transfers never stall or touch SDRAM.  A
    // pending accepted write/read remains backpressured until its ack arrives.
    ioctl_wait = download_selected && (init_busy || sdr_wr_req);
    if (download_byte && (!sdr_ready || init_busy))
        ioctl_wait = 1'b1;
    if (upload_byte && (init_busy || !sdr_ready || !upload_data_ready))
        ioctl_wait = 1'b1;
end

// -------------------------------------------------------------------------
// Dirty/request lifecycle.
//
// Keep dirty set through the upload and clear it only after a clean completion.
// A CPU modification during upload survives completion and creates a fresh
// rising edge on ioctl_upload_req once the current upload has ended.
// -------------------------------------------------------------------------
logic upload_selected_q;
logic modified_during_upload;

always_ff @(posedge clk) begin
    if (rst || cfg_commit || !enabled) begin
        dirty                  <= 1'b0;
        ioctl_upload_req       <= 1'b0;
        upload_selected_q      <= 1'b0;
        modified_during_upload <= 1'b0;
    end
    else begin
        upload_selected_q <= upload_selected;

        // A host restore establishes the persisted baseline and is not itself
        // a modification.  CPU access must be held externally during transfer.
        if (download_byte && sdr_ready && !sdr_wr_req &&
            (ioctl_addr == 27'd0)) begin
            dirty                  <= 1'b0;
            ioctl_upload_req       <= 1'b0;
            modified_during_upload <= 1'b0;
        end

        if (upload_selected && !upload_selected_q) begin
            ioctl_upload_req       <= 1'b0;
            modified_during_upload <= 1'b0;
        end

        if (!upload_selected && upload_selected_q) begin
            dirty                  <= modified_during_upload;
            modified_during_upload <= 1'b0;
        end

        if (modified) begin
            dirty <= 1'b1;
            if (upload_selected)
                modified_during_upload <= 1'b1;
        end

        // hps_io edge-detects this level.  Hold it until index-8 upload starts;
        // after a modified-in-flight upload, raise a new edge on the next idle
        // cycle rather than while the first transfer is still active.
        if (dirty && !upload_selected && !upload_selected_q &&
            !ioctl_upload_req)
            ioctl_upload_req <= 1'b1;
    end
end

endmodule
