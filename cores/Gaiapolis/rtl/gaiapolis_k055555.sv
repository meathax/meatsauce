// SPDX-License-Identifier: GPL-3.0-or-later
module gaiapolis_k055555 (
    input wire monster,
    input  logic        clk,
    input  logic        rst,
    input  logic        we,
    // K055555_word_w receives a 7-bit word offset in 0x488000-0x4880ff.
    input  logic [6:0]  addr,
    input  logic [1:0]  dsn,       // {UDSn,LDSn}, active low
    input  logic [15:0] din,
    output logic [7:0]  priority_code,
    output logic [7:0]  palette_code,
    output logic [3:0]  mix_code,
    output logic [7:0]  tile_blend,
    output logic [7:0]  tile_blend_on,
    output logic [3:0]  shadow_code,
    output logic [7:0]  shadow_priority1, shadow_priority2, shadow_priority3,
    output logic [7:0]  brightness_code,
    // K55_OSBRI (reg 43): brightness-mode select for OBJ (bits 1:0) and SUB1,
    // the ROZ plane (bits 3:2), using the same 0..3 -> K054338 BRI mode map as
    // K55_VBRI; the field order matches OS INMIX (reg 35). MAME 0.289 never
    // reads it (set_brightness() is only called for tile layers 0-3), so
    // sprites and ROZ do not fade there. Both Gaiapolis and Monster Maulers
    // program OSBRI=0x05 and ramp K054338 BRI3 together with VBRI during
    // fades and flashes (MAME bus trace, evidence/mame-blend-regs/).
    // K55_OSBRI_ON (reg 44) has no known consumer; kept as a raw tap.
    output logic [7:0]  osbri_code,
    output logic [7:0]  osbri_on_code,
    output logic [11:0] layer_palette0,
    output logic [11:0] layer_palette1,
    output logic [11:0] layer_palette2,
    output logic [11:0] layer_palette3,
    output logic [7:0]  layer_priority0,
    output logic [7:0]  layer_priority1,
    output logic [7:0]  layer_priority2,
    output logic [7:0]  layer_priority3,
    output logic [7:0]  input_enables,
    output logic [11:0] object_palette_base,
    output logic [11:0] roz_palette_base,
    output logic [7:0]  roz_priority,
    output logic [7:0]  unused_sub2_priority,
    output logic [1:0]  roz_mix,
    input  logic [6:0]  state_addr,
    output logic [7:0]  state_data
);
    // The device exposes a 128-byte window, although only registers 0..45
    // have documented meanings. Keeping all 128 bytes preserves the physical
    // address space and avoids an implicit/truncated alias.
    logic [7:0] regs [0:127];
    integer idx;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (idx = 0; idx < 128; idx = idx + 1)
                regs[idx] <= 8'h00;
        end else if (we) begin
            // K055555_write_reg stores byte values. MAME's word handler
            // writes the low byte only for a low-byte-only access; a
            // full-word access follows its else branch and therefore writes
            // the high byte.
            if (dsn == 2'b10)
                regs[addr] <= din[7:0];
            else if (dsn != 2'b11)
                regs[addr] <= din[15:8];
        end
    end

    // Documented register consumers used by the GX mixer. The full priority
    // pipeline is intentionally a later stage; these taps are byte-accurate.
    always_comb begin
        priority_code   = regs[15]; // K55_PRIINP_8 (OBJ)
        palette_code    = regs[27]; // K55_PALBASE_OBJ
        mix_code        = regs[33][3:0];
        tile_blend      = regs[33]; // K55_BLEND_ENABLES: two bits per tile layer
        tile_blend_on   = regs[34]; // K55_VINMIX_ON: internal/external mix mask
        shadow_code     = regs[40][3:0];
        shadow_priority1 = regs[37];
        shadow_priority2 = regs[38];
        shadow_priority3 = regs[39];
        brightness_code = regs[42]; // K55_VBRI: 2 bits per VRAM layer A/B/C/D
        osbri_code      = regs[43]; // K55_OSBRI (documented, unused by MAME)
        osbri_on_code   = regs[44]; // K55_OSBRI_ON (documented, unused by MAME)
        layer_priority0  = regs[7];
        layer_priority1  = regs[10];
        layer_priority2  = regs[13];
        layer_priority3  = regs[14];
        input_enables    = regs[45];
        // Palette bases are K055555_get_palette_index(n) << 4 colour codes of
        // 16 pens each, i.e. index = base << 8 (11 bits wrap at 2048 entries).
        // Gaiapolis callback masks the color-code base to seven bits,
        // then ORs in the six-bit sprite color before appending its pen.
        object_palette_base = monster ? {regs[27][3:0],8'b0} : {1'b0,regs[27][2:0],8'b0};
        roz_palette_base = {regs[28][3:0],8'b0};
        roz_priority = regs[16];
        unused_sub2_priority = regs[17];
        // MAME extended SUB1 drawing ignores the blend when reg35 is ff.
        // Reg36 is not consumed for this Gaiapolis path.
        roz_mix = regs[35] == 8'hff ? 2'd0 : regs[35][3:2];
        state_data = regs[state_addr];
        // K056832 overrides gfx granularity to 16 even for five-bit tiles.
        layer_palette0  = {regs[23][3:0],8'b0};
        layer_palette1  = {regs[24][3:0],8'b0};
        layer_palette2  = {regs[25][3:0],8'b0};
        layer_palette3  = {regs[26][3:0],8'b0};
    end
endmodule
