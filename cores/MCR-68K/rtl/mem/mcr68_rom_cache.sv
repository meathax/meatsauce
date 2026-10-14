`timescale 1ns/10ps
`default_nettype none

// =============================================================================
// mcr68_rom_cache.sv -- direct-mapped read-only cache for a CPU program-ROM
// SDRAM client (mcr68_rom_fabric.sv client contract on both sides).
//
// WHY THIS EXISTS (2026-08-26 hardware root-cause): with SDRAM_ROM=1 every
// main/sound-CPU ROM bus cycle waits for the full fabric+SDRAM round trip
// (request registration, arbitration against the video/sprite ports, tRP/
// tRCD/CL and the 2-cycle ack stretch).  Best case that is ~240 ns after AS,
// which already misses the 68000's end-of-S4 DTACK sample (~187 ns at 8 MHz),
// so EVERY ROM fetch takes at least one extra wait pair and, under video/
// sprite contention, several.  Both 68000s execute almost entirely from ROM,
// so on real hardware they ran far below their nominal rate while every
// simulation harness (host-file ROMs, flat one-wait DTACK) ran at full speed.
// Observed consequences on the bench: "Sounds Good" music noticeably slow
// and warbling (its tempo and DAC cadence are pure software loops), and
// Xenophobe permanently black -- its boot RAM test (walking-bit loop at
// ~0xA352-0xA376) pets the watchdog ($0B0000) only between sections; slowed
// enough, a section exceeds the 8-vblank watchdog window and the board reset
// loops forever inside the test (hardware debug screen: PC always inside the
// test loop, frame counter advancing, WDOG trip flag set).
//
// The cache restores the verified simulation cadence on hardware: a hit
// answers in 2 clk (40 ns), well before the S4 DTACK sample -- exactly the
// zero-wait behaviour the MAME-calibrated harnesses model.  Hot loops (boot
// RAM test, music sequencer, game main loop) are fully resident after their
// first iteration.
//
// Geometry: ENTRIES_LOG2 sets the direct-mapped entry count; each entry is
// one client word ({valid, tag, data} packed in one inferred M10K RAM).
// ROM contents only change during a download, and the whole core is held in
// reset for the download's duration, so `rst` (wire the caller's
// reset-or-download term) is the only invalidation event.  Invalidation
// walks the RAM one entry per clk; requests arriving mid-flush simply miss
// and are served from the fabric, so the flush is never on the critical path.
//
// Client-port contract (both sides, from mcr68_rom_fabric.sv): requester
// asserts req and holds req+addr stable until the 1-clk ack pulse; data is
// registered and stays stable until the next transaction.  The board-side
// bridges may drop `c_req` early when AS ends; an in-flight fabric miss is
// still completed (the fabric requires req held to ack) and its fill is
// kept, but no client ack is emitted for an abandoned request.
// =============================================================================
module mcr68_rom_cache #(
    parameter int AW           = 17,  // client word/byte address width
    parameter int DW           = 16,  // client data width
    parameter int ENTRIES_LOG2 = 13   // 8192 entries
) (
    input  wire           clk,
    input  wire           rst,      // flush: assert reset OR ioctl_download

    // client side (CPU board bridge)
    input  wire           c_req,
    input  wire  [AW-1:0] c_addr,
    output logic [DW-1:0] c_data,
    output logic          c_ack,

    // memory side (mcr68_rom_fabric client port)
    output logic          m_req,
    output logic [AW-1:0] m_addr,
    input  wire  [DW-1:0] m_data,
    input  wire           m_ack
);
    localparam int IDXW = ENTRIES_LOG2;
    localparam int TAGW = (AW > IDXW) ? (AW - IDXW) : 1;
    localparam int LINEW = 1 + TAGW + DW;   // {valid, tag, data}

    wire [IDXW-1:0] req_idx = c_addr[IDXW-1:0];
    wire [TAGW-1:0] req_tag = c_addr[AW-1:IDXW];

    // Single inferred simple-dual-port RAM: one write port (fill/flush), one
    // synchronous read port (lookup).  Plain Quartus-17-inferable shape.
    logic [LINEW-1:0] line_ram [0:(1<<IDXW)-1];
    logic [LINEW-1:0] ram_q;
    logic             ram_we;
    logic [IDXW-1:0]  ram_waddr;
    logic [LINEW-1:0] ram_wdata;

    always_ff @(posedge clk) begin
        if (ram_we)
            line_ram[ram_waddr] <= ram_wdata;
        ram_q <= line_ram[req_idx];
    end

    wire             hit_valid = ram_q[LINEW-1];
    wire [TAGW-1:0]  hit_tag   = ram_q[LINEW-2 -: TAGW];
    wire [DW-1:0]    hit_data  = ram_q[DW-1:0];

    typedef enum logic [1:0] {
        FLUSH,      // walking invalidate after rst
        IDLE,       // wait for request; RAM read follows c_addr
        LOOKUP,     // ram_q valid for the request captured last cycle
        MISS        // fabric transaction outstanding
    } state_t;
    state_t state;

    logic [IDXW-1:0] flush_idx;
    logic [TAGW-1:0] miss_tag;
    logic [IDXW-1:0] miss_idx;
    logic            miss_live;

    always_ff @(posedge clk) begin
        c_ack <= 1'b0;
        if (rst) begin
            state     <= FLUSH;
            flush_idx <= '0;
            m_req     <= 1'b0;
            m_addr    <= '0;
            ram_we    <= 1'b1;
            ram_waddr <= '0;
            ram_wdata <= '0;
            c_data    <= '0;
            miss_tag  <= '0;
            miss_idx  <= '0;
            miss_live <= 1'b0;
        end else begin
            ram_we <= 1'b0;
            case (state)
                FLUSH: begin
                    // Walking invalidate; requests are simply not served until
                    // it completes (the requester holds req until ack, so the
                    // CPU sees at most one ~(2^IDXW)-clk stall right after
                    // reset release -- ~164 us at 50 MHz for 8K entries).
                    ram_we    <= 1'b1;
                    ram_waddr <= flush_idx + 1'b1;
                    ram_wdata <= '0;
                    flush_idx <= flush_idx + 1'b1;
                    if (&flush_idx)
                        state <= IDLE;
                end

                IDLE: begin
                    if (c_req) begin
                        // ram_q for req_idx is valid on the NEXT edge.
                        miss_tag <= req_tag;
                        miss_idx <= req_idx;
                        state    <= LOOKUP;
                    end
                end

                LOOKUP: begin
                    if (!c_req) begin
                        state <= IDLE;          // request abandoned
                    end else if (hit_valid && (hit_tag == miss_tag)) begin
                        c_data <= hit_data;
                        c_ack  <= 1'b1;
                        state  <= IDLE;
                    end else begin
                        m_req     <= 1'b1;
                        m_addr    <= c_addr;
                        miss_live <= 1'b1;
                        state     <= MISS;
                    end
                end

                MISS: begin
                    // If the client abandons the request (AS ended) the miss
                    // is still completed toward the fabric and its fill kept,
                    // but it must never ack a LATER request with this data.
                    if (!c_req)
                        miss_live <= 1'b0;
                    if (m_ack) begin
                        m_req     <= 1'b0;
                        ram_we    <= 1'b1;
                        ram_waddr <= miss_idx;
                        ram_wdata <= {1'b1, miss_tag, m_data};
                        c_data    <= m_data;
                        if (c_req && miss_live) c_ack <= 1'b1;
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    // The fabric contract requires the requester to hold addr stable until
    // ack; a client that changes addr mid-request would poison the cache.
    logic          chk_busy;
    logic [AW-1:0] chk_addr;
    always_ff @(posedge clk) begin
        if (rst) begin
            chk_busy <= 1'b0;
            chk_addr <= '0;
        end else if (!chk_busy && c_req && (state == IDLE)) begin
            chk_busy <= 1'b1;
            chk_addr <= c_addr;
        end else if (chk_busy) begin
            if (!c_req || c_ack)
                chk_busy <= 1'b0;
            else if (chk_addr !== c_addr)
                $fatal(1, "mcr68_rom_cache: c_addr changed mid-request");
        end
    end
`endif
endmodule

`default_nettype wire
