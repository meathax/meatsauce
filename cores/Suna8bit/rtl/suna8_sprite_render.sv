// Sprite scan-out state machine: walks the 192 sprite descriptor slots at
// sprite RAM 0x1d00-0x1fff (fixed range per suna8_v.cpp's screen_update,
// draw_sprites(...,0x1d00,0x2000,0)), decodes each via suna8_sprite_decode,
// fetches its tiles from sprite RAM and pixels from gfx ROM via
// suna8_gfx_layout, and writes opaque pixels into the framebuffer.
//
// Multisprite X-chaining (MAME's running `mx` counter across consecutive
// multisprite entries within one draw_sprites() call/chip pass) is
// implemented via the `mx`/`eff_sprite_x` registers below.
//
// Hardhead/SRanger text-sprite-list redirects are rendered through the same
// tile/plane pipeline from the 0x1980/0x19c0 lists.  The MAME priority bitmap
// fill used to mask rare sprite/HUD overlaps is intentionally not modelled;
// opaque text pixels themselves are preserved.
//
// The framebuffer grants producer ownership until a complete descriptor pass
// is finished, then parks the renderer until the next vblank swap/clear.
//
// Sparkman's second sprite chip (suna8_v.cpp's screen_update(): a second
// draw_sprites(...,which=1) call, gated on `m_gfxdecode->gfx(1)` existing
// -- only true for sparkman's gfx_suna8_x2 GFXDECODE table, confirmed by
// grep against every other profile's plain single-chip gfx_suna8 table)
// is rendered by walking the same 192 slots a second time with `chip=1`:
// suna8_v.cpp's draw_sprites offsets the *entire* sprite RAM view by
// `which*0x4000` (`spriteram = m_banked_spriteram + which*0x2000*2`), so
// chip 1's descriptor table lives at 0x5D00-0x5FFF, not 0x1D00-0x1FFF --
// and reads gfx ROM data from the "gfx2" media region instead of "gfx1"
// (GFXDECODE_ENTRY("gfx2",...) at index 1 in gfx_suna8_x2).
module suna8_sprite_render
(
    input  logic clk,
    input  logic reset,
    input  logic active,

    input  logic [2:0] profile,
    input  logic flip_screen,
    input  logic [2:0] sprite_bank,
    input  logic palette_bank,
    input  logic [2:0] gfx_bank_latch,

    output logic [15:0] sprite_rd_addr,
    input  logic [7:0] sprite_rd_data,

    output logic [19:0] gfx1_addr,
    input  logic [7:0] gfx1_q,
    input  logic [63:0] gfx1_line_q,
    input  logic gfx1_ready,
    output logic [19:0] gfx2_addr,
    input  logic [7:0] gfx2_q,
    input  logic [63:0] gfx2_line_q,
    input  logic gfx2_ready,

    output logic fb_wr_en,
    output logic [7:0] fb_wr_x,
    output logic [7:0] fb_wr_y,
    output logic [8:0] fb_wr_data,
    // Hard Head/SRanger's first text list marks a two-row high-priority
    // strip in MAME's priority bitmap.  Emit the row tag independently of
    // pixel opacity so transparent text pens still protect the strip.
    output logic fb_priority_en,
    output logic [7:0] fb_priority_y,
    output logic render_done
);

    import suna8_profile_pkg::*;

    typedef enum logic [3:0] {
        ST_DESC_Y, ST_DESC_CODE, ST_DESC_X, ST_DESC_BANK, ST_DECODE,
        ST_TILE_LO, ST_TILE_HI,
        ST_PLANE0, ST_PLANE1, ST_PLANE2, ST_PLANE3,
        ST_WRITE, ST_NEXT_TILE, ST_ADVANCE, ST_TEXT_ADVANCE,
        // suna8_sprite_ram.sv's renderer-facing read is now registered (one
        // cycle of address-to-data latency) rather than combinational, so
        // Quartus can map it onto Cyclone V M10K block RAM instead of
        // falling back to one register per bit (see suna8_sprite_ram.sv for
        // the full rationale -- this array alone overflowed the device's
        // register budget). Every sprite_rd_data consumer below now goes
        // through this one-cycle bubble: the read state sets sprite_rd_addr
        // and records which capture to perform in ram_wait_from, then
        // ST_RAM_WAIT performs that capture once the registered data is
        // valid and advances to what used to be that read state's direct
        // next state.
        ST_RAM_WAIT
    } state_t;

    state_t state;
    state_t ram_wait_from;
    // 192 descriptor slots x 4 bytes = 768 (0x1d00-0x1fff) needs 10 bits;
    // 8 bits would silently wrap after only 64 slots.
    logic [9:0] slot_index;
    // Which sprite chip's 192-slot table is currently being walked. Only
    // ever toggles for sparkman (PROFILE_SPARKMAN); every other profile
    // stays on chip 0 forever.
    logic chip;
    logic [15:0] chip_base;
    logic text_mode;
    logic [15:0] text_base;
    logic [6:0] text_offset;
    logic [7:0] text_ypos;
    logic [5:0] tile_x, tile_y;
    logic [2:0] pixel_x, pixel_y;

    // Multisprite X-chaining: suna8_v.cpp's draw_sprites() keeps a running
    // `mx` accumulator across the whole 192-slot walk of one draw_sprites()
    // call (`int mx=0` local, reset each call). `if (multisprite) { mx +=
    // dimx*8; x = mx; } else mx = x;` -- a "multisprite" entry continues
    // the previous entry's X run rather than using its own descriptor X.
    // One draw_sprites() call == one full slot_index wrap in this FSM (a
    // fresh call per sparkman chip pass too), so mx resets there.
    // Signed so a chained run that has gone negative (off the left edge)
    // stays correctly negative rather than wrapping to a huge unsigned
    // value.
    logic signed [11:0] mx;
    // Latched once per descriptor (first ST_DECODE visit, tile_x==tile_y==0)
    // from either `mx` (multisprite chained) or the descriptor's own signed
    // X (sprite_x, sign bit = descriptor_bank[6]) -- held constant for the
    // rest of that descriptor's tile grid walk.
    logic signed [11:0] eff_sprite_x;

    logic [7:0] desc_y, desc_code, desc_x, desc_bank;
    logic [7:0] tile_data, tile_attr;
    logic [3:0] pixel_index;

    logic descriptor_valid;
    logic [5:0] dim_x, dim_y;
    logic [8:0] sprite_x;
    logic [7:0] sprite_y;
    logic [15:0] tile_ram_addr;
    logic [15:0] gfx_tile_code;
    logic [20:0] gfx_byte_base;
    logic [4:0] palette_group;
    logic tile_flip_x, tile_flip_y;
    logic [3:0] transparent_pen;
    logic multisprite;
    logic [5:0] text_src_x, text_src_y;
    logic [2:0] text_src_page;
    logic signed [9:0] text_row_base;
    logic signed [11:0] text_x_signed;
    logic [7:0] text_y_base;
    logic signed [11:0] text_x_eff;
    logic [7:0] text_y_eff;
    logic [15:0] tile_ram_addr_eff;
    logic [15:0] gfx_tile_code_eff;
    logic [4:0] palette_group_eff;
    logic tile_flip_x_eff, tile_flip_y_eff;
    logic [3:0] transparent_pen_eff;

    suna8_sprite_decode u_decode
    (
        .profile(profile),
        .flip_screen(flip_screen),
        .sprite_bank(sprite_bank),
        .sprite_chip(chip),
        .gfx_bank_latch(gfx_bank_latch),
        .palette_bank(palette_bank),
        .descriptor_y(desc_y),
        .descriptor_code(desc_code),
        .descriptor_x(desc_x),
        .descriptor_bank(desc_bank),
        .tile_x(tile_x),
        .tile_y(tile_y),
        .tile_data(tile_data),
        .tile_attr(tile_attr),
        .descriptor_valid(descriptor_valid),
        .dim_x(dim_x),
        .dim_y(dim_y),
        .sprite_x(sprite_x),
        .sprite_y(sprite_y),
        .tile_ram_addr(tile_ram_addr),
        .gfx_tile_code(gfx_tile_code),
        .gfx_byte_base(gfx_byte_base),
        .palette_group(palette_group),
        .tile_flip_x(tile_flip_x),
        .tile_flip_y(tile_flip_y),
        .transparent_pen(transparent_pen),
        .multisprite(multisprite)
    );

    logic [2:0] gfx_px, gfx_py;
    // Each logical 8-pixel row occupies two bytes per plane.  Cache those
    // eight bytes once, then emit all eight pixels locally.
    logic row_byte_sel;
    logic [2:0] gfx_fetch_px;
    // One held cache line per plane pair. In MAME's layout_8x8x4 a tile's
    // rows 0-3 of one plane pair are exactly one aligned 8-byte line and
    // rows 4-7 the next, so a tile needs four line fetches, not thirty-two
    // byte fetches. The tag includes the chip because gfx1 and gfx2 are
    // different address spaces. Both row halves come out of the held line
    // in one clock: the half-1 byte is always the half-0 byte plus one
    // (x_offset for pixel 4 is bit 8..11 of the same 16-bit row word), and
    // the half-0 byte index is even, so the pair never straddles a line.
    logic [63:0] line_hold [0:1];
    logic [18:0] line_tag [0:1];
    logic line_valid [0:1];
    logic [18:0] line_want [0:1];
    logic line_hit [0:1];
    logic [2:0] line_byte0 [0:1];
    logic [63:0] line_in;
    logic line_in_ready;
    logic row_transparent;
    logic [20:0] prefetch_addr;
    logic [22:0] plane_bit_addr [0:3];
    logic [20:0] plane_byte_addr [0:3];
    logic [2:0] plane_bit_in_byte [0:3];
    logic [22:0] fetch_plane_bit_addr [0:3];
    logic [20:0] fetch_plane_byte_addr [0:3];
    logic [2:0] fetch_plane_bit_in_byte [0:3];
    logic [1:0] plane_index;

    // Text sprites use the fixed 0x1980/0x19c0 descriptor lists and address
    // the same 32x32 tile pages as normal sprites, but their source row is
    // relative to the marker Y position rather than descriptor Y.  Keep the
    // common tile/gfx/pixel pipeline and substitute only these derived fields.
    always_comb begin
        text_row_base = $signed({2'b00, (desc_y & 8'hf8)}) -
                        $signed({2'b00, (text_ypos & 8'hf8)}) - 10'sd16;
        text_src_x = ({1'b0, desc_code[3:0], 1'b0} + tile_x) & 6'h1f;
        // MAME wraps the text-list source row in the 32-row page after the
        // marker-relative subtraction; preserve that mask for negative
        // offsets instead of allowing a six-bit row to select page 1.
        text_src_y = ((text_row_base >>> 3) + tile_y) & 6'h1f;
        text_src_page = desc_code[5:4];
        text_x_signed = $signed({4'd0, desc_x}) -
                        (desc_bank[6] ? 12'sh100 : 12'sd0);
        text_y_base = (8'hf0 - text_ypos) & 8'hff;
        // Flip Screen is applied per tile in px_screen_*_wide below (MAME
        // draw_text_sprites 441-448 flips sx/sy after adding tx*8/ty*8), so
        // the text origin is no longer pre-flipped here.
        text_x_eff = text_x_signed;
        text_y_eff = text_y_base;
        tile_ram_addr_eff = text_mode
            ? ((({13'd0, text_src_page} << 10) +
                ({11'd0, text_src_x} << 5) + {10'd0, text_src_y}) << 1)
            : tile_ram_addr;
        gfx_tile_code_eff = text_mode
            ? ({8'd0, tile_data} + ({14'd0, tile_attr[1:0]} << 8) +
               ({10'd0, desc_bank[5:0]} << 10))
            : gfx_tile_code;
        palette_group_eff = text_mode ? {1'b0, tile_attr[5:2]} : palette_group;
        tile_flip_x_eff = text_mode ? (tile_attr[6] ^ flip_screen) : tile_flip_x;
        tile_flip_y_eff = text_mode ? (tile_attr[7] ^ flip_screen) : tile_flip_y;
        transparent_pen_eff = transparent_pen;
    end

    assign gfx_px = tile_flip_x_eff ? (3'd7 - pixel_x) : pixel_x;
    assign gfx_py = tile_flip_y_eff ? (3'd7 - pixel_y) : pixel_y;
    assign gfx_fetch_px = 3'd0;
    assign line_in = chip ? gfx2_line_q : gfx1_line_q;
    assign line_in_ready = chip ? gfx2_ready : gfx1_ready;
    always_comb begin
        for (int pr = 0; pr < 2; pr++) begin
            line_want[pr] = {chip, fetch_plane_byte_addr[pr * 2][20:3]};
            line_hit[pr] = line_valid[pr] && (line_tag[pr] == line_want[pr]);
            line_byte0[pr] = fetch_plane_byte_addr[pr * 2][2:0];
        end
        // Every plane bit 1 is the transparent pen 0xF (suna8_sprite_decode
        // sets it for every profile). After the ROM inversion a byte of all
        // ones means all four of its pixels are transparent in both planes
        // it carries, so four such bytes are a whole transparent row.
        row_transparent = (&plane_byte[0][0]) && (&plane_byte[0][1]) &&
                          (&plane_byte[2][0]) && (&plane_byte[2][1]);
        if (state == ST_WRITE && !pixel_y[2])
            prefetch_addr = pixel_x[0]
                ? {fetch_plane_byte_addr[2][20:3] ^ 18'd1, 3'b000}
                : {fetch_plane_byte_addr[0][20:3] ^ 18'd1, 3'b000};
        else
            prefetch_addr = {fetch_plane_byte_addr[0][20:3], 3'b000};
    end

`ifdef VERILATOR
    // The fetch pairing above is only valid while planes 0/1 and 2/3 really
    // do share a byte. Check it rather than trust it: if a profile's layout
    // ever separates them, this fires instead of silently rendering plane 1
    // from plane 0's byte.
    always_ff @(posedge clk) begin
        if (!reset && active) begin
            if (fetch_plane_byte_addr[0] !== fetch_plane_byte_addr[1])
                $fatal(1, "SUNA8_LAYOUT_PAIR_BROKEN planes 0/1 differ: %0h vs %0h",
                       fetch_plane_byte_addr[0], fetch_plane_byte_addr[1]);
            if (fetch_plane_byte_addr[2] !== fetch_plane_byte_addr[3])
                $fatal(1, "SUNA8_LAYOUT_PAIR_BROKEN planes 2/3 differ: %0h vs %0h",
                       fetch_plane_byte_addr[2], fetch_plane_byte_addr[3]);
        end
    end
`endif

    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : g_plane
            suna8_gfx_layout u_layout
            (
                .profile(profile),
                .tile_code(gfx_tile_code_eff),
                .plane(p[1:0]),
                .pixel_x(gfx_px),
                .pixel_y(gfx_py),
                .bit_address(plane_bit_addr[p]),
                .byte_address(plane_byte_addr[p]),
                .bit_in_byte(plane_bit_in_byte[p])
            );

            suna8_gfx_layout u_fetch_layout
            (
                .profile(profile),
                .tile_code(gfx_tile_code_eff),
                .plane(p[1:0]),
                .pixel_x(gfx_fetch_px),
                .pixel_y(gfx_py),
                .bit_address(fetch_plane_bit_addr[p]),
                .byte_address(fetch_plane_byte_addr[p]),
                .bit_in_byte(fetch_plane_bit_in_byte[p])
            );
        end
    endgenerate

    logic [7:0] plane_byte [0:3][0:1];
    logic [3:0] plane_bit;
    integer pb;
    always_comb begin
        for (pb = 0; pb < 4; pb = pb + 1)
            // Select the cached byte using the effective (flip-adjusted)
            // pixel coordinate.  The two cached bytes are the same physical
            // row for either orientation; only their output order changes.
            plane_bit[pb] = plane_byte[pb][gfx_px[2]][plane_bit_in_byte[pb]];
    end
    // Plane 0 of MAME's layout_8x8x4 (RGN_FRAC(1,2)+0, the upper ROM half)
    // is the pen's MOST significant bit, not its least: drawgfx.cpp's
    // decoder starts with `planebit = 1 << (planes - 1)` for plane 0 and
    // shifts right per plane (emu/drawgfx.cpp:298). Weighting plane p as
    // pen bit p bit-reversed every pen (1<->8, 2<->4, 5<->10); the
    // transparent pen 0xF is symmetric under that reversal, which is why
    // every sprite kept its exact shape while its colours were wrong
    // (Star Fighter title, R045/R056; Spark Man DIP screen, R026).
    assign pixel_index = {plane_bit[0], plane_bit[1], plane_bit[2], plane_bit[3]};

    always_comb begin
        chip_base = chip ? 16'h4000 : 16'h0000;

        gfx1_addr = 20'd0;
        gfx2_addr = 20'd0;
        plane_index = 2'd0;
        case (state)
            ST_PLANE1: plane_index = 2'd1;
            ST_PLANE2: plane_index = 2'd2;
            ST_PLANE3: plane_index = 2'd3;
            default:   plane_index = 2'd0;
        endcase
        // Outside the two fetch states the address bus used to sit at 0,
        // which the cache treats like any other request: a miss on line 0
        // started a fill nobody wanted and evicted a way the renderer was
        // about to need. Present something useful instead. While the
        // first four rows of a tile are being written, the line for rows
        // 4-7 of each plane pair is certain to be needed next -- it is the
        // sibling line, current line index XOR 1, because a plane pair's
        // 16 bytes for a tile start on a 16-byte boundary -- so its fill
        // runs under the writes and the fetch state finds it already in
        // the cache. In every other idle state the current line is
        // presented, a guaranteed hit that starts nothing.
        case (state)
            ST_PLANE0, ST_PLANE1, ST_PLANE2, ST_PLANE3: begin
                if (chip)
                    gfx2_addr = fetch_plane_byte_addr[plane_index][19:0];
                else
                    gfx1_addr = fetch_plane_byte_addr[plane_index][19:0];
            end
            default: begin
                if (chip)
                    gfx2_addr = prefetch_addr[19:0];
                else
                    gfx1_addr = prefetch_addr[19:0];
            end
        endcase
        sprite_rd_addr = 16'd0;
        case (state)
            ST_DESC_Y:    sprite_rd_addr = text_mode ? (text_base + text_offset)
                                                       : (chip_base + 16'h1d00 + {6'd0, slot_index});
            ST_DESC_CODE: sprite_rd_addr = text_mode ? (text_base + text_offset + 16'd1)
                                                       : (chip_base + 16'h1d00 + {6'd0, slot_index} + 16'd1);
            ST_DESC_X:    sprite_rd_addr = text_mode ? (text_base + text_offset + 16'd2)
                                                       : (chip_base + 16'h1d00 + {6'd0, slot_index} + 16'd2);
            ST_DESC_BANK: sprite_rd_addr = text_mode ? (text_base + text_offset + 16'd3)
                                                       : (chip_base + 16'h1d00 + {6'd0, slot_index} + 16'd3);
            ST_TILE_LO:   sprite_rd_addr = tile_ram_addr_eff;
            ST_TILE_HI:   sprite_rd_addr = tile_ram_addr_eff + 16'd1;
            default: sprite_rd_addr = 16'd0;
        endcase
    end

    logic [11:0] tile_x_px;
    logic [11:0] tile_y_px;
    logic signed [12:0] px_screen_x_wide;
    logic [11:0] px_screen_y_wide;
    logic [11:0] px_screen_y_active;
    logic [8:0] px_screen_x9;
    logic [7:0] px_screen_y8;
    logic in_bounds;

    assign tile_x_px = {6'd0, tile_x} << 3;
    assign tile_y_px = {6'd0, tile_y} << 3;
    // eff_sprite_x is already the correctly-signed X (either the descriptor's
    // own sign-extended X or the chained mx run); no zero-extension here --
    // zero-extending would turn a legitimately negative (off-left-edge) X
    // into a large positive value that never satisfies in_bounds, silently
    // hiding every sprite whose descriptor_bank[6] "X sign" bit is set.
    // Unflipped tile origin: descriptor origin plus tile offset, exactly
    // MAME's sx = x + tx*8 and sy = (y + ty*8) & 0xff (suna8_v.cpp:346-347,
    // draw_text_sprites 441-442).
    logic signed [12:0] tile_origin_x;
    logic [11:0] tile_origin_y;
    logic [7:0] tile_origin_y8;
    assign tile_origin_x = {eff_sprite_x[11], eff_sprite_x} + $signed({1'b0, tile_x_px});
    assign tile_origin_y = text_mode ? ({4'd0, text_y_eff} + tile_y_px)
                                     : ({4'd0, sprite_y} + tile_y_px);
    assign tile_origin_y8 = tile_origin_y[7:0];
    // Flip Screen mirrors each 8x8 tile's position with the constants MAME
    // derives from the full raster: max_x = width-8 = 376, max_y =
    // height-8 = 256 (suna8_v.cpp:179-180, 353-357, 444-448), applied to
    // the tile origin after the offset and, for Y, after the & 0xff wrap.
    // With a 256-wide visible area this pushes everything whose unflipped
    // X is below 121 off the right edge, which is exactly what MAME shows
    // for the flipped self-test screen (R052: only a bottom-right fragment
    // survives) and is the reference this core is checked against. This
    // is MAME's model (evidence tier 3), not PCB-measured behaviour: a
    // cocktail-mode board capture may still show that the real hardware
    // mirrors within the visible 256x224 window instead (INFERRED, W25).
    // Within-tile mirroring is handled by tile_flip_*_eff.
    assign px_screen_x_wide = (flip_screen ? (13'sd376 - tile_origin_x) : tile_origin_x)
                              + $signed({10'd0, pixel_x});
    // suna8_v.cpp draws each tile at `sy = (y + ty*8) & 0xff` -- the tile
    // origin is wrapped mod 256 BEFORE the pixel row is added and before
    // flip_screen's mirror is applied, not after. tile_origin_y8 already
    // holds that wrapped value ([7:0] of the unwrapped 12-bit sum is
    // exactly `& 0xff`); the unflipped branch below used the raw,
    // un-wrapped 12-bit tile_origin_y instead, so a full-height 32-tile
    // column sprite (which always spans the whole 0-255 range once
    // wrapped, regardless of its Y offset -- 32*8=256=2^8) only wrapped
    // correctly at zero offset. The first vertical scroll in the game
    // gives the column a nonzero Y offset for the first time; every tile
    // whose origin then exceeds 255 stopped wrapping back into view and
    // failed the [16,240) bounds check outright, taking the whole
    // background with it. flip_screen already used tile_origin_y8
    // correctly (256 - tile_origin_y8); the unflipped branch now matches.
    assign px_screen_y_wide = (flip_screen ? (12'd256 - {4'd0, tile_origin_y8}) : {4'd0, tile_origin_y8})
                              + {9'd0, pixel_y};
    assign px_screen_x9 = px_screen_x_wide[8:0];
    // px_screen_y_wide is in suna8_v.cpp's own sy coordinate space -- the
    // same raw space MAME's screen visarea uses (set_visarea(0,255,0+16,
    // 255-16) in every suna8.cpp machine_config: visible Y is [16,240), NOT
    // [0,224)). Clipping at "< 224" here (the previous check) instead of
    // against the real [16,240) visarea let sprites whose true Y put them
    // 0-15 lines above the visible area wrongly show up shifted 16 lines
    // down (in the framebuffer's row 0-15), while genuinely visible content
    // in the bottom 16 rows (Y 224-239) never got drawn at all -- and
    // suna8_core.sv's raw-vcount framebuffer read (still un-shifted) then
    // read that misplaced content back 16 rows removed from where the CRT
    // beam actually was, on top of the write-side clipping already being
    // wrong. px_screen_y_active re-bases the confirmed-visible range down
    // to 0-223 (matching the framebuffer's row-storage convention) only
    // after the correct [16,240) bounds check below has passed.
    assign px_screen_y_active = px_screen_y_wide - 12'd16;
    assign px_screen_y8 = px_screen_y_active[7:0];
    assign in_bounds = (px_screen_x_wide >= 13'sd0) && (px_screen_x_wide < 13'sd256) &&
                        (px_screen_y_wide >= 12'd16) && (px_screen_y_wide < 12'd240);

    // Whole-tile visibility, evaluated once before the tile's plane fetches
    // instead of per pixel afterwards. Both mappings above are monotonically
    // increasing in pixel_x and pixel_y -- unflipped adds the pixel offset,
    // flipped subtracts the tile origin from a constant and then adds it --
    // so an 8x8 tile occupies exactly [base, base+7] on each axis and the
    // whole tile is invisible when that span misses the visible window.
    // Skipping such a tile removes only work whose writes in_bounds already
    // suppressed: eight gfx-ROM byte fetches per row for eight rows, plus the
    // 64 ST_WRITE cycles. Brick Zone declares multi-sprites far larger than
    // the 256x224 window, so most of its list is off-screen and the renderer
    // was spending six frames per pass fetching tiles it could never draw.
    logic signed [12:0] tile_base_x;
    logic [11:0] tile_base_y;
    logic tile_visible;
    assign tile_base_x = flip_screen ? (13'sd376 - tile_origin_x) : tile_origin_x;
    // Same wrapped-origin fix as px_screen_y_wide above: this pre-check
    // must agree with the pixel math it is gating, or a wrapped-visible
    // tile gets skipped here before ST_WRITE ever runs.
    assign tile_base_y = flip_screen ? (12'd256 - {4'd0, tile_origin_y8}) : {4'd0, tile_origin_y8};
    assign tile_visible = ((tile_base_x + 13'sd7) >= 13'sd0) && (tile_base_x < 13'sd256) &&
                          ((tile_base_y + 12'd7) >= 12'd16) && (tile_base_y < 12'd240);
`ifdef VERILATOR
    // Sim-only falsification of the whole-tile predicate. The renderer draws
    // every tile as before; this only reports a tile the predicate rejected
    // that then wrote a visible pixel, which is precisely the case where
    // acting on the predicate would drop content. Enabled with +SKIPPROBE.
    logic skip_probe_enable;
    logic [31:0] skip_probe_count;
    logic tile_visible_latched;
    initial skip_probe_enable = $test$plusargs("SKIPPROBE");
    initial skip_probe_count = 32'd0;
`endif

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= ST_DESC_Y;
            ram_wait_from <= ST_DESC_Y;
            slot_index <= 10'd0;
            chip <= 1'b0;
            text_mode <= 1'b0;
            text_offset <= 7'd0;
            tile_x <= 6'd0;
            tile_y <= 6'd0;
            pixel_x <= 3'd0;
            pixel_y <= 3'd0;
            row_byte_sel <= 1'b0;
            fb_wr_en <= 1'b0;
            fb_priority_en <= 1'b0;
            mx <= 12'sd0;
            render_done <= 1'b0;
            line_valid[0] <= 1'b0;
            line_valid[1] <= 1'b0;
        end else if (!active) begin
            // The framebuffer owns the producer/back-bank handshake.  When
            // a completed pass is parked or the back bank is being cleared,
            // restart the descriptor walk only after it grants ownership
            // again; no writes may leak into the displayed bank.
            state <= ST_DESC_Y;
            ram_wait_from <= ST_DESC_Y;
            slot_index <= 10'd0;
            chip <= 1'b0;
            text_mode <= 1'b0;
            text_base <= 16'h1980;
            text_offset <= 7'd0;
            text_ypos <= 8'd0;
            tile_x <= 6'd0;
            tile_y <= 6'd0;
            pixel_x <= 3'd0;
            pixel_y <= 3'd0;
            row_byte_sel <= 1'b0;
            fb_wr_en <= 1'b0;
            fb_priority_en <= 1'b0;
            mx <= 12'sd0;
            render_done <= 1'b0;
            line_valid[0] <= 1'b0;
            line_valid[1] <= 1'b0;
        end else begin
            fb_wr_en <= 1'b0;
            fb_priority_en <= 1'b0;
            render_done <= 1'b0;
            case (state)
                ST_DESC_Y: begin ram_wait_from <= ST_DESC_Y; state <= ST_RAM_WAIT; end
                ST_DESC_CODE: begin ram_wait_from <= ST_DESC_CODE; state <= ST_RAM_WAIT; end
                ST_DESC_X: begin ram_wait_from <= ST_DESC_X; state <= ST_RAM_WAIT; end
                ST_DESC_BANK: begin ram_wait_from <= ST_DESC_BANK; state <= ST_RAM_WAIT; end
                ST_RAM_WAIT: begin
                    // sprite_rd_data now reflects the address set up by
                    // whichever read state we just left (ram_wait_from) --
                    // its own address was captured into suna8_sprite_ram's
                    // output register on the very transition into this
                    // state. Perform exactly the capture+advance that state
                    // used to do directly.
                    case (ram_wait_from)
                        ST_DESC_Y: begin desc_y <= sprite_rd_data; state <= ST_DESC_CODE; end
                        ST_DESC_CODE: begin desc_code <= sprite_rd_data; state <= ST_DESC_X; end
                        ST_DESC_X: begin desc_x <= sprite_rd_data; state <= ST_DESC_BANK; end
                        ST_DESC_BANK: begin
                            desc_bank <= sprite_rd_data;
                            tile_x <= 6'd0;
                            tile_y <= 6'd0;
                            state <= ST_DECODE;
                        end
                        ST_TILE_LO: begin tile_data <= sprite_rd_data; state <= ST_TILE_HI; end
                        ST_TILE_HI: begin
                            tile_attr <= sprite_rd_data;
                            pixel_x <= 3'd0;
                            pixel_y <= 3'd0;
                            row_byte_sel <= 1'b0;
                            // eff_sprite_x was latched back in ST_DECODE, so
                            // tile_origin_x is valid here; deciding any
                            // earlier would test a stale origin on the
                            // descriptor's first tile. A tile whose 8x8
                            // span misses the visible window writes nothing,
                            // so its plane fetches and 64 write cycles are
                            // skipped outright.
                            state <= tile_visible ? ST_PLANE0 : ST_NEXT_TILE;
`ifdef VERILATOR
                            tile_visible_latched <= tile_visible;
`endif
                        end
                        default: state <= ST_DESC_Y;
                    endcase
                end
                ST_DECODE: begin
                    if (tile_x == 6'd0 && tile_y == 6'd0) begin
                        // First (and only) visit to ST_DECODE for this
                        // descriptor -- ST_NEXT_TILE always increments
                        // tile_x/tile_y before looping back, so tile_x/
                        // tile_y are never both 0 again until the next
                        // descriptor. Latch this descriptor's effective X
                        // once, matching MAME evaluating `x`/`mx` once per
                        // sprite rather than per tile.
                        if (text_mode) begin
                            eff_sprite_x <= text_x_eff;
                        end else if (multisprite) begin
                            mx <= mx + $signed({6'd0, dim_x, 3'd0});
                            eff_sprite_x <= mx + $signed({6'd0, dim_x, 3'd0});
                        end else begin
                            mx <= {{3{sprite_x[8]}}, sprite_x};
                            eff_sprite_x <= {{3{sprite_x[8]}}, sprite_x};
                        end
                    end
                    if (text_mode) begin
                        if (desc_code[7] && tile_x < 6'd2 && tile_y < 6'd2)
                            state <= ST_TILE_LO;
                        else
                            state <= ST_TEXT_ADVANCE;
                    end else if (!descriptor_valid || !(tile_x < dim_x && tile_y < dim_y)) begin
                        // Older SunA boards redirect marker descriptors to a
                        // separate text list instead of drawing them as
                        // normal sprites.
                        if ((profile <= PROFILE_SRANGER) &&
                            (desc_bank[7:6] == 2'b11)) begin
                            text_mode <= 1'b1;
                            text_base <= slot_index[5] ? 16'h19c0 : 16'h1980;
                            text_offset <= 7'd0;
                            text_ypos <= desc_y;
                            tile_x <= 6'd0;
                            tile_y <= 6'd0;
                            state <= ST_DESC_Y;
                        end else begin
                            state <= ST_ADVANCE;
                        end
                    end else begin
                        state <= ST_TILE_LO;
                    end
                end
                ST_TILE_LO: begin ram_wait_from <= ST_TILE_LO; state <= ST_RAM_WAIT; end
                ST_TILE_HI: begin ram_wait_from <= ST_TILE_HI; state <= ST_RAM_WAIT; end
                // Every suna8 gfx1/gfx2 ROM_REGION in suna8.cpp is declared
                // ROMREGION_INVERT (a real inverting buffer on the sprite
                // ROM data path, not a MAME software-only convention -- the
                // MRA delivery format has no per-part transform, so an FPGA
                // core reproducing this PCB must invert the raw ROM bytes
                // itself). Missing this made the ROM's "blank" filler tile
                // (raw bits 0 -> intended post-invert value 0xF = MAME's
                // transpen() transparent pen) decode as opaque pixel 0
                // instead, rendering hardhea2's background-fill sprites as
                // solid color garbage instead of transparent (task #30,
                // verif/NOTES.md iteration 39).
                // Planes 0 and 1 live in the same byte, and so do planes 2
                // and 3: suna8_gfx_layout places plane 1 exactly four bits
                // after plane 0 (`plane_offset` = half_region_bits and
                // half_region_bits+4) and plane 3 four bits after plane 2,
                // while `x_offset` never exceeds 3 within a half-row. One
                // byte therefore carries four pixels of two planes, which is
                // what MAME's layout_8x8x4 describes. The renderer used to
                // issue a separate fetch per plane, so half of every row's
                // memory traffic asked for a byte it had just been given --
                // 64 fetch states per tile where 32 do, on the path that
                // decides whether a frame's sprite list fits in a frame.
                // The two states below fetch each shared byte once and latch
                // it into both of its planes; every consumer downstream is
                // unchanged, because each plane still selects its own bit
                // through its own `plane_bit_in_byte`.
                // Each state serves one plane pair for the whole row: both
                // row halves come from one held line in a single clock, and
                // memory is only asked when the row's line is not the one
                // already held (rows 0-3 then 4-7 of a tile, per pair).
                ST_PLANE0: begin
                    if (line_hit[0]) begin
                        plane_byte[0][0] <= ~line_hold[0][line_byte0[0] * 8 +: 8];
                        plane_byte[1][0] <= ~line_hold[0][line_byte0[0] * 8 +: 8];
                        plane_byte[0][1] <= ~line_hold[0][(line_byte0[0] + 3'd1) * 8 +: 8];
                        plane_byte[1][1] <= ~line_hold[0][(line_byte0[0] + 3'd1) * 8 +: 8];
                        state <= ST_PLANE2;
                    end else if (line_in_ready) begin
                        line_hold[0] <= line_in;
                        line_tag[0] <= line_want[0];
                        line_valid[0] <= 1'b1;
                        plane_byte[0][0] <= ~line_in[line_byte0[0] * 8 +: 8];
                        plane_byte[1][0] <= ~line_in[line_byte0[0] * 8 +: 8];
                        plane_byte[0][1] <= ~line_in[(line_byte0[0] + 3'd1) * 8 +: 8];
                        plane_byte[1][1] <= ~line_in[(line_byte0[0] + 3'd1) * 8 +: 8];
                        state <= ST_PLANE2;
                    end
                end
                ST_PLANE2: begin
                    if (line_hit[1]) begin
                        plane_byte[2][0] <= ~line_hold[1][line_byte0[1] * 8 +: 8];
                        plane_byte[3][0] <= ~line_hold[1][line_byte0[1] * 8 +: 8];
                        plane_byte[2][1] <= ~line_hold[1][(line_byte0[1] + 3'd1) * 8 +: 8];
                        plane_byte[3][1] <= ~line_hold[1][(line_byte0[1] + 3'd1) * 8 +: 8];
                        state <= ST_WRITE;
                    end else if (line_in_ready) begin
                        line_hold[1] <= line_in;
                        line_tag[1] <= line_want[1];
                        line_valid[1] <= 1'b1;
                        plane_byte[2][0] <= ~line_in[line_byte0[1] * 8 +: 8];
                        plane_byte[3][0] <= ~line_in[line_byte0[1] * 8 +: 8];
                        plane_byte[2][1] <= ~line_in[(line_byte0[1] + 3'd1) * 8 +: 8];
                        plane_byte[3][1] <= ~line_in[(line_byte0[1] + 3'd1) * 8 +: 8];
                        state <= ST_WRITE;
                    end
                end
                ST_WRITE: if (pixel_x == 3'd0 && !text_mode && row_transparent) begin
                    // Nothing in this row can write: every pixel is the
                    // transparent pen, and outside text mode no priority
                    // tag is emitted either. Advance exactly as the eighth
                    // pixel would have, without spending the eight clocks.
                    // Text-mode rows are never skipped: their priority tag
                    // is emitted for in-bounds transparent pixels too.
                    if (pixel_y == 3'd7) begin
                        pixel_y <= 3'd0;
                        state <= ST_NEXT_TILE;
                    end else begin
                        pixel_y <= pixel_y + 3'd1;
                        state <= ST_PLANE0;
                    end
                end else begin
                    if (text_mode && (text_base == 16'h1980) && in_bounds) begin
                        fb_priority_en <= 1'b1;
                        fb_priority_y <= px_screen_y8;
                    end
                    if (pixel_index != transparent_pen_eff && in_bounds) begin
`ifdef VERILATOR
                        if (!tile_visible_latched && skip_probe_enable &&
                            skip_probe_count < 32'd40) begin
                            skip_probe_count <= skip_probe_count + 32'd1;
                            $display("SKIPBUG slot=%0d tile=%0d,%0d dim=%0dx%0d px=%0d,%0d base=%0d,%0d origin_x=%0d origin_y=%0d screen=%0d,%0d text=%0b flip=%0b",
                                     slot_index, tile_x, tile_y, dim_x, dim_y, pixel_x, pixel_y,
                                     tile_base_x, tile_base_y, tile_origin_x, tile_origin_y,
                                     px_screen_x_wide, px_screen_y_wide, text_mode, flip_screen);
                        end
`endif
                        fb_wr_en <= 1'b1;
                        fb_wr_x <= px_screen_x9[7:0];
                        fb_wr_y <= px_screen_y8;
                        fb_wr_data <= {palette_group_eff, pixel_index};
                    end
                    if (pixel_x == 3'd7) begin
                        pixel_x <= 3'd0;
                        if (pixel_y == 3'd7) begin
                            pixel_y <= 3'd0;
                            state <= ST_NEXT_TILE;
                        end else begin
                            pixel_y <= pixel_y + 3'd1;
                            row_byte_sel <= 1'b0;
                            state <= ST_PLANE0;
                        end
                    end else begin
                        // The eight plane bytes cached by ST_PLANE0..3
                        // (both row halves, gfx_fetch_px = 0/4) already
                        // hold the whole 8-pixel row; only pixel_y and
                        // row_byte_sel select what is fetched. Re-running
                        // the fetch states for every pixel (the previous
                        // behaviour) cost 9 clocks per pixel, so a frame
                        // of eight 4x32-tile column sprites plus the 184
                        // blank 2x2 descriptors (~1,760 tiles, e.g. Hard
                        // Head 2's notice screen) needed ~1.0M clocks
                        // against the 406k available at 24 MHz. The
                        // renderer then straddled frames: no bank swap on
                        // the frames it missed (repeated pictures) and,
                        // because the game rewrites its sprite list every
                        // frame in an alternating order, columns read
                        // during the rewrite vanished (R069). Stay in
                        // ST_WRITE for the remaining pixels of the row.
                        pixel_x <= pixel_x + 3'd1;
                    end
                end
                ST_NEXT_TILE: begin
                    // Bug fix: this state was declared and transitioned
                    // into (from ST_WRITE once an 8x8 tile's 64 pixels are
                    // done) but had no case arm at all, so it silently fell
                    // to the `default: state <= ST_DESC_Y` below --
                    // restarting the descriptor fetch without ever
                    // incrementing tile_x/tile_y. Every sprite only ever
                    // rendered its first (0,0) tile, repeated forever, and
                    // slot_index never advanced past 0 -- no sprite past
                    // slot 0 has ever been drawn. Walk the tile grid
                    // row-major (tile_x 0..dim_x-1, then tile_y+1) and
                    // return to ST_DECODE, which already checks
                    // tile_x<dim_x && tile_y<dim_y and routes to
                    // ST_ADVANCE once the grid is exhausted.
                    if (tile_x == (text_mode ? 6'd1 : (dim_x - 6'd1))) begin
                        tile_x <= 6'd0;
                        tile_y <= tile_y + 6'd1;
                    end else begin
                        tile_x <= tile_x + 6'd1;
                    end
                    state <= ST_DECODE;
                end
                ST_TEXT_ADVANCE: begin
                    // Text lists are 0x80 bytes long and terminate on the
                    // first valid descriptor whose bank bit 7 is clear.
                    // Invalid entries (code bit 7 clear) are skipped.
                    if ((desc_code[7] && !desc_bank[7]) ||
                        (text_offset == 7'h7c)) begin
                        text_mode <= 1'b0;
                        state <= ST_ADVANCE;
                    end else begin
                        text_offset <= text_offset + 7'd4;
                        tile_x <= 6'd0;
                        tile_y <= 6'd0;
                        state <= ST_DESC_Y;
                    end
                end
                ST_ADVANCE: begin
                    // 192 slots x 4 bytes = 768; wrap explicitly since 768
                    // is not a power-of-two boundary slot_index would
                    // naturally overflow at. On wrap, sparkman additionally
                    // toggles to the other sprite chip (0<->1) before
                    // restarting the slot walk; every other profile just
                    // keeps chip at 0 forever (chip is never set to 1 for
                    // them in the first place).
                    if (slot_index == 10'd764) begin
                        slot_index <= 10'd0;
                        // Every wrap starts a fresh draw_sprites() call in
                        // MAME terms (a new frame's single-chip pass, or --
                        // for sparkman -- the other chip's pass), so `mx`
                        // resets here unconditionally.
                        mx <= 12'sd0;
                        if (profile == PROFILE_SPARKMAN) begin
                            if (chip)
                                render_done <= 1'b1;
                            chip <= ~chip;
                        end else begin
                            render_done <= 1'b1;
                        end
                    end else begin
                        slot_index <= slot_index + 10'd4;
                    end
                    state <= ST_DESC_Y;
                end
                default: state <= ST_DESC_Y;
            endcase
        end
    end

endmodule
