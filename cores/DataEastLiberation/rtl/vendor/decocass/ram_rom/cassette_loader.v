//============================================================================
//  DECO Cassette System — Cassette Image Loader + CRC16 Precompute
//
//  Stream the cassette image from hps_io into BRAM during ioctl_download.
//  Compute the per-block CRC16 as bytes stream past and write each block's
//  CRC into a small lookup BRAM.
//
//  CRC16 implementation per MAME `decocass_tape.cpp:136-145` (`tape_crc16_byte`):
//      for (i = 0; i < 8; i++) {
//          crc = (crc >> 1) | (crc << 15);   // rotate right
//          crc ^= (data << 7) & 0x80;        // current data bit -> bit 7
//          if (crc & 0x80) crc ^= 0x0120;
//          data >>= 1;                        // <-- ALL 8 bits (was dropped → CRC bug, fixed 2026-05-30)
//      }
//
//  Each cassette block is 256 data bytes. After every 256 bytes, the running
//  CRC is stored in `crc_table` and the accumulator is reset.
//
//  testval == running CRC for this polynomial (VERIFIED: testval(r)=r, i.e.
//  crc16(crc16(r, r>>8), r) == 0 — the standard CRC residue property). MAME
//  brute-forces `testval` (decocass_tape.cpp:109-112) but always lands on the
//  running CRC, so storing the running CRC directly is exactly correct — no
//  brute-force needed. The BIOS verifies block-CRC == 0; with the data>>=1 fix
//  above making the CRC correct, that now passes.
//============================================================================

`timescale 1 ps / 1 ps

module cassette_loader (
    input  wire        clk_sys,
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,

    output reg  [15:0] bram_addr,
    output reg  [7:0]  bram_dout,
    output reg         bram_we,

    // CRC16 table write interface (256 blocks × 16 bits)
    output reg  [7:0]  crc_table_addr,
    output reg  [15:0] crc_table_data,
    output reg         crc_table_we,

    output reg  [17:0] image_size_bytes
);

    wire [24:0] addr = ioctl_addr;
    wire [7:0]  data = ioctl_dout;

    wire sel_cassette = (addr >= 25'h03000) && (addr <= 25'h3FFFF);
    wire [24:0] cassette_addr_rel = addr - 25'h03000;
    wire is_first_byte = sel_cassette && (cassette_addr_rel == 25'd0);

    // CRC16 step matching MAME `tape_crc16_byte` (decocass_tape.cpp:136-145) exactly.
    // FIX 2026-05-30: the original omitted MAME's `data >>= 1;` (line 144), so it XORed bit 0
    // of `d` on all 8 iterations instead of bits 0..7 — i.e. it dropped 7 of every 8 data bits.
    // That made every block CRC wrong -> CASSETTE ERROR. (The predecessor's "only bit 0
    // contributes" comment was them missing line 144.) With the shift, the CRC is correct, and
    // since testval == running-CRC for this polynomial (verified), storing the running CRC below
    // is exactly MAME's brute-forced testval — no separate testval search needed.
    function [15:0] tape_crc16_byte;
        input [15:0] crc;
        input [7:0]  d;
        integer i;
        reg [15:0] r;
        reg [7:0]  dd;
        begin
            r  = crc;
            dd = d;
            for (i = 0; i < 8; i = i + 1) begin
                r = {r[0], r[15:1]};                    // rotate right: (crc>>1)|(crc<<15)
                r = r ^ (dd[0] ? 16'h0080 : 16'h0000);  // (data << 7) & 0x80
                if (r[7])
                    r = r ^ 16'h0120;
                dd = dd >> 1;                            // MAME line 144 — advance to next data bit
            end
            tape_crc16_byte = r;
        end
    endfunction

    reg [15:0] crc_acc;
    reg [7:0]  byte_in_block;
    reg [7:0]  current_block;

    always @(posedge clk_sys) begin
        bram_we      <= 1'b0;
        crc_table_we <= 1'b0;

        if (ioctl_download && ioctl_wr && sel_cassette) begin
            bram_we    <= 1'b1;
            bram_addr  <= cassette_addr_rel[15:0];
            bram_dout  <= data;

            if (is_first_byte) begin
                // NUMBLOCKS-FIX-2026-06-07: track the LAST NON-ZERO byte (MAME: numblocks =
                // ((last_nonzero|0xFF)+1)/256), NOT the full file size. We were counting all 64 KB =>
                // 256 blocks => the EOT marker landed ~112 blocks too late. After the real data ends
                // (block 144) the tape was NOT yet at EOT, so the 8041 handed back a stale byte instead
                // of 0, and the game's post-load EOT check ($0582: lda $e500 / cmp #0 / beq) failed =>
                // jmp $F000 => reload. Tracking last-nonzero makes num_blocks=(size+255)>>8 round to 144
                // so EOT asserts right after the data. DIAG-REVERT: original (full-file count) below.
                // image_size_bytes <= 18'd1;
                image_size_bytes <= (data != 8'h00) ? 18'd1 : 18'd0;
                crc_acc          <= tape_crc16_byte(16'h0000, data);
                byte_in_block    <= 8'd1;
                current_block    <= 8'd0;
            end else begin
                // NUMBLOCKS-FIX-2026-06-07: advance only on a NON-ZERO byte, to (its offset + 1) =
                // last-non-zero + 1 (trailing zeros must NOT extend the tape length / EOT position).
                // DIAG-REVERT: original (count every byte) below.
                // image_size_bytes <= image_size_bytes + 18'd1;
                if (data != 8'h00) image_size_bytes <= cassette_addr_rel[17:0] + 18'd1;
                if (byte_in_block == 8'd255) begin
                    crc_table_we   <= 1'b1;
                    crc_table_addr <= current_block;
                    crc_table_data <= tape_crc16_byte(crc_acc, data);
                    crc_acc        <= 16'h0000;
                    byte_in_block  <= 8'd0;
                    current_block  <= current_block + 8'd1;
                end else begin
                    crc_acc        <= tape_crc16_byte(crc_acc, data);
                    byte_in_block  <= byte_in_block + 8'd1;
                end
            end
        end
    end

    initial begin
        bram_we          = 1'b0;
        bram_addr        = 16'd0;
        bram_dout        = 8'd0;
        image_size_bytes = 18'd0;
        crc_table_we     = 1'b0;
        crc_table_addr   = 8'd0;
        crc_table_data   = 16'd0;
        crc_acc          = 16'h0000;
        byte_in_block    = 8'd0;
        current_block    = 8'd0;
    end

endmodule
