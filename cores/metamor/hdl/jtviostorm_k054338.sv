/*
 * Violent Storm K054338 color-math wrapper.
 *
 * The register map follows MAME's k054338_device (BSD-3-Clause reference).
 * The fixed-point channel arithmetic is adapted from the GPL-3.0-or-later
 * Bucky GX173 implementation, itself identified as a SiliconRE-derived
 * reconstruction. That donor is implementation evidence only; the
 * Violent Storm K055555 effect routing and analogue DAC remain open.
 */
module jtviostorm_k054338 (
    input  logic       clk,
    input  logic       rst,
    input  logic       we,
    // MAME's word_w offset is the 16-bit word number in 0x254000-0x25401f.
    input  logic [3:0] addr,
    input  logic [1:0] dsn,       // {UDSn,LDSn}, active low
    input  logic [15:0] din,
    input  logic [7:0] front_r, front_g, front_b,
    input  logic       pixel_valid,
    input  logic [7:0] back_r,  back_g,  back_b,
    input  logic       back_valid,
    // The title mixer will later provide the per-pixel selectors from the
    // K055555/object/tile path. This stage intentionally consumes only the
    // documented two-bit selector portion while the remaining routing is open.
    input  logic [3:0] mix_code,
    input  logic [3:0] shadow_code,
    input  logic [7:0] brightness_code,
    // Per-source layer index for the K55_VBRI 2-bit-per-layer brightness
    // field: 0/1/2/3 select VRAM tile layers A/B/C/D (matches the compositor's
    // selected_source encoding for lyrf/lyra/lyrb/lyrc); any other value
    // (4 = OBJ/sprite) is not modulated, matching MAME's set_brightness()
    // (konamigx_v.cpp:253-266), which is invoked only from
    // gx_draw_basic_tilemaps() for layer 0-3 (konamigx_v.cpp:695-701) and is
    // never called for sprites. Defaults to 0 so pre-existing instantiations
    // that do not drive this port keep the prior layer-A-only behaviour.
    input  logic [2:0] bri_layer_sel,
    output logic [7:0] red, green, blue
);
    logic [15:0] regs [0:15];
    integer idx;

    // MAME K054338 register constants.
    localparam integer REG_BGC_R   = 0;
    localparam integer REG_BGC_GB  = 1;
    localparam integer REG_SHD1R   = 2;
    localparam integer REG_BRI3    = 11;
    localparam integer REG_PBLEND  = 13;
    localparam integer REG_CONTROL = 15;

    // Explicit byte-lane update matching COMBINE_DATA().
    always_ff @(posedge clk) begin
        if (rst) begin
            for (idx = 0; idx < 16; idx = idx + 1)
                regs[idx] <= 16'h0000;
        end else begin
            if (we) begin
                if (!dsn[1]) regs[addr][15:8] <= din[15:8];
                if (!dsn[0]) regs[addr][ 7:0] <= din[ 7:0];
`ifdef VERILATOR
                if (addr == REG_PBLEND)
                    $display("K054338_PBLEND din=%04x dsn=%b old=%04x",din,dsn,regs[REG_PBLEND]);
`endif
            end

        end
    end

    wire [1:0] mix_sel = mix_code[1:0];
    wire [1:0] shd_sel = shadow_code[1:0];

    // set_brightness(layer): bri_mode = (K55_VBRI >> layer*2) & 3
    // (konamigx_v.cpp:255). Sprites (bri_layer_sel==4, or any other
    // non-tile value) are never brightness-modulated in MAME for this
    // driver, so they fall to the default (full brightness via
    // brightness_value's own default branch below).
    logic [1:0] bri_sel;
    always_comb begin
        case (bri_layer_sel)
            3'd0: bri_sel = brightness_code[1:0];
            3'd1: bri_sel = brightness_code[3:2];
            3'd2: bri_sel = brightness_code[5:4];
            3'd3: bri_sel = brightness_code[7:6];
            default: bri_sel = 2'd0;
        endcase
    end

    logic       mix_additive;
    logic [4:0] mix_level;
    always_comb begin
        mix_additive = 1'b0;
        mix_level    = 5'd0;
        case (mix_sel)
            2'd1: begin
                // k054338_device::set_alpha_level(): mode 1 -> low byte of
                // PBLEND, mode 2 -> high byte of PBLEND+1, mode 3 -> low byte
                // of PBLEND+1. Bit 5 of the byte is additive, 4:0 the level.
                mix_additive = regs[REG_PBLEND][5];
                mix_level    = regs[REG_PBLEND][4:0];
            end
            2'd2: begin
                mix_additive = regs[REG_PBLEND+1][13];
                mix_level    = regs[REG_PBLEND+1][12:8];
            end
            2'd3: begin
                mix_additive = regs[REG_PBLEND+1][5];
                mix_level    = regs[REG_PBLEND+1][4:0];
            end
            default: begin end
        endcase
        // mystwarr(config) (mystwarr.cpp:993-994, the base config viostorm
        // inherits) calls m_k054338->set_alpha_invert(1). k054338_device::
        // set_alpha_level() then applies "if (m_alpha_inv) mixlv = 0x1f -
        // mixlv;" (k054338.cpp:174) to the raw 5-bit register level before
        // any further use, unconditionally for every pblend mode and
        // regardless of the additive bit. Apply the same inversion here;
        // viostorm/metamrph never runs with alpha_invert clear, so this is
        // unconditional rather than register-gated.
        if (mix_sel != 2'd0)
            mix_level = 5'h1f - mix_level;
    end

    // set_alpha_level() (k054338.cpp:177) expands the raw 5-bit register
    // level to an 8-bit 0-255 scale before it is ever used as a blend
    // weight: "mixlv = (mixlv << 3) | (mixlv >> 2)". Every downstream
    // consumer (drawgfx.h alpha_blend_r32/r16: "(s*level + d*(256-level))
    // >>8") then treats that expanded value as a /256 fixed-point weight,
    // reaching full 255/255 unity gain at the maximum register level.
    // Perform the same expansion here instead of dividing the raw 5-bit
    // field by 32 (which tops out at 31/32, never unity).
    wire [7:0] mix_level8 = {mix_level, mix_level[4:2]};

    function automatic [7:0] mix_channel;
        input [7:0] front;
        input [7:0] back;
        input [7:0] level;
        input       additive;
        reg [8:0] inverse_level;
        reg [17:0] product;
        reg [17:0] value;
        reg signed [8:0] delta;
        reg signed [17:0] delta_product;
        reg signed [17:0] normal_value;
        begin
            inverse_level = 9'd256 - {1'b0,level};
            delta = 9'sd0;
            delta_product = 18'sd0;
            normal_value = 18'sd0;
            if (level == 8'd0) begin
                value = {10'd0,back};
            end else if (!additive && level == 8'hff) begin
                value = {10'd0,front};
            end else if (!additive) begin
                // Exact signed /256 form; preserve the endpoint and additive cases.
                delta = $signed({1'b0,front}) - $signed({1'b0,back});
                delta_product = delta * $signed({1'b0,level});
                normal_value = $signed({10'd0,back}) + (delta_product >>> 8);
                value = normal_value;
            end else begin
                product = {10'd0,front} * ({10'd0,level} + 18'd1);
                value = {10'd0,back} + (product >> 8);
            end
            mix_channel = (value > 18'd255) ? 8'hff : value[7:0];
        end
    endfunction

    logic signed [9:0] shd_r, shd_g, shd_b;
    always_comb begin
        shd_r = 10'sd0;
        shd_g = 10'sd0;
        shd_b = 10'sd0;
        case (shd_sel)
            2'd1: begin
                shd_r = $signed({regs[REG_SHD1R+0][8],regs[REG_SHD1R+0][8:0]});
                shd_g = $signed({regs[REG_SHD1R+1][8],regs[REG_SHD1R+1][8:0]});
                shd_b = $signed({regs[REG_SHD1R+2][8],regs[REG_SHD1R+2][8:0]});
            end
            2'd2: begin
                shd_r = $signed({regs[REG_SHD1R+3][8],regs[REG_SHD1R+3][8:0]});
                shd_g = $signed({regs[REG_SHD1R+4][8],regs[REG_SHD1R+4][8:0]});
                shd_b = $signed({regs[REG_SHD1R+5][8],regs[REG_SHD1R+5][8:0]});
            end
            2'd3: begin
                shd_r = $signed({regs[REG_SHD1R+6][8],regs[REG_SHD1R+6][8:0]});
                shd_g = $signed({regs[REG_SHD1R+7][8],regs[REG_SHD1R+7][8:0]});
                shd_b = $signed({regs[REG_SHD1R+8][8],regs[REG_SHD1R+8][8:0]});
            end
            default: begin end
        endcase
    end

    function automatic [7:0] add_shadow;
        input [7:0] component;
        input signed [9:0] delta;
        input              noclip;
        reg signed [9:0] table_delta;
        reg signed [10:0] value;
        begin
            // Emulator-derived GX shadow semantics: MAME's RGB32 drawing
            // indexes the shadow table with destination RGB15, then pal5bit()
            // expands each channel before adding the signed register delta.
            // dipalette.cpp also clamps table deltas to -255..255. Keep this
            // loss confined to shadows; ordinary RGB, blend and BGC stay 8-bit.
            table_delta = (delta < -10'sd255) ? -10'sd255 :
                          (delta > 10'sd255) ?  10'sd255 : delta;
            value = $signed({3'b000,component[7:3],component[7:5]}) +
                    $signed({table_delta[9],table_delta});
            if (noclip)
                add_shadow = value[7:0];
            else if (value < 0)
                add_shadow = 8'h00;
            else if (value > 11'sd255)
                add_shadow = 8'hff;
            else
                add_shadow = value[7:0];
        end
    endfunction

    wire [7:0] background_r = regs[REG_BGC_R][7:0];
    wire [7:0] background_g = regs[REG_BGC_GB][15:8];
    wire [7:0] background_b = regs[REG_BGC_GB][7:0];
    // GX starts every pixel with K054338 BGC before drawing candidates.
    // If the winner requests alpha but there is no runner-up GX candidate,
    // blend against that already-filled background, not palette entry zero.
    wire [7:0] blend_back_r = back_valid ? back_r : background_r;
    wire [7:0] blend_back_g = back_valid ? back_g : background_g;
    wire [7:0] blend_back_b = back_valid ? back_b : background_b;
    wire [7:0] mixed_r = mix_channel(front_r, blend_back_r, mix_level8, mix_additive);
    wire [7:0] mixed_g = mix_channel(front_g, blend_back_g, mix_level8, mix_additive);
    wire [7:0] mixed_b = mix_channel(front_b, blend_back_b, mix_level8, mix_additive);

    // K054338 KILL (control bit 0) can suppress all drawing. Background-only
    // pixels bypass layer effects; see the pipeline below.
    wire draw_pixel = regs[REG_CONTROL][0] && pixel_valid;

    logic [7:0] brightness_value;
    always_comb begin
        case (bri_sel)
            2'd1: brightness_value = regs[REG_BRI3][7:0];
            2'd2: brightness_value = regs[REG_BRI3+1][15:8];
            2'd3: brightness_value = regs[REG_BRI3+1][7:0];
            default: brightness_value = 8'hff;
        endcase
    end

    function automatic [7:0] apply_brightness;
        input [7:0] component;
        input [7:0] gain;
        reg [15:0] product;
        reg [16:0] rounded;
        begin
            // The physical brightness path is analogue. This digital
            // reconstruction keeps full-scale headroom and rounds the
            // 8x8 product before the output register.
            product = component * gain;
            rounded = {1'b0,product} + {9'd0,product[15:8]} + 17'd127;
            apply_brightness = rounded[15:8];
        end
    endfunction

    // Three-stage colour pipeline (was one long combinational cone from the
    // palette registers to red/green/blue). Stage 1 registers the blend,
    // stage 2 the effect selection and shadow, stage 3 the brightness product.
    // The 6-MHz pixel is sampled every 8 clocks, so the added latency of two
    // clocks stays inside the pixel window.
    reg [7:0] s1_mix_r, s1_mix_g, s1_mix_b;
    reg [7:0] s1_front_r, s1_front_g, s1_front_b;
    reg [7:0] s1_bg_r, s1_bg_g, s1_bg_b;
    reg       s1_draw, s1_front_sel, s1_noshd;
    reg [7:0] s2_r, s2_g, s2_b;
    reg [7:0] s2_bg_r, s2_bg_g, s2_bg_b;
    reg       s2_draw;
    wire [7:0] s1_en_r = s1_draw ? (s1_front_sel ? s1_front_r : s1_mix_r) : s1_bg_r;
    wire [7:0] s1_en_g = s1_draw ? (s1_front_sel ? s1_front_g : s1_mix_g) : s1_bg_g;
    wire [7:0] s1_en_b = s1_draw ? (s1_front_sel ? s1_front_b : s1_mix_b) : s1_bg_b;
    wire [7:0] s1_sh_r = add_shadow(s1_en_r, shd_r, regs[REG_CONTROL][5]);
    wire [7:0] s1_sh_g = add_shadow(s1_en_g, shd_g, regs[REG_CONTROL][5]);
    wire [7:0] s1_sh_b = add_shadow(s1_en_b, shd_b, regs[REG_CONTROL][5]);
    always_ff @(posedge clk) begin
        if (rst) begin
            red <= 8'h00; green <= 8'h00; blue <= 8'h00;
            s1_draw <= 1'b0; s2_draw <= 1'b0;
            s2_r <= 8'h00; s2_g <= 8'h00; s2_b <= 8'h00;
            s2_bg_r <= 8'h00; s2_bg_g <= 8'h00; s2_bg_b <= 8'h00;
        end else begin
            // stage 1: blend and pixel-state
            s1_mix_r <= mixed_r; s1_mix_g <= mixed_g; s1_mix_b <= mixed_b;
            s1_front_r <= front_r; s1_front_g <= front_g; s1_front_b <= front_b;
            s1_bg_r <= background_r; s1_bg_g <= background_g; s1_bg_b <= background_b;
            s1_draw <= draw_pixel;
            s1_front_sel <= (mix_sel == 2'd0);
            s1_noshd <= (shd_sel == 2'd0);
            // stage 2: layer effect and shadow; BGC bypasses both when not drawn
            s2_draw <= s1_draw;
            s2_bg_r <= s1_bg_r; s2_bg_g <= s1_bg_g; s2_bg_b <= s1_bg_b;
            s2_r <= s1_noshd ? s1_en_r : s1_sh_r;
            s2_g <= s1_noshd ? s1_en_g : s1_sh_g;
            s2_b <= s1_noshd ? s1_en_b : s1_sh_b;
            // stage 3: brightness
            red   <= s2_draw ? apply_brightness(s2_r, brightness_value) : s2_bg_r;
            green <= s2_draw ? apply_brightness(s2_g, brightness_value) : s2_bg_g;
            blue  <= s2_draw ? apply_brightness(s2_b, brightness_value) : s2_bg_b;
        end
    end
endmodule
