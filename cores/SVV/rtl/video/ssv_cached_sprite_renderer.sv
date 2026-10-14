// SPDX-License-Identifier: GPL-3.0-or-later
// Vblank-cached scanline renderer for interleaved SSV sprites and tilemaps.
`timescale 1ns/1ps

module ssv_cached_sprite_renderer #(
    // Attract soak used ~1277, but a 1500-frame gameplay soak peaked at 1519 of
    // 1536 -- seventeen entries of margin. On hardware the sticky overrun
    // indicator lights with no per-line deadline marks, which points at this
    // overflowing rather than the renderer running late; an overflow silently
    // drops descriptors, so sprites and tilemap slices simply go missing.
    //
    // 2048 costs roughly eight more M10K. That is affordable now only because
    // narrowing the palette's odd bank freed 31 blocks (530 -> 499 of 553).
    parameter integer CACHE_ENTRIES = 2048
) (
    input  logic         clk,
    input  logic         rst,
    input  ssv_pkg::ssv_cfg_t cfg,
    input  logic         cache_start,
    // One-cycle pulse on the first accepted sprite-list/scroll write in the
    // measured update window. Later writes are coalesced by the core so a
    // dense list cannot chase the build into an empty deadline publication.
    input  logic         cache_restart,
    // Asserted once the raster reaches the lines where the first display rows
    // must be prepared. The vblank descriptor build must give up by then --
    // see the BUILD_ADVANCE abort for why overrunning is unrecoverable.
    input  logic         cache_deadline,
    input  logic         start,
    input  logic   [8:0] target_y,

    input  logic  [15:0] local_control,
    input  logic  [15:0] flip_control,
    input  logic  [15:0] coordinate_control,
    input  logic  [15:0] global_y_base,
    input  logic  [15:0] global_y_adjust,
    input  logic [255:0] sprite_offsets,
    input  logic [511:0] tilemap_scrolls,
    input  logic         shadow_4bit,

    output logic  [16:0] spr_addr,
    input  logic  [15:0] spr_data,
    // The sprite-RAM word at `spr_addr | 1`, available in the same cycle as
    // `spr_data` because sprite RAM is banked by word parity. Valid only when
    // `spr_addr` is even, which every consumer of it below guarantees -- see
    // tile_address(), whose result is always even.
    input  logic  [15:0] spr_data_next,

    output logic         rom_req,
    output logic  [ssv_pkg::SDR_AW:4] rom_addr,
    input  logic [127:0] rom_data,
    input  logic         rom_ack,

    output logic   [3:0] plot_we,
    output logic  [35:0] plot_x,
    output logic  [59:0] plot_color,
    output logic         plot_shadow,
    output logic  [31:0] plot_pen,
    output logic         plot_shadow_4bit,

    output logic         cache_busy,
    output logic         cache_ready,
    output logic         cache_overflow,
    output logic         busy,
    output logic         done
);

localparam logic [11:0] LAST_GLOBAL = 12'hffc;
localparam logic [16:0] LAST_LOCAL  = 17'h1fffc;
wire [8:0] LAST_PIXEL = ssv_pkg::active_width_cfg(cfg) - 1'd1;
wire [8:0] ACTIVE_HEIGHT = ssv_pkg::active_height_cfg(cfg);
localparam integer CACHE_ADDR_WIDTH = $clog2(CACHE_ENTRIES);
// Vblank resolves all CPU-writable coordinate/flip/scroll controls into a
// compact visual descriptor.  Both union arms are exactly 88 bits:
// ordinary = type,sx,sy,code,size,depth,flip,color; tilemap =
// type,sy,mode,unknown,scroll-x,map-y-bias,group.
localparam integer DESC_WIDTH = 88;
localparam logic [CACHE_ADDR_WIDTH:0] CACHE_COUNT_VALUE = CACHE_ENTRIES;
localparam logic [CACHE_ADDR_WIDTH:0] CACHE_LAST_VALUE =
    CACHE_ENTRIES - 1;
// Dense SSV scenes can exceed 128 real sprite descriptors on one scanline.
// The first pass
// counts each visible descriptor occurrence per line; a prefix pass assigns
// compact bases; and a final pass writes the occurrences into one shared pool.
// This keeps dense lines possible without reserving a fixed 240*LINE_SLOTS
// table full of empty scanline slots.
//
// 96 was measured insufficient. A two-player dense-gameplay run of
// `coin_start_2p_dense` (1800 post-VE frames, 431,760 scanlines) reported
//
//   C3_OCC max=96 at_cap=51        <- line_counts saturated, i.e. the cap hit
//   C3_DEM max=101 over_cap=31     <- true demand, and 31 lines DROPPED
//
// Entries store only the descriptor's low page bits; per-line page starts
// reconstruct the upper cache-page bits, as in the original compact table.
// LINE_SLOTS is a per-line guard; LINE_POOL_ENTRIES is the frame-wide bound.
//
// Sized 2026-08-05 against real measured evidence, not the prior "universal
// profile occurrence census" (undocumented anywhere in this repo, and never
// confirmed by an actual Quartus fit -- see docs/OPTIMIZATION_PRE_RBF.md's
// own "Quartus fit pending" note). At 65,536 this table alone needs ~1,024
// MLAB depth-slices (more than the device's entire 985-location MLAB budget)
// or >553 M10K blocks (the device's entire M10K budget) -- confirmed by a
// real build, not estimated. docs/M10K_REDUCTION.md separately measured
// this exact structure against real Dyna Gear gameplay when it was sized as
// a fixed 96-per-line x 240-line table (23,040 entries, the same frame-wide
// total this pool now tracks dynamically): zero drops, peak occupancy only
// 57-90 of the 96 per-line cap. 32,768 keeps ~1.5-2x headroom over that
// measured Dyna Gear peak and costs ~30 M10K blocks (measured bits-per-block
// ratio from the same doc), vs. never fitting at all. Frame-wide high-water
// telemetry added in Aug 2026 measured 11,060 as the largest of seven locally
// runnable qualified-set startup/attract samples (Dyna Gear; no overflow).
// 24,576 is the next useful M10K packing boundary above twice that peak and
// also exceeds the older 23,040-entry gameplay table that completed without
// drops. Ultra X still needs its private ST010 image for the same simulation
// gate, so cache_overflow remains a sticky hardware guard rather than assuming
// the measurement is a proof for every future scene.
localparam integer LINE_SLOTS = CACHE_ENTRIES;
localparam integer LINE_POOL_ENTRIES = 24576;
localparam integer LINE_POOL_ADDR_WIDTH = $clog2(LINE_POOL_ENTRIES);
localparam integer LINE_POOL_COUNT_WIDTH = LINE_POOL_ADDR_WIDTH + 1;
// Keep one additional carry bit in capacity checks. The allocator itself is
// wide enough for the configured pool, but a wrapped end address would turn a
// real overflow into a false in-range result before the bounds guard runs.
localparam integer LINE_POOL_SUM_WIDTH = LINE_POOL_COUNT_WIDTH + 1;
localparam integer LINE_COUNT_WIDTH = $clog2(LINE_SLOTS + 1);
localparam logic [LINE_COUNT_WIDTH-1:0] LINE_SLOTS_VALUE = LINE_SLOTS;
localparam integer LINE_ENTRY_LOW_WIDTH = 7;
localparam integer LINE_ENTRY_PAGE_SIZE = 1 << LINE_ENTRY_LOW_WIDTH;
localparam integer LINE_PAGE_WIDTH = CACHE_ADDR_WIDTH - LINE_ENTRY_LOW_WIDTH;
localparam integer LINE_PAGE_BOUNDARIES =
    (CACHE_ENTRIES + LINE_ENTRY_PAGE_SIZE - 1) / LINE_ENTRY_PAGE_SIZE - 1;
localparam integer LINE_PAGE_META_WIDTH =
    LINE_PAGE_BOUNDARIES * LINE_COUNT_WIDTH;
localparam integer LINE_ADDR_WIDTH = LINE_POOL_ADDR_WIDTH;

typedef enum logic [5:0] {
    IDLE,
    BUILD_CLEAR_LINES,
    BUILD_GLOBAL_WAIT, BUILD_GLOBAL_0, BUILD_GLOBAL_1,
    BUILD_GLOBAL_2, BUILD_GLOBAL_3,
    BUILD_LOCAL_WAIT, BUILD_LOCAL_0, BUILD_LOCAL_1,
    BUILD_LOCAL_2, BUILD_LOCAL_3, BUILD_EVALUATE,
    BUILD_STORE,
    BUILD_BUCKET_READ, BUILD_BUCKET_WRITE, BUILD_ADVANCE,
    BUILD_PREFIX_READ, BUILD_PREFIX_WRITE,
    BUILD_REINDEX_READ, BUILD_REINDEX_WAIT,
    BUILD_REINDEX_OFFSET, BUILD_REINDEX_PRESUM, BUILD_REINDEX_EVAL,
    BUILD_REINDEX_STORE, BUILD_REINDEX_BUCKET_READ,
    BUILD_REINDEX_BUCKET_WRITE,
    RENDER_COUNT_READ, RENDER_COUNT_WAIT,
    RENDER_LINE_READ, RENDER_READ, RENDER_DECODE, RENDER_PREP,
    RENDER_EVAL,
    RENDER_SPRITE_PREP, RENDER_ADVANCE,
    TILE_ROW_ADDR, TILE_ROW_WAIT,
    // One address, both words. The tile code and its attribute are an adjacent
    // even/odd pair, and sprite RAM is banked by parity, so the separate
    // TILE_ATTR_ADDR/TILE_ATTR_WAIT pair that used to follow is gone.
    TILE_CODE_ADDR, TILE_CODE_WAIT,
    TILE_PREP,
    FETCH_START, FETCH_WAIT, PLOT
} state_t;
state_t state;

logic [11:0] global_base;
logic [16:0] local_base;
logic  [4:0] local_index;
logic [15:0] global_w0, global_w1, global_w2, global_w3;
logic [15:0] local_w0, local_w1, local_w2, local_w3;
logic [15:0] tilemaps_offsy;

logic [CACHE_ADDR_WIDTH:0] cache_write_count;
logic [CACHE_ADDR_WIDTH:0] cache_count;
logic [CACHE_ADDR_WIDTH-1:0] cache_read_index;
logic [CACHE_ADDR_WIDTH:0] cache_render_index;
logic [DESC_WIDTH-1:0] cache_q;
// descriptor_cache's single read port (see the merged read below) must
// execute unconditionally every cycle -- Quartus refuses to infer a RAM at
// all ("uninferred due to asynchronous read logic") for an array whose read
// only fires under an enable, per this repo's own documented anti-pattern
// for M10K inference. cache_read_addr_r holds the last address used so an
// unwanted cycle just re-reads the same word (a no-op: descriptor_cache is
// never written outside BUILD_EVALUATE, well away from every state that
// reads it), keeping cache_q's held value and latency identical to before.
logic [CACHE_ADDR_WIDTH-1:0] cache_read_addr_r;
logic [DESC_WIDTH-1:0] cache_decode_q;
logic cache_pending;
// Consecutive copies of the same ordinary (non-shadow, non-tilemap)
// descriptor write the same pens to the same pixels.  Keep one descriptor of
// look-behind so dense title lists do not spend a full graphics fetch on an
// idempotent draw.  Shadow operations are deliberately excluded because a
// repeated shadow darkens the prior result again, and tilemaps have their own
// group-aware suppression below.
logic [DESC_WIDTH-1:0] last_render_descriptor;
logic        last_render_descriptor_valid;
// Build-time counterpart to the render-time duplicate suppression above.
// Consecutive identical ordinary descriptors are idempotent in MAME draw
// order, so keeping one copy avoids filling every affected scanline bucket
// with reset-list duplicates before the renderer ever sees them.
logic [DESC_WIDTH-1:0] build_last_descriptor;
logic        build_last_descriptor_valid;
// After storing the last cache slot, finish its line buckets then stop.
logic cache_stop_after_bucket;
// Set when a deadline/capacity abort re-routes the build into the prefix+
// reindex passes instead of publishing immediately. Suppresses re-triggering
// the deadline containment (cache_deadline is a level for the tail of a
// scanline) while those bounded passes finish.
logic cache_finish_index;
// One array, not two. Pre-resolving the record removes 40 stored bits per
// entry and the render-side global/local coordinate network. Keep it as one
// physical memory: an earlier split packing hint measured eight blocks worse.
(* ramstyle = "M10K, no_rw_check" *)
logic [DESC_WIDTH-1:0] descriptor_cache [0:CACHE_ENTRIES-1];

// Per-line count and pooled-base metadata always share one address and are
// consumed together. Pack them into one 240x27 memory: this fits one Cyclone V
// 256x40 M10K instead of the prior line-count MLAB plus two physical copies of
// line_bases (336 MLAB cells total). Keep one write and one registered read,
// with no reset pin on the array itself.
localparam integer LINE_META_WIDTH = LINE_POOL_ADDR_WIDTH + LINE_COUNT_WIDTH;
(* ramstyle = "M10K, no_rw_check" *)
logic [LINE_META_WIDTH-1:0] line_meta [0:239];
logic [7:0] line_count_addr;
logic [LINE_META_WIDTH-1:0] line_meta_q;
wire [LINE_COUNT_WIDTH-1:0] line_count_q =
    line_meta_q[LINE_COUNT_WIDTH-1:0];
wire [LINE_POOL_ADDR_WIDTH-1:0] line_base_q =
    line_meta_q[LINE_META_WIDTH-1:LINE_COUNT_WIDTH];
// M10K, the placement docs/M10K_REDUCTION.md actually measured for this
// table (21 blocks at 23,040 entries). A later, unmeasured change steered
// this to MLAB at 3x the depth; that placement cannot work at any size in
// the tens-of-thousands-of-entries range this table needs (see the sizing
// comment above LINE_POOL_ENTRIES) -- reverted 2026-08-05.
(* ramstyle = "M10K, no_rw_check" *)
logic [LINE_ENTRY_LOW_WIDTH-1:0] line_entries [0:LINE_POOL_ENTRIES-1];
// Page-boundary metadata is frame-local bookkeeping, not a throughput memory.
// The inferred 240x180 array ignored ramstyle="MLAB" in Quartus 17 and cost
// five M10Ks in the last fit. Use the explicit MLAB-shaped wrapper so the
// placement request is represented in the netlist rather than left to the
// fragile inference heuristic. Its read/write schedule is still one address
// per cycle, exactly like the old array.
logic [LINE_PAGE_META_WIDTH-1:0] line_page_mem_q;
logic [7:0] line_page_ram_wr_addr;
logic [LINE_PAGE_META_WIDTH-1:0] line_page_ram_wr_data;
logic line_page_ram_we;
ssv_mlab240_sdp #(.WIDTH(LINE_PAGE_META_WIDTH)) line_page_starts_ram (
    .clk(clk),
    .wr_addr(line_page_ram_wr_addr),
    .we(line_page_ram_we),
    .wdata(line_page_ram_wr_data),
    .rd_addr(line_count_addr),
    .q(line_page_mem_q)
);
// The old line_page_q register was cleared by reset. The MLAB array itself is
// intentionally uninitialized and is rebuilt before use, so mask its output
// during reset to preserve that observable reset value without adding a reset
// pin to the memory primitive.
logic [LINE_PAGE_META_WIDTH-1:0] line_page_q;
assign line_page_q = rst ? '0 : line_page_mem_q;
logic [LINE_POOL_COUNT_WIDTH-1:0] line_pool_alloc;
logic [CACHE_ADDR_WIDTH:0] cache_scan_index;
// Wire alias, not a register: see the merged read at the cache_q assignment
// below for why this and cache_q now share one descriptor_cache read port.
wire  [DESC_WIDTH-1:0] cache_scan_q = cache_q;
logic [7:0] clear_y;
logic [7:0] bucket_y, bucket_last_y;
logic [CACHE_ADDR_WIDTH-1:0] bucket_descriptor;
logic [LINE_COUNT_WIDTH-1:0] render_line_count;
logic [LINE_COUNT_WIDTH-1:0] render_line_slot;
logic [LINE_ADDR_WIDTH-1:0] line_entry_addr;
logic [LINE_ENTRY_LOW_WIDTH-1:0] line_entry_q;
logic [LINE_PAGE_WIDTH-1:0] line_entry_page_q;
logic [LINE_PAGE_META_WIDTH-1:0] render_line_pages;
logic [7:0] build_first_y, build_last_y;



logic  [8:0] target_y_latched;
logic [19:0] sprite_code;
logic  [3:0] sprite_xnum;
logic  [3:0] sprite_ynum;
logic  [3:0] sprite_tile_x;
logic  [3:0] sprite_tile_y;
logic signed [16:0] sprite_sx;
logic  [2:0] sprite_row;
logic  [2:0] gfx_mode;
logic        flip_x;
logic        flip_y;
logic        shadow;
logic  [8:0] color;
logic  [4:0] plot_i;
logic  [4:0] plot_next_i;
logic        plot_has_later_group;
logic        render_tilemap;
logic [15:0] tile_mode;
logic [15:0] tile_unknown;
logic [15:0] tile_code_low;
logic [15:0] tile_attr;
logic [16:0] tile_word_addr;
logic [16:0] tile_map_x;
// Map origin for the current scanline; fixes which page (i.e. which tilemap)
// the whole line reads from. See tile_address().
logic [16:0] tile_map_x0;
logic [16:0] tile_map_y;
logic [16:0] tile_scroll_x;
logic signed [10:0] tile_screen_x;
logic        last_was_tilemap;
logic  [2:0] last_tilemap_group;

// --- Tilemap code/attribute prefetch ---------------------------------------
// FETCH_WAIT is ~10 cycles in which the renderer does nothing at all but wait
// for the 128-bit graphics row to come back from SDRAM. Sprite RAM is a
// different memory, and its video port is idle for that entire window, so the
// *next* tilemap tile's code/attribute pair is read there and reduced to fetch
// operands ahead of time. When PLOT (or a transparent row) finishes, the
// TILE_CODE_ADDR / TILE_CODE_WAIT / TILE_PREP trio is skipped outright.
//
// This touches sprite RAM only. The graphics row itself is still fetched
// strictly one at a time, and nothing here issues a second p2 transaction --
// the p2 mux is deliberately left alone.
//
// Stages, all of which occur inside FETCH_WAIT/PLOT:
//   1 = drive spr_addr with tile_next_word_addr
//   2 = one-cycle sprite-RAM latency has elapsed; latch the pair
//   3 = do TILE_PREP's arithmetic into the shadow registers, set valid
//   0 = idle: either finished, or never armed (sprite, or last tile of line)
// If the row fetch somehow completed before stage 3, tile_pf_valid stays low
// and the original TILE_CODE_ADDR path runs unchanged.
logic  [1:0] tile_pf_stage;
logic        tile_pf_valid;
logic [15:0] tile_pf_code_low;
logic [15:0] tile_pf_attr;
logic        tile_pf_flip_x;
logic        tile_pf_flip_y;
logic  [8:0] tile_pf_color;
logic  [2:0] tile_pf_row;
logic [19:0] tile_pf_fetch_code;

logic        fetch_start;
logic        fetch_done;
logic [19:0] fetch_code;
logic  [2:0] fetch_row;
logic [31:0] plane01, plane23, plane45, plane67;
logic [127:0] pens;

wire compact_tilemap = cache_decode_q[87];
// Ordinary descriptor arm.
wire signed [16:0] compact_sx = cache_decode_q[86:70];
wire signed [16:0] compact_sy = cache_decode_q[69:53];
wire [19:0] compact_code = cache_decode_q[52:33];
wire  [3:0] compact_xnum = cache_decode_q[32:29];
wire  [3:0] compact_ynum = cache_decode_q[28:25];
wire  [3:0] compact_depth = cache_decode_q[24:21];
wire        compact_flip_x = cache_decode_q[20];
wire        compact_flip_y = cache_decode_q[19];
wire  [8:0] compact_color = cache_decode_q[18:10];
// Tilemap descriptor arm.
wire signed [16:0] compact_tilemap_sy = cache_decode_q[86:70];
wire [15:0] compact_tile_mode = cache_decode_q[69:54];
wire [15:0] compact_tile_unknown = cache_decode_q[53:38];
wire signed [17:0] compact_tile_scroll_x = cache_decode_q[37:20];
wire [16:0] compact_tile_map_y_bias = cache_decode_q[19:3];
wire  [2:0] compact_tile_group = cache_decode_q[2:0];

logic  [1:0] calc_xbits, calc_ybits;
logic  [3:0] calc_xnum, calc_ynum;
logic  [3:0] calc_depth;
logic [19:0] calc_code;
logic        calc_flip_x, calc_flip_y;
logic  [6:0] calc_height;
logic        calc_tilemap;
logic        calc_tilemap_active;
logic signed [16:0] calc_tilemap_sy;
logic signed [17:0] calc_tilemap_sy_work;
logic signed [17:0] calc_tile_scroll_x_work;
logic [16:0] calc_tile_map_y;
logic signed [17:0] calc_tilemap_bottom;

// Registered descriptor-decode results.  Coordinate calculation contains
// several dependent add/subtract stages; separating it from the render-state
// updates keeps that arithmetic out of the 48 MHz state/register paths.
logic        prep_tilemap;
logic        prep_tilemap_active;
logic signed [16:0] prep_tilemap_sy;
logic signed [17:0] prep_tilemap_bottom;
logic [15:0] prep_tile_mode;
logic [15:0] prep_tile_unknown;
logic  [2:0] prep_tile_group;
logic [16:0] prep_tile_map_y;
logic signed [17:0] prep_tile_scroll_x_work;
logic  [6:0] prep_height;
logic [19:0] prep_code;
logic  [3:0] prep_xnum, prep_ynum;
logic  [3:0] prep_depth;
logic        prep_flip_x, prep_flip_y;
logic  [8:0] prep_color;
logic signed [16:0] prep_sx_work, prep_sy_work;
logic signed [16:0] prep_sprites_offsx, prep_sprites_offsy;
logic [15:0] prep_coordinate_control, prep_flip_control;

logic signed [16:0] eval_sx, eval_sy;
logic signed [17:0] eval_line_rel;
logic signed [17:0] compact_bottom;
logic [7:0] compact_first_y, compact_last_y;

// Coordinates are resolved once during vblank and stored in the compact
// record.  The per-scanline path only subtracts Y to select the tile row.
always_comb begin
    eval_sx = prep_sx_work;
    eval_sy = prep_sy_work;
    eval_line_rel = $signed({1'b0, target_y_latched}) - eval_sy;
end

always_comb begin
    if (compact_tilemap)
        compact_bottom = compact_tilemap_sy + 18'sd65;
    else
        compact_bottom = compact_sy +
                         $signed({1'b0, compact_ynum, 3'd0});
    compact_first_y = (compact_tilemap ? compact_tilemap_sy : compact_sy) < 0
                    ? 8'd0
                    : (compact_tilemap ? compact_tilemap_sy[7:0]
                                       : compact_sy[7:0]);
    compact_last_y = (compact_bottom > $signed({9'd0, ACTIVE_HEIGHT}))
                   ? ACTIVE_HEIGHT[7:0] - 1'd1
                   : compact_bottom[7:0] - 1'd1;
end

function automatic logic signed [10:0] signed10(input logic [15:0] value);
    signed10 = $signed({value[9], value[9:0]});
endfunction

function automatic logic signed [8:0] signed8(input logic [15:0] value);
    signed8 = $signed({value[7], value[7:0]});
endfunction

// MAME's init_ssv builds m_tile_code[i] = bitswap<4>(i,0,1,2,3) << 16, which
// is attr[13:10] REVERSED. cairblad uses init_ssv_tilescram, whose table is the
// identity (m_tile_code[i] = i << 16), so the high nibble passes through in
// natural order. One config bit selects between them.
function automatic logic [19:0] expand_code(
    input ssv_pkg::ssv_cfg_t cfg_i,
    input logic [15:0] low,
    input logic [15:0] attr
);
    expand_code = cfg_i.tile_code_identity
                ? {attr[13:10], low}
                : {{attr[10], attr[11], attr[12], attr[13]}, low};
endfunction

function automatic logic [15:0] offset_word(
    input logic [255:0] values,
    input logic   [3:0] index
);
    begin
        case (index)
            4'h0: offset_word = values[15:0];
            4'h1: offset_word = values[31:16];
            4'h2: offset_word = values[47:32];
            4'h3: offset_word = values[63:48];
            4'h4: offset_word = values[79:64];
            4'h5: offset_word = values[95:80];
            4'h6: offset_word = values[111:96];
            4'h7: offset_word = values[127:112];
            4'h8: offset_word = values[143:128];
            4'h9: offset_word = values[159:144];
            4'ha: offset_word = values[175:160];
            4'hb: offset_word = values[191:176];
            4'hc: offset_word = values[207:192];
            4'hd: offset_word = values[223:208];
            4'he: offset_word = values[239:224];
            default: offset_word = values[255:240];
        endcase
    end
endfunction

function automatic logic [19:0] code_for_tile(
    input logic [19:0] base,
    input logic  [3:0] tile_x,
    input logic  [3:0] tile_y,
    input logic  [3:0] xnum,
    input logic  [3:0] ynum,
    input logic        fx,
    input logic        fy
);
    logic [3:0] order_x;
    logic [3:0] order_y;
    logic [7:0] offset;
    begin
        order_x = fx ? (xnum - 1'd1 - tile_x) : tile_x;
        order_y = fy ? (ynum - 1'd1 - tile_y) : tile_y;
        offset = order_x * ynum + order_y;
        code_for_tile = base + offset;
    end
endfunction

function automatic logic [15:0] tilemap_scroll_word(
    input logic [511:0] values,
    input logic   [4:0] index
);
    tilemap_scroll_word = values[index * 16 +: 16];
endfunction

// `x_base` is the map origin for this scanline; `x` is the running position
// along it.
//
// tile_address() carries no per-group base, so a tilemap group is identified
// purely by which page its scroll value lands in -- Dyna Gear puts group 1 in
// page 3, group 3 in page 5 and group 4 in page 6. `page` therefore selects
// *which map to read*, and must be fixed for the whole line by the origin.
// Deriving it from the running `x` instead meant a group whose span crossed a
// page boundary walked into the neighbouring group's map partway across the
// screen: the background went blank and picked up font tiles from whatever
// lived there. `column` already wraps inside the page via size_mask, which is
// the correct behaviour for the scroll itself.
function automatic logic [16:0] tile_address(
    input logic [16:0] x,
    input logic [16:0] x_base,
    input logic [16:0] y,
    input logic [15:0] mode
);
    logic [3:0] size_shift;
    logic [16:0] size_mask;
    logic [16:0] page;
    logic [16:0] base;
    logic [16:0] column;
    logic [16:0] row;
    begin
        size_shift = 4'd8 + {1'b0, mode[15:13]};
        size_mask = (17'd1 << size_shift) - 17'd1;
        page = (x_base & 17'h07fff) >> size_shift;
        // See the matching note in ssv_bg_renderer.sv: computed at 4 bits this
        // wraps for size_shift 14/15 and shifts by 0/1 instead of 16/17.
        base = page << ({1'b0, size_shift} + 5'd2);
        column = (x & (size_mask & 17'h1fff0)) << 2;
        row = (y & 17'h001f0) >> 3;
        tile_address = base + column + row;
    end
endfunction

wire signed [10:0] global_y_base_s = signed10(global_y_base);

// The modulo-2^10 axis sums are captured from the paired sprite-RAM
// outputs at BUILD_LOCAL_1, after both global and offset terms are registered.

wire [3:0] build_offset_index = {global_w0[7:5], 1'b0};
wire [4:0] build_tilemap_base = {local_w0[2:0], 2'b00};
wire [15:0] build_tile_scroll_x =
    tilemap_scroll_word(tilemap_scrolls, build_tilemap_base);
wire [15:0] build_tile_scroll_y =
    tilemap_scroll_word(tilemap_scrolls, build_tilemap_base + 1'd1);
wire [15:0] build_tile_unknown =
    tilemap_scroll_word(tilemap_scrolls, build_tilemap_base + 2'd2);
wire [15:0] build_tile_mode =
    tilemap_scroll_word(tilemap_scrolls, build_tilemap_base + 2'd3);
// Registered at the BUILD_GLOBAL_1->BUILD_LOCAL_WAIT/BUILD_PREFIX_READ
// transition, as soon as global_w0 (and thus build_offset_index) is valid --
// not read live here. The live combinational form put the CPU-writable
// scroll[] table directly on the scroll[37]->line_bases rdaddr_reg setup
// path (measured -1.256ns/16 logic levels): a 16-way offset_word() mux
// sourced straight from an async register, feeding the same-cycle
// build_sy_work/build_first_y arithmetic that BUILD_EVALUATE uses to set
// line_count_addr. global_w0 is already stable three states before
// BUILD_EVALUATE (BUILD_LOCAL_WAIT, BUILD_LOCAL_0, BUILD_LOCAL_1 all run in
// between), so registering the lookup here removes the mux from that
// critical cycle without adding any FSM latency or changing the value used.
logic [15:0] build_offset_x, build_offset_y;
// global_w2/w3 + build_offset_x/y, pre-summed once both operands are stable
// (registered at BUILD_LOCAL_WAIT, two states -- BUILD_LOCAL_0,
// BUILD_LOCAL_1 -- before BUILD_EVALUATE needs it). Addition mod 2^16 is
// associative, and signed10()/signed8() below only ever look at the low 8-10
// bits of the final sum, so splitting "local + global + offset" into
// "local + (global + offset)" changes nothing about the computed value.
// Measured evidence for doing this: after pipelining build_offset_x/y alone
// (the earlier scroll[37]->line_bases fix), the *next*-worst path on this
// same clk_sys->line_bases rdaddr_reg endpoint was global_w3->rdaddr_reg[3]
// (-0.275ns at the Slow -40C corner) -- same arithmetic chain, just entering
// through the other operand the first fix didn't touch. global_w2/w3 have
// the same three-state head start build_offset_x/y already had, so this
// removes them from the single-cycle BUILD_EVALUATE critical path the same
// way, leaving only local_w2/w3 (which have no slack to pipeline: they are
// captured the same cycle BUILD_EVALUATE is entered) as live inputs there.
logic [15:0] build_gx_off_r, build_gy_off_r;
logic [1:0] build_xbits, build_ybits;
logic [3:0] build_xnum, build_ynum;
logic [3:0] build_depth;
logic [6:0] build_height;
logic build_tilemap;
logic build_screen_visible;
logic signed [16:0] build_sx;
logic signed [16:0] build_sy;
logic signed [16:0] build_sx_work;
logic signed [16:0] build_sy_work;
logic signed [16:0] build_offsx;
logic signed [16:0] build_offsy;
logic signed [17:0] build_right;
logic signed [17:0] build_bottom;
logic build_tilemap_active;
logic signed [17:0] build_tilemap_sy_work;
logic signed [16:0] build_tilemap_sy;
logic signed [17:0] build_tilemap_bottom;
logic signed [17:0] build_tile_scroll_x_work;
logic [16:0] build_tile_map_y_bias;
logic [19:0] build_code;
logic build_flip_x, build_flip_y;
// The paired sprite-RAM outputs are valid in BUILD_LOCAL_1. Capture the
// modulo-2^10 axis work there so BUILD_EVALUATE does not carry the local-word
// adder through visibility and line-address selection in one cycle. The
// cache restart path holds the CPU-writable controls stable for this capture.
wire [9:0] build_sx_capture_sum_low =
    spr_data[9:0] + build_gx_off_r[9:0];
wire [9:0] build_sy_capture_sum_low =
    spr_data_next[9:0] + build_gy_off_r[9:0];
logic signed [16:0] build_sx_work_capture;
logic signed [16:0] build_sy_work_capture;

always_comb begin
    build_sx_work_capture = signed10({6'd0, build_sx_capture_sum_low});
    build_sy_work_capture = signed10({6'd0, build_sy_capture_sum_low});
    if (flip_control[14]) begin
        build_sy_work_capture = -build_sy_work_capture;
        if (!flip_control[15])
            build_sy_work_capture = build_sy_work_capture - 17'sd16;
    end
    if (flip_control[12])
        build_sx_work_capture = -build_sx_work_capture + 17'sd256;
end

always_comb begin
    calc_xbits = 2'd0;
    calc_ybits = 2'd0;
    calc_xnum = compact_xnum;
    calc_ynum = compact_ynum;
    calc_depth = compact_depth;
    calc_tilemap = compact_tilemap;
    calc_tilemap_active = compact_tilemap;
    calc_tilemap_sy_work = compact_tilemap_sy;
    calc_tilemap_sy = compact_tilemap_sy;
    calc_tilemap_bottom = calc_tilemap_sy + 18'sd65;
    calc_tile_scroll_x_work = compact_tile_scroll_x;
    calc_tile_map_y = compact_tile_map_y_bias + {8'd0, target_y_latched};
    calc_code = compact_code;
    calc_flip_x = compact_flip_x;
    calc_flip_y = compact_flip_y;

    calc_height = {calc_ynum, 3'd0};
end

always_comb begin
    build_xbits = local_control[14] ? local_w2[11:10]
                                    : global_w0[11:10];
    build_ybits = local_control[14] ? local_w3[11:10]
                                    : global_w0[9:8];
    build_depth = local_control[14] ? local_w2[15:12]
                                   : global_w0[15:12];
    build_xnum = 4'd1 << build_xbits;
    build_ynum = 4'd1 << build_ybits;
    build_height = {build_ynum, 3'd0};
    build_tilemap = (local_w0 <= 16'd7) && (local_w1 == 16'd0) &&
                    (build_xbits == 2'd0) && (build_ybits == 2'd3);
    build_tilemap_active = build_tilemap && (global_w0[4:0] != 0) &&
                           (local_w0 != 0);
    build_tilemap_sy_work = signed10(local_w3);
    if (local_control[12])
        build_tilemap_sy_work = build_tilemap_sy_work - 18'sd32;
    else if (coordinate_control[11]) begin
        if (coordinate_control[12])
            build_tilemap_sy_work = build_tilemap_sy_work -
                                    signed10(tilemaps_offsy);
        else
            build_tilemap_sy_work = build_tilemap_sy_work +
                                    signed10(tilemaps_offsy);
    end
    build_tilemap_sy = signed10(build_tilemap_sy_work[15:0]);
    build_tilemap_bottom = build_tilemap_sy + 18'sd65;
    build_tile_scroll_x_work = $signed({2'b00, build_tile_scroll_x});
    if ((build_tile_unknown & 16'h05ff) == 16'h0440)
        build_tile_scroll_x_work = build_tile_scroll_x_work - 18'sd16;
    else if ((build_tile_unknown & 16'h05ff) == 16'h0401)
        build_tile_scroll_x_work = build_tile_scroll_x_work - 18'sd32;
    build_tile_map_y_bias = {1'b0, build_tile_scroll_y} +
                            {{6{global_y_base_s[10]}}, global_y_base_s} +
                            {1'b0, global_y_adjust} + 17'd2;

    build_code = expand_code(cfg, local_w0, local_w1);
    if ((build_xnum == 4'd2) && (build_ynum == 4'd4))
        build_code = build_code & 20'hffff8;
    build_flip_x = local_w1[15] ^
                   (flip_control[12] && !flip_control[13]);
    build_flip_y = local_w1[14] ^
                   (flip_control[14] && !flip_control[13]);
    build_offsx = signed8(flip_control);
    build_offsy = -(signed10(global_y_base) +
                    $signed({1'b0, global_y_adjust}) + 17'sd1);
    if (coordinate_control == 16'h7140) begin
        build_sx = build_offsx + build_sx_work;
        build_sy = build_offsy - build_sy_work;
    end
    else if (coordinate_control[11]) begin
        build_sx = build_offsx + build_sx_work -
                   $signed({9'd0, build_xnum, 3'd0});
        build_sy = build_offsy - build_sy_work -
                   $signed({10'd0, build_ynum, 2'd0});
    end
    else begin
        build_sx = build_offsx + build_sx_work;
        build_sy = build_offsy - build_sy_work -
                   $signed({9'd0, build_ynum, 3'd0});
    end

    build_right = build_sx + $signed({1'b0, build_xnum, 4'd0});
    build_bottom = build_sy + $signed({1'b0, build_height});
    if (build_tilemap) begin
        if (build_tilemap_sy < 0)
            build_first_y = 8'd0;
        else
            build_first_y = build_tilemap_sy[7:0];
        build_last_y = (build_tilemap_bottom > $signed({9'd0, ACTIVE_HEIGHT}))
                     ? ACTIVE_HEIGHT[7:0] - 1'd1 :
                       build_tilemap_bottom[7:0] - 1'd1;
        build_screen_visible = build_tilemap_active &&
                               (build_tilemap_sy < $signed({8'd0, ACTIVE_HEIGHT})) &&
                               (build_tilemap_bottom > 18'sd0);
    end
    else begin
        if (build_sy < 0)
            build_first_y = 8'd0;
        else
            build_first_y = build_sy[7:0];
        build_last_y = (build_bottom > $signed({9'd0, ACTIVE_HEIGHT}))
                     ? ACTIVE_HEIGHT[7:0] - 1'd1 :
                       build_bottom[7:0] - 1'd1;
        build_screen_visible = (build_sx < $signed({8'd0, LAST_PIXEL}) + 17'sd1) &&
                               (build_right > 18'sd0) &&
                               (build_sy < $signed({8'd0, ACTIVE_HEIGHT})) &&
                               (build_bottom > 18'sd0);
    end
end

wire [DESC_WIDTH-1:0] ordinary_cache_write_data = {
    1'b0, build_sx, build_sy, build_code,
    build_xnum, build_ynum, build_depth,
    build_flip_x, build_flip_y, local_w1[8:0], 10'd0
};
wire [DESC_WIDTH-1:0] tilemap_cache_write_data = {
    1'b1, build_tilemap_sy, build_tile_mode, build_tile_unknown,
    build_tile_scroll_x_work, build_tile_map_y_bias, local_w0[2:0]
};
wire [DESC_WIDTH-1:0] cache_write_data = build_tilemap
    ? tilemap_cache_write_data : ordinary_cache_write_data;
wire build_is_duplicate = build_last_descriptor_valid &&
                          (cache_write_data == build_last_descriptor) &&
                          !build_tilemap && !build_depth[3];
wire build_accept = build_screen_visible && !build_is_duplicate &&
                    (cache_write_count < CACHE_COUNT_VALUE);
wire cache_we = (state == BUILD_EVALUATE) && build_accept;

function automatic logic [LINE_PAGE_WIDTH-1:0] line_page_for_slot(
    input logic [LINE_PAGE_META_WIDTH-1:0] starts,
    input logic [LINE_COUNT_WIDTH-1:0] slot
);
    integer page_i;
    begin
        line_page_for_slot = '0;
        for (page_i = 1; page_i <= LINE_PAGE_BOUNDARIES;
             page_i = page_i + 1) begin
            if (starts[(page_i - 1) * LINE_COUNT_WIDTH +:
                       LINE_COUNT_WIDTH] <= slot)
                line_page_for_slot = LINE_PAGE_WIDTH'(page_i);
        end
    end
endfunction

wire [LINE_COUNT_WIDTH-1:0] line_entry_read_slot =
    (state == RENDER_PREP) ? render_line_slot + 2'd2 :
    (state == RENDER_DECODE) ? render_line_slot + 1'd1 :
    render_line_slot;
wire [LINE_PAGE_WIDTH-1:0] line_entry_read_page =
    line_page_for_slot(render_line_pages, line_entry_read_slot);
wire [CACHE_ADDR_WIDTH-1:0] line_entry_descriptor = {
    line_entry_page_q, line_entry_q
};

logic [LINE_PAGE_META_WIDTH-1:0] line_page_write_data;
logic line_page_write;
integer line_page_write_index;
always_comb begin
    line_page_write_data = line_page_q;
    line_page_write = 1'b0;
    line_page_write_index = 0;
    if (cache_scan_index[CACHE_ADDR_WIDTH-1:LINE_ENTRY_LOW_WIDTH] != 0) begin
        line_page_write_index =
            cache_scan_index[CACHE_ADDR_WIDTH-1:LINE_ENTRY_LOW_WIDTH] - 1'b1;
        if (line_page_q[line_page_write_index * LINE_COUNT_WIDTH +:
                        LINE_COUNT_WIDTH] == LINE_SLOTS_VALUE) begin
            line_page_write_data[line_page_write_index * LINE_COUNT_WIDTH +:
                                 LINE_COUNT_WIDTH] = line_count_q;
            line_page_write = 1'b1;
        end
    end
end

// Single write port for the explicit MLAB. These are the same three writes
// that previously targeted line_page_starts[] in the renderer's state block.
always_comb begin
    line_page_ram_we = 1'b0;
    line_page_ram_wr_addr = line_count_addr;
    // The two boundary-fill states wrote the identical constant, and the
    // idle default wrote a third value ('0) that no write port ever commits,
    // so Quartus built a 3:1 mux across all LINE_PAGE_META_WIDTH bits. The
    // data bus is a don't-care whenever we==0, so defaulting it to the fill
    // constant and merging the two fill states leaves a plain 2:1 select.
    // Every value actually written to the memory is unchanged.
    line_page_ram_wr_data = {LINE_PAGE_BOUNDARIES{LINE_SLOTS_VALUE}};
    if ((state == BUILD_CLEAR_LINES) || (state == BUILD_PREFIX_WRITE)) begin
        line_page_ram_we = 1'b1;
    end
    else if ((state == BUILD_REINDEX_BUCKET_WRITE) && line_page_write) begin
        line_page_ram_we = 1'b1;
        line_page_ram_wr_addr = bucket_y;
        line_page_ram_wr_data = line_page_write_data;
    end
end

// BUILD_REINDEX_BUCKET_READ primes line_base_q for the first bucket, then
// line_count_addr and bucket_y advance together on every write.  The
// registered base is therefore aligned with line_count_q here.  Reading
// line_bases[bucket_y] directly made Quartus clone the whole 240x15 table to
// provide a second read port (another 120 MLAB cells) for no functional gain.
wire [LINE_POOL_SUM_WIDTH-1:0] reindex_pool_addr =
    {{(LINE_POOL_SUM_WIDTH-LINE_POOL_ADDR_WIDTH){1'b0}},
     line_base_q} +
    {{(LINE_POOL_SUM_WIDTH-LINE_COUNT_WIDTH){1'b0}}, line_count_q};
wire [LINE_POOL_SUM_WIDTH-1:0] line_pool_end =
    {1'b0, line_pool_alloc} +
    {{(LINE_POOL_SUM_WIDTH-LINE_COUNT_WIDTH){1'b0}}, line_count_q};

// NOTE on `no_rw_check` for line_meta: the unconditional read below uses
// the same address as the BUILD_CLEAR_LINES / BUILD_BUCKET_WRITE writes, so a
// same-address read-during-write happens on every one of those cycles. That is
// exactly the case `no_rw_check` promises cannot occur, and on hardware the
// read data is undefined where simulation returns the pre-write value.
//
// It is safe only because the colliding read is never consumed. During
// BUILD_BUCKET_WRITE the value landing in line_count_q is replaced by the next
// BUILD_BUCKET_READ (which uses the incremented address) before any state
// reads it, and during BUILD_CLEAR_LINES nothing reads line_count_q at all.
// If a future change ever samples line_count_q one cycle earlier, this
// attribute becomes a live sim-versus-silicon divergence.
//
// Address for descriptor_cache's single, unconditional read port: the
// wanted address on a cycle that needs a fresh value, else cache_read_addr_r
// (last cycle's address) so an uninvolved cycle just repeats the same read.
wire [CACHE_ADDR_WIDTH-1:0] cache_read_addr =
    (state == BUILD_REINDEX_READ) ? cache_scan_index[CACHE_ADDR_WIDTH-1:0] :
    // Next descriptor's read is issued on the last bucket-write cycle of this
    // one, so BUILD_REINDEX_READ is skipped between entries.
    ((state == BUILD_REINDEX_BUCKET_READ) ||
     (state == BUILD_REINDEX_BUCKET_WRITE))
        ? cache_scan_index[CACHE_ADDR_WIDTH-1:0] + 1'd1 :
    ((state == RENDER_READ) ||
     ((state == RENDER_PREP) &&
      (render_line_slot + 1'd1 < render_line_count)))
        ? line_entry_descriptor
        : cache_read_addr_r;

always_ff @(posedge clk) begin
    if (rst) begin
        line_meta_q <= '0;
        line_pool_alloc <= '0;
        line_entry_q <= '0;
        line_entry_page_q <= '0;
        cache_read_addr_r <= '0;
    end
    else begin
        line_meta_q <= line_meta[line_count_addr];
        if ((state == IDLE) && (cache_start || cache_pending))
            line_pool_alloc <= '0;
        if (state == BUILD_CLEAR_LINES) begin
            line_meta[line_count_addr] <= '0;
        end
        else if (state == BUILD_BUCKET_WRITE) begin
            if (line_count_q < LINE_SLOTS_VALUE)
                line_meta[bucket_y] <= {line_base_q, line_count_q + 1'd1};
        end
        else if (state == BUILD_PREFIX_WRITE) begin
            line_meta[line_count_addr] <= {
                line_pool_alloc[LINE_POOL_ADDR_WIDTH-1:0],
                {LINE_COUNT_WIDTH{1'b0}}
            };
            line_pool_alloc <= line_pool_alloc + line_count_q;
        end
        else if ((state == BUILD_REINDEX_BUCKET_WRITE) &&
                 (line_count_q < LINE_SLOTS_VALUE) &&
                 (reindex_pool_addr < LINE_POOL_ENTRIES)) begin
            line_meta[bucket_y] <= {line_base_q, line_count_q + 1'd1};
            line_entries[reindex_pool_addr[LINE_POOL_ADDR_WIDTH-1:0]] <=
                cache_scan_index[LINE_ENTRY_LOW_WIDTH-1:0];
        end

        if ((state == RENDER_LINE_READ) ||
            (state == RENDER_DECODE) ||
            ((state == RENDER_PREP) &&
             (render_line_slot + 2'd2 < render_line_count)))
            line_entry_q <= line_entries[line_entry_addr];
        if ((state == RENDER_LINE_READ) ||
            (state == RENDER_DECODE) ||
            ((state == RENDER_PREP) &&
             (render_line_slot + 2'd2 < render_line_count)))
            line_entry_page_q <= line_entry_read_page;
        // RENDER_READ fetches the first descriptor.  The steady-state loop
        // reaches RENDER_PREP with the next pooled line entry already in
        // line_entry_q, so fetch that descriptor here for RENDER_ADVANCE.
        // Without this prefetch every slot after zero reuses cache_q[0] and
        // the ordinary-descriptor duplicate filter drops the whole line.
        // One read port, not two. RENDER_* (cache_q's old reader) and
        // BUILD_REINDEX_READ (cache_scan_q's) are states of the same single
        // FSM register and can never be active in the same cycle, so these
        // were never really two simultaneous reads -- but writing them as
        // two separately-conditioned reads of descriptor_cache made Quartus
        // infer two physical M10K copies (26 blocks each, 52 total) to give
        // each its own port. cache_scan_q is now a wire alias of cache_q
        // (see its declaration above); merging the reads costs nothing
        // functionally and halves this array's M10K footprint.
        //
        // The read itself must be unconditional (every cycle), not gated by
        // an if/else on state, or Quartus refuses RAM inference entirely
        // ("uninferred due to asynchronous read logic") -- so
        // cache_read_addr selects the wanted address on a cycle that needs a
        // fresh value, and otherwise re-selects cache_read_addr_r (last
        // cycle's address), making the "do nothing" cycles a harmless
        // re-read of the same word instead of a skipped read.
        cache_read_addr_r <= cache_read_addr;
        cache_q <= descriptor_cache[cache_read_addr];
        if (cache_we)
            descriptor_cache[cache_write_count[CACHE_ADDR_WIDTH-1:0]]
                <= cache_write_data;
    end
end

ssv_gfx_row_fetch fetch (
    .clk(clk), .rst(rst), .cfg(cfg), .start(fetch_start),
    .tile_code(fetch_code), .tile_row(fetch_row),
    .rom_req(rom_req), .rom_addr(rom_addr),
    .rom_data(rom_data), .rom_ack(rom_ack),
    .busy(), .done(fetch_done),
    .plane01(plane01), .plane23(plane23),
    .plane45(plane45), .plane67(plane67)
);

ssv_gfx_row_decode decode (
    .plane01(plane01), .plane23(plane23),
    .plane45(plane45), .plane67(plane67),
    .gfx_mode(gfx_mode), .flip_x(flip_x), .pens(pens)
);

logic [7:0] batch_pen [0:3];
logic signed [17:0] batch_x [0:3];
integer plot_lane;
wire tile_flip_x = tile_attr[15] ^
                   (flip_control[12] && !flip_control[13]);
wire tile_flip_y = tile_attr[14] ^
                   (flip_control[14] && !flip_control[13]);

// Sprite-RAM address of the next tilemap tile along this scanline. tile_map_x,
// tile_map_x0, tile_map_y and tile_mode are all fixed for the whole of the
// current tile, so this is stable from the moment that tile starts fetching --
// which is exactly what lets the prefetch run inside FETCH_WAIT. The two
// advance points (FETCH_WAIT's transparent exit and PLOT's) each used to
// instantiate this same tile_address() call; they now share this one.
wire [16:0] tile_next_word_addr =
    tile_address(tile_map_x + 17'd16, tile_map_x0, tile_map_y, tile_mode);
// True when a further tile still fits on the line. This is the same test the
// advance points make, just evaluated one tile earlier, so an armed prefetch
// can never read past the end of the line.
wire tile_next_in_range =
    !((tile_screen_x + 11'sd16) > $signed({2'd0, LAST_PIXEL}));
// tile_flip_x/y above, but for the prefetched attribute.
wire tile_pf_flip_x_next = tile_pf_attr[15] ^
                           (flip_control[12] && !flip_control[13]);
wire tile_pf_flip_y_next = tile_pf_attr[14] ^
                           (flip_control[14] && !flip_control[13]);

// True when BUILD_ADVANCE would step to another local of the same global. The
// read-ahead paths below take exactly this condition, so they visit the same
// descriptors in the same order as the slow path.
wire build_has_next_local = (local_index < global_w0[4:0]) &&
                            ((local_base + 17'd4) <= LAST_LOCAL);

always_comb begin
    spr_addr = {5'd0, global_base};
    unique case (state)
        BUILD_GLOBAL_0: spr_addr = {5'd0, global_base} + 2'd2;
        BUILD_LOCAL_WAIT: spr_addr = local_base;
        BUILD_LOCAL_0: spr_addr = local_base + 2'd2;
        // Descriptor-walk read-ahead. The walk order never depends on whether
        // an entry is accepted, so the next local's first word pair is issued
        // while this one is still being captured/evaluated (BUILD_LOCAL_1,
        // BUILD_BUCKET_WRITE) and its second pair while EVALUATE runs. This
        // is what lets a rejected entry cost two states instead of six.
        BUILD_LOCAL_1: spr_addr = local_base + 3'd4;
        // Held for the whole bucket pass so the next local's first pair is
        // already sitting in the RAM output when the last bucket write runs;
        // the last write then issues the second pair for BUILD_LOCAL_1.
        BUILD_BUCKET_READ: spr_addr = local_base + 3'd4;
        BUILD_BUCKET_WRITE: spr_addr = (bucket_y == bucket_last_y)
                                       ? (local_base + 3'd6)
                                       : (local_base + 3'd4);
        BUILD_EVALUATE: spr_addr = local_base + 3'd6;
        // The local list of a global starts at global_w1 (captured in
        // BUILD_GLOBAL_0), so its first word pair is issued from GLOBAL_1 and
        // BUILD_LOCAL_WAIT is skipped.
        BUILD_GLOBAL_1: spr_addr = {global_w1[14:0], 2'b00};
        // Next global's first pair, issued from the state that steps to it so
        // BUILD_GLOBAL_WAIT is skipped.
        BUILD_ADVANCE: spr_addr = {5'd0, global_base} + 17'd4;
        TILE_ROW_ADDR, TILE_ROW_WAIT:
            spr_addr = ({9'd0, tile_mode[7:0]} << 9) + tile_map_y[8:0];
        TILE_CODE_ADDR, TILE_CODE_WAIT: spr_addr = tile_word_addr;
        default: ;
    endcase

    // The prefetch borrows the idle sprite-RAM video port. It is gated on the
    // two states that own the port but do not use it, so it can never fight the
    // descriptor-cache build walk, the row-scroll table lookup, or the ordinary
    // TILE_CODE_ADDR read above -- none of which can be the current state here.
    if ((tile_pf_stage == 2'd1) &&
        ((state == FETCH_WAIT) || (state == PLOT)))
        spr_addr = tile_next_word_addr;

    plot_next_i = 5'd12;
    plot_has_later_group = 1'b0;
    case (plot_i)
        5'd0: begin
            if (pens[63:32] != 32'd0) begin
                plot_next_i = 5'd4;
                plot_has_later_group = 1'b1;
            end
            else if (pens[95:64] != 32'd0) begin
                plot_next_i = 5'd8;
                plot_has_later_group = 1'b1;
            end
            else if (pens[127:96] != 32'd0) begin
                plot_next_i = 5'd12;
                plot_has_later_group = 1'b1;
            end
        end
        5'd4: begin
            if (pens[95:64] != 32'd0) begin
                plot_next_i = 5'd8;
                plot_has_later_group = 1'b1;
            end
            else if (pens[127:96] != 32'd0) begin
                plot_next_i = 5'd12;
                plot_has_later_group = 1'b1;
            end
        end
        5'd8: begin
            if (pens[127:96] != 32'd0) begin
                plot_next_i = 5'd12;
                plot_has_later_group = 1'b1;
            end
        end
        default: begin
        end
    endcase

    fetch_start = (state == FETCH_START);
    plot_we = 4'd0;
    plot_x = 36'd0;
    plot_pen = 32'd0;
    plot_color = 60'd0;
    for (plot_lane = 0; plot_lane < 4; plot_lane = plot_lane + 1) begin
        batch_pen[plot_lane] =
            pens[(plot_i + plot_lane) * 8 +: 8];
        batch_x[plot_lane] = render_tilemap
            ? tile_screen_x + $signed({13'd0, plot_i}) + plot_lane
            : sprite_sx + $signed({13'd0, plot_i}) + plot_lane;
        plot_we[plot_lane] = (state == PLOT) &&
            (batch_x[plot_lane] >= 0) &&
            (batch_x[plot_lane] <= $signed({9'd0, LAST_PIXEL})) &&
            (batch_pen[plot_lane] != 0);
        plot_x[plot_lane * 9 +: 9] = batch_x[plot_lane][8:0];
        plot_pen[plot_lane * 8 +: 8] = batch_pen[plot_lane];
        plot_color[plot_lane * 15 +: 15] =
            ({color, 6'd0} + batch_pen[plot_lane]) & 15'h7fff;
    end
    plot_shadow = shadow;
    plot_shadow_4bit = shadow_4bit;
end

always_ff @(posedge clk) begin
    if (rst) begin
        state <= IDLE;
        global_base <= 12'd0;
        local_base <= 17'd0;
        local_index <= 5'd0;
        global_w0 <= 16'd0;
        global_w1 <= 16'd0;
        global_w2 <= 16'd0;
        global_w3 <= 16'd0;
        local_w0 <= 16'd0;
        local_w1 <= 16'd0;
        local_w2 <= 16'd0;
        local_w3 <= 16'd0;
        tilemaps_offsy <= 16'd0;
        cache_write_count <= '0;
        cache_count <= '0;
        cache_read_index <= '0;
        cache_render_index <= '0;
        cache_decode_q <= '0;
        last_render_descriptor <= '0;
        last_render_descriptor_valid <= 1'b0;
        build_last_descriptor <= '0;
        build_last_descriptor_valid <= 1'b0;
        cache_busy <= 1'b0;
        cache_ready <= 1'b0;
        cache_overflow <= 1'b0;
        cache_pending <= 1'b0;
        cache_stop_after_bucket <= 1'b0;
        clear_y <= 8'd0;
        line_count_addr <= 8'd0;
        bucket_y <= 8'd0;
        bucket_last_y <= 8'd0;
        bucket_descriptor <= '0;
        render_line_count <= '0;
        render_line_slot <= '0;
        line_entry_addr <= '0;
        render_line_pages <= '0;
        target_y_latched <= 9'd0;
        build_offset_x <= 16'd0;
        build_offset_y <= 16'd0;
        build_gx_off_r <= 16'd0;
        build_gy_off_r <= 16'd0;
        build_sx_work <= 17'sd0;
        build_sy_work <= 17'sd0;
        sprite_code <= 20'd0;
        sprite_xnum <= 4'd0;
        sprite_ynum <= 4'd0;
        sprite_tile_x <= 4'd0;
        sprite_tile_y <= 4'd0;
        sprite_sx <= 17'sd0;
        sprite_row <= 3'd0;
        gfx_mode <= 3'd0;
        flip_x <= 1'b0;
        flip_y <= 1'b0;
        shadow <= 1'b0;
        color <= 9'd0;
        plot_i <= 5'd0;
        render_tilemap <= 1'b0;
        tile_mode <= 16'd0;
        tile_unknown <= 16'd0;
        tile_code_low <= 16'd0;
        tile_attr <= 16'd0;
        tile_word_addr <= 17'd0;
        tile_map_x <= 17'd0;
        tile_map_x0 <= 17'd0;
        tile_map_y <= 17'd0;
        tile_scroll_x <= 17'd0;
        tile_screen_x <= 11'sd0;
        last_was_tilemap <= 1'b0;
        last_tilemap_group <= 3'd0;
        fetch_code <= 20'd0;
        fetch_row <= 3'd0;
        tile_pf_stage <= 2'd0;
        tile_pf_valid <= 1'b0;
        tile_pf_code_low <= 16'd0;
        tile_pf_attr <= 16'd0;
        tile_pf_flip_x <= 1'b0;
        tile_pf_flip_y <= 1'b0;
        tile_pf_color <= 9'd0;
        tile_pf_row <= 3'd0;
        tile_pf_fetch_code <= 20'd0;
        busy <= 1'b0;
        done <= 1'b0;
    end
    else begin
        done <= 1'b0;
        if (cache_start)
            cache_pending <= 1'b1;

        // Prefetch sequencer. Runs beside the main state machine, and only in
        // the two states where the sprite-RAM video port is idle. FETCH_WAIT is
        // reachable only from FETCH_START, which always re-arms tile_pf_stage,
        // so a stage left over from an early-terminating fetch can never be
        // mistaken for a live one.
        if ((state == FETCH_WAIT) || (state == PLOT)) begin
            case (tile_pf_stage)
                2'd1: tile_pf_stage <= 2'd2;
                2'd2: begin
                    tile_pf_code_low <= spr_data;
                    tile_pf_attr     <= spr_data_next;
                    tile_pf_stage    <= 2'd3;
                end
                2'd3: begin
                    // TILE_PREP's arithmetic, verbatim, run early. tile_mode
                    // and tile_map_y are fixed for the whole tilemap run, so
                    // only the attribute-derived terms need shadowing.
                    tile_pf_flip_x <= tile_pf_flip_x_next;
                    tile_pf_flip_y <= tile_pf_flip_y_next;
                    tile_pf_color  <= tile_pf_attr[8:0];
                    tile_pf_row    <= tile_pf_flip_y_next ? ~tile_map_y[2:0]
                                                          :  tile_map_y[2:0];
                    if (tile_pf_flip_y_next ? !tile_map_y[3] : tile_map_y[3])
                        tile_pf_fetch_code <=
                            expand_code(cfg, tile_pf_code_low, tile_pf_attr) + 1'd1;
                    else
                        tile_pf_fetch_code <=
                            expand_code(cfg, tile_pf_code_low, tile_pf_attr);
                    tile_pf_valid <= 1'b1;
                    tile_pf_stage <= 2'd0;
                end
                default: ;
            endcase
        end

        // The raster deadline is a level for only the tail of one scanline.
        // Sampling it solely in BUILD_ADVANCE lets a long bucket/prefix/
        // reindex operation miss the whole window, keep cache_busy asserted
        // throughout visible display, and suppress every line-buffer swap in
        // ssv_core. Apply the containment at every active build phase.
        if (cache_busy && cache_deadline && !cache_finish_index) begin
`ifdef SIMULATION
            $display("CACHE_OVR deadline state=%0d count=%0d writes=%0d",
                     state, cache_count, cache_write_count);
`endif
            cache_overflow <= 1'b1;
            // Publishing here used to hand the renderer a torn index: the
            // list walk's per-line counts belong to THIS frame while the
            // pooled bases and line_entries[] still belong to the LAST one,
            // so RENDER walked mismatched pool regions and whole coherent
            // sprite groups (the HUD, the player) vanished for as long as
            // the deadline kept firing. Never publish half-built state:
            //  - aborted during the list walk: the counts are real, so run
            //    the bounded prefix+reindex passes (240 + writes cycles) and
            //    publish a consistent, merely truncated, index;
            //  - aborted during clear/prefix/reindex: the counts themselves
            //    are torn between frames, so publish an empty frame -- one
            //    blank sprite layer beats groups rendered from garbage.
            if ((state == BUILD_GLOBAL_WAIT) || (state == BUILD_GLOBAL_0) ||
                (state == BUILD_GLOBAL_1) || (state == BUILD_GLOBAL_2) ||
                (state == BUILD_GLOBAL_3) || (state == BUILD_LOCAL_WAIT) ||
                (state == BUILD_LOCAL_0) || (state == BUILD_LOCAL_1) ||
                (state == BUILD_LOCAL_2) || (state == BUILD_LOCAL_3) ||
                (state == BUILD_EVALUATE) || (state == BUILD_STORE) ||
                (state == BUILD_BUCKET_READ) || (state == BUILD_BUCKET_WRITE) ||
                (state == BUILD_ADVANCE)) begin
                cache_finish_index <= 1'b1;
                line_count_addr <= 8'd0;
                state <= BUILD_PREFIX_READ;
            end
            else begin
                cache_count <= '0;
                cache_ready <= 1'b1;
                cache_busy <= 1'b0;
                state <= IDLE;
            end
        end
        // A CPU write landed in the state this build is reading: the capture
        // is torn between two frames. Abandon and rebuild from IDLE via the
        // existing cache_pending path -- the rebuild re-reads everything, so
        // it reflects the post-write state. Deadline containment above wins
        // if both fire on the same edge.
        //
        // The core coalesces the measured vblank write burst, so this restart
        // is also allowed during BUILD_CLEAR_LINES. The first write can arrive
        // before the descriptor walk starts; rewinding once is cheaper than
        // letting the walk capture a pre-write frame, while later writes in the
        // same window cannot restart the clear again.
        else if (cache_busy && cache_restart) begin
`ifdef SIMULATION
            $display("CACHE_RESTART state=%0d writes=%0d", state,
                     cache_write_count);
`endif
            cache_pending <= 1'b1;
            cache_busy <= 1'b0;
            state <= IDLE;
        end
        else unique case (state)
            IDLE: begin
                busy <= 1'b0;
                cache_busy <= 1'b0;
                if (cache_start || cache_pending) begin
                    clear_y <= 8'd0;
                    line_count_addr <= 8'd0;
                    cache_write_count <= '0;
                    cache_ready <= 1'b0;
                    cache_overflow <= 1'b0;
                    cache_stop_after_bucket <= 1'b0;
                    cache_finish_index <= 1'b0;
                    build_last_descriptor_valid <= 1'b0;
                    cache_busy <= 1'b1;
                    cache_pending <= 1'b0;
                    state <= BUILD_CLEAR_LINES;
                end
                else if (start) begin
                    if (cache_ready) begin
                        target_y_latched <= target_y;
                        last_was_tilemap <= 1'b0;
                        cache_render_index <= '0;
                        line_count_addr <= target_y[7:0];
                        busy <= 1'b1;
                        state <= RENDER_COUNT_READ;
                    end
                    else begin
                        done <= 1'b1;
                    end
                end
            end


            BUILD_CLEAR_LINES: begin
                if (clear_y == 8'd239) begin
                    global_base <= 12'd0;
                    state <= BUILD_GLOBAL_WAIT;
                end
                else begin
                    clear_y <= clear_y + 1'd1;
                    line_count_addr <= line_count_addr + 1'd1;
                end
            end

            BUILD_GLOBAL_WAIT: state <= BUILD_GLOBAL_0;
            BUILD_GLOBAL_0: begin
                global_w0 <= spr_data;
                global_w1 <= spr_data_next;
                state <= BUILD_GLOBAL_1;
            end
            BUILD_GLOBAL_1: begin
                global_w2 <= spr_data;
                global_w3 <= spr_data_next;
                build_offset_x <= offset_word(sprite_offsets, build_offset_index);
                build_offset_y <=
                    offset_word(sprite_offsets, build_offset_index + 1'd1);
                if (global_w1[15]) begin
                    line_count_addr <= 8'd0;
                    state <= BUILD_PREFIX_READ;
                end
                else begin
                    // Enter the local loop unconditionally, even when the
                    // global's count field is zero. Combined with the
                    // `local_index < global_w0[4:0]` test in BUILD_ADVANCE
                    // this yields count+1 iterations, which is what MAME's
                    // `for (; num >= 0; num--)` does. Do NOT "optimise" a
                    // zero-count global into a skip: it would drop a
                    // descriptor MAME draws and break frame-CRC parity.
                    local_base <= {global_w1[14:0], 2'b00};
                    local_index <= 5'd0;
                    state <= BUILD_LOCAL_0;
                end
            end
            // Paired reads no longer enter these phases. If a diagnostic
            // force lands here, restart this descriptor from its even base.
            BUILD_GLOBAL_2: state <= BUILD_GLOBAL_WAIT;
            BUILD_GLOBAL_3: state <= BUILD_GLOBAL_WAIT;

            BUILD_LOCAL_WAIT: begin
                // global_w2/w3 and build_offset_x/y are all valid by here
                // (global_w2/w3 since BUILD_GLOBAL_1; build_offset_x/y
                // registered that same transition, see their declaration
                // above) -- pre-sum them now, two states ahead of
                // BUILD_EVALUATE, for the same reason build_offset_x/y
                // itself was pipelined.
                build_gx_off_r <= global_w2 + build_offset_x;
                build_gy_off_r <= global_w3 + build_offset_y;
                state <= BUILD_LOCAL_0;
            end
            BUILD_LOCAL_0: begin
                local_w0 <= spr_data;
                local_w1 <= spr_data_next;
                // Same pre-sum BUILD_LOCAL_WAIT does; repeated here so the
                // GLOBAL_1 -> LOCAL_0 path (which skips WAIT) has it too. It is
                // constant for a global, so re-deriving it is harmless.
                build_gx_off_r <= global_w2 + build_offset_x;
                build_gy_off_r <= global_w3 + build_offset_y;
                state <= BUILD_LOCAL_1;
            end
            BUILD_LOCAL_1: begin
                local_w2 <= spr_data;
                local_w3 <= spr_data_next;
                build_sx_work <= build_sx_work_capture;
                build_sy_work <= build_sy_work_capture;
                if (local_index == 0)
                    tilemaps_offsy <= spr_data_next;
                state <= BUILD_EVALUATE;
            end
            // Paired reads no longer enter these phases. If a diagnostic
            // force lands here, restart this descriptor from its even base.
            BUILD_LOCAL_2: state <= BUILD_LOCAL_WAIT;
            BUILD_LOCAL_3: state <= BUILD_LOCAL_WAIT;

            BUILD_EVALUATE: begin
                if (build_accept) begin
                    // Write+bucket every accepted slot, including the last;
                    // stop after that entry's buckets so it is not orphaned.
                    // Because the stop fires exactly as the count reaches
                    // CACHE_COUNT_VALUE, the "already full" arm below is
                    // unreachable in practice and is kept only as a guard.
                    cache_write_count <= cache_write_count + 1'd1;
                    build_last_descriptor <= cache_write_data;
                    build_last_descriptor_valid <= 1'b1;
                    bucket_descriptor <=
                        cache_write_count[CACHE_ADDR_WIDTH-1:0];
                    bucket_y <= build_first_y;
                    bucket_last_y <= build_last_y;
                    line_count_addr <= build_first_y;
                    cache_stop_after_bucket <=
                        (cache_write_count == CACHE_LAST_VALUE);
                    state <= BUILD_BUCKET_READ;
                end
                else if (build_screen_visible && build_is_duplicate) begin
                    // The render-time duplicate check already establishes
                    // that an identical ordinary descriptor has no visible
                    // effect when repeated consecutively. Skip its cache
                    // slot and continue walking the MAME list.
                    if (build_has_next_local) begin
                        local_index <= local_index + 1'd1;
                        local_base <= local_base + 3'd4;
                        local_w0 <= spr_data;
                        local_w1 <= spr_data_next;
                        state <= BUILD_LOCAL_1;
                    end
                    else
                        state <= BUILD_ADVANCE;
                end
                else if (build_screen_visible) begin
`ifdef SIMULATION
                    $display("CACHE_OVR cache_capacity state=%0d count=%0d writes=%0d",
                             state, cache_count, cache_write_count);
`endif
                    cache_overflow <= 1'b1;
                    // Same torn-index hazard as the deadline path: the walk
                    // stops here, but the pooled index must still be built
                    // before the renderer may see this frame's counts.
                    cache_finish_index <= 1'b1;
                    line_count_addr <= 8'd0;
                    state <= BUILD_PREFIX_READ;
                end
                else begin
                    if (build_has_next_local) begin
                        local_index <= local_index + 1'd1;
                        local_base <= local_base + 3'd4;
                        local_w0 <= spr_data;
                        local_w1 <= spr_data_next;
                        state <= BUILD_LOCAL_1;
                    end
                    else
                        state <= BUILD_ADVANCE;
                end
            end

            // Retained to preserve subsequent state encodings. Normal paired
            // builds commit directly in BUILD_EVALUATE.
            BUILD_STORE: state <= BUILD_EVALUATE;

            BUILD_BUCKET_READ: begin
                // Prime the synchronous count/page read for the first line,
                // then point the read port at the next line while WRITE uses
                // the registered current result.
                if (bucket_y != bucket_last_y)
                    line_count_addr <= line_count_addr + 1'd1;
                state <= BUILD_BUCKET_WRITE;
            end

            BUILD_BUCKET_WRITE: begin
                if (line_count_q >= LINE_SLOTS_VALUE) begin
`ifdef SIMULATION
                    $display("CACHE_OVR bucket_capacity y=%0d count=%0d writes=%0d",
                             bucket_y, line_count_q, cache_write_count);
`endif
                    cache_overflow <= 1'b1;
                end
                if (bucket_y == bucket_last_y) begin
                    if (cache_stop_after_bucket) begin
                        // The descriptor cache is full. Finish the first pass
                        // and build the compact pooled index before publishing
                        // it to the renderer.
                        line_count_addr <= 8'd0;
                        cache_stop_after_bucket <= 1'b0;
                        state <= BUILD_PREFIX_READ;
                    end
                    else if (build_has_next_local) begin
                        // The next local's first word pair was issued this
                        // cycle (see the spr_addr mux); BUILD_LOCAL_0 captures
                        // it, so BUILD_ADVANCE and BUILD_LOCAL_WAIT are skipped.
                        local_index <= local_index + 1'd1;
                        local_base <= local_base + 3'd4;
                        local_w0 <= spr_data;
                        local_w1 <= spr_data_next;
                        state <= BUILD_LOCAL_1;
                    end
                    else begin
                        state <= BUILD_ADVANCE;
                    end
                end
                else begin
                    bucket_y <= bucket_y + 1'd1;
                    line_count_addr <= line_count_addr + 1'd1;
                    state <= BUILD_BUCKET_WRITE;
                end
            end


            BUILD_ADVANCE: begin
                // Hard vblank deadline. The sprite list is only bounded by
                // 1024 globals x 32 locals x up to 240 bucket lines, which is
                // orders of magnitude longer than a frame. If the build ever
                // runs past the start of display, ssv_core's line_buffer_start
                // -- which gates on !cache_busy -- stops firing, so no line
                // ever swaps and the picture freezes. Worse, it cannot
                // recover: the next vblank re-arms the build, so it stays busy
                // forever. Publishing a partial cache degrades one frame's
                // sprites and raises cache_overflow (wired to the overrun LED)
                // instead of latching the whole core into a dead display.
                if ((local_index < global_w0[4:0]) &&
                    ((local_base + 17'd4) <= LAST_LOCAL)) begin
                    local_index <= local_index + 1'd1;
                    local_base <= local_base + 3'd4;
                    state <= BUILD_LOCAL_WAIT;
                end
                else if (global_base < LAST_GLOBAL) begin
                    global_base <= global_base + 3'd4;
                    state <= BUILD_GLOBAL_0;
                end
                else begin
                    line_count_addr <= 8'd0;
                    state <= BUILD_PREFIX_READ;
                end
            end

            BUILD_PREFIX_READ: state <= BUILD_PREFIX_WRITE;

            BUILD_PREFIX_WRITE: begin
                if (line_pool_end > LINE_POOL_ENTRIES) begin
`ifdef SIMULATION
                    $display("CACHE_OVR prefix line=%0d alloc=%0d count=%0d end=%0d",
                             line_count_addr, line_pool_alloc, line_count_q,
                             line_pool_end);
`endif
                    cache_overflow <= 1'b1;
                end
                if (line_count_addr == 8'd239) begin
                    // An empty visible list is a valid frame (for example
                    // during the first post-reset video epoch).  Do not enter
                    // the reindex pass with cache_scan_index=0: that would
                    // decode an unwritten descriptor_cache entry and use its
                    // X/stale Y as a bucket address, producing a false line
                    // pool overflow and renderer-ownership failure.
                    if (cache_write_count == 0) begin
                        cache_count <= '0;
                        cache_ready <= 1'b1;
                        cache_busy <= 1'b0;
                        state <= IDLE;
                    end
                    else begin
                        cache_scan_index <= '0;
                        state <= BUILD_REINDEX_READ;
                    end
                end
                else begin
                    line_count_addr <= line_count_addr + 1'd1;
                    state <= BUILD_PREFIX_READ;
                end
            end

            BUILD_REINDEX_READ: state <= BUILD_REINDEX_WAIT;

            BUILD_REINDEX_WAIT: begin
                cache_decode_q <= cache_scan_q;
                state <= BUILD_REINDEX_EVAL;
            end

            // BUILD_REINDEX_OFFSET/PRESUM mirror the two-stage pipeline
            // BUILD_LOCAL_WAIT/BUILD_GLOBAL_1 already run for the initial
            // build pass (see build_offset_x/y and build_gx_off_r/
            // build_gy_off_r's declarations above). The reindex pass reloads
            // global_w0/w2/w3 fresh per cached descriptor in
            // BUILD_REINDEX_WAIT above, so it needs the same two dependent
            // register stages before build_screen_visible/build_first_y are
            // valid for THIS descriptor -- reusing build_offset_x/y's stale
            // value from whatever the initial build pass last computed would
            // silently misjudge visibility/bucket placement for every
            // reindexed descriptor whose sprite-offset table entry differs.
            BUILD_REINDEX_OFFSET: state <= BUILD_REINDEX_EVAL;

            BUILD_REINDEX_PRESUM: state <= BUILD_REINDEX_EVAL;

            BUILD_REINDEX_EVAL: begin
                bucket_y <= compact_first_y;
                bucket_last_y <= compact_last_y;
                line_count_addr <= compact_first_y;
                state <= BUILD_REINDEX_BUCKET_READ;
            end

            // Retained to preserve subsequent state encodings. Normal second
            // pass entries commit directly in BUILD_REINDEX_EVAL.
            BUILD_REINDEX_STORE: state <= BUILD_REINDEX_EVAL;

            BUILD_REINDEX_BUCKET_READ: begin
                // Same read-ahead schedule as the first pass: one priming
                // cycle, then one pooled line occurrence per clock.
                if (bucket_y != bucket_last_y)
                    line_count_addr <= line_count_addr + 1'd1;
                state <= BUILD_REINDEX_BUCKET_WRITE;
            end

            BUILD_REINDEX_BUCKET_WRITE: begin
                if ((line_count_q >= LINE_SLOTS_VALUE) ||
                    (reindex_pool_addr >= LINE_POOL_ENTRIES)) begin
`ifdef SIMULATION
                    $display("CACHE_OVR reindex line=%0d count=%0d base=%0d addr=%0d scan=%0d",
                             bucket_y, line_count_q,
                             line_base_q, reindex_pool_addr,
                             cache_scan_index);
`endif
                    cache_overflow <= 1'b1;
                end
                if (bucket_y == bucket_last_y) begin
                    if (cache_scan_index + 1'd1 < cache_write_count) begin
                        cache_scan_index <= cache_scan_index + 1'd1;
                        // The next descriptor has been on the RAM output since
                        // BUILD_REINDEX_BUCKET_READ, so BUILD_REINDEX_WAIT's
                        // capture is done here.
                        cache_decode_q <= cache_scan_q;
                        state <= BUILD_REINDEX_EVAL;
                    end
                    else begin
                        cache_count <= cache_write_count;
                        cache_ready <= 1'b1;
                        cache_busy <= 1'b0;
                        state <= IDLE;
                    end
                end
                else begin
                    bucket_y <= bucket_y + 1'd1;
                    line_count_addr <= line_count_addr + 1'd1;
                    state <= BUILD_REINDEX_BUCKET_WRITE;
                end
            end

            RENDER_COUNT_READ: state <= RENDER_COUNT_WAIT;

            RENDER_COUNT_WAIT: begin
                if (line_count_q != 0) begin
                    render_line_count <= line_count_q;
                    render_line_slot <= '0;
                    render_line_pages <= line_page_q;
                    line_entry_addr <= LINE_ADDR_WIDTH'(
                        line_base_q);
                    last_render_descriptor_valid <= 1'b0;
                    state <= RENDER_LINE_READ;
                end
                else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
            end

            RENDER_LINE_READ: state <= RENDER_READ;

            RENDER_READ: begin
                cache_read_index <= line_entry_descriptor;
                cache_render_index <= line_entry_descriptor;
                if (render_line_slot + 1'd1 < render_line_count)
                    line_entry_addr <= line_entry_addr + 1'd1;
                state <= RENDER_DECODE;
            end
            // Keep the M10K output separate from coordinate/decode arithmetic.
            // This extra register removes the cache-to-position critical path.
            RENDER_DECODE: begin
                cache_decode_q <= cache_q;
                if (render_line_slot + 2'd2 < render_line_count)
                    line_entry_addr <= line_entry_addr + 1'd1;
                state <= RENDER_PREP;
            end
            RENDER_PREP: begin
                if (render_line_slot + 2'd3 < render_line_count)
                    line_entry_addr <= line_entry_addr + 1'd1;
                prep_tilemap <= calc_tilemap;
                prep_tilemap_active <= calc_tilemap_active;
                prep_tilemap_sy <= calc_tilemap_sy;
                prep_tilemap_bottom <= calc_tilemap_bottom;
                prep_tile_mode <= compact_tile_mode;
                prep_tile_unknown <= compact_tile_unknown;
                prep_tile_group <= compact_tile_group;
                prep_tile_map_y <= calc_tile_map_y;
                prep_tile_scroll_x_work <= calc_tile_scroll_x_work;
                prep_height <= calc_height;
                prep_code <= calc_code;
                prep_xnum <= calc_xnum;
                prep_ynum <= calc_ynum;
                prep_depth <= calc_depth;
                prep_flip_x <= calc_flip_x;
                prep_flip_y <= calc_flip_y;
                prep_color <= compact_color;
                prep_sx_work <= compact_sx;
                prep_sy_work <= compact_sy;
                prep_sprites_offsx <= '0;
                prep_sprites_offsy <= '0;
                prep_coordinate_control <= '0;
                prep_flip_control <= '0;
                state <= RENDER_EVAL;
            end
            RENDER_EVAL: begin
                if (last_render_descriptor_valid &&
                    (cache_decode_q == last_render_descriptor) &&
                    !calc_tilemap && !calc_depth[3]) begin
                    state <= RENDER_ADVANCE;
`ifdef SIMULATION
                    sim_duplicate_skips <= sim_duplicate_skips + 1;
`endif
                end
                else if (prep_tilemap) begin
                    last_render_descriptor <= cache_decode_q;
                    last_render_descriptor_valid <= 1'b1;
                    if (prep_tilemap_active &&
                        ($signed({1'b0, target_y_latched}) >=
                         prep_tilemap_sy) &&
                        ($signed({1'b0, target_y_latched}) <
                         prep_tilemap_bottom) &&
                        ((prep_tile_mode & 16'he000) != 0)) begin
                        // Adjacent 64-pixel tilemap slices overlap by one
                        // inclusive line in MAME. If the same scroll group
                        // is repeated with no intervening draw, its second
                        // rendering is pixel-for-pixel identical.
                        if (last_was_tilemap &&
                            (last_tilemap_group == prep_tile_group)) begin
                            state <= RENDER_ADVANCE;
                        end
                        else begin
                            last_was_tilemap <= 1'b1;
                            last_tilemap_group <= prep_tile_group;
                            render_tilemap <= 1'b1;
                            tile_mode <= prep_tile_mode;
                            tile_unknown <= prep_tile_unknown;
                            tile_map_y <= prep_tile_map_y;
                            tile_scroll_x <= prep_tile_scroll_x_work[16:0];
                            if (prep_tile_mode[12]) begin
                                state <= TILE_ROW_ADDR;
                            end
                            else begin
                                tile_map_x <= prep_tile_scroll_x_work[16:0];
                                tile_map_x0 <= prep_tile_scroll_x_work[16:0];
                                tile_screen_x <=
                                    -$signed({7'd0,
                                              prep_tile_scroll_x_work[3:0]});
                                tile_word_addr <= tile_address(
                                    prep_tile_scroll_x_work[16:0],
                                    prep_tile_scroll_x_work[16:0],
                                    prep_tile_map_y, prep_tile_mode
                                );
                                state <= TILE_CODE_ADDR;
                            end
                        end
                    end
                    else begin
                        state <= RENDER_ADVANCE;
                    end
                end
                else if ((eval_line_rel >= 0) &&
                         (eval_line_rel <
                         $signed({1'b0, prep_height}))) begin
                    last_render_descriptor <= cache_decode_q;
                    last_render_descriptor_valid <= 1'b1;
                    render_tilemap <= 1'b0;
                    last_was_tilemap <= 1'b0;
                    sprite_code <= prep_code;
                    sprite_xnum <= prep_xnum;
                    sprite_ynum <= prep_ynum;
                    sprite_tile_x <= 4'd0;
                    sprite_tile_y <= eval_line_rel[6:3];
                    sprite_sx <= eval_sx;
                    sprite_row <= prep_flip_y ? ~eval_line_rel[2:0]
                                              : eval_line_rel[2:0];
                    gfx_mode <= prep_depth[2:0];
                    flip_x <= prep_flip_x;
                    flip_y <= prep_flip_y;
                    shadow <= prep_depth[3];
                    color <= prep_color;
                    state <= RENDER_SPRITE_PREP;
                end
                else begin
                    last_render_descriptor <= cache_decode_q;
                    last_render_descriptor_valid <= 1'b1;
                    state <= RENDER_ADVANCE;
                end
            end
            // Isolate descriptor decode from the row-fetch address. The
            // cached values above are registered, breaking the M10K-to-code
            // arithmetic path while adding only one system-clock cycle.
            RENDER_SPRITE_PREP: begin
                fetch_code <= code_for_tile(
                    sprite_code, 4'd0, sprite_tile_y,
                    sprite_xnum, sprite_ynum,
                    flip_x, flip_y
                );
                fetch_row <= sprite_row;
                state <= FETCH_START;
            end

            RENDER_ADVANCE: begin
                if (render_line_slot + 1'd1 < render_line_count) begin
                    render_line_slot <= render_line_slot + 1'd1;
                    cache_decode_q <= cache_q;
                    state <= RENDER_PREP;
                end
                else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
            end

            TILE_ROW_ADDR: state <= TILE_ROW_WAIT;
            TILE_ROW_WAIT: begin
                // The row-scroll offset moves the running position only. MAME
                // fixes `page` from the raw scroll register before adding it
                // (ssv_v.cpp:684 vs :702), so the origin passed here must stay
                // `tile_scroll_x`. Adding the offset first lets a row-scroll
                // word of 0xffff -- a one-pixel step back -- carry a whole
                // scanline onto the neighbouring tilemap.
                tile_map_x <= tile_scroll_x + {1'b0, spr_data};
                tile_map_x0 <= tile_scroll_x;
                tile_screen_x <=
                    -$signed({7'd0,
                              tile_scroll_x[3:0] + spr_data[3:0]});
                tile_word_addr <= tile_address(
                    tile_scroll_x + {1'b0, spr_data},
                    tile_scroll_x,
                    tile_map_y, tile_mode
                );
                state <= TILE_CODE_ADDR;
            end

            TILE_CODE_ADDR: state <= TILE_CODE_WAIT;
            // tile_word_addr is even for every tile (see tile_address), so the
            // attribute is the odd word at the same bank index and arrives on
            // spr_data_next in this very cycle. The old
            // TILE_ATTR_ADDR/TILE_ATTR_WAIT pair -- and the +1 address bump
            // that fed them -- are gone; the address is recomputed from
            // scratch by tile_address() for the next tile either way.
            TILE_CODE_WAIT: begin
                tile_code_low <= spr_data;
                tile_attr <= spr_data_next;
                state <= TILE_PREP;
            end

            TILE_PREP: begin
                gfx_mode <= tile_mode[10:8];
                flip_x <= tile_flip_x;
                flip_y <= tile_flip_y;
                shadow <= tile_mode[11];
                color <= tile_attr[8:0];
                fetch_row <= tile_flip_y ? ~tile_map_y[2:0] :
                                           tile_map_y[2:0];
                if (tile_flip_y ? !tile_map_y[3] : tile_map_y[3])
                    fetch_code <= expand_code(cfg, tile_code_low, tile_attr) +
                                  1'd1;
                else
                    fetch_code <= expand_code(cfg, tile_code_low, tile_attr);
                state <= FETCH_START;
            end

            FETCH_START: begin
                // Arm the prefetch for the tile *after* the one now being
                // fetched. tile_map_x / tile_screen_x were already advanced to
                // the current tile, so tile_next_word_addr and
                // tile_next_in_range both refer to the correct successor.
                // Normal sprites index by code and never walk a map, so they
                // leave the sequencer idle.
                tile_pf_valid <= 1'b0;
                tile_pf_stage <= (render_tilemap && tile_next_in_range)
                                 ? 2'd1 : 2'd0;
                state <= FETCH_WAIT;
            end
            FETCH_WAIT: begin
                if (fetch_done) begin
                    if (pens == 128'd0) begin
                        // A fully transparent decoded row cannot affect the
                        // line buffer.  Skip its four four-pixel plot batches.
                        if (render_tilemap) begin
                            if (tile_screen_x + 11'sd16 >
                                $signed({2'd0, LAST_PIXEL})) begin
                                state <= RENDER_ADVANCE;
                            end
                            else begin
                                tile_screen_x <= tile_screen_x + 11'sd16;
                                tile_map_x <= tile_map_x + 17'd16;
                                tile_word_addr <= tile_next_word_addr;
                                if (tile_pf_valid) begin
                                    // Code and attribute were read out of the
                                    // idle sprite-RAM port during FETCH_WAIT
                                    // and already reduced to fetch operands, so
                                    // TILE_CODE_ADDR/TILE_CODE_WAIT/TILE_PREP
                                    // have nothing left to do.
                                    gfx_mode <= tile_mode[10:8];
                                    shadow <= tile_mode[11];
                                    flip_x <= tile_pf_flip_x;
                                    flip_y <= tile_pf_flip_y;
                                    color <= tile_pf_color;
                                    fetch_row <= tile_pf_row;
                                    fetch_code <= tile_pf_fetch_code;
                                    tile_code_low <= tile_pf_code_low;
                                    tile_attr <= tile_pf_attr;
                                    state <= FETCH_START;
                                end
                                else begin
                                    state <= TILE_CODE_ADDR;
                                end
                            end
                        end
                        else if (sprite_tile_x + 1'd1 < sprite_xnum) begin
                            sprite_tile_x <= sprite_tile_x + 1'd1;
                            sprite_sx <= sprite_sx + 17'sd16;
                            fetch_code <= code_for_tile(
                                sprite_code, sprite_tile_x + 1'd1,
                                sprite_tile_y, sprite_xnum, sprite_ynum,
                                flip_x, flip_y
                            );
                            fetch_row <= sprite_row;
                            state <= FETCH_START;
                        end
                        else begin
                            state <= RENDER_ADVANCE;
                        end
                    end
                    else begin
                        if (pens[31:0] != 32'd0)
                            plot_i <= 5'd0;
                        else if (pens[63:32] != 32'd0)
                            plot_i <= 5'd4;
                        else if (pens[95:64] != 32'd0)
                            plot_i <= 5'd8;
                        else
                            plot_i <= 5'd12;
                        state <= PLOT;
                    end
                end
            end

            PLOT: begin
                if (!plot_has_later_group) begin
                    if (render_tilemap) begin
                        if (tile_screen_x + 11'sd16 >
                            $signed({2'd0, LAST_PIXEL})) begin
                            state <= RENDER_ADVANCE;
                        end
                        else begin
                            tile_screen_x <= tile_screen_x + 11'sd16;
                            tile_map_x <= tile_map_x + 17'd16;
                            tile_word_addr <= tile_next_word_addr;
                            if (tile_pf_valid) begin
                                // See the matching note in FETCH_WAIT above.
                                gfx_mode <= tile_mode[10:8];
                                shadow <= tile_mode[11];
                                flip_x <= tile_pf_flip_x;
                                flip_y <= tile_pf_flip_y;
                                color <= tile_pf_color;
                                fetch_row <= tile_pf_row;
                                fetch_code <= tile_pf_fetch_code;
                                tile_code_low <= tile_pf_code_low;
                                tile_attr <= tile_pf_attr;
                                state <= FETCH_START;
                            end
                            else begin
                                state <= TILE_CODE_ADDR;
                            end
                        end
                    end
                    else if (sprite_tile_x + 1'd1 < sprite_xnum) begin
                        sprite_tile_x <= sprite_tile_x + 1'd1;
                        sprite_sx <= sprite_sx + 17'sd16;
                        fetch_code <= code_for_tile(
                            sprite_code, sprite_tile_x + 1'd1,
                            sprite_tile_y, sprite_xnum, sprite_ynum,
                            flip_x, flip_y
                        );
                        fetch_row <= sprite_row;
                        state <= FETCH_START;
                    end
                    else begin
                        state <= RENDER_ADVANCE;
                    end
                end
                else begin
                    plot_i <= plot_next_i;
                end
            end
        endcase
    end
end

`ifdef SIMULATION
// -------------------------------------------------------------------------
// Sim-only: uncapped per-scanline descriptor demand.
//
// line_counts saturates at LINE_SLOTS (see the BUILD_BUCKET_WRITE guard on
// the always_ff above), so the synthesised counter can only ever say "this
// line reached the cap", never how far past it the scene actually went. That
// is not enough to choose a new LINE_SLOTS: raising 96 to 128 is only useful
// if the demand fits under 128.
//
// This array counts every bucket write *attempt*, including the ones the cap
// discards, so the required depth can be read off directly. Nothing here
// drives the DUT and the whole block is excluded from synthesis.
// -------------------------------------------------------------------------
integer sim_line_demand [0:239];
integer sim_line_demand_max;
integer sim_line_demand_total;
integer sim_line_demand_i;
integer sim_duplicate_skips;
integer sim_line_pool_peak;
integer sim_line_pool_builds;
integer sim_plot_rows_nonzero;
integer sim_plot_cycles;
integer sim_empty_plot_groups;

initial begin
    for (sim_line_demand_i = 0; sim_line_demand_i < 240;
         sim_line_demand_i = sim_line_demand_i + 1)
        sim_line_demand[sim_line_demand_i] = 0;
    sim_line_demand_max = 0;
    sim_line_demand_total = 0;
    sim_duplicate_skips = 0;
    sim_line_pool_peak = 0;
    sim_line_pool_builds = 0;
    sim_plot_rows_nonzero = 0;
    sim_plot_cycles = 0;
    sim_empty_plot_groups = 0;
end

always_ff @(posedge clk) begin
    if (state == PLOT)
        sim_plot_cycles <= sim_plot_cycles + 1;
    if ((state == FETCH_WAIT) && fetch_done && (pens != 128'd0)) begin
        sim_plot_rows_nonzero <= sim_plot_rows_nonzero + 1;
        sim_empty_plot_groups <= sim_empty_plot_groups +
            (pens[31:0] == 32'd0) + (pens[63:32] == 32'd0) +
            (pens[95:64] == 32'd0) + (pens[127:96] == 32'd0);
    end
    if (state == BUILD_CLEAR_LINES) begin
        sim_line_demand[line_count_addr] <= 0;
        if (line_count_addr == 0)
            sim_line_demand_total <= 0;
    end
    else if (state == BUILD_BUCKET_WRITE) begin
        sim_line_demand[bucket_y] <= sim_line_demand[bucket_y] + 1;
        sim_line_demand_total <= sim_line_demand_total + 1;
        if (sim_line_demand[bucket_y] + 1 > sim_line_demand_max)
            sim_line_demand_max <= sim_line_demand[bucket_y] + 1;
    end
    if ((state == BUILD_PREFIX_WRITE) && (line_count_addr == 8'd239)) begin
        sim_line_pool_builds <= sim_line_pool_builds + 1;
        if (line_pool_end > sim_line_pool_peak)
            sim_line_pool_peak <= line_pool_end;
        $display("LINE_POOL build=%0d used=%0d peak=%0d capacity=%0d",
                 sim_line_pool_builds + 1, line_pool_end,
                 (line_pool_end > sim_line_pool_peak)
                     ? line_pool_end : sim_line_pool_peak,
                 LINE_POOL_ENTRIES);
    end
end
`endif


`ifdef SIMULATION
// Per-phase cycle accounting for one descriptor build, printed when the build
// commits or the deadline cuts it off. Sim-only; used to find where a dense
// scene spends its vblank budget.
integer sim_ph_walk, sim_ph_bucket, sim_ph_prefix, sim_ph_reindex, sim_ph_visits, sim_ph_acc;
logic   sim_ph_was_busy;
always @(posedge clk) begin
    sim_ph_was_busy <= cache_busy;
    if (rst || (cache_busy && !sim_ph_was_busy)) begin
        sim_ph_walk <= 0; sim_ph_bucket <= 0; sim_ph_prefix <= 0;
        sim_ph_reindex <= 0; sim_ph_visits <= 0; sim_ph_acc <= 0;
    end else if (cache_busy) begin
        case (state)
            BUILD_BUCKET_READ, BUILD_BUCKET_WRITE: sim_ph_bucket <= sim_ph_bucket + 1;
            BUILD_PREFIX_READ, BUILD_PREFIX_WRITE: sim_ph_prefix <= sim_ph_prefix + 1;
            BUILD_REINDEX_READ, BUILD_REINDEX_WAIT, BUILD_REINDEX_OFFSET,
            BUILD_REINDEX_PRESUM, BUILD_REINDEX_EVAL, BUILD_REINDEX_STORE,
            BUILD_REINDEX_BUCKET_READ, BUILD_REINDEX_BUCKET_WRITE:
                sim_ph_reindex <= sim_ph_reindex + 1;
            default: sim_ph_walk <= sim_ph_walk + 1;
        endcase
        if (state == BUILD_EVALUATE) sim_ph_visits <= sim_ph_visits + 1;
        if (state == BUILD_EVALUATE && build_accept) sim_ph_acc <= sim_ph_acc + 1;
    end
    if (!rst && ((!cache_busy && sim_ph_was_busy && cache_ready) || (cache_busy && cache_deadline && !cache_finish_index)))
        $display("CACHE_PHASES walk=%0d bucket=%0d prefix=%0d reindex=%0d visits=%0d accepted=%0d",
                 sim_ph_walk, sim_ph_bucket, sim_ph_prefix, sim_ph_reindex,
                 sim_ph_visits, sim_ph_acc);
end
`endif

endmodule
