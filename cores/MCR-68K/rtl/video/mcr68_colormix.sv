// =============================================================================
// mcr68_colormix.sv -- MCR-68k (Xenophobe) final pixel compositor + palette
// lookup.
//
// Combines the tilemap engine's per-pixel tile data and the sprite engine's
// two (already-resolved) priority-group pixels into the single winning pen
// for the current screen pixel, looks that pen up through the 64-entry
// xRBG_333 palette RAM (`mcr68_mem_sim.sv` `palette_rd_addr`/`palette_rd_data`
// port, read directly rather than re-invented here), and expands the 3-bit
// R/B/G guns to 8 bits each.
//
// Purely combinational (no `clk`, no internal state): for any given pixel,
// present the tilemap/sprite layer inputs and the palette-RAM data for that
// pixel's resolved address, and `{r,g,b}` appear in the same cycle. This
// matches `mcr68_mem_sim.sv`'s current palette read port, which is async
// (see that file's header). If a later hardware palette RAM is a registered
// M10K/MLAB block (1-cycle address->data latency), the *caller* is
// responsible for delaying the `tm_*`/`sp_lo_*`/`sp_hi_*` inputs by that same
// latency so they still describe the pixel `palette_rd_data` answers for --
// this module does not add that pipeline stage itself.
//
// -----------------------------------------------------------------------
// Render order -- cross-checked against `screen_update_mcr68`,
// `D:\Arcade\AI\mame289\src\mame\bally\mcr68.cpp:359-373`:
//
//   1. m_bg_tilemap->draw(..., TILEMAP_DRAW_OPAQUE | TILEMAP_DRAW_ALL_CATEGORIES, 0);
//        -- opaque: every tile pen (including pen 0) is drawn unconditionally,
//           regardless of tileinfo.category. This is the base layer; nothing
//           can be transparent through it because nothing has been drawn yet.
//   2. mcr68_update_sprites(..., 0);          // low-priority sprite group
//   3. m_bg_tilemap->draw(..., 1, 0);
//        -- category filter = 1 (draws ONLY tiles whose tileinfo.category==1,
//           set at mcr68.cpp:261 from tile-word bit 15), using the tilemap's
//           normal transparent_pen(0) set in video_start (mcr68.cpp:276) --
//           i.e. pen 0 is transparent on THIS call, unlike call 1. This is
//           the "draw tiles with priority over sprites" pass: it punches
//           back over the low-priority sprites just drawn in step 2.
//   4. mcr68_update_sprites(..., 1);          // high-priority sprite group,
//                                              // drawn last, on top of all
//                                              // of the above.
//
// Implemented below as a 4-stage sequential overwrite (`always_comb`, later
// stage always wins where its condition holds) -- the natural hardware
// mirror of MAME's draw-call order, since drawgfx composes purely by later
// writes clobbering earlier ones within a frame's single bitmap.
//
// -----------------------------------------------------------------------
// Tilemap engine interface (this module's assumption; reconcile against the
// actual tilemap-engine agent's output):
//   One set of {tm_pen, tm_color_bank, tm_category} per pixel, already
//   decoded from the raw 16-bit tile word exactly as `get_bg_tile_info`
//   does it (mcr68.cpp:254-262):
//     data                          = tile RAM word (byte-wide chip, D0-D7,
//                                      but tile decode reads it as a full
//                                      16-bit value spanning 2 CPU words --
//                                      see mcr68_mem_sim.sv header)
//     code    = (data & 0x3ff) | ((data >> 4) & 0xc00)      -- not needed here
//     tm_pen                        = decoded 4-bit pixel pen from gfx1,
//                                      0..15 (tile ROM is 4bpp)
//     tm_color_bank  = (~data >> 12) & 3                    -- ACTIVE LOW,
//                                      already inverted by the tilemap engine
//                                      before it reaches this module
//     tm_category    = (data >> 15) & 1                     -- "priority over
//                                      sprites" category bit
//   The SAME set of signals serves BOTH tilemap draw calls (1) and (3) above
//   -- they read identical tile data; only the compositing rule differs
//   (call 1 ignores pen==0 and category, call 3 requires category==1 and
//   treats pen==0 as transparent). This module applies both rules itself
//   from the one input set, so the tilemap engine does not need to run two
//   separate passes or expose two sets of signals.
//
// Sprite engine interface (this module's assumption; reconcile against the
// actual sprite-engine agent's output):
//   Per priority group (low/high), ONE already-resolved {valid, pen, color}
//   for the current pixel -- i.e. the sprite engine itself performs the
//   MAME `prio_transmask` two-pass masking (mcr68.cpp:338-347,
//   trans_mask=0x0101 then 0xFEFF, RAM slot 511->0 so slot 0 wins within a
//   pass) and the per-group priority-buffer refill (`screen.priority().fill
//   (1, ...)`, mcr68.cpp:310, called once per `mcr68_update_sprites`
//   invocation) using its own internal line/priority buffer. This module
//   receives only the outcome:
//     sp_*_valid = 1 iff this priority group draws a visible pixel here --
//                  either pass 1 drew a normal pen (1-7,9-15; pens 0 and 8
//                  are excluded from pass 1 by trans_mask 0x0101), or pass 2
//                  drew pen 8 because the priority buffer at this pixel was
//                  still unwritten (value 1) when pass 2 ran. sp_*_valid=0
//                  means fully transparent for this group -- whatever layer
//                  is under it (base tilemap, or nothing yet) shows through.
//     sp_*_pen   = the winning 4-bit pen (never 0; is exactly 8 only for a
//                  pass-2 mask hit, otherwise 1-7/9-15 from pass 1).
//     sp_*_color = ~flags & 0x03 (mcr68.cpp:329) -- ACTIVE LOW, already
//                  inverted by the sprite engine before it reaches this
//                  module (mirrors tm_color_bank's inversion convention).
//   If the sprite-engine agent instead exposes raw per-sprite hit data
//   (unresolved pass1/pass2 pens, no internal masking), this interface
//   needs revision -- flag at integration time, do not silently adapt.
//
// -----------------------------------------------------------------------
// Palette lookup -- MAME's shared `gfxdecode` starts both gfx1 (tiles) and
// gfx2 (sprites) at palette base index 0, so tilemap and sprite pens index
// the SAME 64-entry palette; each uses its own 2-bit "color" field as the
// bank:
//     palette_addr[5:0] = {bank[1:0], pen[3:0]} = bank*16 + pen
// This module drives `mcr68_mem_sim.sv`'s `palette_rd_addr` with the winning
// layer's bank/pen and reads `palette_rd_data` back through the same port
// (read that module first -- it already implements the 64x16 write-only-
// from-CPU palette storage; this module does not duplicate it).
//
// Palette word format: xRBG_333 (`mcr68.cpp:1242`, MAME `emupal.h`
// `standard_rgb_decoder<3,3,3,6,0,3>`). Gun order is R,B,G -- NOT R,G,B:
//     bits [8:6] = Red, [5:3] = Blue, [2:0] = Green (bits [15:9] unused/"x").
// 3-bit-to-8-bit expansion uses MAME's `pal3bit`:
//     pal3bit(b) = (b << 5) | (b << 2) | (b >> 1)
// =============================================================================

`timescale 1ns / 1ps

module mcr68_colormix (
    // -------------------------------------------------------------------
    // Tilemap engine, current pixel. See "Tilemap engine interface" above.
    // -------------------------------------------------------------------
    input  logic [3:0] tm_pen,          // decoded tile pen, 0..15
    input  logic [1:0] tm_color_bank,   // (~data>>12)&3, already active-low corrected
    input  logic       tm_category,     // (data>>15)&1 -- draw-over-sprites category

    // -------------------------------------------------------------------
    // Low-priority sprite group (mcr68_update_sprites(...,0)), resolved.
    // See "Sprite engine interface" above.
    // -------------------------------------------------------------------
    input  logic       sp_lo_valid,
    input  logic [3:0] sp_lo_pen,
    input  logic [1:0] sp_lo_color,     // ~flags & 3, already active-low corrected

    // -------------------------------------------------------------------
    // High-priority sprite group (mcr68_update_sprites(...,1)), resolved.
    // Same shape as the low-priority group; drawn last, on top of everything.
    // -------------------------------------------------------------------
    input  logic       sp_hi_valid,
    input  logic [3:0] sp_hi_pen,
    input  logic [1:0] sp_hi_color,

    // -------------------------------------------------------------------
    // Palette RAM read port -- wired directly to mcr68_mem_sim.sv's
    // palette_rd_addr/palette_rd_data (entry index 0..63, async read).
    // -------------------------------------------------------------------
    output logic [5:0]  palette_rd_addr,
    // Bits [15:9] are the xRBG_333 "x" (unused) high bits of the 16-bit RAM
    // word -- intentionally unread below, not dead by omission.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [15:0] palette_rd_data,
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------
    // Final composited, palette-expanded pixel for the current screen
    // position. Three separate 8-bit guns (not a packed 24-bit bus) to
    // match this project's video sink, sys/arcade_video.v, which consumes
    // VGA_R/VGA_G/VGA_B as independent 8-bit ports.
    // -------------------------------------------------------------------
    output logic [7:0] r,
    output logic [7:0] g,
    output logic [7:0] b
);

    // -------------------------------------------------------------------
    // Stage 1-4: sequential overwrite in MAME draw-call order
    // (mcr68.cpp:359-373). Later stage wins wherever its condition holds;
    // "no condition holds" at a given stage means "leave the pixel from the
    // previous stage untouched" -- exactly what drawing nothing does to an
    // existing bitmap.
    // -------------------------------------------------------------------
    logic [1:0] mix_bank;
    logic [3:0] mix_pen;

    always_comb begin
        // (1) Opaque tilemap, all categories: base layer, always visible --
        //     pen 0 is NOT transparent here (TILEMAP_DRAW_OPAQUE).
        mix_bank = tm_color_bank;
        mix_pen  = tm_pen;

        // (2) Low-priority sprites: opaque wherever the sprite engine
        //     reports a resolved hit (pen 0 never appears as sp_lo_pen --
        //     trans_mask 0x0101 excludes it from pass 1, and pass 2 only
        //     ever draws pen 8).
        if (sp_lo_valid) begin
            mix_bank = sp_lo_color;
            mix_pen  = sp_lo_pen;
        end

        // (3) Category-1 tilemap tiles, transparent pen 0: punches back
        //     over the low-priority sprites just composited in (2).
        if (tm_category && (tm_pen != 4'd0)) begin
            mix_bank = tm_color_bank;
            mix_pen  = tm_pen;
        end

        // (4) High-priority sprites: drawn last, on top of everything above.
        if (sp_hi_valid) begin
            mix_bank = sp_hi_color;
            mix_pen  = sp_hi_pen;
        end
    end

    // -------------------------------------------------------------------
    // Palette index = bank*16 + pen (bank in bits [5:4], pen in bits [3:0]).
    // Same 64-entry palette for both tilemap (gfx1) and sprite (gfx2) pens
    // per MAME's shared gfxdecode base-index-0 start for both regions.
    // -------------------------------------------------------------------
    assign palette_rd_addr = {mix_bank, mix_pen};

    // -------------------------------------------------------------------
    // xRBG_333 unpack (R,B,G gun order, NOT R,G,B) and pal3bit expansion.
    // palette_rd_data[15:9] are unused ("x") bits of the 16-bit RAM word;
    // only [8:0] are meaningful.
    // -------------------------------------------------------------------
    function automatic logic [7:0] pal3bit(input logic [2:0] v);
        logic [7:0] v8;
        v8 = {5'd0, v};
        pal3bit = (v8 << 5) | (v8 << 2) | (v8 >> 1);
    endfunction

    wire [2:0] pal_r = palette_rd_data[8:6];
    wire [2:0] pal_b = palette_rd_data[5:3];
    wire [2:0] pal_g = palette_rd_data[2:0];

    assign r = pal3bit(pal_r);
    assign g = pal3bit(pal_g);
    assign b = pal3bit(pal_b);

endmodule
