// SPDX-License-Identifier: GPL-3.0-or-later
//============================================================================
//  ST010 program fetch: SDRAM-backed 24-bit instruction supply for upd96050.
//
//  WHY THIS EXISTS AT ALL
//  ----------------------
//  The uPD96050's program store is 16384 x 24 bits = 393,216 bits. An M10K
//  holds 10,240 BITS, so on chip this is 16 blocks deep x 3 lanes = 48 M10K
//  against 36 free. The core therefore fetches externally, which is why
//  upd96050.sv exposes prg_req/prg_valid rather than embedding a ROM.
//  Do not "simplify" this away -- see docs/PHASE9_ST010_SPEC.md correction 1.
//
//  PORT CHOICE: p5, the second 64-bit 4-word burst port
//  ---------------------------------------------------
//  p1 (64-bit burst), p3 (16-bit) and p5 (64-bit burst) were all tied off.
//    - p3 is 16 bits per transaction. A 24-bit instruction would need two
//      transactions, doubling both the request count and the FSM's states, for
//      no benefit.
//    - p1 and p5 are identical in width and burst length. p5 is chosen because
//      it is LAST in the round-robin priority chain (sdram.sv:237-242), so a
//      DSP fetch can never delay the graphics row fetcher (p2) or the sample
//      engine (p4) ahead of it in any arbitration state. p1 sits immediately
//      after p0 and would be the more intrusive of the two.
//
//  BANDWIDTH, WITH THE ARITHMETIC SHOWN
//  ------------------------------------
//    ce_dsp     = 2.5 MHz          (MAME's 10 MHz / 4-clock instruction)
//    clk_sys    = 48.324 MHz       -> 19.3 clk_sys per instruction
//    clk_ram    = 96.648 MHz       (clk_sys x 2)
//
//  One p5 burst returns 4 x 16 bits = 8 bytes = TWO instruction dwords, so a
//  single-line cache serving strictly sequential code misses on every second
//  instruction:
//
//    bursts/s  = 2.5e6 / 2 = 1.25e6
//    clk_ram budget per burst = 96.648e6 / 1.25e6 = 77 clk_ram
//
//  A row-hit 4-word read on this controller costs CAS + 4 beats, order 8-10
//  clk_ram, so the DSP occupies about 12% of the cycles it is given -- and the
//  region lives alone in SDRAM bank 2, whose 2048-column row spans 4 KB = 1024
//  instructions, so consecutive fetches are row hits by construction and never
//  evict another client's open row. Branch-heavy code raises the miss rate
//  toward 1 burst per instruction (2.5e6/s, 38 clk_ram of budget), still
//  roughly 4x margin. That is why one line is enough and no prefetch is added:
//  an unmeasured prefetcher would spend M10K/ALM to buy headroom that is
//  already there.
//
//  BYTE EXTRACTION
//  ---------------
//  The loader packs stream byte pairs little-endian, so the SDRAM word at byte
//  address 2k is { rom[2k+1], rom[2k] }. sdram.sv delivers
//  p5_dout = {word@+6, word@+4, word@+2, word@+0} (deliver(), :628), hence
//  byte n of the 8-byte line is d[8n +: 8].
//
//  MAME's dspprg is 32-bit BIG-endian and the fetch is read_dword(pc) >> 8:
//      prg_data = { rom[4pc+0], rom[4pc+1], rom[4pc+2] }   MSB first
//  Instruction 2m of a line uses bytes 0,1,2; instruction 2m+1 uses 4,5,6.
//  Bytes 3 and 7 are the unused low byte of each dword.
//============================================================================

`timescale 1ns/1ps

module ssv_st010_prg_fetch (
    input        clk,
    input        rst,
    // Held low when the running game has no ST010: the FSM parks, sdr_req is
    // constant 0 and the port behaves exactly as the tie-off it replaces.
    input        enable,

    // upd96050 side. prg_req is held until prg_valid and prg_addr is stable for
    // the whole burst (upd96050.sv:80), so no address latch is needed on entry.
    input [13:0] prg_addr,
    input        prg_req,
    output [23:0] prg_data,
    output       prg_valid,

    // SDRAM p5: 64-bit, 4-word burst, address in 8-byte units.
    output logic sdr_req,
    output logic [ssv_pkg::SDR_AW:3] sdr_addr,
    input [63:0] sdr_dout,
    input        sdr_ack
);

import ssv_pkg::*;

// One 8-byte line. Tag is the line number, i.e. the instruction address with
// its low bit removed.
logic [63:0] line_data;
logic [12:0] line_tag;
logic        line_valid;
logic [12:0] req_tag;
logic        busy;
logic        ack_d;

wire [12:0] want_tag = prg_addr[13:1];
wire        hit      = line_valid && (line_tag == want_tag);

assign prg_valid = enable && hit;
assign prg_data  = prg_addr[0]
                 ? {line_data[39:32], line_data[47:40], line_data[55:48]}
                 : {line_data[ 7: 0], line_data[15: 8], line_data[23:16]};

// Line base byte address -> p5 units. pc with bit 0 cleared is the first
// instruction of the line.
wire [SDR_AW:0] line_byte = st010_prg_byte_addr({want_tag, 1'b0});

always_ff @(posedge clk) begin
    if (rst || !enable) begin
        sdr_req    <= 1'b0;
        sdr_addr   <= '0;
        busy       <= 1'b0;
        line_valid <= 1'b0;
        line_tag   <= '0;
        req_tag    <= '0;
        ack_d      <= 1'b0;
    end
    else begin
        ack_d <= sdr_ack;
        if (busy) begin
            // sdram.sv stretches ack for 2 clk_ram = 1 clk_sys, so the rising
            // edge is the one and only sample point.
            if (sdr_ack && !ack_d) begin
                line_data  <= sdr_dout;
                line_tag   <= req_tag;
                line_valid <= 1'b1;
                busy       <= 1'b0;
                sdr_req    <= 1'b0;
            end
        end
        // Do not raise a fresh req while the previous transfer's stretched ack
        // is still high: the controller latches on the req RISING edge, and an
        // overlapping ack would be mistaken for this request's completion.
        else if (prg_req && !hit && !sdr_ack) begin
            req_tag  <= want_tag;
            sdr_addr <= line_byte[SDR_AW:3];
            sdr_req  <= 1'b1;
            busy     <= 1'b1;
        end
    end
end

endmodule
