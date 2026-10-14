package suna8_profile_pkg;

typedef enum logic [2:0] {
    PROFILE_HARDHEAD = 3'd0,
    PROFILE_SRANGER  = 3'd1,
    PROFILE_SPARKMAN = 3'd2,
    PROFILE_STARFIGH = 3'd3,
    PROFILE_HARDHEA2 = 3'd4,
    PROFILE_BRICKZN   = 3'd5
} suna8_profile_t;

typedef struct packed {
    logic has_ym3812;
    logic has_dual_ym2203;
    logic has_ay8910;
    logic has_samples;
    logic has_pcm_cpu;
    logic has_dual_sprite;
    logic has_palette_bank;
    logic has_banked_sprite_ram;
    logic encrypted_main_cpu;
    logic [1:0] palette_banks;
} suna8_profile_features_t;

function automatic suna8_profile_features_t profile_features(input suna8_profile_t profile);
    profile_features = '0;
    case (profile)
        PROFILE_HARDHEAD: begin
            profile_features.has_ym3812 = 1'b1;
            profile_features.has_ay8910 = 1'b1;
            profile_features.has_samples = 1'b1;
            profile_features.encrypted_main_cpu = 1'b1;
            profile_features.palette_banks = 2'd1;
        end
        PROFILE_SRANGER: begin
            profile_features.has_dual_ym2203 = 1'b1;
            profile_features.has_samples = 1'b1;
            profile_features.palette_banks = 2'd1;
        end
        PROFILE_SPARKMAN: begin
            profile_features.has_ym3812 = 1'b1;
            profile_features.has_ay8910 = 1'b1;
            profile_features.has_samples = 1'b1;
            profile_features.has_dual_sprite = 1'b1;
            profile_features.encrypted_main_cpu = 1'b1;
            profile_features.palette_banks = 2'd1;
        end
        PROFILE_STARFIGH: begin
            profile_features.has_ym3812 = 1'b1;
            profile_features.has_ay8910 = 1'b1;
            profile_features.has_samples = 1'b1;
            profile_features.encrypted_main_cpu = 1'b1;
            profile_features.has_banked_sprite_ram = 1'b1;
            profile_features.palette_banks = 2'd1;
        end
        PROFILE_HARDHEA2: begin
            profile_features.has_ym3812 = 1'b1;
            profile_features.has_ay8910 = 1'b1;
            profile_features.has_pcm_cpu = 1'b1;
            profile_features.encrypted_main_cpu = 1'b1;
            profile_features.has_banked_sprite_ram = 1'b1;
            profile_features.palette_banks = 2'd1;
        end
        PROFILE_BRICKZN: begin
            profile_features.has_ym3812 = 1'b1;
            profile_features.has_ay8910 = 1'b1;
            profile_features.has_pcm_cpu = 1'b1;
            profile_features.encrypted_main_cpu = 1'b1;
            profile_features.has_banked_sprite_ram = 1'b1;
            profile_features.has_palette_bank = 1'b1;
            profile_features.palette_banks = 2'd2;
        end
        default: begin
            profile_features = '0;
        end
    endcase
endfunction

function automatic logic profile_code_valid(input logic [2:0] code);
    profile_code_valid = (code <= PROFILE_BRICKZN);
endfunction

endpackage
