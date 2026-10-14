package suna8_media_pkg;

// The MRA descriptors use one flat byte-addressed download image.  Keep these
// addresses identical to the checked-in MRA files so the loader and the
// eventual SDRAM controller cannot silently disagree about a region.
localparam logic [24:0] MEDIA_MAIN_BASE   = 25'h000000;
localparam logic [24:0] MEDIA_AUDIO_BASE  = 25'h080000;
localparam logic [24:0] MEDIA_PCM_BASE    = 25'h090000;
localparam logic [24:0] MEDIA_GFX1_BASE   = 25'h0a0000;
localparam logic [24:0] MEDIA_GFX2_BASE   = 25'h1a0000;
localparam logic [24:0] MEDIA_SAMPLES_BASE = 25'h2a0000;
localparam logic [24:0] MEDIA_PROMS_BASE  = 25'h2b0000;

localparam logic [20:0] MEDIA_MAIN_SIZE   = 21'h050000;
localparam logic [19:0] MEDIA_AUDIO_SIZE  = 20'h010000;
localparam logic [19:0] MEDIA_PCM_SIZE    = 20'h010000;
localparam logic [20:0] MEDIA_GFX1_SIZE   = 21'h100000;
localparam logic [20:0] MEDIA_GFX2_SIZE   = 21'h100000;
localparam logic [19:0] MEDIA_SAMPLES_SIZE = 20'h010000;
localparam logic [15:0] MEDIA_PROMS_SIZE  = 16'h0100;

// Exact sequential index-0 image lengths emitted by the six curated MRAs.
// A profile is not allowed to release the machine until its complete image
// has arrived in order; this prevents a valid index-1 byte from booting CPUs
// against empty, truncated, or discontinuously addressed SDRAM contents.
localparam logic [24:0] MEDIA_IMAGE_HARDHEAD = 25'h2a8000;
localparam logic [24:0] MEDIA_IMAGE_SRANGER  = 25'h2a8000;
localparam logic [24:0] MEDIA_IMAGE_SPARKMAN = 25'h2b0000;
localparam logic [24:0] MEDIA_IMAGE_STARFIGH = 25'h2b0100;
localparam logic [24:0] MEDIA_IMAGE_HARDHEA2 = 25'h120000;
localparam logic [24:0] MEDIA_IMAGE_BRICKZN  = 25'h160000;
localparam logic [24:0] MEDIA_IMAGE_MAX      = MEDIA_IMAGE_STARFIGH;

typedef enum logic [2:0] {
    MEDIA_NONE    = 3'd0,
    MEDIA_MAIN    = 3'd1,
    MEDIA_AUDIO   = 3'd2,
    MEDIA_PCM     = 3'd3,
    MEDIA_GFX1    = 3'd4,
    MEDIA_GFX2    = 3'd5,
    MEDIA_SAMPLES = 3'd6,
    MEDIA_PROMS   = 3'd7
} suna8_media_region_t;

function automatic suna8_media_region_t media_region_for_address(
    input logic [24:0] address
);
    begin
        media_region_for_address = MEDIA_NONE;
        if ((address >= MEDIA_MAIN_BASE) &&
            (address < MEDIA_MAIN_BASE + MEDIA_MAIN_SIZE))
            media_region_for_address = MEDIA_MAIN;
        else if ((address >= MEDIA_AUDIO_BASE) &&
                 (address < MEDIA_AUDIO_BASE + MEDIA_AUDIO_SIZE))
            media_region_for_address = MEDIA_AUDIO;
        else if ((address >= MEDIA_PCM_BASE) &&
                 (address < MEDIA_PCM_BASE + MEDIA_PCM_SIZE))
            media_region_for_address = MEDIA_PCM;
        else if ((address >= MEDIA_GFX1_BASE) &&
                 (address < MEDIA_GFX1_BASE + MEDIA_GFX1_SIZE))
            media_region_for_address = MEDIA_GFX1;
        else if ((address >= MEDIA_GFX2_BASE) &&
                 (address < MEDIA_GFX2_BASE + MEDIA_GFX2_SIZE))
            media_region_for_address = MEDIA_GFX2;
        else if ((address >= MEDIA_SAMPLES_BASE) &&
                 (address < MEDIA_SAMPLES_BASE + MEDIA_SAMPLES_SIZE))
            media_region_for_address = MEDIA_SAMPLES;
        else if ((address >= MEDIA_PROMS_BASE) &&
                 (address < MEDIA_PROMS_BASE + MEDIA_PROMS_SIZE))
            media_region_for_address = MEDIA_PROMS;
    end
endfunction

function automatic logic [24:0] media_region_base(
    input suna8_media_region_t region
);
    begin
        case (region)
            MEDIA_MAIN:    media_region_base = MEDIA_MAIN_BASE;
            MEDIA_AUDIO:   media_region_base = MEDIA_AUDIO_BASE;
            MEDIA_PCM:     media_region_base = MEDIA_PCM_BASE;
            MEDIA_GFX1:    media_region_base = MEDIA_GFX1_BASE;
            MEDIA_GFX2:    media_region_base = MEDIA_GFX2_BASE;
            MEDIA_SAMPLES: media_region_base = MEDIA_SAMPLES_BASE;
            MEDIA_PROMS:   media_region_base = MEDIA_PROMS_BASE;
            default:       media_region_base = 25'd0;
        endcase
    end
endfunction

function automatic logic [24:0] media_region_offset(
    input logic [24:0] address,
    input suna8_media_region_t region
);
    media_region_offset = address - media_region_base(region);
endfunction

function automatic logic media_address_valid(input logic [24:0] address);
    media_address_valid = (media_region_for_address(address) != MEDIA_NONE);
endfunction

function automatic logic [24:0] media_image_size_for_profile(
    input logic [2:0] profile
);
    begin
        case (profile)
            3'd0: media_image_size_for_profile = MEDIA_IMAGE_HARDHEAD;
            3'd1: media_image_size_for_profile = MEDIA_IMAGE_SRANGER;
            3'd2: media_image_size_for_profile = MEDIA_IMAGE_SPARKMAN;
            3'd3: media_image_size_for_profile = MEDIA_IMAGE_STARFIGH;
            3'd4: media_image_size_for_profile = MEDIA_IMAGE_HARDHEA2;
            3'd5: media_image_size_for_profile = MEDIA_IMAGE_BRICKZN;
            default: media_image_size_for_profile = 25'd0;
        endcase
    end
endfunction

// Reflected CRC-32/ISO-HDLC byte step (polynomial 0xedb88320). The loader
// fingerprints the exact sequential stream received from MiSTer Main and the
// SDRAM backend applies the same function to a cold readback before releasing
// the CPUs. This proves the external memory path, not merely the HPS stream.
function automatic logic [31:0] media_crc32_byte(
    input logic [31:0] crc,
    input logic [7:0] data
);
    logic [31:0] next_crc;
    integer bit_index;
    begin
        next_crc = crc ^ {24'd0, data};
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            if (next_crc[0])
                next_crc = (next_crc >> 1) ^ 32'hedb88320;
            else
                next_crc = next_crc >> 1;
        end
        media_crc32_byte = next_crc;
    end
endfunction

endpackage
