// SPDX-License-Identifier: GPL-3.0-or-later
// Fetch one 16-pixel Dyna Gear tile row with a single 128-bit SDRAM burst.
//
// The ROM loader packs the three populated MAME graphics quarters into one
// aligned 16-byte record per tile row (ssv_pkg::gfx_record_addr), so what used
// to be two serial p1 transactions -- the packed Q0/Q1 beat, then the Q2 beat
// of which half was discarded -- is now one p2 transaction. MAME's absent
// fourth quarter reads as zero.
`timescale 1ns/1ps

module ssv_gfx_row_fetch (
    input  logic         clk,
    input  logic         rst,
    // Per-game configuration; supplies the tile-code modulus.
    input  ssv_pkg::ssv_cfg_t cfg,
    input  logic         start,
    input  logic  [19:0] tile_code,
    input  logic   [2:0] tile_row,

    output logic         rom_req,
    output logic  [ssv_pkg::SDR_AW:4] rom_addr,
    input  logic [127:0] rom_data,
    input  logic         rom_ack,

    output logic         busy,
    output logic         done,
    output logic  [31:0] plane01,
    output logic  [31:0] plane23,
    output logic  [31:0] plane45,
    output logic  [31:0] plane67
);

import ssv_pkg::*;

typedef enum logic {IDLE, WAIT_ACK} state_t;
state_t state;

// Tile-code wrapping is MAME's `code % elements()`, and elements() is
// per-game (0x18000 / 0x20000 / 0x30000 / 0x40000). The old local
// `code[16:0]` mask was only correct for Dyna Gear's 0x20000; see
// ssv_pkg::wrap_code_cfg and verif/tb_ssv_cfg.sv, which measures the old mask
// disagreeing with the modulo 643 times per sweep on a 0x30000 title.

// Quartus 17's Verilog parser rejects a bit-select applied straight to a
// function call: `gfx_record_addr(...)[SDR_AW:4]` is a syntax error there even
// though the simulator accepts it. Naming the result keeps both toolchains
// happy. (A comment line may not begin with the simulator's name either --
// that is read as a lint pragma.)
// 18 bits, not 17. wrap_code_cfg already returns 18, and a 0x40000-tile title
// (any 32 MB sprite region: cairblad, drifto94, vasara, vasara2) uses all of
// them. The old 17'(...) cast silently folded the upper half of tile space onto
// the lower half; Dyna Gear's 0x20000 tiles fit 17 bits exactly, so it was the
// one title that could not show the fault.
wire [SDR_AW:0] start_record_addr =
    gfx_record_addr(wrap_code_cfg(cfg, tile_code), tile_row);

always_ff @(posedge clk) begin
    if (rst) begin
        state    <= IDLE;
        rom_req  <= 1'b0;
        rom_addr <= '0;
        busy     <= 1'b0;
        done     <= 1'b0;
        plane01  <= 32'd0;
        plane23  <= 32'd0;
        plane45  <= 32'd0;
        plane67  <= 32'd0;
    end
    else begin
        done <= 1'b0;
        unique case (state)
            IDLE: begin
                rom_req <= 1'b0;
                busy    <= 1'b0;
                if (start) begin
                    rom_addr <= start_record_addr[SDR_AW:4];
                    rom_req  <= 1'b1;
                    busy     <= 1'b1;
                    state    <= WAIT_ACK;
                end
            end

            WAIT_ACK: begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    plane01 <= rom_data[31:0];
                    plane23 <= rom_data[63:32];
                    plane45 <= rom_data[95:64];
                    // Bytes 12..15 are the record's quarter-3 slot. On a
                    // three-quarter title (Dyna Gear) the loader never writes
                    // them, so they hold whatever the chip powered up with --
                    // X against a chip model. Forcing zero there is
                    // load-bearing, not cosmetic.
                    //
                    // Four-quarter titles (drifto94, vasara, vasara2)
                    // DO populate it, so the choice is now per game rather than
                    // a constant. Reading unwritten memory on a 3-quarter title
                    // would be the same bug in the other direction, which is
                    // why this is gated and not simply opened up.
                    plane67 <= (cfg.gfx_quarters == 3'd4) ? rom_data[127:96]
                                                          : 32'd0;
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    state   <= IDLE;
                end
            end
        endcase
    end
end

endmodule
