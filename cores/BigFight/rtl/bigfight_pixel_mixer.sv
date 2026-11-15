// MAME0.289 cyclwarr_state::screen_update composition order.
module bigfight_pixel_mixer (
    input logic [51:0] tile_pixels,
    input logic sprite_opaque,
    input logic [12:0] sprite_palette,
    input logic sprite_shadow,shadow_inverse,
    output logic [12:0] palette_index,
    output logic palette_shadow
);
    integer layer;
    always_comb begin
        palette_index=13'd0;
        palette_shadow=sprite_shadow ^ shadow_inverse;
        // Each record: {opaque, category, palette[10:0]}, layer0 lowest bits.
        // MAME draws3,2,1,0; the lower layer number wins within each pass.
        for(layer=3;layer>=0;layer=layer-1)
            if(tile_pixels[layer*13+12] && !tile_pixels[layer*13+11])
                palette_index={2'b00,tile_pixels[layer*13 +: 11]};
        // Shadows affect category0 backgrounds, before normal object colors.
        if(sprite_opaque) begin
            palette_index=sprite_palette;
            palette_shadow=1'b0;
        end
        for(layer=3;layer>=0;layer=layer-1)
            if(tile_pixels[layer*13+12] && tile_pixels[layer*13+11]) begin
                palette_index={2'b00,tile_pixels[layer*13 +: 11]};
                palette_shadow=1'b0;
            end
    end
endmodule
