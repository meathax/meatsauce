module suna8_gfx_layout
(
    input  logic [2:0] profile,
    input  logic [15:0] tile_code,
    input  logic [1:0] plane,
    input  logic [2:0] pixel_x,
    input  logic [2:0] pixel_y,
    output logic [22:0] bit_address,
    output logic [20:0] byte_address,
    output logic [2:0] bit_in_byte
);

    logic [22:0] tile_base;
    logic [22:0] plane_offset;
    logic [22:0] half_region_bits;
    logic [3:0] x_offset;

    // MAME's layout_8x8x4 is a split 2-bit-per-ROM layout: the first two
    // logical planes live in the upper half of the gfx1/gfx2 ROM region,
    // planes 2 and 3 in the lower half. The split point is RGN_FRAC(1,2) --
    // half of the *actual* ROM region size in bits -- which is NOT a fixed
    // constant: gfx1 is 0x40000 bytes for hardhead/sranger, 0x80000 for
    // hardhea2, 0xc0000 for brickzn, and 0x100000 for sparkman/starfigh
    // (confirmed against suna8.cpp's ROM_REGION("gfx1",...) declarations
    // per game). Using the 1MB-only split for every profile silently reads
    // planes 0/1 from the wrong half of the ROM on every profile except
    // sparkman/starfigh -- confirmed as the root cause of hardhea2's
    // garbled self-test-screen sprites (verif/NOTES.md iteration 38).
    always_comb begin
        case (profile)
            3'd0, 3'd1: half_region_bits = 23'h100000; // hardhead/sranger: 0x40000 bytes
            3'd4:       half_region_bits = 23'h200000; // hardhea2: 0x80000 bytes
            3'd5:       half_region_bits = 23'h300000; // brickzn: 0xc0000 bytes
            default:    half_region_bits = 23'h400000; // sparkman/starfigh: 0x100000 bytes
        endcase

        tile_base = {8'd0, tile_code[14:0]} << 7;
        case (plane)
            2'd0: plane_offset = half_region_bits;
            2'd1: plane_offset = half_region_bits + 23'd4;
            2'd2: plane_offset = 23'd0;
            default: plane_offset = 23'd4;
        endcase

        case (pixel_x)
            3'd0: x_offset = 4'd3;
            3'd1: x_offset = 4'd2;
            3'd2: x_offset = 4'd1;
            3'd3: x_offset = 4'd0;
            3'd4: x_offset = 4'd11;
            3'd5: x_offset = 4'd10;
            3'd6: x_offset = 4'd9;
            default: x_offset = 4'd8;
        endcase

        bit_address = tile_base + plane_offset +
                      ({16'd0, pixel_y} << 4) + x_offset;
        byte_address = bit_address[22:3];
        // MAME gfx_layout bit offsets count from the MSB of each byte:
        // drawgfx.cpp readbit() tests `0x80 >> (bitnum % 8)`. Offset 3 in
        // the layout is therefore data bit 4, not data bit 3. Indexing the
        // raw byte with the low three address bits directly mirrors every
        // 4-pixel nibble and swaps the two planes that share a byte, which
        // is how every self-test screen rendered as structured garbage.
        bit_in_byte = 3'd7 - bit_address[2:0];
    end

endmodule
