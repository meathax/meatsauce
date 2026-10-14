module suna8_sprite_decode
(
    input  logic [2:0] profile,
    input  logic flip_screen,
    input  logic [2:0] sprite_bank,
    input  logic sprite_chip,
    input  logic [2:0] gfx_bank_latch,
    input  logic palette_bank,
    input  logic [7:0] descriptor_y,
    input  logic [7:0] descriptor_code,
    input  logic [7:0] descriptor_x,
    input  logic [7:0] descriptor_bank,
    input  logic [5:0] tile_x,
    input  logic [5:0] tile_y,
    input  logic [7:0] tile_data,
    input  logic [7:0] tile_attr,

    output logic descriptor_valid,
    output logic [5:0] dim_x,
    output logic [5:0] dim_y,
    output logic [8:0] sprite_x,
    output logic [7:0] sprite_y,
    output logic [15:0] tile_ram_addr,
    output logic [15:0] gfx_tile_code,
    output logic [20:0] gfx_byte_base,
    output logic [4:0] palette_group,
    output logic tile_flip_x,
    output logic tile_flip_y,
    output logic [3:0] transparent_pen,
    output logic multisprite
);

    logic [5:0] source_x;
    logic [5:0] source_y;
    logic [2:0] source_page;
    logic [5:0] gfx_bank;
    logic color_bank;
    logic base_flip_x;
    logic base_flip_y;
    logic [7:0] source_tile;
    logic [7:0] source_attr;
    logic [12:0] tile_word_index;
    logic [15:0] local_tile_code;
    logic [20:0] gfx_byte_offset;

    // This is the exact descriptor split documented in suna8_v.cpp.  The
    // renderer consumes a descriptor as a rectangle of tile references; it
    // is not a conventional scrolling tilemap.
    always_comb begin
        descriptor_valid = 1'b0;
        dim_x = 6'd0;
        dim_y = 6'd0;
        source_x = 6'd0;
        source_y = 6'd0;
        source_page = 3'd0;
        gfx_bank = 6'd0;
        color_bank = 1'b0;
        base_flip_x = 1'b0;
        base_flip_y = 1'b0;
        multisprite = 1'b0;
        source_tile = 8'd0;
        source_attr = 8'd0;
        tile_word_index = 13'd0;
        local_tile_code = 16'd0;
        gfx_byte_offset = 21'd0;

        if (profile <= 3'd1) begin
            // Hard Head and Super/Rough Ranger use the older text-capable
            // descriptor format.
            if (descriptor_bank[7:6] == 2'b11) begin
                // Text/HUD sprite list marker (suna8_v.cpp draw_sprites():
                // `(bank & 0xc0) == 0xc0` redirects to draw_text_sprites()
                // and `continue`s -- this slot is never a normal sprite).
                // dim 0x0 makes the renderer's tile_x<dim_x&&tile_y<dim_y
                // gate fail immediately, matching MAME's skip-and-continue.
                // The renderer redirects the marker to the fixed HUD lists;
                // its framebuffer-side row priority map models MAME's
                // priority bitmap for the first text list.
                dim_x = 6'd0;
                dim_y = 6'd0;
                descriptor_valid = 1'b1;
            end else begin
                gfx_bank = descriptor_bank[5:0];
                if (descriptor_code[7]) begin
                    dim_x = 6'd2;
                    dim_y = 6'd32;
                    source_x = {1'b0, descriptor_code[3:0], 1'b0};
                    source_y = 6'd0;
                    source_page = descriptor_code[5:4];
                    multisprite = descriptor_code[6];
                end else begin
                    dim_x = 6'd2;
                    dim_y = 6'd2;
                    source_x = {1'b0, descriptor_code[3:0], 1'b0};
                    source_y = {1'b0, descriptor_code[6:5], 3'b110};
                    source_page = {2'b0, descriptor_code[4]};
                end
                descriptor_valid = 1'b1;
            end
        end else begin
            // Brick Zone, Hard Head 2, Spark Man, and Star Fighter use the
            // later format.  The profile-specific gfx-bank adjustment is
            // kept here, at the shared hardware boundary.
            case (descriptor_code[7:6])
                2'b11: begin
                    dim_x = 6'd4;
                    dim_y = 6'd32;
                    source_x = {1'b0, descriptor_code[3:1], 2'b00};
                    source_y = 6'd0;
                    base_flip_x = descriptor_code[0];
                    source_page = descriptor_code[5:4];
                    gfx_bank = descriptor_bank[4:0];
                end
                2'b10: begin
                    dim_x = 6'd2;
                    dim_y = 6'd32;
                    source_x = {1'b0, descriptor_code[3:0], 1'b0};
                    source_y = 6'd0;
                    source_page = descriptor_code[5:4];
                    gfx_bank = descriptor_bank[4:0];
                end
                2'b01: begin
                    dim_x = 6'd4;
                    dim_y = 6'd4;
                    source_x = {1'b0, descriptor_code[3:1], 2'b00};
                    base_flip_x = descriptor_code[0];
                    base_flip_y = descriptor_bank[4];
                    // MAME: srcy = (((bank&0x80)>>4)+(bank&4)+((~bank>>4)&2))*2
                    // -- bank[4] only feeds flip_y here, it is not folded
                    // into srcy (unlike the plain 2x2 case below, which uses
                    // the wider ((~bank>>4)&3) mask).
                    source_y = {1'b0, descriptor_bank[7], descriptor_bank[2],
                                ~descriptor_bank[5], 2'b00};
                    source_page = {1'b0, descriptor_code[5:4]} + 3'd4;
                    gfx_bank = descriptor_bank[1:0];
                    // suna8_v.cpp draw_sprites(), case 0x40, switches on
                    // m_gfxbank_type, not on the game: GFXBANK_TYPE_BRICKZN
                    // adds 4 ("brickzn: 06,a6,a2,b2->6"), STARFIGH adds the
                    // latched bank when the field reads 3, SPARKMAN adds
                    // nothing. Hard Head 2 is BRICKZN type as well as Brick
                    // Zone: its machine config is derived from Brick Zone's
                    // (hardhea2 -> brickzn -> brickzn11) and never overrides
                    // VIDEO_START, so it inherits vh_start_common(false,
                    // GFXBANK_TYPE_BRICKZN). Restricting the +4 to Brick Zone
                    // put every Hard Head 2 4x4 sprite 4*0x400 tiles low in
                    // the gfx ROM -- the player drawn as font glyphs, which
                    // no attract-mode frame could catch because attract mode
                    // has no 4x4 sprites at all.
                    if ((profile == 3'd5) || (profile == 3'd4))
                        gfx_bank = gfx_bank + 6'd4;
                    else if ((profile == 3'd3) && (gfx_bank == 3))
                        gfx_bank = gfx_bank + {3'b0, gfx_bank_latch};
                    color_bank = descriptor_bank[3];
                end
                default: begin
                    dim_x = 6'd2;
                    dim_y = 6'd2;
                    source_x = {1'b0, descriptor_code[3:0], 1'b0};
                    base_flip_x = 1'b0;
                    base_flip_y = 1'b0;
                    source_y = {1'b0, descriptor_bank[7], descriptor_bank[2],
                                (~descriptor_bank[5:4]), 1'b0};
                    source_page = {1'b0, descriptor_code[5:4]};
                    gfx_bank = descriptor_bank[1:0];
                    if ((profile == 3'd3) && (gfx_bank == 3))
                        gfx_bank = gfx_bank + {3'b0, gfx_bank_latch};
                end
            endcase
            descriptor_valid = 1'b1;
            multisprite = descriptor_code[7] && descriptor_bank[7];
        end

        sprite_x = {descriptor_bank[6], descriptor_x};
        sprite_y = 8'h00 - descriptor_y - ({2'd0, dim_y} << 3);
        // flip_screen is applied per tile in suna8_sprite_render.sv, after
        // the tile offset has been added (suna8_v.cpp:352-357 computes
        // sx = x + tx*8 first and only then sx = max_x - sx). Pre-flipping
        // the origin here and then adding the tile offset mirrored every
        // multi-tile sprite about the wrong axis (audit item 21.4 / W25).
        // Within-tile mirroring (tile_flip_x/y ^ flip_screen below) is
        // unchanged.

        if (tile_x < dim_x && tile_y < dim_y) begin
            source_tile = tile_x;
            source_attr = tile_y;
            if (base_flip_x)
                source_tile = dim_x - tile_x - 1'b1;
            if (base_flip_y)
                source_attr = dim_y - tile_y - 1'b1;

            tile_word_index = ({10'd0, source_page} << 10) +
                              ({8'd0, ((source_x + source_tile) & 6'h1f)} << 5) +
                              {7'd0, ((source_y + source_attr) & 6'h1f)};
            // Each Spark Man sprite chip has a 16 KiB reference space.  The
            // CPU-visible bank is selected elsewhere; rendering walks the
            // complete chip space exactly like MAME's `which` pointer.
            tile_ram_addr = (sprite_chip ? 16'h4000 : 16'h0000) +
                            (tile_word_index << 1);
            local_tile_code = {8'd0, tile_data} +
                              ({14'd0, tile_attr[1:0]} << 8) +
                              ({10'd0, gfx_bank} << 10);
            gfx_tile_code = local_tile_code;
            gfx_byte_offset = local_tile_code * 21'd16;
            gfx_byte_base = gfx_byte_offset;

            tile_flip_x = tile_attr[6] ^ base_flip_x ^ flip_screen;
            tile_flip_y = tile_attr[7] ^ base_flip_y ^ flip_screen;
            palette_group = {1'b0, (tile_attr[5:2] ^ {3'd0, color_bank})};
            if ((profile == 3'd5) && palette_bank)
                palette_group = palette_group + 5'd16;
            transparent_pen = 4'hf;
        end else begin
            tile_ram_addr = 16'd0;
            gfx_tile_code = 16'd0;
            gfx_byte_base = 21'd0;
            tile_flip_x = 1'b0;
            tile_flip_y = 1'b0;
            palette_group = 5'd0;
            transparent_pen = 4'hf;
        end
    end

endmodule
