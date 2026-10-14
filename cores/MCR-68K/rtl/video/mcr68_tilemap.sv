// =============================================================================
// mcr68_tilemap.sv -- MCR-68k (Xenophobe) background tilemap engine.
//
// *** Phase 3 video RTL. Consumes two SIMULATION-ONLY staging modules
// (rtl/mcr68_mem_sim.sv, rtl/video/mcr68_gfx_rom_sim.sv) -- see their own
// headers. This module's own logic (bit-field decode, tile-word
// reconstruction FSM, flip/pen math) IS intended to be synthesizable; only
// its two dependencies are sim-only stand-ins for the eventual SDRAM path. ***
//
// =============================================================================
// PROVENANCE -- read directly, not from memory, for this file:
//   Plan:  C:\Users\meath\.claude\plans\you-a-makeing-a-fizzy-rabin.md, "Video"
//          section (tilemap bullet).
//   MAME:  D:\Arcade\AI\mame289\src\mame\bally\mcr68.cpp
//            :254-262   get_bg_tile_info()      -- tile-word bit-field decode
//            :1153-1162 mcr68_bg_layout          -- gfx_layout struct (ROM bit
//                                                    packing; delegated to
//                                                    mcr68_gfx_rom_sim.sv, see
//                                                    below -- NOT re-derived
//                                                    here)
//          D:\Arcade\AI\mame289\src\emu\tilemap.h
//            :342-343   TILE_FLIPX=0x01, TILE_FLIPY=0x02
//            :812       TILE_FLIPYX(yx) = yx & 3  -- confirms bit0=FLIPX,
//                                                     bit1=FLIPY of the
//                                                     shifted (data>>10) value,
//                                                     i.e. data[10]=FLIPX,
//                                                     data[11]=FLIPY.
//          D:\Arcade\AI\mame289\src\emu\drawgfx.cpp
//            :24-27     readbit() -- MSB-first bit numbering, used to
//                                     independently confirm
//                                     mcr68_gfx_rom_sim.sv's own byte-packing
//                                     derivation before trusting it.
//
// -----------------------------------------------------------------------
// Tile-word bit-field decode (get_bg_tile_info, mcr68.cpp:254-262), verified
// bit-by-bit below. Let `data` = the reconstructed 16-bit tile word:
//
//   MAME:  code  = (data & 0x3ff) | ((data >> 4) & 0xc00);
//     0x3ff (bits 9:0) contributes data[9:0] -> code[9:0].
//     0xc00 after >>4 selects data bits 15,14 shifted into result bits 11,10
//     -- i.e. data[14]->code[10], data[15]->code[11]. Since gfx1 has exactly
//     2048 (2^11) elements, code bit 11 (== data[15]) is always discarded by
//     the implicit mod-2048 wrap at the gfx-decode boundary -- it has NO
//     effect on which tile graphic is fetched. So the bits that actually
//     select the graphic are exactly {data[14], data[9:0]} -- 11 bits,
//     0..2047, matching the plan's "code (11-bit, mod 2048)" and requiring
//     no explicit masking here (it is already exactly 11 bits by
//     construction).
//   RTL:   code[10:0] = {data[14], data[9:0]}                    -- EXACT
//
//   MAME:  color = (~data >> 12) & 3;
//   RTL:   tm_color_bank[1:0] = ~data[13:12]                     -- EXACT
//          (active-low: bits 12/13 of the raw word are inverted)
//
//   MAME:  tileinfo.set(0, code, color, TILE_FLIPYX(data >> 10));
//          TILE_FLIPYX(yx) = yx & 3, TILE_FLIPX=bit0, TILE_FLIPY=bit1 of yx
//          => (data>>10) bit0 = data[10] = FLIPX, bit1 = data[11] = FLIPY.
//   RTL:   flipx = data[10], flipy = data[11]                    -- EXACT
//
//   MAME:  if (m_gfxdecode->gfx(0)->elements() < 0x1000)
//              tileinfo.category = (data >> 15) & 1;
//          gfx1 has 2048 elements (< 0x1000 = 4096), so this condition is
//          always true for Xenophobe -- the category assignment always
//          applies. data[15] is therefore simultaneously (a) the discarded-
//          by-mod-2048 top bit of the raw `code` expression above and (b)
//          the real, load-bearing "draw over sprites" category flag -- the
//          plan's "code-bit-11-alias AND priority category bit" wording.
//   RTL:   tm_category = data[15]                                -- EXACT
//
// -----------------------------------------------------------------------
// Dependency interfaces -- READ DIRECTLY (both files already existed when
// this module was written; nothing below is guessed):
//
//   rtl/mcr68_mem_sim.sv (background VRAM):
//     vram_rd_addr [10:0] word index 0..2047, vram_rd_data [7:0], async/
//     combinational (`assign vram_rd_data = vram_mem[vram_rd_addr];`).
//     ONE port, ONE byte per address -- reconstructing the 16-bit tile word
//     needs two sequential reads (MAME: `data = (videoram[tile_index*2] &
//     0xff) | ((videoram[tile_index*2+1] & 0xff) << 8)`, tile_index counted
//     row-major TILEMAP_SCAN_ROWS over the 32x32 grid). This is the one
//     place this module cannot be purely combinational -- see "Timing /
//     tm_valid contract" below.
//
//   rtl/video/mcr68_gfx_rom_sim.sv PORT 1 (tile ROM, gfx1) -- ALREADY
//     WRITTEN by the sibling agent (no interface guess was needed):
//       in:  gfx1_code[10:0], gfx1_row[2:0] (0..7, pre-flip -- caller passes
//            7-row for flipY), gfx1_pair[1:0] (0..3, which 2-column group,
//            pre-flip -- caller passes 3-pair for flipX per that file's own
//            documented convention)
//       out: gfx1_pen0[3:0] (even/first column of the pair), gfx1_pen1[3:0]
//            (odd/second column), both fully decoded and combinational
//            (zero added latency). gfx1_byte0/gfx1_byte1 (raw bytes) also
//            exist on that port but are NOT consumed here -- this module
//            only needs the pre-decoded pens.
//     This module does NOT reproduce that file's own bit-packing math
//     (STEP8(0,2)/STEP8(0,16) byte layout, ROMREGION_INVERT handling) --
//     that is entirely that module's responsibility and is out of scope
//     here by design (single-responsibility split agreed at hand-off).
//     Rather than separately deriving `3-pair`/swap-pens for flip-X as that
//     file's comment suggests, this module instead computes the single
//     post-flip absolute source column (0..7) once and re-splits it into
//     pair/parity -- provably equivalent, simpler to verify. See
//     `col_f`/`gfx1_pair`/`pen_sel` below.
//
// -----------------------------------------------------------------------
// Pixel-doubling (GFXDECODE_SCALE(2,2), mcr68.cpp:1180) and grid geometry:
//   Tilemap is 32x32 tiles of 16x16 (already-doubled) pixels, TILEMAP_SCAN_
//   ROWS (mcr68.cpp:275), transparent pen 0 (mcr68.cpp:276). `pixel_x`/
//   `pixel_y` arrive already in the doubled 512x480 space (see
//   rtl/video/mcr68_video_timing.sv):
//     tile_col   = pixel_x[8:4]   (0..31)   src_col (pre-flip) = pixel_x[3:1] (0..7)
//     tile_row   = pixel_y[8:4]   (0..31)   src_row (pre-flip) = pixel_y[3:1] (0..7)
//     tile_index = tile_row*32 + tile_col = {tile_row[4:0],tile_col[4:0]} (10 bits)
//       -- exact because 32 = 2^5, so the multiply is a plain concatenation.
//
// -----------------------------------------------------------------------
// Timing / tm_valid contract (the one deliberate departure from "purely
// combinational"):
//   Because the VRAM read port above is single-ported and byte-wide, this
//   module needs 2 clk cycles (FETCH_LO, FETCH_HI) to reconstruct a new
//   16-bit tile word whenever (tile_col,tile_row) changes vs the tile
//   currently cached; the gfx1 ROM lookup that follows is then fully
//   combinational (zero extra latency), so total worst-case latency is 2
//   clk cycles, entered only at a tile-column/row boundary (every 16
//   doubled pixels -- 16 clk-equivalents of dwell time at a 1:1 clk:pixel
//   ratio, comfortably more than 2). `tm_valid` is LOW during those 2
//   cycles and HIGH otherwise; per this project's rule against ever
//   presenting silently-wrong pixels (CLAUDE.md, "never obtain a pass by
//   coercing"), tm_pen/tm_color_bank/tm_category are held at their previous
//   (stale, previous-tile) values while tm_valid is low rather than
//   inventing a plausible-looking but wrong value -- callers MUST gate on
//   tm_valid, not sample unconditionally.
//
//   *** INTEGRATION FLAG, not silently worked around: rtl/video/
//   mcr68_colormix.sv (also already written) currently has NO tm_valid (or
//   any) gating input -- its own header literally says "this module's
//   assumption; reconcile against the actual tilemap-engine agent's
//   output" for exactly this port set. As written today, colormix would
//   sample tm_pen/tm_color_bank/tm_category unconditionally every clk,
//   which means the ~2 cycles after each tile-column boundary (a small
//   fraction of dwell time, but real) would composite the PREVIOUS tile's
//   data for those 2 pixels' worth of clocks. This needs one of, at
//   integration time:
//     (a) add a `tm_valid` input to mcr68_colormix.sv and have its
//         instantiating parent hold/pause the pixel pipeline (or simply not
//         advance pixel_x/pixel_y) while tm_valid is low, or
//     (b) upgrade this module to a one-tile-lookahead double-buffered
//         prefetch (fetch tile N+1 during tile N's 16-cycle dwell time, so
//         tm_valid is always high in steady state) -- deferred here per the
//         task's own explicit guidance that "a simple combinational-ish
//         design with the RAM read latency it naturally has is fine" for
//         this correctness-first phase, pipeline depth being explicitly a
//         later timing-closure concern.
//   Do not silently drop tm_valid to make the port lists match -- flagging
//   this mismatch for reconciliation is the whole point of writing it down
//   here.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module mcr68_tilemap #(
    parameter bit SYNC_GFX = 1'b0,

    // ------------------------------------------------------------------
    // gfx1 region size (see rtl/mcr68_game_profile.svh). 0x10000 for
    // Xenophobe/Blasted, 0x20000 for Arch Rivals/Pigskin -- confirmed
    // from the ROM_REGION( ..., "gfx1", ROMREGION_INVERT ) lines in
    // mcr68.cpp. The default is Xenophobe's, so GAME_XENOPHOB constant-folds
    // to the pre-widening RTL exactly.
    //
    // This is NOT just a width change. MAME's get_bg_tile_info
    // (mcr68.cpp:254-262) has two size-dependent behaviours:
    //
    //   code = (data & 0x3ff) | ((data >> 4) & 0xc00)   -- a 12-bit value
    //     whose top bit is data[15]. With 2048 elements that bit is discarded
    //     by drawgfx's implicit `code %= elements()`; with 4096 elements it
    //     is load-bearing and selects the upper half of the tile ROM.
    //
    //   if (elements() < 0x1000) tileinfo.category = (data >> 15) & 1;
    //     4096 is NOT < 0x1000, so archrivl/pigskin get NO category
    //     assignment at all -- category stays at its tilemap default of 0.
    //     data[15] cannot be both a code bit and a priority flag; MAME
    //     resolves that by size, and so does this module.
    // ------------------------------------------------------------------
    parameter int GFX1_BYTES = 'h10000,
    // Derived -- do NOT override. mcr68_bg_layout is 8x8 4bpp RGN_FRAC(1,2):
    // 16 bytes/tile/half, 32 bytes/tile over the whole region.
    parameter int GFX1_ELEMENTS = GFX1_BYTES / 32,       // 2048 or 4096
    parameter int GFX1_CODE_W   = $clog2(GFX1_ELEMENTS)  // 11 or 12
) (
    input  logic        clk,
    input  logic        rst,           // synchronous, active-high

    // 1 = the ACTIVE title has a 2048-element gfx1 (64 KiB): MAME's
    // `code %= elements()` drops code bit 11 and `elements() < 0x1000` is true
    // so tileinfo.category = data[15]. 0 = 4096 elements (128 KiB, archrivl/
    // pigskin): bit 11 is a real code bit and there is NO category assignment.
    // Runtime, not a parameter -- one bitstream sizes arrays to the union but
    // must still behave correctly for whichever title is actually loaded.
    input  logic        gfx1_small,

    // -------------------------------------------------------------------
    // Pixel position, from rtl/video/mcr68_video_timing.sv (or equivalent).
    // Doubled 512x480 space; meaningful while the caller's own hblank/
    // vblank are deasserted (this module does not look at blanking itself
    // -- it will happily decode tiles at out-of-range coordinates during
    // blanking, harmlessly, since nothing consumes the result then).
    // -------------------------------------------------------------------
    // Bit 0 of each is the pixel-doubling artifact (2 doubled pixels share
    // one source column/row) and is intentionally never read below.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [8:0]  pixel_x,
    input  logic [8:0]  pixel_y,
    input  logic        pixel_active, // !hblank && !vblank; coordinates wrap in blanking
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------
    // Background VRAM read port -- wired straight to rtl/mcr68_mem_sim.sv's
    // vram_rd_addr/vram_rd_data (word index 0..2047, async single-byte
    // port). This module owns that port exclusively (no other consumer
    // should drive vram_rd_addr).
    // -------------------------------------------------------------------
    output logic [10:0] vram_rd_addr,
    input  logic [7:0]  vram_rd_data,

    // -------------------------------------------------------------------
    // Tile ROM (gfx1) read port -- wired straight to rtl/video/
    // mcr68_gfx_rom_sim.sv PORT 1 (gfx1_code/gfx1_row/gfx1_pair in,
    // gfx1_pen0/gfx1_pen1 out). This module owns this port exclusively.
    // -------------------------------------------------------------------
    output logic [GFX1_CODE_W-1:0] gfx1_code,
    output logic [2:0]  gfx1_row,
    output logic [1:0]  gfx1_pair,
    input  logic [3:0]  gfx1_pen0,
    input  logic [3:0]  gfx1_pen1,

    // -------------------------------------------------------------------
    // Decoded output for (pixel_x,pixel_y). Port NAMES match rtl/video/
    // mcr68_colormix.sv's existing tm_pen/tm_color_bank/tm_category exactly
    // (that module's own header names these as its assumed tilemap-engine
    // interface) -- tm_valid is the one addition; see the "Timing /
    // tm_valid contract" note above for why and what to do about it.
    // -------------------------------------------------------------------
    output logic        tm_valid,
    output logic [3:0]  tm_pen,        // 0 = transparent (consumer's rule, not enforced here)
    output logic [1:0]  tm_color_bank, // (~data>>12)&3, already active-low corrected
    output logic        tm_category    // (data>>15)&1, draw-over-sprites category
);

    // -------------------------------------------------------------------
    // Tile addressing from the live pixel position.
    // -------------------------------------------------------------------
    wire [4:0] req_tile_col = pixel_x[8:4];
    wire [4:0] req_tile_row = pixel_y[8:4];
    wire [9:0] req_tile_index = {req_tile_row, req_tile_col}; // row*32+col, exact (32=2^5)

    wire [2:0] src_col = pixel_x[3:1]; // 0..7, pre-flip
    wire [2:0] src_row = pixel_y[3:1]; // 0..7, pre-flip

    // -------------------------------------------------------------------
    // Tile-word cache + 2-cycle VRAM fetch FSM. See "Timing / tm_valid
    // contract" above. `cache_col`/`cache_row` name the tile that
    // `tile_word` currently holds; `primed` is false only before the very
    // first fetch completes after reset.
    // -------------------------------------------------------------------
    localparam logic [1:0] ST_IDLE = 2'd0;
    localparam logic [1:0] ST_LO   = 2'd1;
    localparam logic [1:0] ST_HI   = 2'd2;
    localparam logic [1:0] ST_GFX  = 2'd3;

    logic [1:0]  state;
    logic [4:0]  cache_col, cache_row;
    logic        primed;
    logic [7:0]  lo_byte_r;
    logic [15:0] tile_word;

    wire mismatch = !primed || (req_tile_col != cache_col) || (req_tile_row != cache_row);

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= ST_IDLE;
            primed       <= 1'b0;
            cache_col    <= '0;
            cache_row    <= '0;
            lo_byte_r    <= '0;
            tile_word    <= '0;
            vram_rd_addr <= '0;
        end else begin
            unique case (state)
                ST_IDLE: begin
                    if (pixel_active && mismatch) begin
                        // Latch the NEW target tile now, so the LO/HI fetch
                        // below stays addressed to it even if pixel_x/y
                        // keep moving mid-fetch.
                        cache_col    <= req_tile_col;
                        cache_row    <= req_tile_row;
                        vram_rd_addr <= {req_tile_index, 1'b0}; // tile_index*2 (low byte)
                        state        <= ST_LO;
                    end
                end

                ST_LO: begin
                    // vram_rd_addr has been stable at the low-byte address
                    // since the IDLE->LO edge above; mem_sim's port is
                    // async, so vram_rd_data is already valid here.
                    lo_byte_r    <= vram_rd_data;
                    vram_rd_addr <= {cache_row, cache_col, 1'b1}; // tile_index*2+1 (high byte)
                    state        <= ST_HI;
                end

                ST_HI: begin
                    // vram_rd_addr has been stable at the high-byte address
                    // since the LO->HI edge above.
                    tile_word <= {vram_rd_data, lo_byte_r}; // {hi,lo}, matches MAME's
                                                             // data = lo | (hi<<8)
                    primed    <= 1'b1;
                    state     <= SYNC_GFX ? ST_GFX : ST_IDLE;
                end

                ST_GFX: state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

    assign tm_valid = pixel_active && primed && (state == ST_IDLE) &&
                       (req_tile_col == cache_col) && (req_tile_row == cache_row);

    // -------------------------------------------------------------------
    // Tile-word bit-field decode -- see the line-by-line derivation in the
    // header comment. Purely combinational off the cached `tile_word`;
    // stale (previous tile) whenever tm_valid is low, by design.
    // -------------------------------------------------------------------
    // Full 12-bit MAME code expression; the implicit `code %= elements()` at
    // the drawgfx boundary is the truncation to GFX1_CODE_W below. At
    // GFX1_ELEMENTS==2048 that truncation drops tile_word[15] and leaves
    // exactly the previous `{tile_word[14], tile_word[9:0]}` -- bit-identical.
    // code_raw[11] is deliberately dropped when GFX1_ELEMENTS==2048 -- that IS
    // MAME's `code %= elements()`, not an oversight.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [11:0] code_raw    = {tile_word[15], tile_word[14], tile_word[9:0]};
    /* verilator lint_on UNUSEDSIGNAL */
    wire        flipx       = tile_word[10];
    wire        flipy       = tile_word[11];

    // MAME's `code %= elements()` and `if (elements() < 0x1000)` both depend on
    // the ACTIVE title's gfx1 size, not on how much memory was elaborated. A
    // single bitstream sizes its arrays to the union (4096 elements) but must
    // still behave as a 2048-element gfx1 when running xenophob/blasted/
    // non-priority profiles -- otherwise tm_category is forced to 0 and Xenophobe's
    // "draw over sprites" flag silently disappears. So the SIZE is
    // elaboration-time and the BEHAVIOUR is runtime, driven from the profile.
    assign gfx1_code     = gfx1_small ? {{(GFX1_CODE_W-11){1'b0}}, code_raw[10:0]}
                                      : code_raw[GFX1_CODE_W-1:0];
    assign tm_color_bank = ~tile_word[13:12];
    // `if (elements() < 0x1000)` -- see the parameter block. Constant-folds to
    // `tile_word[15]` for a 2048-element gfx1 and to a hard 0 for 4096.
    assign tm_category   = gfx1_small ? tile_word[15] : 1'b0;

    // -------------------------------------------------------------------
    // Flip-adjusted source row/column, then gfx1 addressing + pen mux.
    // col_f is the single post-flip absolute source column (0..7); this is
    // provably equivalent to mcr68_gfx_rom_sim.sv's own suggested
    // "pass 3-pair and swap pens" flip-X convention (both ultimately select
    // the same physical bit), just derived once here instead of twice.
    // -------------------------------------------------------------------
    wire [2:0] row_f = flipy ? (3'd7 - src_row) : src_row;
    wire [2:0] col_f = flipx ? (3'd7 - src_col) : src_col;

    assign gfx1_row  = row_f;
    assign gfx1_pair = col_f[2:1];

    wire pen_sel = col_f[0]; // 0 = even/first column of the pair (gfx1_pen0),
                              // 1 = odd/second column (gfx1_pen1)
    assign tm_pen = pen_sel ? gfx1_pen1 : gfx1_pen0;

endmodule

`default_nettype wire
