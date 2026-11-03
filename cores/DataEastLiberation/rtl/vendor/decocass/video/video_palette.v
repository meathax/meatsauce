// DECO Cassette — Palette BRAM + PROM color lookup (task 11)
// Implements the 64-entry × 32-color palette block.
//
// Architecture (from decocass_v.cpp and decocass.cpp):
//   - 64 logical pens (0-63)
//   - Pens 0-31 map directly to CLUT entries 0-31
//   - Pens 32-63 map to CLUT entries with bitswap applied (bit flip for headlight mode)
//   - Palette RAM ($E000-$E0FF, 256 bytes) stores the PROM index for each indirect color entry
//   - Each write at offset stores a PROM index; actual address mapping uses (offset & 31) ^ 16
//   - CLUT contains 32 precomputed {R,G,B} triplets from arcade PROM + resistor network
//
// From decocass_v.cpp:323-333 (decocass_paletteram_w):
//   - offset = (offset & 31) ^ 16  // XOR A4 (bit 4) into the CLUT index
//   - RGB output is inverted: ~data[2:0] for R, ~data[5:3] for G, ~data[7:6] for B
//   - pal3bit(x) = (x<<5)|(x<<2)|(x>>1)  // 3-bit to 4-bit expansion
//   - pal2bit(x) = (x<<6)|(x<<4)|(x<<2)|x  // 2-bit to 4-bit expansion
//
// From decocass.cpp:1004-1012 (decocass_palette):
//   - Pens 0-31: set_pen_indirect(i, i)
//   - Pens 32-63: set_pen_indirect(32+i, bitswap(i, 7,6,5,4,3,1,2,0))

module video_palette (
    input  wire        clk_sys,
    input  wire        ce_pix,

    // CPU write port for paletteram ($E000-$E0FF)
    input  wire        cpu_we,
    input  wire [7:0]  cpu_addr,
    input  wire [7:0]  cpu_dout,

    // Palette lookup
    input  wire [5:0]  pen,              // 6-bit logical pen (0-63)
    input  wire [4:0]  prom_index,       // 5-bit index (unused stub for spec compatibility)

    // RGB output (4 bits each, synth to 8-bit by zero-extension at top)
    output reg  [3:0]  red,
    output reg  [3:0]  grn,
    output reg  [3:0]  blu
);

    // ========================================
    // Palette RAM: 256-byte dual-port BRAM
    // Stores PROM color indices (5 bits per entry)
    // CPU writes at $E000-$E0FF; read indexed by pen[4:0]
    // Note: pen[5] selects between two alternate palettes (direct vs. bitswapped)
    //       which is handled by the indirect color mapping in MAME
    // ========================================
    wire [7:0] palram_dout;

    // INVERT-AT-WRITE 2026-05-16: real hardware has inverters on the
    // palette ROM output (the `~data` in MAME's decocass_paletteram_w).
    // On hardware, palette RAM defaults to all-1s at power-on (pull-ups +
    // inverter latches), so ~default = 0 = BLACK background. Our Cyclone V
    // BRAM defaults to all-0s instead, so reading `~0` gives 0xFF = WHITE
    // — exactly the residual white-screen bug after the XOR + decode fixes.
    // Inverting at write time so default-0-BRAM still decodes to black:
    //   BIOS writes X → store ~X in BRAM (default state stays 0 = matches
    //   "no write" → reads as 0 → decodes without further inversion to
    //   black).  Any actual BIOS-written byte gets its bits inverted on
    //   storage; the downstream decode then takes the bits directly,
    //   producing the same final RGB as MAME's `~data` formula.
    wire [7:0] cpu_dout_inv = ~cpu_dout;

    // PALETTE-BG-COLORSET-2026-06-28: pens 32-63 use MAME's BITSWAPPED indirect half
    // (decocass_palette: set_pen_indirect(32+i, bitswap<8>(i,7,6,5,4,3,1,2,0)) = swap pen bits 1↔2).
    // pens 0-31 = direct. Read index into the 32-color palram:
    wire [4:0] pal_rd_idx = pen[5] ? {pen[4], pen[3], pen[1], pen[2], pen[0]} : pen[4:0];

    dpram #(.address_width(8), .data_width(8)) palram_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we),
        .address_a(cpu_addr), .data_a(cpu_dout_inv), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        // PALETTE-BG-COLORSET-2026-06-28: original direct read below, uncomment to restore (no upper-half bitswap)
        // .address_b(pen[4:0]),
        .address_b({3'b000, pal_rd_idx}),
        .data_b(8'b0), .q_b(palram_dout)
    );

    // ========================================
    // Direct RGB decode from the palette byte (MAME decocass_paletteram_w).
    //
    // 2026-05-16: REPLACED placeholder rainbow CLUT.
    // The byte stored in the palette encodes RGB directly per
    // decocass_v.cpp:323-333:
    //   m_palette->set_indirect_color(offset,
    //       rgb_t(pal3bit(~data >> 0),    // R
    //             pal3bit(~data >> 3),    // G
    //             pal2bit(~data >> 6)));  // B
    //
    // So palram_dout (the byte BIOS wrote) IS the color — no CLUT lookup.
    // Inverted because the PROM/resistor-network on real hardware inverts.
    //
    // pal3bit (3-bit → 4-bit) closed-form: out = {x, x[2]}
    //   verifies: 0→0, 1→2, 2→4, 3→6, 4→9, 5→11, 6→13, 7→15 (matches MAME)
    // pal2bit (2-bit → 4-bit) closed-form: out = {x, x}
    //   verifies: 0→0, 1→5, 2→10, 3→15 (matches MAME)
    //
    // Previous code did `CLUT[palram_dout[4:0]]` against a rainbow
    // placeholder where CLUT[0]=white. Half a dozen common byte values
    // (0x00, 0x20, 0x40, ..., 0xE0) all map low-5-bits to 0 → white-
    // screen-no-matter-what-BIOS-actually-encoded. That ate hours.
    // ========================================

    // The bytes in the BRAM are already inverted at write time (see above),
    // so we take the bits directly here — no further inversion. That makes
    // default-0 BRAM decode to BLACK (matching MAME's default state) and
    // BIOS-written bytes decode to the same final RGB as MAME's `~data`.
    wire [2:0] r_raw = palram_dout[2:0];    // red,   3 bits
    wire [2:0] g_raw = palram_dout[5:3];    // green, 3 bits
    wire [1:0] b_raw = palram_dout[7:6];    // blue,  2 bits

    always @(posedge clk_sys) begin
        if (ce_pix) begin
            red <= {r_raw, r_raw[2]};   // pal3bit
            grn <= {g_raw, g_raw[2]};   // pal3bit
            blu <= {b_raw, b_raw};      // pal2bit
        end
    end

endmodule
