module jtviostorm_k055555 (
    input  logic        clk,
    input  logic        rst,
    input  logic        we,
    // K055555_word_w receives a 7-bit word offset in 0x258000-0x2580ff.
    input  logic [6:0]  addr,
    input  logic [1:0]  dsn,       // {UDSn,LDSn}, active low
    input  logic [15:0] din,
    output logic [7:0]  priority_code,
    output logic [7:0]  palette_code,
    output logic [3:0]  mix_code,
    output logic [3:0]  shadow_code,
    output logic [7:0]  brightness_code,
    // K55_OSBRI (reg 43) / K55_OSBRI_ON (reg 44): documented as OBJ/SUB
    // brightness enable fields (k055555.cpp header comment, regs 43/44).
    // MAME 0.289's konamigx_v.cpp never reads either register for any
    // driver on this board (grep of konamigx_v.cpp/mystwarr_v.cpp finds no
    // OSBRI/OSBRI_ON consumer; set_brightness() at konamigx_v.cpp:253 is
    // only invoked for VRAM tile layers 0-3 from gx_draw_basic_tilemaps,
    // konamigx_v.cpp:695-701). Exposed here as raw taps for documentation
    // and any future evidence; not wired into brightness gain math because
    // no MAME-verified formula consumes them for this title.
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
    output logic [11:0] object_palette_base
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
        shadow_code     = regs[40][3:0];
        brightness_code = regs[42]; // K55_VBRI: 2 bits per VRAM layer A/B/C/D
        osbri_code      = regs[43]; // K55_OSBRI (documented, unused by MAME)
        osbri_on_code   = regs[44]; // K55_OSBRI_ON (documented, unused by MAME)
        layer_priority0  = regs[7];
        layer_priority1  = regs[10];
        layer_priority2  = regs[13];
        layer_priority3  = regs[14];
        input_enables    = regs[45];
        // Violent Storm overrides the base GX configuration with
        // screen_update_metamrph.  Its sprite callback uses a 16-word object
        // palette block: K055555_get_palette_index(4) << 4.  Keep the
        // physical palette-index boundary explicit at 12 bits, matching the
        // complete 0x1000-word palette RAM window.
        object_palette_base = ({4'b0000,regs[27]} << 4);
        // MAME's screen update uses K055555_get_palette_index(layer) << 4
        // for the four K056832 layers. Preserve all seven documented base
        // bits and expose the resulting 12-bit word index to the palette
        // boundary; physical masking, if any, remains explicit there.
        layer_palette0  = {regs[23],4'b0};
        layer_palette1  = {regs[24],4'b0};
        layer_palette2  = {regs[25],4'b0};
        layer_palette3  = {regs[26],4'b0};
    end
endmodule
