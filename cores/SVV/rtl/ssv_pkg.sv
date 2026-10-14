// SPDX-License-Identifier: GPL-3.0-or-later
// Universal SSV memory / ROM layout selected by the runtime MRA descriptor.
`timescale 1ns/1ps

package ssv_pkg;

    // -----------------------------------------------------------------------
    // SDRAM layout.
    //
    // Sizes CONFIRMED against a real SAM-5127 cartridge (28 Jul 2026): the
    // graphics sockets are silkscreened `16M-MASK`, i.e. 16 Mbit (2 MB) mask
    // ROMs, in four banks of four. Dyna Gear populates six of those sixteen
    // positions (6 x 2 MB = 12 MB of graphics) plus two more for samples
    // (4 MB). A fully populated SAM-5127 tops out at 32 MB of graphics, so a
    // family title needing more than that is not a plain SAM-5127 and will
    // need its own layout block below.
    //
    // See docs/hardware/SSV_BOARD_HARDWARE.md.
    //
    // GRAPHICS REPACK (see docs/SDRAM_GFX_REPACK_DESIGN.md).
    //
    // The graphics region is no longer a copy of MAME's sprite ROM. Every
    // 16-pixel tile row occupies one aligned 16-byte record:
    //
    //   byte  0.. 3  MAME graphics quarter 0 -> plane01
    //   byte  4.. 7  quarter 1               -> plane23
    //   byte  8..11  quarter 2               -> plane45
    //   byte 12..15  quarter 3 -- NEVER WRITTEN on Dyna Gear; the fetcher
    //                forces plane67 to zero rather than reading it.
    //
    // so one 128-bit p2 burst supplies a whole row instead of two 64-bit p1
    // bursts. The old SDR_SPRITES_* names are gone deliberately: they now
    // describe something that no longer exists.
    //
    // The region grew 12 MB -> 16 MB (the unwritten quarter-3 slot). To keep
    // XRAM and CPU RAM on their existing bases -- five testbenches hardcode
    // 0x1100000/0x1160000 -- graphics grows into the gap the sample region
    // vacates, and the samples move above CPU RAM. SDR_SAMPLES_BASE is the
    // ONLY constant whose value changes.
    //
    // BANK MAP (128 MB module: 64M x 16 = 4 banks x 8192 rows x 2048 cols).
    //
    // The controller decodes bank from word address bits [26:25], i.e. BYTE
    // address [27:26], so each bank is 32 MB:
    //
    //   bank 0  0x0000000  V60 program, XRAM ($160000), CPU RAM ($400000)
    //   bank 1   0x2000000  packed graphics records (up to 32 MiB)
    //   bank 2   0x4000000  free
    //   bank 3   0x6000000  ES5506 samples, then optional ST010 image
    //
    // Regions are placed in SEPARATE banks on purpose, and it is not
    // cosmetic. Every bank holds one open row; two clients in the same bank
    // evict each other's row and pay PRE + tRP + ACT + tRCD = 6 clk_ram, twice.
    //
    // Measured (docs/PHASE0_MEASUREMENT.md): with the old 32 MB map the whole
    // layout fell inside one bank once the geometry widened, and row conflicts
    // rose from 564,030 to 1,033,032 over 215 gameplay frames while the
    // graphics port's row-hit rate fell from 92.0% to 89.0%. Separating the
    // regions is what takes that back.
    //
    // Do NOT "tidy" these into one contiguous ascending block. layout_fault()
    // below checks pairwise non-overlap precisely so this map is legal.

    localparam int SDR_AW = 26;

    localparam logic [SDR_AW:0] SDR_MAINCPU_BASE = 27'h0000000; // bank 0
    localparam logic [SDR_AW:0] SDR_GFX_BASE     = 27'h2000000; // bank 1

    // CPU-writable regions parked in SDRAM because they do not fit beside the
    // board RAMs in Cyclone V block memory.
    //
    // SDR_CPU_RAM_BASE backs the CPU window at $400000. It was previously
    // called SDR_DYNA_RAM_BASE, which read as though the region were a Dyna
    // Gear invention; it is not, it is the board's RAM at that address.
    localparam logic [SDR_AW:0] SDR_XRAM_BASE    = 27'h0400000; // bank 0
    localparam logic [SDR_AW:0] SDR_CPU_RAM_BASE = 27'h0420000; // bank 0
    // Cairblad's address map adds a 64 KiB battery-backed NVRAM window at
    // $580000. Keep it in the unused tail of bank 0 so it uses the existing
    // external SDRAM path rather than spending another block-RAM instance.
    localparam logic [SDR_AW:0] SDR_NVRAM_BASE   = 27'h0470000; // bank 0
    localparam logic [SDR_AW:0] SDR_EAGL_RAM_BASE = 27'h0500000; // 4 MiB
    localparam logic [SDR_AW:0] SDR_SAMPLES_BASE = 27'h6000000; // bank 3

    // ST010 (NEC uPD96050) program ROM, for the three drifto94_state titles.
    //
    // Put this small image immediately after the fixed 8 MiB sample slot in
    // bank 3; the regions do not overlap and the descriptor still selects
    // whether the DSP exists. Bank 2 remains free in the supported profile.
    //
    // The whole 69,632-byte st010.bin image is placed here contiguously:
    //   + 0x00000 .. 0x0ffff   "dspprg", 16384 x 32-bit big-endian, 24 used
    //   + 0x10000 .. 0x10fff   "dspdata", 2048 x 16-bit big-endian
    // Only the program half is ever READ from SDRAM -- the data half is 4 M10K
    // on chip and is written there directly by the loader -- but placing both
    // keeps the loader's stream mapping a single identity offset instead of a
    // special case, and the 4 KB costs nothing.
    //
    // The base MUST be 8-byte aligned: program fetch uses the controller's
    // 64-bit p5 port, whose address is [SDR_AW:3].
    localparam logic [SDR_AW:0] SDR_ST010_BASE = 27'h6800000; // bank 3 tail

    // Sizes of the regions inside the MRA index-0 STREAM. These are the
    // shipped game's actual byte counts and are NOT the SDRAM slot sizes
    // below; conflating the two is why the map previously only described
    // Dyna Gear.
    localparam logic [26:0] STREAM_MAINCPU_SIZE = 27'h0100000; //  1 MB
    localparam logic [26:0] STREAM_SAMPLES_SIZE = 27'h0400000; //  4 MB

    localparam logic [26:0] STREAM_MAINCPU   = 27'h0000000;
    localparam logic [26:0] STREAM_SPRITES   = 27'h0100000;
    localparam logic [26:0] STREAM_SAMPLES   = 27'h0D00000;
    // st010.bin, appended after the samples. Present only in the MRAs for the
    // three drifto94_state titles; a title without it simply never sends bytes
    // in this range, which is why extending STREAM_END is not observable for
    // Dyna Gear.
    localparam logic [26:0] STREAM_ST010      = 27'h1100000;
    localparam logic [26:0] STREAM_ST010_SIZE = 27'h0011000; // 69,632 bytes
    localparam logic [26:0] STREAM_END       = 27'h1111000;

    // Byte offset inside st010.bin where "dspdata" begins (ssv.cpp ROM_COPY).
    localparam logic [26:0] ST010_DATA_OFFSET = 27'h0010000;

    // Region sizes, so the assertions below are checkable rather than implied.
    localparam logic [SDR_AW:0] SDR_MAINCPU_SIZE = 27'h0400000; //  4 MB slot
    localparam logic [SDR_AW:0] SDR_GFX_SIZE     = 27'h2000000; // 32 MB slot
    localparam logic [SDR_AW:0] SDR_XRAM_SIZE    = 27'h0020000; // 128 KB
    localparam logic [SDR_AW:0] SDR_CPU_RAM_SIZE = 27'h0041000; // SRMP7 0x400fb0
    localparam logic [SDR_AW:0] SDR_NVRAM_SIZE   = 27'h0010000; //  64 KB
    localparam logic [SDR_AW:0] SDR_EAGL_RAM_SIZE = 27'h0400000;
    localparam logic [SDR_AW:0] SDR_SAMPLES_SIZE = 27'h0800000; //  8 MB slot
    localparam logic [SDR_AW:0] SDR_ST010_SIZE   = 27'h0011000; // 68 KB exact

    // Raw graphics bytes in the MRA stream: 3 populated quarters x 4 MB.
    // The MRA itself is unchanged; only where the loader puts the bytes is.
    localparam logic [26:0] STREAM_GFX_SIZE  = 27'h0C00000;

    // MAME ssv_state::vblank_r() returns the raster status in the upper byte:
    // VBLANK sets bits 12 and 13 (0x3000), HBLANK sets bit 11 (0x0800).
    // Keep this board-visible encoding in one shared helper so a game that
    // polls $1c0000 sees the same status in every descriptor profile.
    function automatic logic [15:0] ssv_video_status(
        input logic vblank, input logic hblank
    );
        ssv_video_status = (vblank ? 16'h3000 : 16'h0000) |
                           (hblank ? 16'h0800 : 16'h0000);
    endfunction

    // ES5506 compressed samples use the OTTO u-law equation from MAME's
    // es5506_device::compute_tables(), rather than a conventional telephony
    // u-law table.  Keep it in the shared package so the voice engine and
    // source-backed regressions cannot silently grow different decoders.
    function automatic logic signed [15:0] es5506_ulaw_decode(
        input logic [7:0] code
    );
        logic [15:0] rawval;
        logic [15:0] mantissa;
        logic [2:0] exponent;
        logic signed [15:0] signed_mantissa;
        begin
            rawval = {code, 8'h80};
            exponent = rawval[15:13];
            mantissa = rawval << 3;
            if (exponent == 3'd0) begin
                signed_mantissa = mantissa;
                es5506_ulaw_decode = signed_mantissa >>> 7;
            end else begin
                mantissa = (mantissa >> 1) | ((~mantissa) & 16'h8000);
                signed_mantissa = mantissa;
                es5506_ulaw_decode = signed_mantissa >>> (7 - exponent);
            end
        end
    endfunction

    // Quarters the loader writes vs. slots the record reserves. The 4/3
    // expansion in SDR_GFX_SIZE is exactly this ratio, and it is zero for a
    // title that populates all four quarters.
    localparam logic [26:0] GFX_QUARTERS_LOADED = 27'd3;
    localparam logic [26:0] GFX_QUARTERS_PACKED = 27'd4;

    // MiSTer SDRAM module fitted on the target board.
    localparam logic [SDR_AW+1:0] SDR_TOTAL_BYTES = 28'h8000000; // 128 MB

    // -----------------------------------------------------------------------
    // PER-GAME CONFIGURATION
    //
    // One universal core supports the nine hardware profiles selected by the
    // MRA descriptor. What varies between them is small but not derivable from
    // the ROM stream, so
    // it is carried explicitly. Sizes come from MAME's ROM_REGION declarations
    // (src/mame/seta/ssv.cpp), which is the authority for every field here.
    //
    // Tile-code wrapping is the subtle one. MAME does
    // `code % gfxelement->elements()` (ssv_v.cpp), a true MODULO, and
    // elements() = sprites_region / 128:
    //
    //   ultrax                       0xC00000 -> 0x18000 = 3 * 2^15
    //   dynagear                    0x1000000 -> 0x20000 =     2^17
    //   twineag2/stmblade           0x1800000 -> 0x30000 = 3 * 2^16
    //   cairblad/drifto94/vasara*   0x2000000 -> 0x40000 =     2^18
    //   mslider                     0xA00000  -> 0x14000 = 5 * 2^14
    //
    // Five of the nine supported entries use a non-power-of-two region, so the
    // `wrap_code = code[16:0]` mask is wrong for them twice over: wrong width
    // and wrong wrap rule. Every case is either 2^k, 3*2^k, or 5*2^k. For odd
    //     code % (3<<k) == ((code >> k) % 3) << k | code[k-1:0]
    // with (code>>k) at most 6 bits, so the modulo is a small LUT rather than
    // a divider.
    // -----------------------------------------------------------------------
    typedef struct packed {
        logic [3:0] game_id;
        logic [2:0] prog_mb;            // 1, 2 or 4
        logic [6:0] gfx_mb;             // includes SRMP7's 64 MiB board
        logic [4:0] gfx_code_k;         // tile modulus exponent
        logic       gfx_code_mul3;      // modulus is 3<<k, not 1<<k
        logic       gfx_code_mul5;      // modulus is 5<<k, not 1<<k
        // (1<<gfx_code_k)-1, precomputed. It is derived, not independent, but
        // it MUST be a stored field rather than recomputed in the wrap: as a
        // variable shift it put a 20-bit barrel shifter in the combinational
        // path from this record to the SDRAM address and cost -12.7 ns.
        logic [19:0] gfx_code_mask;
        logic [2:0] gfx_quarters;       // populated quarters: 3 or 4
        logic [7:0] bank_map;           // 2 bits per ES5506 CR bank
        logic [3:0] bank_valid;         // which CR banks carry data
        logic       tile_code_identity; // init_ssv_tilescram vs init_ssv
        logic       irq_level1_line0;   // init_ssv_irq1 (twineag2, ultrax)
        // 0 none, 1 decoded but idle, 2 decoded six-button input window.
        logic [1:0] extra_input_mode;
        logic       lockout_inverted;   // descriptor fact; no coin gating yet
        logic       has_nvram;          // decodes the descriptor NVRAM window
        // NVRAM map size: 0 none, 1 = $580000-$5807ff, 2 = $580000-$58ffff.
        logic [1:0] nvram_mode;
        // ST010 (uPD96050) daughterboard present: drifto94, stmblade, twineag2.
        // Carried in the spare bit 3 of the config block's flags0 byte, beside
        // tile_code_identity / irq_level1_line0 / reserved descriptor bit 2.
        logic       has_st010;
        // drifto94_map exposes machine().rand() reads at $510000/$520000;
        // this remains descriptor-selected rather than a set-name branch.
        logic       has_drifto_unknown;
        logic [5:0] sample_mb;          // concatenated loaded ES5506 banks
        logic [1:0] wdog_mode;          // 0 none, 1 read-kick, 2 write-kick
        // Extra CPU RAM selected by the MAME address map: 0 none, 1 =
        // $400000-$43ffff, 2 = $010000-$03ffff.  This is board-map data,
        // not a set-name branch, and keeps the one universal core honest.
        logic [1:0] extra_ram_mode;
        // 0 normal SYSTEM port; 1 fixes Test/Tilt high (Vasara wiring).
        logic       system_input_mode;
        // Descriptor-v3 family extensions.  These are hardware/map classes,
        // never set names: zero preserves the original SSV profile.
        logic       irq_level2_line120;
        logic       mainram_mirror_010000;
        logic [3:0] input_layout;
        logic [2:0] mahjong_mode;
        logic [2:0] custom_output_mode;
        // Descriptor-selected MiSTer convenience inputs. These are not PCB
        // features: each selects one shared frame-timed mapper.
        logic       rapid_fire_b3_to_b1;
        logic       rapid_fire_b1;
        logic       rapid_fire_b2;
        logic       srmp7_sample_half_bank;
        logic       srmp7_irqv_mame;
        // 1 Eagle/uPD4701, 2 Sexy/uPD7001, 3 GDFS/ST0020+ADC+EEPROM.
        logic [1:0] optional_io_mode;
        logic [7:0] adc_conversion_cycles;
        logic [7:0] visible_width_half; // exact MAME visarea width / 2
        logic [7:0] visible_height;     // exact MAME visarea height
    } ssv_cfg_t;

    // Dyna Gear (SAM-5127). Reproduces today's hardwired behaviour exactly, so
    // it is the reference the generalisation is regression-tested against.
    function automatic ssv_cfg_t cfg_dynagear();
        cfg_dynagear = '0;
        cfg_dynagear.game_id = 4'd0;
        cfg_dynagear.prog_mb = 3'd1;
        cfg_dynagear.gfx_mb = 6'd16;
        cfg_dynagear.gfx_code_k = 5'd17;
        cfg_dynagear.gfx_code_mask = 20'h1ffff;
        cfg_dynagear.gfx_quarters = 3'd3;
        cfg_dynagear.bank_valid = 4'b0100;
        cfg_dynagear.extra_input_mode = 2'd1;
        cfg_dynagear.sample_mb = 6'd4;
        cfg_dynagear.wdog_mode = 2'd1;
        cfg_dynagear.extra_ram_mode = 2'd1;
        cfg_dynagear.visible_width_half = 8'd168;
        cfg_dynagear.visible_height = 8'd240;
    endfunction

    // The three requested shooter sets. These records mirror the generated
    // MRA configuration block, whose fields are derived from MAME's ssv.cpp.
    function automatic ssv_cfg_t cfg_cairblad();
        cfg_cairblad = '0;
        cfg_cairblad.game_id = 4'd1;
        cfg_cairblad.prog_mb = 3'd2;
        cfg_cairblad.gfx_mb = 6'd32;
        cfg_cairblad.gfx_code_k = 5'd18;
        cfg_cairblad.gfx_code_mask = 20'h3ffff;
        cfg_cairblad.gfx_quarters = 3'd3;
        cfg_cairblad.bank_valid = 4'b0001;
        cfg_cairblad.tile_code_identity = 1'b1;
        cfg_cairblad.lockout_inverted = 1'b1;
        cfg_cairblad.has_nvram = 1'b1;
        cfg_cairblad.nvram_mode = 2'd2;
        cfg_cairblad.sample_mb = 6'd4;
        cfg_cairblad.wdog_mode = 2'd1;
        cfg_cairblad.visible_width_half = 8'd169;
        cfg_cairblad.visible_height = 8'd240;
    endfunction

    function automatic ssv_cfg_t cfg_vasara();
        cfg_vasara = '0;
        cfg_vasara.game_id = 4'd2;
        cfg_vasara.prog_mb = 3'd4;
        cfg_vasara.gfx_mb = 6'd32;
        cfg_vasara.gfx_code_k = 5'd18;
        cfg_vasara.gfx_code_mask = 20'h3ffff;
        cfg_vasara.gfx_quarters = 3'd4;
        cfg_vasara.bank_map = 8'h04;
        cfg_vasara.bank_valid = 4'b0011;
        cfg_vasara.sample_mb = 6'd8;
        cfg_vasara.wdog_mode = 2'd2;
        cfg_vasara.system_input_mode = 1'b1;
        cfg_vasara.rapid_fire_b3_to_b1 = 1'b1;
        cfg_vasara.visible_width_half = 8'd168;
        cfg_vasara.visible_height = 8'd240;
    endfunction

    function automatic ssv_cfg_t cfg_vasara2();
        cfg_vasara2 = cfg_vasara();
        cfg_vasara2.game_id = 4'd3;
    endfunction

    function automatic ssv_cfg_t cfg_drifto94();
        cfg_drifto94 = cfg_vasara();
        cfg_drifto94.game_id   = 4'd4;
        cfg_drifto94.has_nvram = 1'b1;
        cfg_drifto94.nvram_mode = 2'd1; // drifto94_map $580000-$5807ff
        cfg_drifto94.has_st010 = 1'b1;
        cfg_drifto94.has_drifto_unknown = 1'b1;
        cfg_drifto94.wdog_mode = 2'd0;
        cfg_drifto94.system_input_mode = 1'b0;
        cfg_drifto94.visible_height = 8'd238;
    endfunction

    function automatic ssv_cfg_t cfg_stmblade();
        cfg_stmblade = cfg_drifto94();
        cfg_stmblade.game_id       = 4'd5;
        cfg_stmblade.gfx_mb        = 6'd24;
        cfg_stmblade.gfx_code_k    = 5'd16;
        cfg_stmblade.gfx_code_mul3 = 1'b1;
        cfg_stmblade.gfx_code_mask = 20'h0ffff;
        cfg_stmblade.gfx_quarters  = 3'd3;
        cfg_stmblade.bank_map      = 8'h00;
        cfg_stmblade.bank_valid    = 4'b0001;
        cfg_stmblade.has_nvram     = 1'b1;
        cfg_stmblade.sample_mb     = 6'd4;
        cfg_stmblade.visible_width_half = 8'd176;
        cfg_stmblade.visible_height = 8'd240;
    endfunction

    function automatic ssv_cfg_t cfg_twineag2();
        cfg_twineag2 = cfg_stmblade();
        cfg_twineag2.game_id          = 4'd6;
        cfg_twineag2.prog_mb          = 3'd2;
        cfg_twineag2.bank_map         = 8'h44;
        cfg_twineag2.bank_valid       = 4'b1111;
        cfg_twineag2.irq_level1_line0 = 1'b1;
        cfg_twineag2.has_nvram        = 1'b0;
        cfg_twineag2.nvram_mode       = 2'd0;
        cfg_twineag2.has_drifto_unknown = 1'b0;
        cfg_twineag2.sample_mb        = 6'd8;
        cfg_twineag2.wdog_mode        = 2'd1;
        cfg_twineag2.extra_ram_mode   = 2'd2; // twineag2_map $010000-$03ffff
        cfg_twineag2.rapid_fire_b1    = 1'b1;
        cfg_twineag2.rapid_fire_b2    = 1'b1;
        // twineag2() restores the standard 336-pixel SSV visible width;
        // do not inherit STM Blade's wider 352-pixel machine configuration.
        cfg_twineag2.visible_width_half = 8'd168;
    endfunction

    function automatic ssv_cfg_t cfg_ultrax();
        cfg_ultrax = cfg_twineag2();
        cfg_ultrax.game_id          = 4'd7;
        cfg_ultrax.gfx_mb           = 6'd12;
        cfg_ultrax.gfx_code_k       = 5'd15;
        cfg_ultrax.gfx_code_mask    = 20'h07fff;
        cfg_ultrax.has_st010        = 1'b0;
    endfunction

    function automatic ssv_cfg_t cfg_mslider();
        cfg_mslider = '0;
        cfg_mslider.game_id               = 4'd8;
        cfg_mslider.prog_mb               = 3'd1;
        cfg_mslider.gfx_mb                = 7'd10;
        cfg_mslider.gfx_code_k            = 5'd14;
        cfg_mslider.gfx_code_mul5         = 1'b1;
        cfg_mslider.gfx_code_mask         = 20'h03fff;
        cfg_mslider.gfx_quarters          = 3'd3;
        cfg_mslider.bank_valid            = 4'b0001;
        cfg_mslider.sample_mb             = 6'd4;
        cfg_mslider.mainram_mirror_010000 = 1'b1;
        cfg_mslider.visible_width_half   = 8'd176;
        cfg_mslider.visible_height       = 8'd240;
    endfunction

    // Survival Arts (USA). Mirrors the generated MRA descriptor
    // (53030118100103000480090904A8F0...): 1 MiB program, 24 MiB graphics
    // (3x8 MiB), x3 tile code multiplier, six-button window at $500008.
    function automatic ssv_cfg_t cfg_survartsu();
        cfg_survartsu = '0;
        cfg_survartsu.game_id           = 4'd9;
        cfg_survartsu.prog_mb           = 3'd1;
        cfg_survartsu.gfx_mb            = 7'd24;
        cfg_survartsu.gfx_code_k        = 5'd16;
        cfg_survartsu.gfx_code_mul3     = 1'b1;
        cfg_survartsu.gfx_code_mask     = 20'h0ffff;
        cfg_survartsu.gfx_quarters      = 3'd3;
        cfg_survartsu.bank_valid        = 4'b0100;
        cfg_survartsu.extra_input_mode  = 2'd2;
        cfg_survartsu.sample_mb         = 6'd4;
        cfg_survartsu.wdog_mode         = 2'd1;
        cfg_survartsu.extra_ram_mode    = 2'd1;
        cfg_survartsu.visible_width_half = 8'd168;
        cfg_survartsu.visible_height    = 8'd240;
    endfunction

    function automatic ssv_cfg_t cfg_for_game(input logic [3:0] game_id);
        case (game_id)
            4'd1:    cfg_for_game = cfg_cairblad();
            4'd2:    cfg_for_game = cfg_vasara();
            4'd3:    cfg_for_game = cfg_vasara2();
            4'd4:    cfg_for_game = cfg_drifto94();
            4'd5:    cfg_for_game = cfg_stmblade();
            4'd6:    cfg_for_game = cfg_twineag2();
            4'd7:    cfg_for_game = cfg_ultrax();
            4'd8:    cfg_for_game = cfg_mslider();
            4'd9:    cfg_for_game = cfg_survartsu();
            default: cfg_for_game = cfg_dynagear();
        endcase
    endfunction

    // MAME only decodes the extra-button window for maps that explicitly
    // expose $500008-$500009. Keep the address predicate beside
    // the descriptor type so the universal core cannot accidentally turn the
    // window into a global alias when another set is selected.
    function automatic logic extra_input_window_cfg(
        input ssv_cfg_t cfg,
        input logic [23:0] addr
    );
        extra_input_window_cfg = (cfg.extra_input_mode != 2'd0) &&
            (addr >= 24'h500008) && (addr <= 24'h500009);
    endfunction

    function automatic logic [8:0] active_width_cfg(input ssv_cfg_t cfg);
        active_width_cfg = {cfg.visible_width_half, 1'b0};
    endfunction

    function automatic logic [8:0] active_height_cfg(input ssv_cfg_t cfg);
        active_height_cfg = {1'b0, cfg.visible_height};
    endfunction

    // MRA index-0 stream boundaries. The graphics stream contains the
    // populated quarters only; the loader expands each row into a four-quarter
    // 16-byte record in SDRAM. The sample stream is four MiB per loaded
    // ES5506 bank, including the zero-filled lane implied by ROM_LOAD16_BYTE.
    function automatic logic [26:0] stream_prog_size_cfg(input ssv_cfg_t cfg);
        stream_prog_size_cfg = 27'(cfg.prog_mb) << 20;
    endfunction

    function automatic logic [26:0] stream_gfx_size_cfg(input ssv_cfg_t cfg);
        if (cfg.gfx_quarters == 3'd4)
            stream_gfx_size_cfg = 27'(cfg.gfx_mb) << 20;
        else
            stream_gfx_size_cfg = (27'(cfg.gfx_mb) << 18) * 27'd3;
    endfunction

    function automatic logic [26:0] stream_gfx_start_cfg(input ssv_cfg_t cfg);
        stream_gfx_start_cfg = stream_prog_size_cfg(cfg);
    endfunction

    function automatic logic [26:0] stream_samples_start_cfg(input ssv_cfg_t cfg);
        stream_samples_start_cfg = stream_gfx_start_cfg(cfg) +
                                   stream_gfx_size_cfg(cfg);
    endfunction

    function automatic logic [26:0] stream_samples_size_cfg(input ssv_cfg_t cfg);
        stream_samples_size_cfg = 27'(cfg.sample_mb) << 20;
    endfunction

    function automatic logic [26:0] stream_st010_start_cfg(input ssv_cfg_t cfg);
        stream_st010_start_cfg = stream_samples_start_cfg(cfg) +
                                 stream_samples_size_cfg(cfg);
    endfunction

    function automatic logic [26:0] stream_end_cfg(input ssv_cfg_t cfg);
        stream_end_cfg = stream_st010_start_cfg(cfg) +
                         (cfg.has_st010 ? STREAM_ST010_SIZE : 27'd0);
    endfunction

    function automatic logic [SDR_AW:1] sample_word_addr_cfg(
        input ssv_cfg_t cfg, input logic [1:0] bank,
        input logic [31:0] accum, input logic srmp7_bank
    );
        logic [1:0] slot;
        begin
            case (bank)
                2'd0: slot = cfg.bank_map[1:0];
                2'd1: slot = cfg.bank_map[3:2];
                2'd2: slot = cfg.bank_map[5:4];
                default: slot = cfg.bank_map[7:6];
            endcase
            if (cfg.srmp7_sample_half_bank) begin
                case (bank)
                    2'd0: slot = 2'd0;
                    2'd1: slot = 2'd1;
                    2'd2: slot = 2'd2;
                    default: slot = 2'd0; // region 3 base is slot 4 below
                endcase
            end
            sample_word_addr_cfg = SDR_SAMPLES_BASE[SDR_AW:1] +
                (26'(slot) << 21) +
                ((cfg.srmp7_sample_half_bank && bank == 2'd3)
                    ? (26'd4 << 21) : 26'd0) +
                ((cfg.srmp7_sample_half_bank && bank[1])
                    ? (26'(srmp7_bank) << 21) : 26'd0) +
                {5'd0, accum[31:11]};
        end
    endfunction

    // MAME's graphics region is split into four logical quarters, but the
    // populated stream may contain only three of them. The quarter byte count
    // is therefore gfx_region/4, not a power of two: 3, 4, 6, or 8 MiB for
    // the qualified profiles. This arithmetic is used only by the download
    // mapper, not by the live graphics address path.
    function automatic logic [26:0] gfx_quarter_bytes_cfg(
        input ssv_cfg_t cfg
    );
        gfx_quarter_bytes_cfg = 27'(cfg.gfx_mb) << 18;
    endfunction

    // code % ((1, 3, or 5)<<k), returned at the full 18 bits required by the
    // qualified 32 MiB region (0x40000 tiles). The quotient-side operand is
    // only six bits because the smallest qualified k is 14. Constant modulo
    // three/five is a small LUT, not a variable divider in the SDRAM address path.
    function automatic logic [17:0] wrap_code_cfg(
        input ssv_cfg_t cfg, input logic [19:0] code
    );
        logic  [5:0] high6;
        logic  [1:0] rem3;
        logic  [2:0] rem5;
        logic [19:0] low;
        // One AND against the stored mask -- no shifter.
        low = code & cfg.gfx_code_mask;
        if (cfg.gfx_code_mul5) begin
            high6 = 6'(code >> cfg.gfx_code_k);
            rem5 = 3'(high6 % 6'd5);
            wrap_code_cfg = 18'(low | (20'(rem5) << cfg.gfx_code_k));
        end
        else if (!cfg.gfx_code_mul3) begin
            wrap_code_cfg = 18'(low);
        end
        else begin
            high6 = 6'(code >> cfg.gfx_code_k);
            rem3 = 2'(high6 % 6'd3);
            wrap_code_cfg = 18'(low | (20'(rem3) << cfg.gfx_code_k));
        end
    endfunction

    // -----------------------------------------------------------------------
    // THE authority on where a tile row lives. The ROM loader, the row fetcher
    // and every testbench SDRAM model must call these; a divergence between
    // them is precisely the "wrong ROM load offset" failure that CLAUDE.md
    // warns produces fake bugs.
    //
    // Widths are spelled out because a silent truncation here is the whole
    // bug. All four concatenations are 27 bits, matching SDR_AW+1:
    //   {2'd0, code[17:0], 7'd0} = 27, {20'd0, row, 4'd0}     = 27,
    //   {23'd0, quarter, 2'd0}   = 27, {25'd0, byte_in_row}   = 27.
    // -----------------------------------------------------------------------
    function automatic logic [SDR_AW:0] gfx_record_addr(
        input logic [17:0] code, input logic [2:0] row
    );
        gfx_record_addr = SDR_GFX_BASE + {2'd0, code, 7'd0}
                                       + {20'd0, row, 4'd0};
    endfunction

    function automatic logic [SDR_AW:0] gfx_plane_addr(
        input logic [17:0] code, input logic [2:0] row,
        input logic  [1:0] quarter, input logic [1:0] byte_in_row
    );
        gfx_plane_addr = gfx_record_addr(code, row)
                       + {23'd0, quarter, 2'd0}
                       + {25'd0, byte_in_row};
    endfunction

    // -----------------------------------------------------------------------
    // ST010 addressing. As with gfx_record_addr above, these are THE authority:
    // the ROM loader, the program-fetch cache and tb_ssv_rom_loader all call
    // them, so a divergence is impossible rather than merely unlikely.
    // -----------------------------------------------------------------------

    // Where an st010.bin stream byte lands in SDRAM. Identity offset inside the
    // region, so the image is contiguous and the "dspprg"/"dspdata" split is a
    // property of the READERS, not of the placement.
    function automatic logic [SDR_AW:0] st010_stream_dest_cfg(
        input ssv_cfg_t cfg, input logic [26:0] stream_addr
    );
        st010_stream_dest_cfg =
            SDR_ST010_BASE + (stream_addr - stream_st010_start_cfg(cfg));
    endfunction

    // Byte address of instruction `pc`. MAME's dspprg is a 32-bit big-endian
    // region and the fetch is read_dword(pc) >> 8, so the instruction occupies
    // bytes 4*pc + 0..2 and byte 4*pc + 3 is never used.
    function automatic logic [SDR_AW:0] st010_prg_byte_addr(
        input logic [13:0] pc
    );
        st010_prg_byte_addr = SDR_ST010_BASE + {11'd0, pc, 2'd0};
    endfunction

    // 2048-word on-chip data ROM index for an st010.bin stream byte in the
    // "dspdata" half. Two BYTES per word, big-endian.
    function automatic logic [10:0] st010_drom_word_cfg(
        input ssv_cfg_t cfg, input logic [26:0] stream_addr
    );
        st010_drom_word_cfg = 11'(
            (stream_addr - (stream_st010_start_cfg(cfg) +
                            ST010_DATA_OFFSET)) >> 1);
    endfunction

    // -----------------------------------------------------------------------
    // Layout self-check.
    //
    // A package cannot hold an `initial` block, so the rule lives here as a
    // constant function and ssv_core reports on it at time 0. The point is that
    // when a second title arrives with different ROM sizes, a layout that
    // silently overlaps becomes a loud simulation failure instead of corrupt
    // graphics nobody traces back to this file.
    //
    // Returns 0 if the layout is sound, otherwise the number of the rule that
    // failed, so the message can say which one.
    // -----------------------------------------------------------------------
    // Pairwise overlap test. The rules used to assume the regions were in
    // ascending address order, which stopped being true once they were placed
    // in separate SDRAM banks: with bank = byte address [27:26], a
    // bank-separated map is deliberately NOT ascending-contiguous.
    function automatic bit overlaps(
        input logic [SDR_AW:0] a_base, input logic [SDR_AW:0] a_size,
        input logic [SDR_AW:0] b_base, input logic [SDR_AW:0] b_size
    );
        overlaps = (a_base < b_base + b_size) && (b_base < a_base + a_size);
    endfunction

    function automatic int layout_fault();
        // --- SDRAM regions: pairwise non-overlapping, inside the module ---
        if (overlaps(SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE,
                     SDR_GFX_BASE,     SDR_GFX_SIZE))               return 1;
        if (overlaps(SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE,
                     SDR_XRAM_BASE,    SDR_XRAM_SIZE) ||
            overlaps(SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 2;
        if (overlaps(SDR_GFX_BASE, SDR_GFX_SIZE,
                     SDR_XRAM_BASE,    SDR_XRAM_SIZE) ||
            overlaps(SDR_GFX_BASE, SDR_GFX_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_GFX_BASE, SDR_GFX_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 3;
        if (overlaps(SDR_XRAM_BASE, SDR_XRAM_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_XRAM_BASE, SDR_XRAM_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE) ||
            overlaps(SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 4;
        if (overlaps(SDR_NVRAM_BASE, SDR_NVRAM_SIZE,
                     SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE) ||
            overlaps(SDR_NVRAM_BASE, SDR_NVRAM_SIZE,
                     SDR_GFX_BASE, SDR_GFX_SIZE) ||
            overlaps(SDR_NVRAM_BASE, SDR_NVRAM_SIZE,
                     SDR_XRAM_BASE, SDR_XRAM_SIZE) ||
            overlaps(SDR_NVRAM_BASE, SDR_NVRAM_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_NVRAM_BASE, SDR_NVRAM_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 18;
        if ({1'b0, SDR_SAMPLES_BASE} + {1'b0, SDR_SAMPLES_SIZE}
                                                > SDR_TOTAL_BYTES ||
            {1'b0, SDR_GFX_BASE} + {1'b0, SDR_GFX_SIZE}
                                                > SDR_TOTAL_BYTES ||
            {1'b0, SDR_NVRAM_BASE} + {1'b0, SDR_NVRAM_SIZE}
                                                > SDR_TOTAL_BYTES)  return 5;

        // --- MRA stream: contiguous, and independent of the SDRAM map ---
        // The repack breaks the old "stream offset == SDRAM base" identity,
        // so these rules check the stream against itself instead.
        if (STREAM_MAINCPU != 27'h0000000)                          return 6;
        if (STREAM_SPRITES != STREAM_MAINCPU + STREAM_MAINCPU_SIZE)
                                                                    return 7;
        if (STREAM_SAMPLES != STREAM_SPRITES + STREAM_GFX_SIZE)     return 8;
        if (STREAM_ST010   != STREAM_SAMPLES + STREAM_SAMPLES_SIZE)
                                                                    return 9;

        // --- The repack itself ---
        // Every 12 raw bytes becomes a 16-byte record, so the packed
        // footprint is GFX_QUARTERS_PACKED/GFX_QUARTERS_LOADED of the
        // stream's. That was asserted as an EQUALITY against the region size,
        // which silently required the region to be sized for one specific
        // game. It is now a bound: the packed data must FIT the slot, so the
        // same 32 MB slot serves every title from Ultra X Weapons' 12 MB to
        // Vasara's 32 MB.
        if ((STREAM_GFX_SIZE / GFX_QUARTERS_LOADED) * GFX_QUARTERS_PACKED
                                            > SDR_GFX_SIZE)         return 10;
        // p2 bursts are 16-byte aligned (sdram.sv p2_addr is [AW:4]), and the
        // record address is BASE + code<<7 + row<<4, so BASE must be too.
        if (SDR_GFX_BASE[3:0] != 4'd0)                              return 11;

        // --- ST010 ---
        // Appended to the checks above rather than folded into rules 1-4, so
        // the existing rule numbers keep meaning what the git history says.
        if (overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE) ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_GFX_BASE,     SDR_GFX_SIZE)     ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_XRAM_BASE,    SDR_XRAM_SIZE)    ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_NVRAM_BASE,  SDR_NVRAM_SIZE)    ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 12;
        if ({1'b0, SDR_ST010_BASE} + {1'b0, SDR_ST010_SIZE}
                                                > SDR_TOTAL_BYTES)  return 13;
        // p5 bursts are 8-byte aligned (sdram.sv p5_addr is [AW:3]).
        if (SDR_ST010_BASE[2:0] != 3'd0)                            return 14;
        // The whole image must fit the region, and "dspdata" must start where
        // MAME's ROM_COPY says it does.
        if (SDR_ST010_SIZE != STREAM_ST010_SIZE)                    return 15;
        if (ST010_DATA_OFFSET + 27'h1000 != STREAM_ST010_SIZE)      return 16;
        if (STREAM_END != STREAM_ST010 + STREAM_ST010_SIZE)         return 17;
        return 0;
    endfunction

    localparam int SDR_LAYOUT_FAULT = layout_fault();

    // Video timing.
    //
    // CONFIRMED from a photograph of a real STA-0001B motherboard (28 Jul 2026):
    // the board carries two crystals, **42.9545 MHz** and **48.000 MHz**, both
    // legible on the silkscreen next to the can. See
    // docs/hardware/SSV_BOARD_HARDWARE.md.
    //
    //   42.9545 MHz / 6 = 7.159083 MHz pixel clock
    //   7.159083 MHz / (454 x 262) = 60.19 Hz
    //
    // so the divide-by-6 and the totals below are consistent with real board
    // hardware, not just with the emulator they were originally taken from.
    //
    // NOT yet confirmed: the active/blank split (336/240) and the sync pulse
    // positions in ssv_video_timing.sv. Those still need a scope on a board.
    //
    // clk_sys is 48.317307 MHz in the generated PLL. The two 16-bit enables
    // deliberately track the *ratio* of the board's independent crystals:
    // 16 MHz / (42.954545 MHz / 6) = 704 / 315. CPU_INC=21701 with
    // PIXEL_INC=9710 is -3.7 ppm from that ratio; 21702 was +42.4 ppm and
    // moved one four-write ES5506 group across Dyna Gear lockstep token 100.
    localparam logic [15:0] SSV_CPU_INC   = 16'd21701;
    localparam logic [15:0] SSV_PIXEL_INC = 16'd9710;
    localparam logic [8:0] SSV_HTOTAL  = 9'h1C6; // 454
    localparam logic [8:0] SSV_HBSTART = 9'h150; // 336
    localparam logic [8:0] SSV_VTOTAL  = 9'h106; // 262
    localparam logic [8:0] SSV_VBSTART = 9'h0F0; // 240

endpackage
