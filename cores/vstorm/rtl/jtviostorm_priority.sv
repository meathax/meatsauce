/*
 * Violent Storm candidate compositor.
 *
 * KNOWN register mapping comes from MAME's konamigx_v.cpp: tile A/B/C/D use
 * K055555 registers 7/10/13/14 and register 45 gates VA/VB/VC/VD/OBJ.
 * The title-local candidate selection is also the ownership boundary for
 * per-pixel effects: a selected tile carries its K055555 mix selector and a
 * selected object carries its K055673 effect/mix and shadow codes.  The
 * downstream K054338 stage consumes those selectors on the same pixel path.
 * Full GX z-code and alpha/tie behavior beyond this documented order remain
 * separate evidence items.
 */
module jtviostorm_priority(
    input  logic [7:0]  input_enables,
    input  logic [7:0]  layer_priority0,
    input  logic [7:0]  layer_priority1,
    input  logic [7:0]  layer_priority2,
    input  logic [7:0]  layer_priority3,
    input  logic [11:0] layer_palette0,
    input  logic [11:0] layer_palette1,
    input  logic [11:0] layer_palette2,
    input  logic [11:0] layer_palette3,
    // 9 bits: [8:5]=colnib (K055555 4-bit palette-nibble field), [4:0]=raw
    // 5bpp tile pen (0-31) -- see Fix 1, jtviostorm_k056832_video.sv.
    input  logic [8:0]  lyrf_pxl,
    input  logic [8:0]  lyra_pxl,
    input  logic [8:0]  lyrb_pxl,
    input  logic [8:0]  lyrc_pxl,
    input  logic [1:0]  lyrf_mix,
    input  logic [1:0]  lyra_mix,
    input  logic [1:0]  lyrb_mix,
    input  logic [1:0]  lyrc_mix,
    input  logic [8:0]  sprite_pixel,
    input  logic [4:0]  sprite_priority,
    input  logic [1:0]  sprite_shadow,
    input  logic [11:0] object_palette_base,
    output logic [11:0] palette_index,
    output logic [1:0]  selected_mix,
    output logic [1:0]  selected_shadow,
    output logic [2:0]  selected_source,
    output logic        selected_valid
);
    logic [7:0]  best_priority;
    logic [11:0] best_palette;
    logic [1:0]  best_mix;
    logic [1:0]  best_shadow;
    logic [2:0]  best_source;
    logic        best_valid;
    logic [7:0]  sprite_rank;
    logic [1:0]  sprite_shadow_eff;

    // K056832's gfx element is decoded at 5bpp (32 raw pens/tile) but its
    // palette granularity is forced to 16 (create_gfx(),
    // k054156_k054157_k056832.cpp:358 "gfx(gfx_index)->set_granularity(16)")
    // regardless of bpp. The final palette pen is therefore the plain
    // arithmetic sum base + colnib*16 + pen(0-31), where pen's top bit
    // (>=16) deliberately overlaps/carries into the next colnib's 16-color
    // block -- this is the real hardware behaviour, not a rounding error.
    // viostorm_tile_callback (mystwarr_v.cpp:72-81) confirms colnib is the
    // 4-bit attr[7:4] field and m_layer_colorbase[layer] is
    // K055555_get_palette_index(layer)<<4 (mystwarr_v.cpp:277,
    // screen_update_metamrph path), matching layer_paletteN = {regN,4'b0}
    // as already produced by jtviostorm_k055555.sv.
    function automatic [11:0] tile_palette(input [11:0] base, input [3:0] colnib, input [4:0] pen);
        tile_palette = base + {4'd0,colnib,4'b0} + {7'd0,pen};
    endfunction

    // metamrph_sprite_callback (mystwarr_v.cpp:105-112) treats a raw shadow
    // field of 3 as K055555_SKIPSHADOW, not a third shadow-colour preset:
    // the sprite's shadow draw pass is entirely suppressed
    // (konamigx_v.cpp:604, `!(color & K055555_SKIPSHADOW)` gates whether the
    // shadow object is ever queued for drawing). Fold that into the raw
    // 2-bit field before it reaches candidacy/selection so a value of 3
    // behaves as "no shadow" rather than selecting K054338 shadow preset 3.
    always_comb begin
        sprite_shadow_eff = (sprite_shadow == 2'd3) ? 2'd0 : sprite_shadow;
    end

    // The pinned GX mixer sorts objects in descending numeric priority and
    // draws them in that order.  Since later solid draws are frontmost, lower
    // numeric priorities are the visible candidate. Equal priorities use the
    // later candidate source as a stable deterministic tie rule (A < B < C <
    // D < OBJ); this is explicit because MAME's stable-sort tie order is not a
    // silicon proof.
    // The donor exposes attr[9:5] as five bits.  Violent Storm's pinned MAME
    // metamrph callback uses `(color & 8'he0) >> 2`: attr[7:5] are the
    // priority bits, attr[9:8] are sprite effects, and the callback places
    // the three-bit mask in the mixer bits [5:3].
    always_comb begin
        best_priority = 8'h00;
        best_palette  = 12'd0;
        best_mix      = 2'd0;
        best_shadow   = 2'd0;
        best_source   = 3'd0;
        best_valid    = 1'b0;
        sprite_rank   = {2'b00,sprite_priority[2:0],3'b000};

        // Transparency is decided by the raw tile pen (lyrX_pxl[4:0]) alone,
        // matching MAME's tilemap transparent_pen(0) check against the
        // decoded gfx pixel -- the colnib palette-group field does not
        // affect transparency.
        if (input_enables[0] && (lyrf_pxl[4:0] != 5'd0)) begin
            best_valid    = 1'b1;
            best_priority = layer_priority0;
            best_palette  = tile_palette(layer_palette0, lyrf_pxl[8:5], lyrf_pxl[4:0]);
            best_mix      = lyrf_mix;
            best_source   = 3'd0;
        end
        if (input_enables[1] && (lyra_pxl[4:0] != 5'd0) &&
            (!best_valid || layer_priority1 < best_priority ||
             (layer_priority1 == best_priority && 3'd1 > best_source))) begin
            best_valid    = 1'b1;
            best_priority = layer_priority1;
            best_palette  = tile_palette(layer_palette1, lyra_pxl[8:5], lyra_pxl[4:0]);
            best_mix      = lyra_mix;
            best_shadow   = 2'd0;
            best_source   = 3'd1;
        end
        if (input_enables[2] && (lyrb_pxl[4:0] != 5'd0) &&
            (!best_valid || layer_priority2 < best_priority ||
             (layer_priority2 == best_priority && 3'd2 > best_source))) begin
            best_valid    = 1'b1;
            best_priority = layer_priority2;
            best_palette  = tile_palette(layer_palette2, lyrb_pxl[8:5], lyrb_pxl[4:0]);
            best_mix      = lyrb_mix;
            best_shadow   = 2'd0;
            best_source   = 3'd2;
        end
        if (input_enables[3] && (lyrc_pxl[4:0] != 5'd0) &&
            (!best_valid || layer_priority3 < best_priority ||
             (layer_priority3 == best_priority && 3'd3 > best_source))) begin
            best_valid    = 1'b1;
            best_priority = layer_priority3;
            best_palette  = tile_palette(layer_palette3, lyrc_pxl[8:5], lyrc_pxl[4:0]);
            best_mix      = lyrc_mix;
            best_shadow   = 2'd0;
            best_source   = 3'd3;
        end
        // K055673 emits pen zero for a shadow-only object pixel while keeping
        // the shadow code nonzero.  Such a pixel is still a real candidate:
        // it modifies the previously selected colour rather than replacing
        // it with palette entry zero.  Ignoring it loses all sprite shadow
        // effects.  A zero pen with zero shadow remains transparent.
        if (input_enables[4] &&
            ((sprite_pixel[3:0] != 4'd0) || (sprite_shadow_eff != 2'd0)) &&
            (!best_valid || sprite_rank < best_priority ||
             (sprite_rank == best_priority && 3'd4 > best_source))) begin
            best_valid    = 1'b1;
            best_priority = sprite_rank;
            if (sprite_pixel[3:0] != 4'd0)
                best_palette = object_palette_base + {3'd0,sprite_pixel};
            // For a shadow-only pen retain the lower-priority colour and let
            // selected_shadow route the effect through K054338.  If no lower
            // candidate exists, the initialized palette zero is the physical
            // background entry rather than an invented sprite colour.
            // The callback's attr[9:8] field is the sprite effect selector
            // (the same two-bit mix domain carried by the tile layers).  It
            // must follow the selected object pixel into K054338; forcing
            // zero here silently discards sprite shadow/alpha variants.
            best_mix      = sprite_priority[4:3];
            best_shadow   = sprite_shadow_eff;
            best_source   = 3'd4;
        end

        palette_index   = best_palette;
        selected_mix    = best_mix;
        selected_shadow = best_shadow;
        selected_source = best_source;
        selected_valid  = best_valid;
    end
endmodule
