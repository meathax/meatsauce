// SPDX-License-Identifier: GPL-3.0-or-later
// Candidate packed-image translation only. The caller must hold the selected
// region/address through the corresponding granule reply; no arbitration,
// request ownership, CDC or physical SDRAM behavior is implemented here.
module spinal_rom_map (
    input  logic [3:0] region,
    input  logic [21:0] offset,
    input  logic [63:0] granule_data,
    output logic valid,
    output logic [24:0] granule_address,
    output logic [2:0] lane,
    output logic [63:0] data
);
    // Byte offsets and sizes are parsed by scripts/pack_rom_image.py.
    localparam logic [24:0] BASE_MAINCPU = 25'h000000, SIZE_MAINCPU = 25'h060000;
    localparam logic [24:0] BASE_SOUNDBANK = 25'h060000, SIZE_SOUNDBANK = 25'h020000;
    localparam logic [24:0] BASE_AUDIOCPU = 25'h080000, SIZE_AUDIOCPU = 25'h008000;
    localparam logic [24:0] BASE_GFX1 = 25'h088000, SIZE_GFX1 = 25'h100000;
    localparam logic [24:0] BASE_GFX2 = 25'h188000, SIZE_GFX2 = 25'h200000;
    localparam logic [24:0] BASE_SPRITEGFX = 25'h388000, SIZE_SPRITEGFX = 25'h100000;
    localparam logic [24:0] BASE_GFX4 = 25'h488000, SIZE_GFX4 = 25'h200000;
    localparam logic [24:0] BASE_SPRLOOKUPROM = 25'h688000, SIZE_SPRLOOKUPROM = 25'h024000;
    localparam logic [24:0] BASE_ADPCMA = 25'h6ac000, SIZE_ADPCMA = 25'h100000;

    logic [24:0] base, size, absolute_address;
    logic [3:0] width_bytes;
    logic big_word;
    logic [63:0] shifted;
    always @* begin
        base=0; size=0; width_bytes=0; big_word=0;
        case(region)
            0: begin base=BASE_MAINCPU; size=SIZE_MAINCPU; width_bytes=2; big_word=1; end
            1: begin base=BASE_SOUNDBANK; size=SIZE_SOUNDBANK; width_bytes=1; end
            2: begin base=BASE_AUDIOCPU; size=SIZE_AUDIOCPU; width_bytes=1; end
            4: begin base=BASE_GFX1; size=SIZE_GFX1; width_bytes=4; end
            5: begin base=BASE_GFX2; size=SIZE_GFX2; width_bytes=4; end
            6: begin base=BASE_SPRITEGFX; size=SIZE_SPRITEGFX; width_bytes=8; end
            7: begin base=BASE_GFX4; size=SIZE_GFX4; width_bytes=8; end
            8: begin base=BASE_SPRLOOKUPROM; size=SIZE_SPRLOOKUPROM; width_bytes=2; big_word=1; end
            9: begin base=BASE_ADPCMA; size=SIZE_ADPCMA; width_bytes=1; end
            default: begin end
        endcase
        absolute_address=base+{3'b000,offset};
        valid=width_bytes!=0 && ({3'b000,offset}+{21'd0,width_bytes}<=size) &&
              ((absolute_address & ({21'd0,width_bytes}-1'b1))==0);
        granule_address=valid ? {absolute_address[24:3],3'b000} : 25'd0;
        lane=valid ? absolute_address[2:0] : 3'd0;
        shifted=granule_data >> (lane*8);
        data=0;
        if(valid) begin
            if(big_word) data={48'd0,shifted[7:0],shifted[15:8]};
            else case(width_bytes)
                1: data={56'd0,shifted[7:0]};
                4: data={32'd0,shifted[31:0]};
                8: data=shifted;
                default: data=0;
            endcase
        end
    end
endmodule
