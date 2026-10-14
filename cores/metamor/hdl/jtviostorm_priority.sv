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
    input  logic [8:0]  lvc_pxl,
    input  logic [7:0]  sub1_priority,
    input  logic [11:0] sub1_palette_base,
    input  logic [1:0]  lyrf_mix,
    input  logic [1:0]  lyra_mix,
    input  logic [1:0]  lyrb_mix,
    input  logic [1:0]  lyrc_mix,
    input  logic [8:0]  sprite_pixel,
    input  logic [4:0]  sprite_priority,
    input  logic [1:0]  sprite_shadow,
    input  logic [2:0]  sprite_shadow_prio,
    input  logic [11:0] object_palette_base,
    output logic [11:0] palette_index,
    output logic [1:0]  selected_mix,
    output logic [1:0]  selected_shadow,
    output logic [2:0]  selected_source,
    output logic        selected_valid,
    // Runner-up visible candidate. K054338 uses this as the destination
    // colour when the winning pixel requests alpha blending.
    output logic [11:0] background_palette_index,
    output logic [2:0]  background_source,
    output logic        background_valid
);
    logic [7:0]  best_priority;
    logic [11:0] best_palette;
    logic [1:0]  best_mix;
    logic [1:0]  best_shadow;
    logic [2:0]  best_source;
    logic        best_valid;
    logic [7:0]  sprite_rank;
    logic [1:0]  sprite_shadow_eff;
    logic        shade_hit;
    logic [7:0]  back_priority;
    logic [11:0] back_palette;
    logic [2:0]  back_source;
    logic        back_valid;

    // K056832's gfx element is decoded at 5bpp (32 raw pens/tile) but its
    // palette granularity is forced to 16 (create_gfx(),
    // k054156_k054157_k056832.cpp:358 "gfx(gfx_index)->set_granularity(16)")
    // regardless of bpp. The final palette pen is therefore the plain
    // arithmetic sum base + colnib*16 + pen(0-31). This is an emulation-
    // derived rule, not verified PCB wiring: Coin-Op Collection's GX224
    // notes (2026-09-06) describe concatenation instead. The current tile
    // ROM decoder supplies a zero fifth plane; reconcile its bus packing
    // and palette wiring before changing the colour-field bit assignment.
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

    // Parallel rank selection preserves the existing total order without
    // routing the winner through a second serial runner-up scan. Lower numeric
    // priority wins. Equal tiles prefer SUB1 > D > C > B > A; every tile wins
    // a tie against OBJ. No pipeline stage or pixel latency is added.
    logic [7:0] candidate_priority [0:5];
    logic [11:0] candidate_palette [0:5];
    logic [1:0] candidate_mix [0:5];
    logic [2:0] candidate_source [0:5];
    logic [5:0] candidate_valid, winner, runner;
    logic [5:0] ahead [0:5];
    integer i, j;
    function automatic [2:0] tie_weight(input integer index);
        tie_weight = (index == 5) ? 3'd0 : index + 1;
    endfunction
    always_comb begin
        sprite_rank = {2'b00,sprite_priority[2:0],3'b000};
        candidate_priority[0]=layer_priority0;
        candidate_priority[1]=layer_priority1;
        candidate_priority[2]=layer_priority2;
        candidate_priority[3]=layer_priority3;
        candidate_priority[4]=sub1_priority;
        candidate_priority[5]=sprite_rank;
        candidate_palette[0]=tile_palette(layer_palette0,lyrf_pxl[8:5],lyrf_pxl[4:0]);
        candidate_palette[1]=tile_palette(layer_palette1,lyra_pxl[8:5],lyra_pxl[4:0]);
        candidate_palette[2]=tile_palette(layer_palette2,lyrb_pxl[8:5],lyrb_pxl[4:0]);
        candidate_palette[3]=tile_palette(layer_palette3,lyrc_pxl[8:5],lyrc_pxl[4:0]);
        candidate_palette[4]=sub1_palette_base+{3'd0,lvc_pxl};
        // MAME metamrph_sprite_callback ORs the 5-bit raw sprite colour
        // into (K55_PALBASE_OBJ<<4), so colour bit 4 overlaps the base field.
        // Adding the fields incorrectly carries when both are set.
        candidate_palette[5]=object_palette_base | {3'd0,sprite_pixel};
        candidate_mix[0]=lyrf_mix; candidate_mix[1]=lyra_mix;
        candidate_mix[2]=lyrb_mix; candidate_mix[3]=lyrc_mix;
        candidate_mix[4]=2'd0; candidate_mix[5]=sprite_priority[4:3];
        candidate_source[0]=3'd0; candidate_source[1]=3'd1;
        candidate_source[2]=3'd2; candidate_source[3]=3'd3;
        candidate_source[4]=3'd5; candidate_source[5]=3'd4;
        candidate_valid[0]=input_enables[0] && lyrf_pxl[4:0]!=0;
        candidate_valid[1]=input_enables[1] && lyra_pxl[4:0]!=0;
        candidate_valid[2]=input_enables[2] && lyrb_pxl[4:0]!=0;
        candidate_valid[3]=input_enables[3] && lyrc_pxl[4:0]!=0;
        candidate_valid[4]=input_enables[5] && lvc_pxl[3:0]!=0;
        candidate_valid[5]=input_enables[4] && sprite_pixel[3:0]!=0;
        for (i=0;i<6;i=i+1) begin
            ahead[i]=6'd0;
            for (j=0;j<6;j=j+1) begin
                if (i!=j)
                    ahead[i][j]=candidate_valid[j] &&
                        ((candidate_priority[j]<candidate_priority[i]) ||
                         ((candidate_priority[j]==candidate_priority[i]) &&
                          (tie_weight(j)>tie_weight(i))));
            end
            winner[i]=candidate_valid[i] && ahead[i]==0;
            runner[i]=candidate_valid[i] && ahead[i]!=0 &&
                      (ahead[i] & (ahead[i]-6'd1))==0;
        end
        best_priority=0; best_palette=0; best_mix=0; best_source=0;
        back_priority=0; back_palette=0; back_source=0;
        best_valid=|winner; back_valid=|runner;
        for (i=0;i<6;i=i+1) begin
            best_priority=best_priority | ({8{winner[i]}} & candidate_priority[i]);
            best_palette=best_palette | ({12{winner[i]}} & candidate_palette[i]);
            best_mix=best_mix | ({2{winner[i]}} & candidate_mix[i]);
            best_source=best_source | ({3{winner[i]}} & candidate_source[i]);
            back_priority=back_priority | ({8{runner[i]}} & candidate_priority[i]);
            back_palette=back_palette | ({12{runner[i]}} & candidate_palette[i]);
            back_source=back_source | ({3{runner[i]}} & candidate_source[i]);
        end
        shade_hit=1'b0;
        // A shadow needs a drawable destination; the K054338 backdrop is
        // outside the layer/shadow ladder (GX224 PCB reference notes).
        if (best_valid && input_enables[4] && sprite_shadow_eff!=0) begin
            if (best_source==3'd4)
                shade_hit=sprite_rank>={2'b00,sprite_shadow_prio,3'b000};
            else shade_hit=best_priority>{2'b00,sprite_shadow_prio,3'b000};
        end
        best_shadow=shade_hit?sprite_shadow_eff:2'd0;
        palette_index=best_palette; selected_mix=best_mix;
        selected_shadow=best_shadow; selected_source=best_source;
        selected_valid=best_valid;
        background_palette_index=back_palette;
        background_source=back_source; background_valid=back_valid;
    end
endmodule
