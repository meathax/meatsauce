// DECO Cassette — Background tilemap renderer (task 09)
//
// 2026-05-17 — FULL REWRITE. Previous version was completely stubbed
// (tile_code_byte and bitmap_byte hardcoded to 0). This version wires
// CPU writes through to internal BRAMs and produces real pixel output.
//
// 2026-06-28 — BG-REBUILD: dual-tilemap (L=top half / R=bottom half) + per-half
// scroll (back_h/vl/vr_shift) + empty-tile mask. This is the MAME-faithful
// structure (decocass_v.cpp draw_edge:625, get_bg_l/r:199-219, video_start:700-704,
// tile_offset[32*32]:130-163). Fixes: (a) the white dashes in empty BG cells
// (empty-tile mask was missing), (b) choppy scrolling on Boulder Dash et al
// (hardware fine-scroll registers were unused → only coarse CPU tile placement).
// Every line it replaces is preserved directly below as a `// BG-REBUILD-2026-06-28:`
// comment. Revert = restore those originals, delete the BG-REBUILD code.
//   *** REGRESSION RISK: scrollx = 256 - back_h_shift may map the visible columns
//       to a different LUT quadrant than the old no-scroll path. If BurgerTime/LnC
//       shift by ~256px on the first build, that pins the hcnt/vcnt-vs-MAME origin
//       delta (read it via MAME's screen_update popmessage: key 'I' → mode/h/vl/vr)
//       and we add a constant origin offset. First build is a DIAGNOSTIC for this.
//   *** ROTATION: the L/R split is on NATIVE screen-Y (vcnt). On rotated/vertical
//       games (e.g. Flying Ball) it appears as a left/right seam — that's correct,
//       rotation is handled downstream. Do NOT re-axis the split.
//
// MAME reference (decocass.cpp:961-970 tilelayout, decocass_v.cpp:130-163
// tile_offset, decocass_v.cpp:199-228 get_bg_*_tile_info):
//   - 32×32 tilemap of 16×16-pixel tiles
//   - 16 unique tile bitmaps (4-bit tile_code), 3 bits per pixel
//   - tilemap codes live in $D000-$D3FF (upper nibble of each byte)
//   - tile bitmaps share the same bytes: $D000-$D3FF holds plane 0
//     (in the upper nibble — bit positions 4..7), $D400-$D7FF holds
//     planes 1 and 2 interleaved (lower nibble = plane 1, upper = plane 2)
//   - get_bg_l/r_tile_info returns m_bgvideoram[tile_index] >> 4
//
// Pixel-byte mapping (per MAME tilelayout):
//   tile N, row y, pixel x (16 pixels per row):
//     group   = x[3:2]                  (0..3 nibble groups)
//     bytaddr = N*64 + y + group*16     (4 distinct bytes per row per plane)
//     plane 0 byte at byaddr             (in $D000-$D3FF region)
//     plane 1+2 byte at byaddr + 1024   (in $D400-$D7FF region)
//     plane 0 pixel bit = byte[4 + x[1:0]]  (upper nibble)
//     plane 1 pixel bit = byte[0 + x[1:0]]  (lower nibble of $D4xx byte)
//     plane 2 pixel bit = byte[4 + x[1:0]]  (upper nibble of $D4xx byte)

module video_bg (
    input  wire        clk_sys,
    input  wire        ce_pix,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,

    // Scroll/mode registers (BG-REBUILD-2026-06-28: now USED — were deferred)
    input  wire [7:0]  back_h_shift,
    input  wire [7:0]  back_vl_shift,
    input  wire [7:0]  back_vr_shift,
    input  wire [7:0]  mode_set,

    // FG color register — also drives BG color (decocass_v.cpp:201-204)
    input  wire [7:0]  color_center_bot,

    // CPU write port (shared $D000-$D7FF, 11-bit address)
    input  wire        cpu_we_tile,
    input  wire [10:0] cpu_addr_tile,
    input  wire [7:0]  cpu_dout,

    // Render outputs
    output reg  [5:0]  bg_pen,   // PALETTE-BG-COLORSET-2026-06-28: 6-bit pen (color-set 5 → pens 40-47, bitswapped half)
    output reg         bg_opaque
);

    // ========================================
    // BG-REBUILD-2026-06-28: scroll-aware coordinate derivation.
    // Original no-scroll derivation preserved below (commented).
    // ========================================
    // BG-REBUILD-2026-06-28: original below, uncomment to restore (no-scroll, visible 16x16 only)
    // wire [4:0] tile_col = {1'b0, hcnt[7:4]};   // 0..15 visible (tilemap is 32 wide)
    // wire [4:0] tile_row = {1'b0, vcnt[7:4]};
    // wire [3:0] pix_x    = hcnt[3:0];           // 0..15 pixel within tile
    // wire [3:0] pix_y    = vcnt[3:0];

    // ---- per-half vertical scroll (draw_edge:630-637) ----
    //   scrolly_l = back_vl_shift          (+256 if  mode_set&0x04)
    //   scrolly_r = 256 - back_vr_shift    (+256 if !(mode_set&0x04))
    //   half is selected by SCREEN-Y: L = top (vcnt<128), R = bottom (vcnt>=128) — video_start:700-704
    wire        bank        = mode_set[2];                       // mode_set & 0x04 bank select
    wire [9:0]  scrolly_l   = {2'b0, back_vl_shift} + (bank ? 10'd256 : 10'd0);
    wire [9:0]  scrolly_r   = (10'd256 - {2'b0, back_vr_shift}) + (bank ? 10'd0 : 10'd256);
    wire        half_bottom = (vcnt >= 9'd128);                  // R tilemap (bottom screen half)
    wire [9:0]  scrolly     = half_bottom ? scrolly_r : scrolly_l;
    wire [9:0]  srcline     = ({1'b0, vcnt} + scrolly) & 10'h1ff;   // (y + scrolly) & 0x1ff (draw_edge:663)

    // ---- horizontal scroll + x-mode (draw_edge:639,673-679) ----
    // (BG-HSHIFT-2026-06-28 REVERTED 2026-06-28: hcnt origin shift did NOT move the top/bottom band on HW → not the
    //  bg hcnt origin. Reverted to the plain xsum. The 8px band is a vcnt/active-window issue — see video_timing.)
    wire [9:0]  scrollx = 10'd256 - {2'b0, back_h_shift};        // 256 - back_h_shift
    wire [9:0]  xsum    = {1'b0, hcnt} + scrollx;                // hcnt + scrollx
    wire [9:0]  srccol  =
        (mode_set[1:0] == 2'b00) ? {2'b0, xsum[7:0]}             : // (x+sx)&0xff        — hwy normal
        (mode_set[1:0] == 2'b01) ? ((xsum + 10'h100) & 10'h1ff)  : // (x+sx+0x100)&0x1ff — manhattan top
        (mode_set[1:0] == 2'b10) ? ({2'b0, xsum[7:0]} + 10'h100) : // ((x+sx)&0xff)+0x100— manhattan normal
                                   (xsum & 10'h1ff);                // (x+sx)&0x1ff       — hwy/burnrub

    // ---- tile cell + within-tile pixel from the scrolled coords ----
    wire [4:0]  tile_col = srccol[8:4];     // 0..31
    wire [4:0]  tile_row = srcline[8:4];    // 0..31
    wire [3:0]  pix_x    = srccol[3:0];
    wire [3:0]  pix_y    = srcline[3:0];

    // ========================================
    // tile_offset LUT — full 32×32 (decocass_v.cpp:130-163).
    // BG-REBUILD-2026-06-28: extended from cols0-15/rows0-15 to the FULL 32×32 (scroll can push col/row past 15).
    //   col_base = (col[4]?0x100:0) + (0x078 - col[3:0]*8)       col[4] adds +0x100
    //   row_off  = (row[4]?0x200:0) + (row[3] ? 0x08f-row[3:0] : row[3:0])   row[4] adds +0x200
    //   tile_index = col_base + row_off    (0..0x3ff)
    // Spot-checks vs table: col0row0=0x078 col0row16=0x278 col16row0=0x178 col0row8=0x0ff col0row15=0x0f8 col0row24=0x2ff
    // ========================================
    // BG-REBUILD-2026-06-28: original half-LUT (cols0-15/rows0-15 only) below, uncomment to restore
    // wire [9:0] bg_base    = 10'h078 - {3'b0, tile_col[3:0], 3'b0};   // 0x078 - col*8
    // wire [9:0] tile_index = tile_row[3] ? (bg_base + 10'h08f - {6'b0, tile_row[3:0]})   // rows 8..15 (mirrored)
    //                                     : (bg_base + {6'b0, tile_row[3:0]});            // rows 0..7
    wire [9:0] col_base = (tile_col[4] ? 10'h100 : 10'h000) + (10'h078 - {3'b0, tile_col[3:0], 3'b0});
    wire [9:0] row_off  = (tile_row[4] ? 10'h200 : 10'h000)
                        + (tile_row[3] ? (10'h08f - {6'b0, tile_row[3:0]}) : {6'b0, tile_row[3:0]});
    wire [9:0] tile_index = col_base + row_off;

    // ========================================
    // BRAM #1: tile codes (also doubles as plane-0 bitmap source).
    // $D000-$D3FF = first 1KB of tileram. CPU writes when cpu_addr_tile < 0x400.
    // ========================================
    wire cpu_we_tile_lo = cpu_we_tile && (cpu_addr_tile < 11'h400);
    wire cpu_we_tile_hi = cpu_we_tile && (cpu_addr_tile >= 11'h400);

    wire [7:0] tilecode_byte;
    dpram #(.address_width(10), .data_width(8)) bg_tilecodes_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_tile_lo),
        .address_a(cpu_addr_tile[9:0]), .data_a(cpu_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        .address_b(tile_index), .data_b(8'b0), .q_b(tilecode_byte)
    );

    // ========================================
    // Per-half flip + empty-tile mask (get_bg_l/r_tile_info:199-219).
    //   L (top)    : flags=0 (no flip);  empty when  (tile_index & 0x80)
    //   R (bottom) : TILE_FLIPY;         empty when !(tile_index & 0x80)
    //   ⇒ flip = half_bottom ;  blank = tile_index[7] ^ half_bottom
    // Empty (blank) cells render TRANSPARENT (kills the white dashes that were the empty-placeholder glyph).
    // ========================================
    // BG-REBUILD-2026-06-28: original single-tilemap flip-on-bit7 hack below, uncomment to restore
    // wire [3:0] eff_pix_y = tile_index[7] ? (4'd15 - pix_y) : pix_y;
    wire [3:0] eff_pix_y  = half_bottom ? (4'd15 - pix_y) : pix_y;
    wire       blank_comb = tile_index[7] ^ half_bottom;

    // BG-SKEWFIX-2026-06-28: the tile-code BRAM (bg_tilecodes) has 1-cycle read latency, so `tilecode_byte` reflects
    // the tile from hcnt N-1 while pix_x/eff_pix_y/blank_comb are from hcnt N. Latching them together (original s1
    // below) drew tile N-1's code with tile N's pixel offset → a 1px-wrong sliver at each tile's hcnt boundary = a
    // line at each tile's TOP on the 90°-rotated display (the colored-line artifact, MAME-clean). Fix: delay the
    // coordinate/mask path one cycle (stage A) so it aligns with tilecode_byte, THEN latch s1. (Sprites already do
    // this via their delayed bit_r — that's why sprites are clean.) Net: uniform ~1px hcnt shift, clean boundaries.
    reg [3:0] pixA_x, pixA_y;
    reg       blankA;
    always @(posedge clk_sys) begin
        if (ce_pix) begin
            pixA_x <= pix_x;
            pixA_y <= eff_pix_y;
            blankA <= blank_comb;
        end
    end

    // Latch tile_code, pixel coordinates and the empty-mask 1 cycle (waiting for tilecode_byte).
    reg [3:0] s1_tile_code;
    reg [3:0] s1_pix_x, s1_pix_y;
    reg       s1_blank;     // BG-REBUILD-2026-06-28: pipelined empty-tile mask (aligns with s1_tile_code)
    always @(posedge clk_sys) begin
        if (ce_pix) begin
            s1_tile_code <= tilecode_byte[7:4];
            // BG-SKEWFIX-2026-06-28: original un-delayed pix/mask below, uncomment to restore the 1px boundary skew
            // s1_pix_x  <= pix_x;
            // s1_pix_y  <= eff_pix_y;
            // s1_blank  <= blank_comb;
            s1_pix_x     <= pixA_x;
            s1_pix_y     <= pixA_y;
            s1_blank     <= blankA;
        end
    end

    // ========================================
    // BRAM #2: plane 0 bitmap (same memory as tile codes — $D000-$D3FF).
    //   byte_addr = tile_code*64 + pix_y + pix_x[3:2]*16
    // We use a separate dpram so we can read tile codes and plane 0 simultaneously.
    // CPU writes are mirrored from the same $D000-$D3FF range.
    // ========================================
    // BG-BITMAP-FIX-2026-06-10: group order reversed per tilelayout xoffset = (3 - x[3:2])*16 (was x[3:2]*16).
    wire [9:0] plane0_addr = {s1_tile_code[3:0], 6'b0} + {6'b0, s1_pix_y[3:0]} + {4'b0, (2'd3 - s1_pix_x[3:2]), 4'b0};
    wire [7:0] plane0_byte;
    dpram #(.address_width(10), .data_width(8)) bg_plane0_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_tile_lo),
        .address_a(cpu_addr_tile[9:0]), .data_a(cpu_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        .address_b(plane0_addr), .data_b(8'b0), .q_b(plane0_byte)
    );

    // ========================================
    // BRAM #3: planes 1+2 bitmap ($D400-$D7FF).
    //   byte_addr = tile_code*64 + pix_y + pix_x[3:2]*16   (in second 1KB)
    // CPU writes from cpu_addr_tile[9:0] when cpu_addr_tile[10] is set.
    // ========================================
    wire [9:0] plane12_addr = plane0_addr;  // same offset within the second 1KB region
    wire [7:0] plane12_byte;
    dpram #(.address_width(10), .data_width(8)) bg_plane12_inst (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_tile_hi),
        .address_a(cpu_addr_tile[9:0]), .data_a(cpu_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(ce_pix), .wren_b(1'b0),
        .address_b(plane12_addr), .data_b(8'b0), .q_b(plane12_byte)
    );

    // ========================================
    // Latch second stage (pix_x[1:0] needs to align with byte data)
    // ========================================
    reg [1:0] s2_pix_x_lo;
    reg       s2_blank;     // BG-REBUILD-2026-06-28: empty-tile mask, 2nd pipeline stage (aligns with bg_pen)
    always @(posedge clk_sys) begin
        if (ce_pix) begin
            s2_pix_x_lo <= s1_pix_x[1:0];
            s2_blank    <= s1_blank;
        end
    end

    // Extract pixel bits from the bytes:
    //   plane 0: byte[4 + pix_x[1:0]] — upper nibble of $D0xx byte
    //   plane 1: byte[0 + pix_x[1:0]] — lower nibble of $D4xx byte
    //   plane 2: byte[4 + pix_x[1:0]] — upper nibble of $D4xx byte
    // BG-BITMAP-FIX-2026-06-10: MSB-first (like the FG FLIP-FIX) + correct nibbles per tilelayout planeoffset
    // {8196,8192,4} (decocass.cpp:961): pen LSB(p0) = $D000 LOWER nibble bit(3-x); p1 = $D400 UPPER nibble bit(7-x);
    // pen MSB(p2) = $D400 LOWER nibble bit(3-x). (Was nibbles swapped + LSB-first.)
    wire [2:0] bg_xlo = {1'b0, s2_pix_x_lo};        // 0..3
    wire p0 = plane0_byte [3'd3 - bg_xlo];          // $D000 lower nibble, MSB-first
    wire p1 = plane12_byte[3'd7 - bg_xlo];          // $D400 upper nibble, MSB-first
    wire p2 = plane12_byte[3'd3 - bg_xlo];          // $D400 lower nibble, MSB-first

    wire [2:0] pen = {p2, p1, p0};

    // ========================================
    // Output: palette index per MAME get_bg_l_tile_info (decocass_v.cpp:199-208):
    //   color = (m_color_center_bot >> 7) & 1  (1 bit)
    //   tileinfo.set(2, tile_code, color * 4 + 1, 0)
    // Use {1'b0, color, pen[2:0]} (5-bit). Transparent on pen=0 OR empty-tile (s2_blank).
    // ========================================
    always @(posedge clk_sys) begin
        if (ce_pix) begin
            // PALETTE-BG-COLORSET-2026-06-28: emit the FULL 6-bit pen per MAME gfx(2) color = `color*4+1`.
            //   color_attr = ccb[7] ? 5 : 1 ;  pen = color_attr*8 + pix_pen = {color_attr[2:0], pen}
            //   ccb[7]=0 → pens 8-15 (lower/direct);  ccb[7]=1 → pens 40-47 (upper half, bitswapped in video_palette).
            // Original simplified mapping below, uncomment to restore:
            // bg_pen <= {1'b0, color_center_bot[7], pen};
            bg_pen    <= {(color_center_bot[7] ? 3'b101 : 3'b001), pen};
            // BG-REBUILD-2026-06-28: original below, uncomment to restore (no empty-tile mask)
            // bg_opaque <= (pen != 3'b000);
            bg_opaque <= (pen != 3'b000) & ~s2_blank;   // empty cells transparent → fill shows → no white dash
        end
    end

endmodule
