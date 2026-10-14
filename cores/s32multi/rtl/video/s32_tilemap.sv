//============================================================================
//  System 32 scroll/tilemap engine — 315-5387
//  (DESIGN.md §6.2, Appendix C)
//  Renders one scanline of each enabled layer into per-layer line buffers:
//    NBG0/1: MAME-exact 12.20 X/Y zoom and fractional scroll
//            ($1FF10-1E, $1FF50-56, 0x200=1.0)
//    NBG2/3: rowscroll/rowselect via VRAM tables ($1FF04)
//    Line windows: $1FF04 bits 4/5 repurpose those tables as per-line
//            min/max X for clip windows 2/3 (titlef ring, ga2 torch)
//    TEXT:   8x8 chars from VRAM (page/bank $1FF5C)
//    BITMAP: linear VRAM bitmap 4/8bpp ($1FF88-8C)
//  Tile pixel data: 16x16 4bpp from SDRAM tile region via p1 burst port
//  (one 64-bit burst = one tile row).
//  Output pixel format into line buffers: {palette[8:0], pen[3:0]} + opaque
//  flag; the mixer applies palbase/shift.
//
//  Time budget: renders during previous line's active+blank at clk_ram/2;
//  worst case 4 layers x 416 px + text + bitmap ≈ 2700 fetch-limited cycles,
//  available ≈ 3000 (DESIGN.md §10.2).
//============================================================================

module s32_tilemap (
    input             clk,          // clk_ram
    input             rst,

    // frame timing
    input       [8:0] line,         // line to render (next display line)
    input             line_start,   // pulse: begin rendering `line`
    output reg        line_done,
    input             mode_416,
    input             is_multi32,    // Multi 32: per-layer external tilebank
    input       [7:0] ext_tilebank, // 315-5296 port H (System 32 uses bit 0)

    // video registers (from s32_vram)
    input      [15:0] r1ff00, r1ff02, r1ff04, r1ff06, r1ff5c, r1ff5e,
    input      [15:0] r1ff88, r1ff8a, r1ff8c, r1ff8e,
    input      [15:0] scrollfracx [0:1],
    input      [15:0] scrollfracy [0:1],
    input      [15:0] scrollx [0:3],
    input      [15:0] scrolly [0:3],
    input      [15:0] offsx   [0:3],
    input      [15:0] offsy   [0:3],
    input      [15:0] pages   [0:7],
    input      [15:0] zoomx   [0:1],
    input      [15:0] zoomy   [0:1],
    input      [15:0] clips   [0:19],

    // VRAM fetch port
    output reg [15:0] vram_addr,
    input      [15:0] vram_rdata,

    // SDRAM tile data port (p1)
    output reg        tile_req,
    output reg [21:3] tile_addr,    // 8-byte aligned within tile region
    input      [63:0] tile_data,
    input             tile_ack,

    // line buffer write (to mixer): layer 0=TEXT 1..4=NBG0-3 5=BITMAP
    output reg        lb_we,
    output reg  [2:0] lb_layer,
    output reg  [8:0] lb_x,
    output reg [13:0] lb_pix,       // {pal[8:0], pen[3:0]} | [13]=opaque-valid
    output      [5:0] layer_off_o   // to the mixers (MAME enablemask, inverted)
);

// layer enable logic: $1FF02 low bits + $1FF8E second disable set
// (+ $1FF00 bits 12/13 disable NBG2/NBG3 — MAME update_tilemaps)
wire [5:0] layer_off = { r1ff02[5] | r1ff8e[5],                // BITMAP
                         r1ff02[3] | r1ff8e[4] | r1ff00[13],   // NBG3
                         r1ff02[2] | r1ff8e[3] | r1ff00[12],   // NBG2
                         r1ff02[1] | r1ff8e[2],                // NBG1
                         r1ff02[0] | r1ff8e[1],                // NBG0
                         r1ff02[4] | r1ff8e[0] };              // TEXT
assign layer_off_o = layer_off;

// Multi 32 selects a 2-bit external tilebank per layer from the full port-H
// byte ((external >> 2*bgnum) & 3), with no $1FF00 bit 10; System 32 keeps the
// single-bit external + $1FF00[10] form (audit R20 TM-3).  Computed at the NBG
// tile fetch (T_PIX) where `lay` (0..3) is valid — the only consumer.
function automatic [1:0] tilebank_of(input [2:0] l);
    tilebank_of = is_multi32 ? ext_tilebank[{l[1:0], 1'b0} +: 2]
                             : {ext_tilebank[0], r1ff00[10]};
endfunction

// rendering FSM: iterate layers, per layer iterate x
typedef enum logic [4:0] {
    T_IDLE, T_LWIN, T_LSTART, T_SCALE, T_SCALE_APPLY, T_ROWTAB1, T_ROWTAB2, T_ROWSEL1, T_ROWSEL2,
    T_NAME, T_NAMEW, T_NAMER, T_PIX, T_PIXW, T_EMIT,
    T_TXT_NAME, T_TXT_NAMEW, T_TXT_NAMER,
    T_TXT_PIX, T_TXT_PIXW, T_TXT_PIXR, T_TXT_EMIT,
    T_BMP, T_BMPW, T_BMPR, T_BMP_EMIT, T_DONE
} tst_t;
tst_t tst;

reg [2:0]  lay;          // 0..3 = NBG0..3, 4 = TEXT, 5 = BITMAP
reg [9:0]  x;            // dest x
reg [9:0]  srcx;         // source x (integer part)
reg [8:0]  srcy;
reg [31:0] xacc;
reg signed [31:0] xstep; // MAME source coordinate/step, 12.20 modulo 2^32
reg [15:0] name;
reg [63:0] row;
reg [15:0] rowscroll_add;
// per-line window X extents fetched from the repurposed row tables
reg [8:0]  lwa_min, lwa_max;  // clip window 2 override ($1FF04 bit 4)
reg [8:0]  lwb_min, lwb_max;  // clip window 3 override ($1FF04 bit 5)
reg [2:0]  lw_ph;

// Row-invariant tile-fetch operands, resolved once per layer row.
//
// MAME's update_tilemap_rowscroll (segas32_v.cpp) hoists exactly these out of
// its inner loop: `xscroll`/`yscroll` and the flip flags are computed once for
// the layer, and each row resolves its effective source Y and its pair of page
// pixmaps (`src[2]`) before the per-pixel loop, which then does only
// `srcx += srcxstep` and `src[(srcx >> 9) & 1]`.  The previous form re-derived
// all of it inside T_NAME for every tile, so `lay` fanned out through the
// scrollx/offsx/scrolly array muxes, a three-operand adder and the page-word
// select within one 96.6 MHz cycle -- the design's worst setup path.
//
// These are written only at the states that lead into T_NAME, never inside the
// T_EMIT->T_NAME tile loop, because none of their inputs may change within a
// row: rowscroll_add and srcy are set during layer setup,
// and latching the CPU-written scroll/page inputs per row (rather than per
// tile) is what the reference model does.
reg [9:0]  sx_base;      // scrollx - offsx + rowscroll, NBG2/3 only
reg [8:0]  sy_row;       // effective source Y for this row
reg [2:0]  pg_idx;       // {lay[1:0], sy_row[8]} latched for this row
reg        flipx_row;    // tile_flipx latched for this row
reg [1:0]  tilebank_row; // tilebank_of(lay) latched for this row

// Bitmap VRAM is word-wide while the renderer consumes one pixel per cycle.
// Retain an explicitly tagged word for its two 8bpp or four 4bpp lanes rather
// than paying the synchronous VRAM latency again for every pixel.  The tag is
// checked on every emit, so a live scroll/mode change falls back to a fresh
// read instead of reusing data from a different word interpretation.
reg [15:0] bmp_word;
reg [15:0] bmp_word_addr;
reg [15:0] bmp_req_addr;
reg        bmp_word_bpp8;
reg        bmp_req_bpp8;
reg        bmp_word_valid;

// NBG0/1 use MAME's exact (0x200 << 20)/zoom calculation on both axes.
// A shared restoring divider keeps that work off the 96.6 MHz render path.
reg         scale_start;
wire        scale_busy, scale_done;
reg  [11:0] scale_zx, scale_zy;
wire [22:0] scale_xquot, scale_yquot;
reg signed [10:0] scale_xbase;
reg signed [10:0] scale_ybase;
reg        [31:0] scale_xorigin, scale_yorigin;
reg signed [33:0] scale_yprod, scale_xprod;
reg               scale_flipx;
reg               scale_cache_hit;
reg        [22:0] scale_cached_xquot, scale_cached_yquot;
reg               scale_cache_valid [0:1];
reg        [11:0] scale_cache_zx [0:1];
reg        [11:0] scale_cache_zy [0:1];
reg        [22:0] scale_cache_xquot [0:1];
reg        [22:0] scale_cache_yquot [0:1];

// The reciprocal quotient is 23 bits, while the signed destination-center
// offset is 11 bits.  Explicitly widen both operands before multiplying: an
// unsized 11x23 expression is evaluated at the quotient width in some
// simulators/synthesis front ends and drops the high 12.20 coordinate bits.
wire signed [33:0] scale_xbase_ext = {{23{scale_xbase[10]}}, scale_xbase};
wire signed [33:0] scale_ybase_ext = {{23{scale_ybase[10]}}, scale_ybase};
wire signed [33:0] scale_xquot_ext = {11'b0, scale_xquot};
wire signed [33:0] scale_yquot_ext = {11'b0, scale_yquot};
wire signed [33:0] scale_cached_xquot_ext = {11'b0, scale_cached_xquot};
wire signed [33:0] scale_cached_yquot_ext = {11'b0, scale_cached_yquot};

s32_tilemap_scale_div scale_div (
    .clk(clk), .rst(rst), .start(scale_start),
    .yden(scale_zy), .xden(scale_zx),
    .busy(scale_busy), .done(scale_done),
    .yquot(scale_yquot), .xquot(scale_xquot)
);

wire [8:0] hpix = mode_416 ? 9'd416 : 9'd320;
wire [3:0] lay_idx = {1'b0, lay};
wire tile_flipx = r1ff00[9] ^ ((lay < 4) ? r1ff00[lay_idx] : 1'b0);
wire tile_flipy = r1ff00[9] ^ (((lay < 4) ? r1ff00[lay_idx] : 1'b0) & ~r1ff00[8]);
wire [31:0] nacc_zoom = xacc + xstep;
wire [9:0] nsx_zoom = nacc_zoom[29:20];
wire [8:0] text_srcx = r1ff00[9] ? (9'd511 - x[8:0]) : x[8:0];
wire [7:0] text_srcy = r1ff00[9] ? (8'd255 - line[7:0]) : line[7:0];


// Page select is now split across the row boundary: the row latches only the
// 3-bit page index (2x2 pages of 512x256), a single read port expands it, and
// just the sx[9] half-select remains in the per-tile path.  Latching the index
// rather than the word keeps this to one 8:1 mux on the 128-bit `pages` bus
// instead of one per write site, and pg_idx is registered so the mux sits off
// the T_NAME critical path.
wire [15:0] pg_word = pages[pg_idx];

// tile name address within VRAM: page*0x200 + row*32 + col
function automatic [15:0] name_addr(input [6:0] pg, input [9:0] sx, input [8:0] sy);
    name_addr = {pg, 9'b0} + {7'b0, sy[7:4], sx[8:4]};
endfunction

function automatic [15:0] bitmap_addr(input [8:0] bx, input [8:0] by,
                                      input bpp8);
    bitmap_addr = bpp8 ? {by[7:0], bx[8:1]} : {by, bx[8:2]};
endfunction

// layer clip windows (MAME compute_clipping_extents, per-pixel form):
//   rect i = clips[4i..4i+3] = {min_x[8:0], min_y[7:0], max_x[8:0], max_y[7:0]}
//   (max inclusive); pixel drawn iff !enable | (inside-union ^ clipout)
function automatic clip_enable_of(input [2:0] bg);
    clip_enable_of = r1ff02[4'd11 + {1'b0, bg}];
endfunction

// Line windows: when $1FF04 bit 4 (5) repurposes the NBG2 (NBG3) row tables,
// the rowscroll quarter holds a per-line window min X and the rowselect
// quarter its max X, overriding clip window 2's (3's) X extents on that line.
// $FFFF table entries collapse the window to nothing on that line.  Layers
// opt in through the normal $1FF06 nibble; with clip-out set the layer is
// drawn only outside the per-line trapezoid (titlef boxing ring, ga2 torch).
function automatic clip_vis(input [8:0] xx, input [8:0] yy,
                            input en, input outp, input [4:0] msk);
    logic [4:0] hit;
    logic [8:0] test_x;
    logic [8:0] test_y;
    logic [8:0] cminx, cmaxx;
    integer ci;
    test_x = r1ff00[9] ? (hpix - 1'b1 - xx) : xx;
    test_y = r1ff00[9] ? (9'd223 - yy) : yy;
    for (ci = 0; ci < 5; ci = ci + 1) begin
        cminx = clips[4*ci][8:0];
        cmaxx = clips[4*ci+2][8:0];
        if (ci == 2 && r1ff04[4]) begin cminx = lwa_min; cmaxx = lwa_max; end
        if (ci == 3 && r1ff04[5]) begin cminx = lwb_min; cmaxx = lwb_max; end
        hit[ci] = msk[ci] &&
            test_x >= cminx && test_y >= {1'b0, clips[4*ci+1][7:0]} &&
            test_x <= cmaxx && test_y <= {1'b0, clips[4*ci+3][7:0]};
    end
    clip_vis = !en || ((|hit) ^ outp);
endfunction

// Text layer name address: MAME's get_text_tile_info uses the full five-bit
// page selector $1FF5C[8:4] (<<11 words). Golden Axe stores its gameplay HUD
// and GO-prompt name table in the upper half of video RAM.
wire [15:0] text_page_base = {r1ff5c[8:4], 11'b0};
// text char gfx base: bank bits 2:0 of $1FF5C, 16 words/char
wire [15:0] text_bank_base = {r1ff5c[2:0], 13'b0};

always @(posedge clk) begin
    if (rst) begin
        tst <= T_IDLE; line_done <= 0; lb_we <= 0; tile_req <= 0;
        scale_start <= 0;
        scale_cache_hit <= 1'b0;
        scale_cache_valid[0] <= 1'b0;
        scale_cache_valid[1] <= 1'b0;
        bmp_word_valid <= 1'b0;
        lwa_min <= 9'h1ff; lwa_max <= 9'h1ff;
        lwb_min <= 9'h1ff; lwb_max <= 9'h1ff;
        lw_ph <= 3'd0;
    end
    else begin
        lb_we <= 1'b0;
        scale_start <= 1'b0;
        // Completion is a pulse, not an idle-level indication.  The line
        // scheduler may legally accept the next scanline on the cycle this
        // pulse is observed; leaving it high until the next start would make
        // that newly accepted job look complete one cycle later.
        line_done <= 1'b0;

        case (tst)
        T_IDLE: if (line_start) begin
            lay <= 0;
            x   <= 0;
            line_done <= 0;
            // A cached bitmap word never crosses a scanline epoch.
            bmp_word_valid <= 1'b0;
            if (r1ff04[4] | r1ff04[5]) begin
                // fetch this line's window extents from the row tables
                vram_addr <= {r1ff04[15:10], 10'b0} +
                             {7'b0, (r1ff00[9] ? (9'd223 - line) : line)};
                lw_ph <= 3'd0;
                tst <= T_LWIN;
            end
            else tst <= T_LSTART;
        end

        // Per-line window fetch: four table words at +0x000/+0x200 (window 2
        // min/max X) and +0x100/+0x300 (window 3 min/max X), two VRAM-latency
        // cycles apiece, before any layer of this line renders.
        T_LWIN: begin
            logic [15:0] lw_row;
            lw_row = {7'b0, (r1ff00[9] ? (9'd223 - line) : line)};
            lw_ph <= lw_ph + 3'd1;
            case (lw_ph)
                3'd1: begin
                    lwa_min <= vram_rdata[8:0];
                    vram_addr <= {r1ff04[15:10], 10'b0} + 16'h0200 + lw_row;
                end
                3'd3: begin
                    lwa_max <= vram_rdata[8:0];
                    vram_addr <= {r1ff04[15:10], 10'b0} + 16'h0100 + lw_row;
                end
                3'd5: begin
                    lwb_min <= vram_rdata[8:0];
                    vram_addr <= {r1ff04[15:10], 10'b0} + 16'h0300 + lw_row;
                end
                3'd7: begin
                    lwb_max <= vram_rdata[8:0];
                    tst <= T_LSTART;
                end
                default: ;
            endcase
        end

        // per-layer setup
        T_LSTART: begin
            if (lay < 4) begin
                if (layer_off[lay+1]) begin
                    lay <= lay + 1'd1;
                    // Always re-enter layer setup.  Jumping directly from a
                    // disabled NBG3 to T_TXT_NAME bypassed the TEXT disable
                    // bit and rendered stale text pixels anyway.
                    tst <= T_LSTART;
                    if (lay == 3) begin x <= 0; end
                end
                else if (lay < 2) begin
                    logic [11:0] zy, zx;
                    logic [11:0] zy_eff;
                    logic cache_hit;
                    logic fx, fy;
                    logic signed [10:0] xdest;
                    logic signed [10:0] ydest;
                    logic signed [10:0] xcenter;
                    logic signed [10:0] ycenter;
                    fx = r1ff00[9] ^ r1ff00[lay_idx];
                    fy = r1ff00[9] ^ (r1ff00[lay_idx] & ~r1ff00[8]);
                    zy = (zoomy[lay][11:0] < 12'h080) ? 12'h080 : zoomy[lay][11:0];
                    zx = (zoomx[lay][11:0] < 12'h080) ? 12'h080 : zoomx[lay][11:0];
                    zy_eff = r1ff00[14] ? zy : zx;
                    // The reciprocal divider's numerator is constant. Its
                    // complete input key is therefore the pair of clamped,
                    // effective X/Y denominators (the independent-Y select is
                    // already folded into zy_eff). Keep one exact entry per
                    // zoomable layer so different NBG0/NBG1 zooms do not thrash.
                    cache_hit = scale_cache_valid[lay[0]] &&
                                scale_cache_zx[lay[0]] == zx &&
                                scale_cache_zy[lay[0]] == zy_eff;
                    scale_zx <= zx;
                    // MAME uses zoom X for both axes unless independent Y
                    // zoom is selected by $1FF00 bit 14.
                    scale_zy <= zy_eff;
                    // MAME treats the destination center as signed 9-bit at
                    // neutral zoom and signed 10-bit whenever that axis is
                    // zoomed.  This subtle rule is required by Holo and by
                    // several attract/course-selection backgrounds.
                    xcenter = (zx == 12'h200)
                            ? $signed({{2{offsx[lay][8]}}, offsx[lay][8:0]})
                            : $signed({offsx[lay][9], offsx[lay][9:0]});
                    ycenter = ((r1ff00[14] ? zy : zx) == 12'h200)
                            ? $signed({{2{offsy[lay][8]}}, offsy[lay][8:0]})
                            : $signed({offsy[lay][9], offsy[lay][9:0]});
                    xdest = fx ? $signed({2'b00, hpix - 1'b1}) : 11'sd0;
                    ydest = fy ? $signed(11'd223 - {2'b00, line}) : $signed({2'b00, line});
                    scale_xbase <= xdest - xcenter;
                    scale_ybase <= ydest - ycenter;
                    scale_xorigin <= {2'b0, scrollx[lay][9:0], 20'b0} +
                                     {12'b0, scrollfracx[lay][15:8], 12'b0};
                    scale_yorigin <= {3'b0, scrolly[lay][8:0], 20'b0} +
                                     {12'b0, scrollfracy[lay][15:9], 13'b0};
                    scale_flipx <= fx;
                    scale_cache_hit <= cache_hit;
                    if (cache_hit) begin
                        scale_cached_xquot <= scale_cache_xquot[lay[0]];
                        scale_cached_yquot <= scale_cache_yquot[lay[0]];
                    end
                    else begin
                        scale_start <= 1'b1;
                    end
                    x <= 0;
                    rowscroll_add <= 0;
                    tst <= T_SCALE;
                end
                else begin
                    // compute source y for this layer
                    logic [8:0] sy;
                    logic [8:0] ylookup;
                    ylookup = tile_flipy ? (9'd223 - line) : line;
                    sy = scrolly[lay][8:0] + ylookup;
                    xacc  <= 0;
                    xstep <= 32'sh0010_0000; // unused for NBG2/3
                    srcy <= sy;
                    x <= 0;
                    rowscroll_add <= 0;
                    // Row invariants for the direct T_NAME entry below.  The
                    // T_ROWTAB1 path recomputes them once its table words
                    // arrive, so setting them unconditionally here is safe.
                    sx_base   <= scrollx[lay][9:0] - {1'b0, offsx[lay][8:0]};
                    sy_row    <= sy;
                    pg_idx    <= {lay[1:0], sy[8]};
                    flipx_row <= tile_flipx;
                    tilebank_row <= tilebank_of(lay);
                    // rowscroll/rowselect fetch for NBG2/3
                    if (!r1ff04[lay_idx+4'd2] &&
                        (r1ff04[lay_idx-4'd2] | r1ff04[lay_idx])) begin
                        // Rowselect is a distinct table at +0x200. If row
                        // scroll is off, fetch rowselect directly here.
                        vram_addr <= {r1ff04[15:10], 10'b0} +
                                     (lay == 3 ? 16'h0100 : 16'h0000) +
                                     (r1ff04[lay_idx-4'd2] ? 16'h0000 : 16'h0200) +
                                     {7'b0, ylookup};
                        tst <= T_ROWTAB1;
                    end
                    else tst <= T_NAME;
                end
            end
            else if (lay == 4) begin
                x <= 0;
                // Keep enum assignments in explicit branches for Quartus-17
                // and Icarus; the conditional expression needs a simulator-
                // specific enum cast but has identical hardware semantics.
                if (layer_off[0]) tst <= T_LSTART;
                else              tst <= T_TXT_NAME;
                if (layer_off[0]) lay <= 5;
            end
            else begin
                // bitmap
                x <= 0;
                if (layer_off[5]) tst <= T_DONE;
                else              tst <= T_BMP;
            end
        end

        // V-2 (MAME update_tilemap_zoom): exact 12.20 reciprocal step, with
        // destination zoom floored at 0x80.
        // Register the two DSP products before the final coordinate add so
        // neither operation spans the full 96 MHz cycle.
        T_SCALE: begin
            if (scale_cache_hit) begin
                scale_yprod <= scale_ybase_ext * scale_cached_yquot_ext;
                scale_xprod <= scale_xbase_ext * scale_cached_xquot_ext;
                xstep <= scale_flipx ? -$signed({9'b0, scale_cached_xquot})
                                     :  $signed({9'b0, scale_cached_xquot});
                scale_cache_hit <= 1'b0;
                tst <= T_SCALE_APPLY;
            end
            else if (scale_done) begin
                scale_yprod <= scale_ybase_ext * scale_yquot_ext;
                scale_xprod <= scale_xbase_ext * scale_xquot_ext;
                xstep <= scale_flipx ? -$signed({9'b0, scale_xquot})
                                     :  $signed({9'b0, scale_xquot});
                scale_cache_valid[lay[0]] <= 1'b1;
                scale_cache_zx[lay[0]] <= scale_zx;
                scale_cache_zy[lay[0]] <= scale_zy;
                scale_cache_xquot[lay[0]] <= scale_xquot;
                scale_cache_yquot[lay[0]] <= scale_yquot;
                tst <= T_SCALE_APPLY;
            end
        end
        T_SCALE_APPLY: begin
            logic [31:0] ycoord;
            ycoord = scale_yorigin + scale_yprod[31:0];
            srcy <= ycoord[28:20];
            xacc <= scale_xorigin + scale_xprod[31:0];
            // NBG0/1 take their source X from xacc, so sx_base is unused here
            // and is deliberately left alone.  NBG0/1 never take the row
            // scroll/select path, so the row's effective Y is simply the
            // freshly computed srcy.
            sy_row    <= ycoord[28:20];
            pg_idx    <= {lay[1:0], ycoord[28]};
            flipx_row <= tile_flipx;
            tilebank_row <= tilebank_of(lay);
            tst <= T_NAME;
        end

        // rowscroll value
        T_ROWTAB1: begin
            // wait 1 clk for vram read
            tst <= T_ROWTAB2;
        end
        T_ROWTAB2: begin
            // Row invariants, using this cycle's incoming row-scroll word and
            // row-select value rather than their not-yet-registered forms.
            logic [9:0] rsa_c;
            logic [8:0] syc;
            rsa_c = (r1ff04[lay_idx-4'd2] && !r1ff04[lay_idx+4'd2])
                  ? vram_rdata[9:0] : rowscroll_add[9:0];
            // Row select applies only on the inner else branch below (row
            // select enabled without row scroll); every other exit keeps the
            // layer-setup srcy.
            syc = (r1ff04[lay_idx] && !r1ff04[lay_idx+4'd2] &&
                   !r1ff04[lay_idx-4'd2])
                ? (scrolly[lay][8:0] + vram_rdata[8:0]) : srcy;
            sx_base <= scrollx[lay][9:0] - {1'b0, offsx[lay][8:0]} + rsa_c;
            sy_row  <= syc;
            pg_idx  <= {lay[1:0], syc[8]};

            if (r1ff04[lay_idx-4'd2] && !r1ff04[lay_idx+4'd2])
                rowscroll_add <= vram_rdata & 16'h3ff;
            if (r1ff04[lay_idx] && !r1ff04[lay_idx+4'd2]) begin
                if (r1ff04[lay_idx-4'd2]) begin
                    vram_addr <= {r1ff04[15:10], 10'b0} + 16'h0200 +
                                 (lay == 3 ? 16'h0100 : 16'h0000) +
                                 {7'b0, (tile_flipy ? (9'd223-line) : line)};
                    tst <= T_ROWSEL1;
                end
                else begin
                    // Row select is folded into sy_row/pg_word above.
                    tst <= T_NAME;
                end
            end
            else tst <= T_NAME;
        end
        T_ROWSEL1: tst <= T_ROWSEL2;
        T_ROWSEL2: begin
            // This path always enables row select, so the row's effective Y is
            // the row-select table word.  rowscroll_add was already latched in
            // T_ROWTAB2 and is reused here.
            logic [8:0] syc;
            syc = scrolly[lay][8:0] + vram_rdata[8:0];
            sx_base <= scrollx[lay][9:0] - {1'b0, offsx[lay][8:0]} +
                       rowscroll_add[9:0];
            sy_row  <= syc;
            pg_idx  <= {lay[1:0], syc[8]};
            tst <= T_NAME;
        end

        // fetch tile name for current x
        T_NAME: begin
            // Only the x-dependent term is computed here now; the layer/row
            // operands were resolved by the states above.  All arithmetic is
            // mod 2^10 as before, so splitting the sum is bit-exact.
            logic [9:0] sx;
            logic [6:0] pg;
            if (lay < 2) sx = xacc[29:20];
            else         sx = sx_base +
                              (flipx_row ? (hpix - 1'b1 - x[8:0]) : x);
            pg = sx[9] ? pg_word[14:8] : pg_word[6:0];
            srcx <= sx;
            vram_addr <= name_addr(pg, sx, sy_row);
            tst <= T_NAMEW;
        end
        T_NAMEW: begin
            // The VRAM video port is synchronous: the address is sampled on
            // this edge and its registered data is visible after the edge.
            // Consume it in the following state, not as the old address is
            // still visible here.
            tst <= T_NAMER;
        end
        T_NAMER: begin
            name <= vram_rdata;
            tst <= T_PIX;
        end
        // fetch tile pixel row from SDRAM: tile code 13 bits + bank
        T_PIX: begin
            logic [14:0] code;
            logic [3:0]  trow;
            logic [8:0] eff_y;
            code = {tilebank_row, name[12:0]};
            eff_y = sy_row;   // same row-invariant value, resolved once above
            trow = eff_y[3:0] ^ {4{name[15]}};
            tile_addr <= {code, trow};   // 15+4 = 19 bits of 8-byte rows
            tile_req  <= 1'b1;
            tst <= T_PIXW;
        end
        T_PIXW: if (tile_ack) begin
            tile_req <= 0;
            row <= tile_data;
            tst <= T_EMIT;
        end
        // emit up to 16 pixels (or until tile boundary/zoom step)
        T_EMIT: begin
            logic [3:0] col;
            logic [3:0] pen;
            col = srcx[3:0] ^ {4{name[14]}};
            // $1FF8E[11:8] is NOT a pen-0-opaque enable.  MAME 0.289 keeps
            // that reading permanently disabled, and Title Fight proves it on
            // hardware: the game holds $1FF8E=$0C00 while the ring floor is
            // the per-line backdrop; an opaque NBG2/NBG3 pen 0 would bury the
            // floor under CRAM[$1800]=black (real-PCB footage shows the
            // floor).  NBG pen 0 is therefore always transparent here.
            // 4bpp packed msb-first per 16px row (bgcharlayout nibble order)
            // bgcharlayout x-offsets {0,4,16,20,8,12,24,28,...}: column ->
            // nibble index swaps the middle bits; even nibble = high half of
            // its byte (MSB-first packing), odd = low half.
            begin
                logic [3:0] nib;
                nib = {col[3], col[1], col[2], col[0]};
                pen = row[{nib[3:1], 3'b000} + (nib[0] ? 3'd0 : 3'd4) +: 4];
            end
            lb_we    <= 1'b1;
            lb_layer <= lay + 3'd1;   // NBG0 = layer1
            lb_x     <= x[8:0];
            // clip window: $1FF02 bit (11+bg) enable / (6+bg) clip-out;
            // $1FF06 nibble bg selects rects 0-3
            lb_pix   <= {(|pen) && clip_vis(x[8:0], line,
                            clip_enable_of(lay),
                            r1ff02[4'd6  + {1'b0, lay}],
                            {1'b0, r1ff06[{lay[1:0], 2'b00} +: 4]}),
                         name[12:4], pen};
            // advance
            if (x == hpix-1) begin
                lay <= lay + 1'd1;
                tst <= T_LSTART;
            end
            else begin
                x <= x + 1'd1;
                if (lay < 2) begin
                    xacc <= nacc_zoom;
                    // refetch name/pixels when tile col crosses
                    if (nsx_zoom[9:4] != srcx[9:4]) tst <= T_NAME;
                    else srcx <= nsx_zoom;
                end
                else begin
                    // Advance with the same row-latched flip that T_NAME used
                    // to address the tile.  Using the live wire here while
                    // T_NAME uses flipx_row would tear a row's addressing if
                    // the CPU wrote $1FF00 mid-scanline.
                    if ((!flipx_row && srcx[3:0] == 4'hf) ||
                        ( flipx_row && srcx[3:0] == 4'h0)) tst <= T_NAME;
                    else srcx <= flipx_row ? (srcx - 1'd1) : (srcx + 1'd1);
                end
            end
        end

        // ---- text layer: 8x8 4bpp chars from VRAM ----
        T_TXT_NAME: begin
            vram_addr <= text_page_base + {5'b0, text_srcy[7:3], text_srcx[8:3]};
            tst <= T_TXT_NAMEW;
        end
        T_TXT_NAMEW: begin
            tst <= T_TXT_NAMER;
        end
        T_TXT_NAMER: begin
            name <= vram_rdata;
            tst <= T_TXT_PIX;
        end
        T_TXT_PIX: begin
            // char gfx: 8x8x4 = 16 words; word = 4 pixels (packed msb)
            vram_addr <= text_bank_base + {name[8:0], 4'b0} + {text_srcy[2:0], text_srcx[2]} ;
            tst <= T_TXT_PIXW;
        end
        T_TXT_PIXW: begin
            tst <= T_TXT_PIXR;
        end
        T_TXT_PIXR: begin
            row[15:0] <= vram_rdata;
            tst <= T_TXT_EMIT;
        end
        T_TXT_EMIT: begin
            logic [1:0] col;
            logic [3:0] pen;
            col = text_srcx[1:0];
            case (col)
                2'd0: pen = row[7:4];
                2'd1: pen = row[3:0];
                2'd2: pen = row[15:12];
                default: pen = row[11:8];
            endcase
            lb_we    <= 1'b1;
            lb_layer <= 3'd0;
            lb_x     <= x[8:0];
            lb_pix   <= {|pen, 2'b00, name[15:9], pen};
            if (x == hpix-1) begin
                lay <= 5;
                tst <= T_LSTART;
            end
            else begin
                x <= x + 1'd1;
                if (x[1:0] == 2'b11) begin
                    if (x[2:0] == 3'b111) tst <= T_TXT_NAME;
                    else                  tst <= T_TXT_PIX;
                end
            end
        end

        // ---- bitmap layer (MAME update_bitmap) ----
        //   4bpp: 512x512, row = 128 words, y wraps 9 bits
        //   8bpp: 512x256, row = 256 words, y wraps 8 bits
        //   color = (reg 0x1FF8C << 4) masked above the pen bits
        T_BMP: begin
            logic [8:0] bx, by;
            logic [15:0] addr;
            bx = x[8:0] + r1ff88[8:0];
            by = line + r1ff8a[8:0];
            addr = bitmap_addr(bx, by, r1ff00[11]);
            vram_addr <= addr;
            bmp_req_addr <= addr;
            bmp_req_bpp8 <= r1ff00[11];
            bmp_word_valid <= 1'b0;
            tst <= T_BMPW;
        end
        T_BMPW: begin
            tst <= T_BMPR;
        end
        T_BMPR: begin
            bmp_word <= vram_rdata;
            bmp_word_addr <= bmp_req_addr;
            bmp_word_bpp8 <= bmp_req_bpp8;
            bmp_word_valid <= 1'b1;
            tst <= T_BMP_EMIT;
        end
        T_BMP_EMIT: begin
            logic [8:0] bx;
            logic [8:0] by;
            logic [8:0] next_bx;
            logic [15:0] want_addr, next_addr;
            logic [7:0] pen8;
            bx = x[8:0] + r1ff88[8:0];
            by = line + r1ff8a[8:0];
            want_addr = bitmap_addr(bx, by, r1ff00[11]);
            if (!bmp_word_valid || bmp_word_addr != want_addr ||
                bmp_word_bpp8 != r1ff00[11]) begin
                // Fully general fallback for a word/mode miss. Keep x fixed
                // until the correctly tagged synchronous read completes.
                vram_addr <= want_addr;
                bmp_req_addr <= want_addr;
                bmp_req_bpp8 <= r1ff00[11];
                bmp_word_valid <= 1'b0;
                tst <= T_BMPW;
            end
            else begin
                if (r1ff00[11])
                    pen8 = bx[0] ? bmp_word[15:8] : bmp_word[7:0];
                else
                    pen8 = {4'b0, bmp_word[{bx[1:0],2'b00} +: 4]};
                lb_we    <= 1'b1;
                lb_layer <= 3'd5;
                lb_x     <= x[8:0];
                // bitmap clip: $1FF02 bit15 enable / bit10 clip-out, rect 4 only
                if (r1ff00[11])
                    lb_pix <= {(|pen8) && clip_vis(x[8:0], line,
                                  r1ff02[15], r1ff02[10], 5'b10000),
                               r1ff8c[8:4], pen8};               // 8bpp
                else
                    lb_pix <= {(|pen8[3:0]) && clip_vis(x[8:0], line,
                                  r1ff02[15], r1ff02[10], 5'b10000),
                               r1ff8c[8:0], pen8[3:0]};          // 4bpp
                if (x == hpix-1) begin
                    bmp_word_valid <= 1'b0;
                    tst <= T_DONE;
                end
                else begin
                    x <= x + 1'd1;
                    // Stay in the cached word for all remaining lanes. At
                    // the final lane, launch the next word immediately so
                    // the old address-setup state does not add a bubble.
                    if ((r1ff00[11] && bx[0]) ||
                        (!r1ff00[11] && bx[1:0] == 2'b11)) begin
                        next_bx = bx + 1'd1;
                        next_addr = bitmap_addr(next_bx, by, r1ff00[11]);
                        vram_addr <= next_addr;
                        bmp_req_addr <= next_addr;
                        bmp_req_bpp8 <= r1ff00[11];
                        bmp_word_valid <= 1'b0;
                        tst <= T_BMPW;
                    end
                end
            end
        end

        T_DONE: begin
            line_done <= 1'b1;
            tst <= T_IDLE;
        end
        default: tst <= T_IDLE;
        endcase
    end
end

endmodule

//============================================================================
// Shared unsigned tilemap zoom divider.
//
// Computes (0x200 << 20)/yden followed by (0x200 << 20)/xden with one
// 30-bit restoring datapath.  Each quotient takes 30 clocks and truncates
// toward zero exactly like MAME's unsigned integer division.
//============================================================================
module s32_tilemap_scale_div (
    input             clk,
    input             rst,
    input             start,
    input      [11:0] yden,
    input      [11:0] xden,
    output reg        busy,
    output reg        done,
    output reg [22:0] yquot,
    output reg [22:0] xquot
);

reg [29:0] shift_r;
reg [12:0] rem_r;
reg [11:0] den_r;
reg [11:0] xden_r;
reg  [4:0] bit_count;
reg        axis_x;

wire [12:0] trial_raw = {rem_r[11:0], shift_r[29]};
wire        trial_ge = trial_raw >= {1'b0, den_r};
wire [12:0] trial_next = trial_ge ? trial_raw - {1'b0, den_r}
                                         : trial_raw;
wire [29:0] shift_next = {shift_r[28:0], trial_ge};

always @(posedge clk) begin
    if (rst) begin
        shift_r <= 0;
        rem_r <= 0;
        den_r <= 0;
        xden_r <= 0;
        bit_count <= 0;
        axis_x <= 0;
        busy <= 0;
        done <= 0;
        yquot <= 0;
        xquot <= 0;
    end
    else begin
        done <= 1'b0;
        if (start && !busy) begin
            shift_r <= 30'h20000000;
            rem_r <= 0;
            den_r <= yden;
            xden_r <= xden;
            bit_count <= 0;
            axis_x <= 1'b0;
            busy <= 1'b1;
        end
        else if (busy) begin
            shift_r <= shift_next;
            rem_r <= trial_next;
            if (bit_count == 5'd29) begin
                if (!axis_x) begin
                    yquot <= shift_next[22:0];
                    shift_r <= 30'h20000000;
                    rem_r <= 0;
                    den_r <= xden_r;
                    bit_count <= 0;
                    axis_x <= 1'b1;
                end
                else begin
                    xquot <= shift_next[22:0];
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
            else bit_count <= bit_count + 1'd1;
        end
    end
end

endmodule

//============================================================================
// Scanline launch guard for the tile renderer.
//
// line_kick crosses from the clk_sys CRT timing into clk_ram and therefore
// remains high for more than one clk_ram edge. Convert it to one event, keep
// the target line/buffer immutable until the renderer completes, and drop
// rather than corrupt the active render with any missed line deadline.
// A completion pulse and a new boundary may coincide: the old job is then
// complete and the new one is accepted without an idle bubble.
//============================================================================
module s32_tile_line_scheduler (
    input             clk,
    input             rst,
    input             line_kick,
    input       [8:0] next_line,
    input             line_done,
    output reg        line_start,
    output reg  [8:0] render_line,
    output reg        lb_bank,
    output reg        busy
);

reg kick_active;

always @(posedge clk) begin
    if (rst) begin
        line_start     <= 1'b0;
        render_line    <= 9'd0;
        lb_bank        <= 1'b0;
        busy           <= 1'b0;
        kick_active    <= 1'b0;
    end
    else begin
        line_start <= 1'b0;
        // A completed render releases the scheduler. The acceptance below
        // has later assignment priority so done+kick immediately launches
        // the next line while still producing exactly one start pulse.
        if (line_done)
            busy <= 1'b0;

        if (!line_kick)
            kick_active <= 1'b0;
        else if (!kick_active) begin
            kick_active <= 1'b1;
            if (!busy || line_done) begin
                render_line <= next_line;
                lb_bank     <= next_line[0];
                line_start  <= 1'b1;
                busy        <= 1'b1;
            end
        end
    end
end

endmodule
