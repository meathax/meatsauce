package s24_pkg;

    localparam logic [26:0] SDR_BOOT_BASE    = 27'h000_0000;
    localparam logic [26:0] SDR_ROMBOARD_BASE= 27'h010_0000;
    localparam logic [26:0] SDR_FLOPPY_BASE  = 27'h080_0000;
    localparam logic [26:0] SDR_FDKEY_BASE   = 27'h0a0_0000;
    localparam logic [26:0] SDR_WORKA_BASE   = 27'h100_0000;
    localparam logic [26:0] SDR_WORKB_BASE   = 27'h104_0000;
    localparam logic [26:0] SDR_TILE_BASE    = 27'h108_0000;
    localparam logic [26:0] SDR_CHAR_BASE    = 27'h110_0000;
    localparam logic [26:0] SDR_PALETTE_BASE = 27'h118_0000;
    localparam logic [26:0] SDR_SPRITE_BASE  = 27'h400_0000;

    typedef struct packed {
        logic [7:0] input_profile;
        logic [7:0] track_bytes_hi;
        logic [7:0] track_bytes_lo;
        logic [3:0] reserved1;
        logic [3:0] magic_table;
        logic       mahjong;
        logic       hotrod_io;
        logic       golf_io;
        logic       has_adc;
        logic       has_upd4701;
        logic       has_fd1094;
        logic       has_romboard;
        logic       has_floppy;
        // Bytes 5..7 are zero in the legacy descriptor.  Version one gives
        // the loader named board-domain profile fields without changing the
        // descriptor size or invalidating existing MRAs.
        logic [7:0] profile_version;
        logic [3:0] motherboard_revision;
        logic [1:0] sprite_memory_population;
        logic [1:0] fdc_timing_profile;
        logic [1:0] romboard_profile;
        logic [1:0] analogue_profile;
        // Bit 0: this game's tilemaps intentionally toggle a layer's disable
        // bit every frame to fake CRT-integrated translucency (Bonanza
        // Bros' projector beam and stage intro card), so s24_tile's
        // flicker-blend heuristic is safe to engage for it. Left clear for
        // every other set: that heuristic was verified against Bonanza Bros
        // only, and forcing it on for a game whose disable-bit toggling
        // means something else (e.g. Crack Down's window/radar layer
        // management) renders stale tile/scroll data instead of nothing,
        // which reads as one viewport bleeding into another. See
        // s24_core.sv's blend_capable and s24_tile.sv's blend_en.
        logic [1:0] video_profile;
        logic [1:0] cpu_profile;
    } board_desc_t;

    // The 315-5295-facing transaction contract.  The physical SDRAM adapter
    // remains below this boundary; these fields describe the board-visible
    // cycle that arbitration and device models must observe.
    typedef enum logic [1:0] {
        BUS_PHASE_CAPTURE = 2'd0,
        BUS_PHASE_GRANTED = 2'd1,
        BUS_PHASE_WAIT    = 2'd2,
        BUS_PHASE_COMPLETE= 2'd3
    } bus_phase_t;

    typedef struct packed {
        logic        valid;
        logic        requester;     // 0 = CPU-A, 1 = CPU-B
        logic [23:0] address;
        logic [1:0]  byte_enable;   // {UDS, LDS}, active lanes are one
        logic        read_nwrite;
        logic [2:0]  function_code;
        logic [15:0] write_data;
        bus_phase_t  phase;
        logic        grant;
        logic        wait_state;
        logic        complete;
    } board_transaction_t;

    localparam logic [7:0] INPUT_GENERIC = 8'd0;
    localparam logic [7:0] INPUT_GGROUND = 8'd1;
    // Additional MAME System 24 cabinet/input families.  Keep these as
    // behavioural profiles rather than set-name checks so clones and future
    // dumps select the same physical wiring.
    localparam logic [7:0] INPUT_QUIZ4   = 8'd2;
    localparam logic [7:0] INPUT_QROUKA  = 8'd3;
    localparam logic [7:0] INPUT_MAHJONG = 8'd4;

    localparam logic [1:0] ANALOGUE_STANDARD = 2'd0;
    localparam logic [1:0] ANALOGUE_ROUGHRAC = 2'd1;

    // 837-7187 ROM-board jumper populations.  The names are the ROM device
    // densities printed in the board notes, not byte capacities: 2M uses
    // four pairs of 27C020 devices, 4M uses four pairs of 27C040 devices,
    // and 8M uses two pairs of 27C080 devices.  The 4M profile preserves the
    // legacy linear 4 MiB media layout.
    localparam logic [1:0] ROMBOARD_PROFILE_4M = 2'd0;
    localparam logic [1:0] ROMBOARD_PROFILE_2M = 2'd1;
    localparam logic [1:0] ROMBOARD_PROFILE_8M = 2'd2;

    typedef enum logic [3:0] {
        MAGIC_NONE      = 4'd0,
        MAGIC_DCCLUB    = 4'd2,
        MAGIC_QROUKA    = 4'd3,
        MAGIC_QUIZMEKU  = 4'd4,
        MAGIC_MAHMAJN   = 4'd5,
        MAGIC_MAHMAJN2  = 4'd6,
        MAGIC_BNZABROS  = 4'd7
    } magic_sel_t;

    // The ROM-board /INT3 input is a level-1 source enabled by bit 0 of the
    // per-CPU IRQ-enable registers. Keep it distinct from the periodic FRC
    // event, which is the higher-level timer source at bit 5.
    localparam int IRQ_INT3   = 0;
    localparam int IRQ_YM2151 = 1;
    localparam int IRQ_TIMER  = 2;
    localparam int IRQ_VBLANK = 3;
    localparam int IRQ_SPRITE = 4;
    localparam int IRQ_FRC    = 5;

    function automatic [15:0] merge16(
        input [15:0] old_data,
        input [15:0] new_data,
        input [1:0]  byte_en
    );
        merge16 = {
            byte_en[1] ? new_data[15:8] : old_data[15:8],
            byte_en[0] ? new_data[7:0]  : old_data[7:0]
        };
    endfunction

    function automatic logic [26:1] word_address(input logic [26:0] byte_address);
        word_address = byte_address[26:1];
    endfunction

    // Convert the 256 KiB CPU-visible bank window into the byte offset in
    // the downloaded ROM-board image.  The 2M jumper population uses BK2:BK1
    // to select one of four ROM pairs and BK0 as the pair-local high address;
    // BK3 is not connected to ROM selection.  4M and 8M populations both
    // present a linear 4 MiB byte image in the loader, with all four bank
    // bits contributing to the offset.  Reserved profiles intentionally use
    // the conservative 4M mapping until a board netlist assigns them.
    function automatic logic [21:0] romboard_offset(
        input logic [1:0] profile,
        input logic [3:0] bank,
        input logic [17:0] window_address
    );
        if (profile == ROMBOARD_PROFILE_2M)
            romboard_offset = {1'b0, bank[2:0], window_address};
        else
            romboard_offset = {bank, window_address};
    endfunction

endpackage
