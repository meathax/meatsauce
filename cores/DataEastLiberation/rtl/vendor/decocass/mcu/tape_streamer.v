// DECO Cassette System — Tape Streamer
// Synthesized implementation of decocass_tape.cpp
//
// Produces 4800 bps serial tape data from a cassette image (256-byte blocks).
// Image contains RAW data bytes; CRC16 is computed on-the-fly in hardware per block.
//
// Mirroring MAME decocass_tape.cpp: maintains clockpos (tape position),
// computes region/byte/bit from clockpos, reads image bytes, applies CRC16,
// and outputs serial stream with framing.

module tape_streamer (
    input  wire        clk_sys,          // 96 MHz system clock
    input  wire        ce_tape,          // 4.8 kHz clock-enable strobe
    input  wire        reset,

    // Tape image read port (SDRAM or BRAM)
    output wire [17:0] image_addr,
    input  wire [7:0]  image_q,

    input  wire [17:0] image_size_bytes,

    // Transport control from MCU
    input  wire        motor_on,
    input  wire        direction,        // 1 = forward, 0 = rewind
    input  wire [1:0]  speed_select,     // 00 stop, 01 normal, 10 fast-fwd, 11 rewind

    // CRC16 table lookup (computed by cassette_loader at ROM-load time)
    output wire [7:0]  crc_addr,
    input  wire [15:0] crc_q,

    // Outputs to MCU
    output wire        tape_data,
    output wire        tape_clock,
    output wire        tape_bot,
    output wire        tape_eot
);

    // =====================================================================
    // Constants from decocass_tape.cpp
    // =====================================================================

    // Tape clock rate: 4800 Hz, thus 2 clocks per bit, 16 per byte
    localparam TAPE_CLOCKRATE       = 4800;
    localparam CLOCKS_PER_BIT       = 2;
    localparam CLOCKS_PER_BYTE      = 16;

    // Convert milliseconds to tape clocks: (ms * 4800 / 1000)
    localparam LEADER_CLOCKS        = 4800;      // 1.0 s
    localparam LEADER_GAP_CLOCKS    = 7200;      // 1.5 s
    localparam BOT_CLOCKS           = 12;        // 2.5 ms
    localparam BOT_GAP_CLOCKS       = 1440;      // 300 ms

    // Region markers (tape clock positions)
    localparam REGION_LEADER_END    = LEADER_CLOCKS;
    localparam REGION_LEADER_GAP_END = REGION_LEADER_END + LEADER_GAP_CLOCKS;
    localparam REGION_BOT_END       = REGION_LEADER_GAP_END + BOT_CLOCKS;
    localparam REGION_BOT_GAP_END   = REGION_BOT_END + BOT_GAP_CLOCKS;

    // Data block structure (MAME decocass_tape.h BYTE_BLOCK_TOTAL = 331):
    // PRE_GAP(34) + LEADIN(1) + HEADER(1) + DATA(256) + CRC_MSB(1) + CRC_LSB(1) +
    // TRAILER(1) + LEADOUT(1) + LONGCLOCK(1) + POSTGAP(34) = 331 bytes
    // FIX 2026-05-30: was 297 — the predecessor summed through LONGCLOCK and DROPPED the
    // 34-byte POSTGAP (its own comment lists it but mis-totals). Result: post-gap unreachable,
    // every block mis-framed, total_clocks/EOT short by 34 bytes/block.
    // Each byte = 16 clock cycles at tape rate
    localparam BYTES_PER_BLOCK      = 331;
    localparam CLOCKS_PER_BLOCK     = BYTES_PER_BLOCK * CLOCKS_PER_BYTE;

    // Byte indices within a block
    localparam BYTE_PRE_GAP_START   = 0;
    localparam BYTE_PRE_GAP_END     = 33;
    localparam BYTE_LEADIN          = 34;
    localparam BYTE_HEADER          = 35;
    localparam BYTE_DATA_START      = 36;
    localparam BYTE_DATA_END        = 291;
    localparam BYTE_CRC_MSB         = 292;
    localparam BYTE_CRC_LSB         = 293;
    localparam BYTE_TRAILER         = 294;
    localparam BYTE_LEADOUT         = 295;
    localparam BYTE_LONGCLOCK       = 296;
    localparam BYTE_POSTGAP_START   = 297;
    localparam BYTE_POSTGAP_END     = 330;

    // =====================================================================
    // State registers
    // =====================================================================

    reg [31:0] clockpos;                // Current tape position (in clock cycles)
    reg [31:0] total_clocks;            // Total clocks for this image
    reg [31:0] num_blocks;              // Number of data blocks

    // Derived from clockpos (combinational)
    wire [31:0] data_region_clocks;
    wire [31:0] dataclock;
    wire [8:0]  byte_offset;
    wire [2:0]  bit_offset;
    // TIMING-FIX-2026-06-09: block_num is now a REGISTERED counter (was a combinational ÷5296).
    reg  [7:0]  block_num;
    reg  [31:0] block_base;   // tape position of the start of the current block (= RBG_END + block_num*CLOCKS_PER_BLOCK)

    // Current byte being output
    wire [7:0]  current_byte;

    // CRC table is external (computed by cassette_loader at ROM-load time,
    // stored in `crc16_table_bram` in the wrapper). Drive read address from
    // `block_num`; result comes back via `crc_q` (1-cycle BRAM latency).
    assign crc_addr = block_num;

    // =====================================================================
    // Compute total tape clocks from image size
    // =====================================================================

    always @(posedge clk_sys) begin
        if (reset) begin
            // numblocks = ceil(image_size_bytes / 256)
            // Scan would be at init; for hardware, assume cassette_loader provides length
            num_blocks <= (image_size_bytes + 255) >> 8;

            // Total clocks = header + (blocks * CLOCKS_PER_BLOCK) + trailer
            // Header: LEADER + LEADER_GAP + BOT + BOT_GAP (= REGION_BOT_GAP_END)
            // Trailer: BOT_GAP + EOT + EOT_GAP + TRAILER_GAP + TRAILER (symmetric)
            total_clocks <= REGION_BOT_GAP_END +
                           ((image_size_bytes + 255) >> 8) * CLOCKS_PER_BLOCK +
                           REGION_BOT_GAP_END;  // Symmetric trailer
        end
    end

    // =====================================================================
    // Tape position advance (motor-driven)
    // =====================================================================

    // FIX 2026-05-30: honor FAST. MAME |speed| is 7 (fast) or 1 (normal); speed_select==2'b10
    // = fast. Previously clockpos moved by ±1 regardless, so fast-fwd / fast-rewind ran at 1x and
    // tape positioning (e.g. rewind-to-BOT) took 7x longer — a plausible "deck not responding".
    wire [31:0] step = (speed_select == 2'b10) ? 32'd7 : 32'd1;

    always @(posedge clk_sys) begin
        if (reset) begin
            clockpos <= 0;
        end else if (ce_tape && motor_on) begin
            if (direction) begin   // forward
                clockpos <= (clockpos + step < total_clocks) ? (clockpos + step)
                                                             : (total_clocks - 1);
            end else begin         // rewind
                clockpos <= (clockpos > step) ? (clockpos - step) : 32'd0;
            end
            // motor_on == 0 -> position holds
        end
    end

    // =====================================================================
    // TIMING-FIX-2026-06-09: registered block counter (replaces the 32-bit ÷/% CLOCKS_PER_BLOCK)
    // =====================================================================
    // The old `data_region_clocks / 5296` and `% 5296` were a ~58 ns combinational divide on clk_sys
    // (failed setup by -47 ns, restricted Fmax 17.29 MHz) => non-deterministic builds. Track the block
    // with a counter instead: block_base = tape position of the start of the current block; dataclock is
    // then an exact SUBTRACT (below). clockpos moves by at most ±step (1 or 7) per ce_tape, so we cross at
    // most ONE block boundary per tick. block_num/block_base are REGISTERED => stable all cycle, so the
    // 8041 never samples a mid-settle transient. (Reset signal handles the clockpos->0 jump.)
    //
    // Mirror of the clockpos-update result (matches the always block above), for the counter:
    wire [31:0] clockpos_next = !(ce_tape && motor_on) ? clockpos :
                                direction ? ((clockpos + step < total_clocks) ? (clockpos + step) : (total_clocks - 1))
                                          : ((clockpos > step) ? (clockpos - step) : 32'd0);

    always @(posedge clk_sys) begin
        if (reset) begin
            block_num  <= 8'd0;
            block_base <= REGION_BOT_GAP_END;          // start of block 0
        end else if (ce_tape && motor_on) begin
            if (clockpos_next >= block_base + CLOCKS_PER_BLOCK) begin
                block_num  <= block_num + 8'd1;        // crossed forward into the next block
                block_base <= block_base + CLOCKS_PER_BLOCK;
            end else if (clockpos_next < block_base && block_num != 8'd0) begin
                block_num  <= block_num - 8'd1;        // crossed back into the previous block (rewind)
                block_base <= block_base - CLOCKS_PER_BLOCK;
            end
        end
    end

    // =====================================================================
    // Combinational: Decode tape position into region/block/byte/bit
    // =====================================================================

    assign data_region_clocks = (clockpos >= REGION_BOT_GAP_END) ?
                                (clockpos - REGION_BOT_GAP_END) : 32'h0;   // kept: feeds clk_bit (RCLK parity)

    // TIMING-FIX-2026-06-09: dataclock = exact position within the current block via SUBTRACT (no divide);
    // block_num is the registered counter above. Originals (32-bit combinational divide/modulo) below:
    // assign dataclock = data_region_clocks % CLOCKS_PER_BLOCK;
    // assign block_num = (data_region_clocks / CLOCKS_PER_BLOCK) & 8'hFF;
    assign dataclock   = (clockpos >= block_base) ? (clockpos - block_base) : 32'h0;
    // RDATA-PHASE-ADVANCE-2026-06-27 (Build-1 fix for cscrtry/type4 "tape error #1", count stuck at 999):
    // The MCU samples RDATA IMMEDIATELY after the RCLK rising edge (mcu.dasm: $1A7 syncs to RCLK rising, then $0B4
    // does `in a,p2 / jb7` = read RDATA). RCLK (clk_bit) rises on EVEN data_region_clocks; decoding byte/bit straight
    // from `dataclock` made the data byte+bit flip ON that same edge → ZERO setup → marginal misread on specific
    // byte patterns (cscrtry's count bits land on the bad edge; cmissnx's survive → looks game-specific but isn't).
    // FIX: ADVANCE the byte/bit decode by ONE tape-clock so the data is SETTLED one clockpos before the sampled
    // rising edge. The MCU reads the SAME bit sequence (0..7), now with a full tape-clock of setup — helps ALL games.
    // RCLK itself (clk_bit, from data_region_clocks) is UNCHANGED. The 2026-06-04 attempt DELAYED RDATA (→ read the
    // PREVIOUS bit, wrong direction); this ADVANCES it. REVERT: set `dataclock_out = dataclock`.
    wire [31:0] dataclock_out = dataclock + 32'd1;
    assign byte_offset = dataclock_out / CLOCKS_PER_BYTE;          // ÷16 = shift (power of two, cheap)
    assign bit_offset  = (dataclock_out / CLOCKS_PER_BIT) & 3'h7;  // ÷2  = shift (cheap)

    // =====================================================================
    // Region detection (mirrors MAME lines 232-275)
    // =====================================================================

    // TAPE-EOT-FIX-2026-06-04: trailer/EOT region detection was broken — wrong start
    // constants + logically-impossible in_eot/in_eot_gap ranges (always false), so
    // tape_eot NEVER asserted and in_trailer spanned the whole trailing 13452 clocks.
    // Ported MAME's symmetric end-of-tape boundaries (decocass_tape.cpp:251-258),
    // measured DOWN from total_clocks (mirror of the leader side). ORIGINAL (WRONG):
    // wire [31:0] trailer_start = total_clocks - REGION_BOT_GAP_END;
    // wire [31:0] eot_gap_start = total_clocks - REGION_BOT_END;
    // wire [31:0] eot_start = total_clocks - BOT_CLOCKS;
    // TIMING-FIX-2026-06-09b: these were combinational subtracts of total_clocks. STA showed the residual
    // -6.75 ns failing path is total_clocks[*] -> (region compare -> bot_eot) -> the MAIN 6502 ($E502 status
    // read, deco222 T65). total_clocks is CONSTANT after reset, so REGISTER the boundaries => total_clocks is
    // off the clockpos->status->6502 combinational path. Originals (combinational) below:
    // wire [31:0] eot_gap_start     = total_clocks - REGION_BOT_GAP_END;
    // wire [31:0] eot_start         = total_clocks - REGION_BOT_END;
    // wire [31:0] trailer_gap_start = total_clocks - REGION_LEADER_GAP_END;
    // wire [31:0] trailer_start     = total_clocks - REGION_LEADER_END;
    reg [31:0] eot_gap_start, eot_start, trailer_gap_start, trailer_start;
    always @(posedge clk_sys) begin
        eot_gap_start     <= total_clocks - REGION_BOT_GAP_END;     // total - 13452
        eot_start         <= total_clocks - REGION_BOT_END;         // total - 12012
        trailer_gap_start <= total_clocks - REGION_LEADER_GAP_END;  // total - 12000
        trailer_start     <= total_clocks - REGION_LEADER_END;      // total - 4800
    end

    wire in_leader     = (clockpos < REGION_LEADER_END);
    wire in_leader_gap = (clockpos >= REGION_LEADER_END &&
                         clockpos < REGION_LEADER_GAP_END);
    wire in_bot        = (clockpos >= REGION_LEADER_GAP_END &&
                         clockpos < REGION_BOT_END);
    wire in_bot_gap    = (clockpos >= REGION_BOT_END &&
                         clockpos < REGION_BOT_GAP_END);

    // TAPE-EOT-FIX-2026-06-04: mirror of the leader side, measured down from total_clocks
    // (MAME decocass_tape.cpp:251-258). ORIGINAL (WRONG — in_eot/in_eot_gap never true):
    // wire in_trailer     = (clockpos >= trailer_start);
    // wire in_eot_gap     = (clockpos >= eot_gap_start && clockpos < trailer_start);
    // wire in_eot         = (clockpos >= eot_start && clockpos < eot_gap_start);
    wire in_eot_gap     = (clockpos >= eot_gap_start     && clockpos < eot_start);
    wire in_eot         = (clockpos >= eot_start         && clockpos < trailer_gap_start);
    wire in_trailer_gap = (clockpos >= trailer_gap_start && clockpos < trailer_start);
    wire in_trailer     = (clockpos >= trailer_start);

    wire in_data        = !in_leader && !in_leader_gap && !in_bot && !in_bot_gap &&
                         !in_trailer && !in_trailer_gap && !in_eot_gap && !in_eot;

    // =====================================================================
    // Image read address (combinational, no buffering)
    // For DATA region, read from image based on block + data offset
    // =====================================================================

    assign image_addr = (in_data && byte_offset >= BYTE_DATA_START &&
                        byte_offset <= BYTE_DATA_END) ?
                        ({block_num, 8'h00} + (byte_offset - BYTE_DATA_START)) :
                        18'h0;

    // =====================================================================
    // Current byte value selection
    // Mirrors MAME get_status_bits() logic
    // =====================================================================

    assign current_byte =
        in_leader || in_leader_gap || in_bot_gap ||
        in_eot_gap || in_trailer || in_eot ? 8'h00 :
        in_bot || in_eot ? 8'h00 :
        (byte_offset >= BYTE_PRE_GAP_START && byte_offset <= BYTE_PRE_GAP_END) ? 8'h00 :
        (byte_offset == BYTE_LEADIN) ? 8'h00 :
        (byte_offset == BYTE_HEADER) ? 8'hAA :
        (byte_offset >= BYTE_DATA_START && byte_offset <= BYTE_DATA_END) ? image_q :
        (byte_offset == BYTE_CRC_MSB) ? crc_q[15:8] :
        (byte_offset == BYTE_CRC_LSB) ? crc_q[7:0] :
        (byte_offset == BYTE_TRAILER) ? 8'hAA :
        (byte_offset == BYTE_LEADOUT) ? 8'h00 :
        (byte_offset == BYTE_LONGCLOCK) ? 8'h00 :
        (byte_offset >= BYTE_POSTGAP_START && byte_offset <= BYTE_POSTGAP_END) ? 8'h00 :
        8'h00;

    // =====================================================================
    // Output: tape_data (serial, LSB-first — current_byte[0] = LSB streamed first)
    // =====================================================================
    // RDATA-PHASE-FIX-2026-06-04: the MCU read loop (mcu.dasm $1A7) EDGE-SYNCS to RCLK (P2.6:
    // spins for a falling edge, then a rising edge) and samples RDATA (P2.7) just AFTER the rising
    // edge. Our RCLK and the old combinational RDATA both transitioned on the SAME (even) clockpos,
    // so RDATA was changing at the exact edge the MCU samples => setup/hold race => garbage bits
    // (block count stuck at default => ERROR #1). MAME never sees this (lockstep functional model,
    // no async sampling). FIX: register RDATA on ce_tape so it transitions on the RCLK FALLING edge
    // (odd clockpos) — stable, with ~half a tape-clock of setup before the rising edge the MCU
    // triggers on (also aligns the MCU's first caught edge to bit0, not bit1). RCLK unchanged
    // (still MAME-faithful).
    // REVERTED 2026-06-04: the registered delay below did NOT fix the read (count still stuck at
    // 999) and may have regressed it. The exact RCLK edge the MCU samples RDATA on is UNKNOWN ($1A7
    // edge-sync and the jb7 samples are in separate routines), so the delay direction was a guess.
    // Back to combinational while we MEASURE the read pipeline (READ-PIPELINE-PROBE in Arcade-*.sv).
    // To re-apply: restore the 4 reg/always/assign lines, comment the combinational assign.
    // reg tape_data_r;
    // always @(posedge clk_sys)
    //     if (reset)        tape_data_r <= 1'b0;
    //     else if (ce_tape) tape_data_r <= current_byte[bit_offset];
    // assign tape_data = tape_data_r;
    assign tape_data = current_byte[bit_offset];   // ORIGINAL (restored)

    // =====================================================================
    // Output: tape_clock (active high during clocked regions, MAME line 304-315)
    // =====================================================================

    wire clk_region_active = (in_data &&
                             byte_offset >= BYTE_LEADIN &&
                             byte_offset <= BYTE_LONGCLOCK);

    // MAME decocass_tape.cpp:305 — read clock (bit 0x40) is HIGH when (clockpos-offset) is EVEN.
    wire clk_bit = (data_region_clocks & 32'h1) ? 1'b0 : 1'b1;  // even -> 1, odd -> 0  (== MAME 0x40)

    // FIX 2026-05-30: was `~clk_bit`, which inverted the read clock vs MAME -> MCU sampled tape
    // data on the wrong edge -> no valid bytes -> "deck not responding". Now matches MAME line 305.
    assign tape_clock = (byte_offset == BYTE_LONGCLOCK) ? 1'b1 :  // LONGCLOCK holds high
                       (clk_region_active) ? clk_bit :            // alternating read clock (MAME polarity)
                       1'b0;                                      // Idle

    // =====================================================================
    // Output: tape_bot and tape_eot (hole sense signals)
    // Mirrors MAME get_status_bits() lines 292-294
    // =====================================================================

    // TAPE-EOT-FIX-2026-06-04: MAME sets the 0x20 hole-sense in LEADER|BOT|EOT|TRAILER
    // (get_status_bits, decocass_tape.cpp:293). Only the COMBINED tape_bot|tape_eot is
    // consumed (mcu_tape_iface bot_eot / $E502 D4), so split start-side vs end-side.
    // ORIGINAL (tape_eot used always-false in_eot_gap/in_eot => never asserted):
    // assign tape_bot = in_leader || in_bot || in_eot || in_trailer;
    // assign tape_eot = in_eot_gap || in_eot;
    assign tape_bot = in_leader || in_bot;       // start-side holes
    assign tape_eot = in_eot    || in_trailer;   // end-side holes (combined = MAME 0x20)

    // CRC table is populated externally by cassette_loader.

endmodule
