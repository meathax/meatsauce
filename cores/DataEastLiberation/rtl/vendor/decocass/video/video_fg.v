// DECO Cassette — Foreground tilemap renderer (task 08)
// Fetches and renders the 256×256 foreground tilemap from fgvideoram + colorram,
// with character bitmaps coming from charram (RAM-based graphics).
//
// Geometry: 32 cols × 32 rows × 8×8 pixels = 256×256 px tilemap
// Scan order: column-major per MAME decocass_v.cpp:187-192 fgvideoram_scan_cols
//
// CHARACTER FORMAT — VERIFIED FROM MAME decocass.cpp:939-948 `charlayout`:
//   - 8×8 pixel characters
//   - 1024 characters total (10-bit tile code)
//   - 3 bits per pixel — THREE planes
//   - Plane offsets: 0, 8192, 16384 bytes (in CPU $6000-$BFFF region)
//   - CPU memory layout:
//       $6000-$7FFF = Plane 0  (8 KB)
//       $8000-$9FFF = Plane 1  (8 KB)
//       $A000-$BFFF = Plane 2  (8 KB)
//   - Tile-code source per get_fg_tile_info (decocass_v.cpp:221-228):
//       tile_index = 256 * (attr & 3) + code   (10 bits)
//   - FG palette index = {2'b00, color_center_bot[0], pen[2:0]}  (5 bits)
//
// 2026-05-17 — REWRITE. Previous version was 2 planes × 4 KB = 8 KB total
// (vs. MAME's 3 planes × 8 KB = 24 KB), used 8-bit tile codes (vs. 10-bit),
// and built fg_pen as `{attr[2:0], pen[1:0]}` (vs. MAME's
// `{0, color_center_bot[0], pen[2:0]}`). With these errors, ~2/3 of BIOS's
// character data was overwritten in BRAM and the surviving bytes were
// decoded with wrong pen indices. Symptom: black screen even though BIOS
// was actively writing fgvram + charram + colram (confirmed via audio probe
// rounds R5/R6/R7 and the 2026-05-17 PC-bar diagnostic). See
// `Common-Pitfalls/MAME palette address transforms are load-bearing` and
// [[decocass_white_screen_audit_2026-05-16]] for the full investigation.

module video_fg (
    input  wire        clk_sys,
    input  wire        ce_pix,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,

    // CPU-side write ports
    input  wire        cpu_we_fg,         // fgvideoram ($C000-$C3FF)
    input  wire        cpu_we_col,        // colorram   ($C400-$C7FF)
    input  wire        cpu_we_char_p0,    // charram plane 0 ($6000-$7FFF)
    input  wire        cpu_we_char_p1,    // charram plane 1 ($8000-$9FFF)
    input  wire        cpu_we_char_p2,    // charram plane 2 ($A000-$BFFF)
    input  wire [12:0] cpu_addr,          // 13-bit (covers up to 8 KB per plane)
    input  wire [7:0]  cpu_dout,

    // FG color register (decocass.cpp E410 — get_fg_tile_info uses BIT(.,0))
    input  wire [7:0]  color_center_bot,

    // Render outputs
    output reg  [4:0]  fg_pen,             // 5-bit palette idx
    output wire        fg_opaque           // 1 when fg_pen != 0
);

    // ========================================
    // Internal timing extraction
    // ========================================
    // FG-HSHIFT-TEST-2026-06-11: ROTATION CORRECTION. Display is rotated 90° → display-VERTICAL = raster-HORIZONTAL
    // (hcnt). Direction confirmed DOWN. hcnt+14 overshot; user wants ONE TILE (8px), tile-aligned — so shift htile
    // by +8 (=+1 tile) and keep the natural `hcnt[2:0]==0` load phase (no sub-tile shift). Tunable by whole tiles.
    // DIAG-REVERT-2026-06-11: restore `htile = hcnt[7:3]`.
    wire [8:0] hcnt_fg = hcnt + 9'd8;
    // wire [4:0] htile = hcnt[7:3];          // tile column index (original, no shift)
    wire [4:0] htile = hcnt_fg[7:3]; // tile column index (shifted)
    wire [4:0] vtile = vcnt[7:3]; // tile row index (vcnt shift REVERTED — was the wrong axis)
    wire [2:0] vline = vcnt[2:0]; // scan line within 8-line char

    // FG-WRAP-BLANK-2026-06-29: hcnt_fg[8]=1 means hcnt_fg passed 256, so htile=hcnt_fg[7:3] has rolled 31->0
    // and is RE-FETCHING char columns 0/1 at the display-bottom = the mirrored tile row ("data from further up").
    // Blank those off-map (wrapped) tiles. This MOVES NOTHING — FG/BG alignment (FG-HSHIFT +8, FG-VSHIFT +2) is
    // untouched; it only suppresses the spurious wrapped tiles. offmap is delayed 2 ce_pix to land on char_p0
    // (htile -> tile_code8 [+1] -> char_p0 [+1]); gating the SR-load source keeps it self-aligned to the pixel.
    // REVERT: delete offmap_r1/r2 and restore the plain `pat_pN_sr <= char_pN;` lines in the SR load below.
    reg offmap_r1, offmap_r2;
    always @(posedge clk_sys) if (ce_pix) begin
        offmap_r1 <= hcnt_fg[8];
        offmap_r2 <= offmap_r1;
    end

    // ========================================
    // Tile RAM arrays (fgvideoram, colorram, charram)
    // ========================================

    // fgvram & colorram have a SWIZZED MIRROR at $C800-$CFFF per MAME
    // `mirrorvideoram_w` (decocass_m.cpp:72-73): swap upper 5 bits and lower
    // 5 bits of the 10-bit offset. cpu_addr[11] distinguishes mirror from
    // direct: bit 11 = 0 → direct, bit 11 = 1 → mirror (apply swiz).
    wire [9:0] write_addr_raw = cpu_addr[9:0];
    wire [9:0] write_addr_eff = cpu_addr[11]
                                ? {write_addr_raw[4:0], write_addr_raw[9:5]}
                                : write_addr_raw;

    // fgvideoram: 1K dual-port (tile codes, 8-bit values per cell)
    wire [7:0] tile_code8;
    dpram #(.address_width(10), .data_width(8)) fgvideoram_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_fg),
        .address_a(write_addr_eff), .data_a(cpu_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        .address_b({~htile, vtile}), .data_b(8'b0), .q_b(tile_code8)
    );

    // colorram: 1K dual-port (attribute byte per cell; bits[1:0] extend tile code)
    wire [7:0] attr;
    dpram #(.address_width(10), .data_width(8)) colorram_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_col),
        .address_a(write_addr_eff), .data_a(cpu_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        .address_b({~htile, vtile}), .data_b(8'b0), .q_b(attr)
    );

    // 10-bit tile code per MAME get_fg_tile_info:
    //   tile_index = 256 * (attr & 3) + code
    //              = {attr[1:0], code[7:0]}
    wire [9:0] tile_code = {attr[1:0], tile_code8};

    // ========================================
    // charram: 3 planes × 8 KB each (13-bit address)
    //
    // CPU writes are routed by upper address bits in decocass.v:
    //   $6000-$7FFF (cpu_addr[15:13] == 3'b011) → cpu_we_char_p0
    //   $8000-$9FFF (cpu_addr[15:13] == 3'b100) → cpu_we_char_p1
    //   $A000-$BFFF (cpu_addr[15:13] == 3'b101) → cpu_we_char_p2
    // Each plane stores 1024 tiles × 8 bytes/tile = 8192 bytes.
    //
    // Read side: same address {tile_code[9:0], vline[2:0]} into all three.
    // ========================================
    wire [7:0] char_p0, char_p1, char_p2;
    wire [12:0] char_read_addr = {tile_code, vline};

    dpram #(.address_width(13), .data_width(8)) charram_p0_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_char_p0),
        .address_a(cpu_addr[12:0]), .data_a(cpu_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        .address_b(char_read_addr), .data_b(8'b0), .q_b(char_p0)
    );

    dpram #(.address_width(13), .data_width(8)) charram_p1_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_char_p1),
        .address_a(cpu_addr[12:0]), .data_a(cpu_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        .address_b(char_read_addr), .data_b(8'b0), .q_b(char_p1)
    );

    dpram #(.address_width(13), .data_width(8)) charram_p2_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_char_p2),
        .address_a(cpu_addr[12:0]), .data_a(cpu_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        .address_b(char_read_addr), .data_b(8'b0), .q_b(char_p2)
    );

    // ========================================
    // Pixel shift pipeline — 3 bits per pixel from 3 planes
    //
    // FLIP-FIX 2026-05-30: MAME's gfx decode is MSB-FIRST — pixel x reads bit (7-x) via the
    // `(src >> (7 - (bit&7)))` extraction, NOT "bit x". The old code (commented below) read bit[0]
    // and shifted RIGHT (LSB-first) → every FG glyph mirrored horizontally (DECO boot screen: logo
    // OK because it's sprites, but CASSETTE / SYSTEM / WAIT... all backwards). Fix = read bit[7],
    // shift LEFT. OLD: assign pen={pat_p2_sr[0],pat_p1_sr[0],pat_p0_sr[0]}; shift {1'b0,sr[7:1]}.
    // ========================================
    reg [7:0] pat_p0_sr, pat_p1_sr, pat_p2_sr;
    wire [2:0] pen;
    assign pen = { pat_p2_sr[7], pat_p1_sr[7], pat_p0_sr[7] };

    always @(posedge clk_sys) begin
        if (ce_pix) begin
            // FG-HSHIFT-TEST-2026-06-11: tile-aligned shift — the +8 htile shift is a whole tile, so load on the
            // NATURAL hcnt phase (no sub-tile load shift needed).
            if (hcnt[2:0] == 3'b000) begin
                // Load new 8-pixel char line
                pat_p0_sr <= offmap_r2 ? 8'h00 : char_p0;   // FG-WRAP-BLANK-2026-06-29: blank wrapped col (was char_p0)
                pat_p1_sr <= offmap_r2 ? 8'h00 : char_p1;   // FG-WRAP-BLANK-2026-06-29: blank wrapped col (was char_p1)
                pat_p2_sr <= offmap_r2 ? 8'h00 : char_p2;   // FG-WRAP-BLANK-2026-06-29: blank wrapped col (was char_p2)
            end else begin
                // Shift LEFT for next pixel (MSB-first — see FLIP-FIX above)
                pat_p0_sr <= {pat_p0_sr[6:0], 1'b0};
                pat_p1_sr <= {pat_p1_sr[6:0], 1'b0};
                pat_p2_sr <= {pat_p2_sr[6:0], 1'b0};
            end
        end
    end

    // ========================================
    // FG palette index — MAME get_fg_tile_info:
    //   tileinfo.set(0,                                  // gfx 0 (charlayout)
    //       256 * (attr & 3) + code,                     // tile index
    //       BIT(m_color_center_bot, 0),                  // color = 0 or 1
    //       0);
    // gfx 0 has 4 color sets × 8 pens (3bpp). Effective palette index:
    //   {color_center_bot[0], pen[2:0]}   (4-bit; padded to 5-bit fg_pen)
    // Transparent pen 0 per set_transparent_pen(0) at video_start.
    // ========================================
    // FG-VSHIFT-2026-06-28: the FG sits ~2px LOW vs the BG (the BG pipeline is ~2 stages deeper). Under the 90°
    // rotation display-vertical = hcnt and high-hcnt = TOP (HW-confirmed via the hblank=263 test), and the mixer
    // samples per-hcnt — so DELAYING the FG output by N ce_pix moves it UP N display rows. Two extra stages → up 2.
    // Tunable: add/remove a stage to nudge ±1 row. (Can only move UP via delay; if it ever needs DOWN, delay BG.)
    // DIAG-REVERT-2026-06-28: original single-stage output below, uncomment + drop the 2 extra stages to restore.
    // always @(posedge clk_sys) if (ce_pix) fg_pen <= { 1'b0, color_center_bot[0], pen };
    reg [4:0] fg_pen_s0, fg_pen_s1;
    always @(posedge clk_sys) begin
        if (ce_pix) begin
            fg_pen_s0 <= { 1'b0, color_center_bot[0], pen };   // stage 0 = original timing
            fg_pen_s1 <= fg_pen_s0;                            // +1 row up
            fg_pen    <= fg_pen_s1;                            // +2 rows up  (FG-VSHIFT = 2)
        end
    end

    assign fg_opaque = (fg_pen[2:0] != 3'b000);

endmodule
