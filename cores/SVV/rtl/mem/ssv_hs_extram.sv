// SPDX-License-Identifier: GPL-3.0-or-later
//
// Byte port into the SDRAM-backed extra work RAM for the hiscore module.
//
// MAME maps SSV main RAM at $000000-$00ffff (block RAM in this core) and gives
// twineag2/ultrax a second RAM at $010000-$03ffff (ssv.cpp: "More RAM"), which
// this core keeps in SDRAM at SDR_CPU_RAM_BASE.  hiscore.dat puts the score
// table of both games in that second RAM, so the hiscore module needs a path
// to it.  SDRAM cannot answer in the single cycle the module's extraction loop
// assumes, hence the ram_ready handshake it now carries.
//
// Reads are cached one 8-byte SDRAM burst at a time.  The module walks the
// table byte by byte, so a line serves eight accesses and the CPU stays paused
// for a fraction of the time a per-byte read would cost.
`timescale 1ns/1ps

module ssv_hs_extram #(
    parameter int SDR_AW = 26,
    // Physical base of the extra work RAM window (ssv_pkg::SDR_CPU_RAM_BASE).
    parameter logic [SDR_AW:0] EXTRA_BASE = 27'h0420000,
    // CPU byte address the window starts at.  Both bases are 8-byte aligned,
    // which keeps the burst-line index a plain slice of the CPU address.
    parameter logic [17:0]     CPU_BASE   = 18'h10000
) (
    input  logic             clk,
    input  logic             rst,

    // High only for a descriptor with extra_ram_mode == 2 (the $010000 window).
    input  logic             enable,
    // High while the hiscore module is inside a RAM access (its ram_intent_*
    // outputs).  The cached line is dropped between accesses: the CPU runs in
    // that gap and is the one updating the score table, so a line held across
    // it would hand the next extraction pre-CPU bytes.
    input  logic             hs_access,

    // Hiscore-module side.  hs_addr is a CPU byte address.
    input  logic [17:0]      hs_addr,
    input  logic             hs_write,
    input  logic [7:0]       hs_din,
    output logic [7:0]       hs_dout,
    output logic             hs_ready,
    output logic             hs_sel,

    input  logic             sdr_ready,

    // 64-bit read client, suitable for an otherwise-free p1 port.
    output logic             rd_req,
    output logic [SDR_AW:3]  rd_addr,
    input  logic [63:0]      rd_dout,
    input  logic             rd_ack,

    // Shared byte-enabled write client.  Arbitration is external, exactly as
    // for ssv_nvram_bridge.
    output logic             wr_req,
    output logic [SDR_AW:1]  wr_addr,
    output logic [15:0]      wr_din,
    output logic [1:0]       wr_be,
    input  logic             wr_ack
);

wire [17:0] offset    = hs_addr - CPU_BASE;
wire [SDR_AW:0] phys  = EXTRA_BASE + {9'd0, offset};
wire [SDR_AW:3] line  = phys[SDR_AW:3];
wire [1:0]  word_sel  = hs_addr[2:1];
wire        byte_sel  = hs_addr[0];

assign hs_sel = enable && (hs_addr >= CPU_BASE);

logic             line_valid;
logic [SDR_AW:3]  line_tag;
logic [63:0]      line_data;
logic [SDR_AW:3]  rd_tag;
logic             wr_busy;
logic             hs_write_q;

wire hit = line_valid && (line_tag == line);

assign hs_ready = !hs_sel || (hit && !wr_busy);

wire [5:0]  line_word_bit = {word_sel, 4'd0};
wire [5:0]  line_byte_bit = {hs_addr[2:0], 3'd0};
wire [15:0] hit_word = line_data[line_word_bit +: 16];
assign hs_dout = byte_sel ? hit_word[15:8] : hit_word[7:0];

always_ff @(posedge clk) begin
    if (rst) begin
        rd_req     <= 1'b0;
        rd_addr    <= '0;
        rd_tag     <= '0;
        wr_req     <= 1'b0;
        wr_addr    <= '0;
        wr_din     <= '0;
        wr_be      <= '0;
        wr_busy    <= 1'b0;
        line_valid <= 1'b0;
        line_tag   <= '0;
        line_data  <= '0;
        hs_write_q <= 1'b0;
    end
    else begin
        hs_write_q <= hs_write;

        if (!enable || !hs_access)
            line_valid <= 1'b0;

        if (rd_req && rd_ack) begin
            rd_req     <= 1'b0;
            line_data  <= rd_dout;
            line_tag   <= rd_tag;
            line_valid <= 1'b1;
        end
        else if (hs_sel && !hit && !rd_req && !wr_busy && sdr_ready) begin
            rd_req  <= 1'b1;
            rd_addr <= line;
            rd_tag  <= line;
        end

        if (wr_req && wr_ack) begin
            wr_req  <= 1'b0;
            wr_busy <= 1'b0;
        end
        else if (hs_write && !hs_write_q && hs_sel && !wr_busy && sdr_ready) begin
            wr_req  <= 1'b1;
            wr_busy <= 1'b1;
            wr_addr <= phys[SDR_AW:1];
            wr_din  <= {hs_din, hs_din};
            wr_be   <= byte_sel ? 2'b10 : 2'b01;
            // Keep the cached line coherent with what was just written so a
            // later extraction pass does not read back the pre-restore byte.
            if (hit)
                line_data[line_byte_bit +: 8] <= hs_din;
        end
    end
end

endmodule
