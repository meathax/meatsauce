// Violent Storm GX168/GX173 main-bus decode.
// `addr` is the 24-bit byte address ({68000 A[23:1],1'b0}).
// The ranges are deliberately kept explicit: aliases and unpopulated gaps
// must be established from board evidence before being folded together.
module jtviostorm_decode (
    input  logic [23:0] addr,
    input  logic        active,
    output logic        cs_main,
    output logic        cs_ram,
    output logic        cs_obj,
    output logic        cs_extra,
    output logic        cs_sprite_ctl,
    output logic        cs_scratch,
    output logic        cs_scratch_reg,
    output logic        cs_k054338,
    output logic        cs_k055555,
    output logic        cs_prot,
    output logic        cs_k053252,
    output logic        cs_sound_irq,
    output logic        cs_k054321,
    output logic        cs_k056832,
    output logic        cs_io,
    output logic        cs_vram,
    output logic        cs_tile_read,
    output logic        cs_lvc_rom,
    output logic        cs_palette,
    output logic        cs_video,
    output logic        cs_any
);
    // 056804 PAL inputs are AS+A16-A22 only (F1); A23 is not decoded, so the
    // whole map mirrors every 0x800000. Mask it out before the range compares.
    wire [23:0] a = {1'b0, addr[22:0]};

    always_comb begin
        cs_main        = 1'b0;
        cs_ram         = 1'b0;
        cs_obj         = 1'b0;
        cs_extra       = 1'b0;
        cs_sprite_ctl  = 1'b0;
        cs_scratch     = 1'b0;
        cs_scratch_reg = 1'b0;
        cs_k054338     = 1'b0;
        cs_k055555     = 1'b0;
        cs_prot        = 1'b0;
        cs_k053252     = 1'b0;
        cs_sound_irq   = 1'b0;
        cs_k054321     = 1'b0;
        cs_k056832     = 1'b0;
        cs_io          = 1'b0;
        cs_vram        = 1'b0;
        cs_tile_read   = 1'b0;
        cs_lvc_rom     = 1'b0;
        cs_palette     = 1'b0;

        if (active) begin
            cs_main        = (a <= 24'h1f_ffff);
            cs_ram         = (a >= 24'h20_0000 && a <= 24'h20_ffff);
            cs_obj         = (a >= 24'h21_0000 && a <= 24'h21_0fff);
            cs_extra       = (a >= 24'h21_1000 && a <= 24'h21_ffff);
            // The K053246/K055673 windows are separated by an unmapped gap:
            // OBJSET1 at 0x240000-0x240007, then ROM readback/OBJSET2 at
            // 0x244000-0x24401f. Do not turn the intervening addresses into
            // an undocumented alias of the sprite device.
            cs_sprite_ctl  = ((a >= 24'h24_0000 && a <= 24'h24_0007) ||
                              (a >= 24'h24_4000 && a <= 24'h24_401f));
            cs_scratch     = (a >= 24'h24_c000 && a <= 24'h24_ffff);
            cs_scratch_reg = (a >= 24'h25_0000 && a <= 24'h25_000f);
            cs_k054338     = (a >= 24'h25_4000 && a <= 24'h25_401f);
            cs_k055555     = (a >= 24'h25_8000 && a <= 24'h25_80ff);
            // Metamorphic Force has no K055550 protection window here.
            cs_prot        = 1'b0;
            cs_k053252     = (a >= 24'h26_0000 && a <= 24'h26_001f);
            cs_sound_irq   = (a >= 24'h26_4000 && a <= 24'h26_4001);
            cs_k054321     = (a >= 24'h26_8000 && a <= 24'h26_801f);
            // Two disjoint K056832 write windows (register block and VRAM
            // bank/scroll block); 0x26c008-0x26ffff is unmapped on the real
            // bus, not an alias of the device.
            cs_k056832     = ((a >= 24'h26_c000 && a <= 24'h26_c007) ||
                              (a >= 24'h27_0000 && a <= 24'h27_003f));
            // Four small disjoint I/O windows; 0x274004-0x277fff and
            // 0x278004-0x27bfff are unmapped, not part of cs_io.
            cs_io          = ((a >= 24'h27_4000 && a <= 24'h27_4003) ||
                              (a >= 24'h27_8000 && a <= 24'h27_8003) ||
                              (a >= 24'h27_c000 && a <= 24'h27_c001));
            cs_vram        = (a >= 24'h30_0000 && a <= 24'h30_3fff);
            cs_tile_read   = (a >= 24'h31_0000 && a <= 24'h31_1fff);
            cs_lvc_rom     = (a >= 24'h32_0000 && a <= 24'h32_1fff);
            cs_palette     = (a >= 24'h33_0000 && a <= 24'h33_1fff);
        end

        cs_video = cs_sprite_ctl | cs_scratch | cs_scratch_reg |
                   cs_k054338 | cs_k055555 | cs_k053252 |
                   cs_k056832 | cs_vram | cs_tile_read | cs_lvc_rom | cs_palette;
        cs_any = cs_main | cs_ram | cs_obj | cs_extra | cs_video |
                 cs_prot | cs_sound_irq | cs_k054321 | cs_io;
    end
endmodule
