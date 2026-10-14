// SPDX-License-Identifier: GPL-3.0-or-later
// Per-game index-0 stream: program, populated graphics quarters, concatenated
// ES5506 banks, then an optional ST010 image.
//
// SDRAM destinations (ssv_pkg):
//   program  -> 0x0000000 identity
//   graphics -> SDR_GFX_BASE, repacked into one aligned 16-byte record per
//               16-pixel tile row (Q0|Q1|Q2|Q3), so ssv_gfx_row_fetch reads
//               a whole row with one 128-bit p2 burst.
//   samples  -> SDR_SAMPLES_BASE in SDRAM bank 3, isolated from CPU, graphics,
//               and optional ST010 traffic.

`timescale 1ns/1ps

module ssv_rom_loader (
    input              clk,
    input              rst,
    input              mem_ready,
    input              ioctl_download,
    input        [7:0] ioctl_index,
    input              ioctl_wr,
    input       [26:0] ioctl_addr,
    input        [7:0] ioctl_dout,
    output             ioctl_wait,
    output logic       sdr_wr_req,
    output logic [ssv_pkg::SDR_AW:1] sdr_wr_addr,
    output logic [15:0] sdr_wr_din,
    output logic [1:0] sdr_wr_be,
    input              sdr_wr_ack,
    // Per-game configuration, parsed from MRA <rom index="1">.
    output ssv_pkg::ssv_cfg_t cfg,
    output logic       cfg_valid,
    output logic       cfg_commit,
    // ST010 data ROM ("dspdata"): 2048 x 16 on chip, so it is written straight
    // into the DSP wrapper's block RAM rather than read back from SDRAM. The
    // program half ("dspprg") is 48 M10K and goes to SDRAM instead.
    output logic       st010_drom_we,
    output logic [10:0] st010_drom_wa,
    output logic [15:0] st010_drom_wd,
    output logic       rom_loaded
);

import ssv_pkg::*;

logic [7:0] byte_lo;
logic       busy;
logic       index0_seen;

// ---------------------------------------------------------------------------
// Per-game configuration, MRA <rom index="1">. Generated media uses the
// 24-byte v3 image below; legacy/private 16-byte v2 images remain accepted.
//
//   0  magic 'S' (0x53)      8  bank_valid
//   1  version (2)           9  flags0: b0 tile_code_identity
//   2  prog_mb                        b1 irq_level1_line0
//   3  gfx_mb (7 bits)                b7 reserved (must remain zero)
//                                     b3 has_st010, b4 drifto unknown reads
//                                     b5 inverted lockout
//                                     b7..b6 extra_input_mode
//   4  gfx_code_k           10  wdog_mode
//   5  b1 gfx_code_mul5, b0 gfx_code_mul3
//   6  gfx_quarters         13  visible width / 2
//   7  bank_map             12  sample_mb
//                            14  visible height
//                            10 b2 has_nvram, b4..b3 extra_ram_mode,
//                               b5 system_input_mode, b7..b6 nvram_mode
//                               (0 none, 1 2 KiB, 2 64 KiB)
//                            15  checksum: bytes 0..14 summed, negated
//
// The block MUST precede <rom index="0"> in the MRA, because index-0 bytes
// cannot be placed without knowing the layout. A mis-ordered or malformed
// block leaves cfg_valid low, index 0 is then discarded, rom_loaded never
// asserts and LED_USER stays lit.
//
// There is deliberately NO silent fallback to Dyna Gear defaults. A fallback
// turns a packaging mistake into a corrupt-graphics bug hunt, which is exactly
// the class of fake bug this core has spent effort avoiding elsewhere.
// ---------------------------------------------------------------------------
// v2 remains accepted for existing/private media.  v3 is a 24-byte atomic
// block; its checksum is byte 23 and it cannot commit at the v2 boundary.
localparam int CFG_V2_BYTES = 16;
localparam int CFG_BYTES = 24;
logic [7:0] cfg_raw [0:CFG_BYTES-1];
logic [7:0] cfg_sum;
logic       cfg_accept;
logic [7:0] cfg_sum_byte [0:CFG_BYTES-2];
logic [7:0] cfg_sum_pair [0:11];
logic [7:0] cfg_sum_quad [0:5];
logic [7:0] cfg_sum_octet [0:2];
integer    cfg_sum_i;
logic [CFG_BYTES-1:0] cfg_received;
logic                 cfg_commit_pending;
logic [CFG_BYTES-1:0] cfg_received_after_write;
logic [7:0]           cfg_version_after_write;
logic [CFG_BYTES-1:0] cfg_required_after_write;

// Completion is evaluated from the image including the byte accepted on this
// edge.  In particular, version may itself be the final out-of-order byte;
// reading cfg_raw[1] here would then use the previous transaction's version.
always_comb begin
    cfg_received_after_write = cfg_received;
    cfg_version_after_write = cfg_raw[1];
    if (ioctl_addr < CFG_BYTES) begin
        if (ioctl_addr == 0)
            cfg_received_after_write = '0;
        cfg_received_after_write[ioctl_addr[4:0]] = 1'b1;
        if (ioctl_addr == 1)
            cfg_version_after_write = ioctl_dout;
    end
    cfg_required_after_write =
        (cfg_version_after_write == 8'd3) ? {CFG_BYTES{1'b1}} :
        {{(CFG_BYTES-CFG_V2_BYTES){1'b0}}, {CFG_V2_BYTES{1'b1}}};
end

function automatic ssv_pkg::ssv_cfg_t cfg_decode();
    cfg_decode = '0;
    cfg_decode.game_id            = cfg_raw[11][3:0];
    cfg_decode.prog_mb            = cfg_raw[2][2:0];
    cfg_decode.gfx_mb             = cfg_raw[3][6:0];
    cfg_decode.gfx_code_k         = cfg_raw[4][4:0];
    cfg_decode.gfx_code_mul3      = cfg_raw[5][0];
    cfg_decode.gfx_code_mul5      = cfg_raw[5][1];
        // Derived here, ONCE, rather than in the wrap. As a variable shift in
        // the wrap it cost -12.7 ns on the path to the SDRAM address.
    // Validation permits only these six geometry-bound exponents.  Spell out
    // their exact masks so the descriptor commit does not build a 20-bit
    // variable barrel shifter; invalid/unqualified payloads decode safely.
    unique case (cfg_raw[4][4:0])
        5'd14: cfg_decode.gfx_code_mask = 20'h03fff;
        5'd15: cfg_decode.gfx_code_mask = 20'h07fff;
        5'd16: cfg_decode.gfx_code_mask = 20'h0ffff;
        5'd17: cfg_decode.gfx_code_mask = 20'h1ffff;
        5'd18: cfg_decode.gfx_code_mask = 20'h3ffff;
        5'd19: cfg_decode.gfx_code_mask = 20'h7ffff;
        default: cfg_decode.gfx_code_mask = 20'h00000;
    endcase
    cfg_decode.gfx_quarters       = cfg_raw[6][2:0];
    cfg_decode.bank_map           = cfg_raw[7];
    cfg_decode.bank_valid         = cfg_raw[8][3:0];
    cfg_decode.tile_code_identity = cfg_raw[9][0];
    cfg_decode.irq_level1_line0   = cfg_raw[9][1];
    cfg_decode.extra_input_mode   = cfg_raw[9][7:6];
    cfg_decode.lockout_inverted   = cfg_raw[9][5];
    cfg_decode.has_nvram          = cfg_raw[10][2];
    cfg_decode.has_st010          = cfg_raw[9][3];
    cfg_decode.has_drifto_unknown = cfg_raw[9][4];
    cfg_decode.sample_mb          = cfg_raw[12][5:0];
    cfg_decode.wdog_mode          = cfg_raw[10][1:0];
    cfg_decode.extra_ram_mode     = cfg_raw[10][4:3];
    cfg_decode.nvram_mode         = cfg_raw[10][7:6];
    cfg_decode.system_input_mode  = cfg_raw[10][5];
    cfg_decode.visible_width_half = cfg_raw[13];
    cfg_decode.visible_height     = cfg_raw[14];
    cfg_decode.irq_level2_line120 = (cfg_raw[1] == 8'd3) && cfg_raw[18][0];
    cfg_decode.mainram_mirror_010000 = (cfg_raw[1] == 8'd3) && cfg_raw[15][0];
    cfg_decode.input_layout       = (cfg_raw[1] == 8'd3) ? cfg_raw[16][3:0] : 4'd0;
    cfg_decode.mahjong_mode       = (cfg_raw[1] == 8'd3) ? cfg_raw[17][2:0] : 3'd0;
    cfg_decode.custom_output_mode = (cfg_raw[1] == 8'd3) ? cfg_raw[19][2:0] : 3'd0;
    cfg_decode.rapid_fire_b3_to_b1 = (cfg_raw[1] == 8'd3) && cfg_raw[19][3];
    cfg_decode.rapid_fire_b1       = (cfg_raw[1] == 8'd3) && cfg_raw[19][4];
    cfg_decode.rapid_fire_b2       = (cfg_raw[1] == 8'd3) && cfg_raw[19][5];
    cfg_decode.srmp7_sample_half_bank = (cfg_raw[1] == 8'd3) && cfg_raw[20][0];
    cfg_decode.srmp7_irqv_mame    = (cfg_raw[1] == 8'd3) && cfg_raw[20][1];
    cfg_decode.optional_io_mode   = (cfg_raw[1] == 8'd3) ? cfg_raw[21][1:0] : 2'd0;
    cfg_decode.adc_conversion_cycles = (cfg_raw[1] == 8'd3) ? cfg_raw[22] : 8'd0;
endfunction

// Keep malformed descriptors away from variable shifts, bank selectors and
// stream-boundary arithmetic.  This is deliberately a small constant-domain
// predicate rather than a general divider/modulo path: the version-2 ABI has
// only the qualified graphics geometries and sample sizes.
function automatic logic cfg_domain_valid();
    logic gfx_valid;
    logic bank_map_valid;
    logic geometry_valid;
    begin
        unique case (cfg_raw[3][6:0])
            7'd10: gfx_valid = (cfg_raw[1] == 8'd3) &&
                                  (cfg_raw[4][4:0] == 5'd14) &&
                                  cfg_raw[5][1] && !cfg_raw[5][0] &&
                                  (cfg_raw[6][2:0] == 3'd3);
            7'd14: gfx_valid = (cfg_raw[1] == 8'd3) &&
                                  (cfg_raw[21][1:0] == 2'd1) &&
                                  (cfg_raw[4][4:0] == 5'd14) &&
                                  !cfg_raw[5][1] && !cfg_raw[5][0] &&
                                  (cfg_raw[6][2:0] == 3'd4);
            6'd12: gfx_valid = (cfg_raw[4][4:0] == 5'd15) &&
                                   !cfg_raw[5][1] && cfg_raw[5][0] &&
                                  (cfg_raw[6][2:0] == 3'd3);
            6'd16: gfx_valid = (cfg_raw[4][4:0] == 5'd17) &&
                                  !cfg_raw[5][1] && !cfg_raw[5][0] &&
                                  (cfg_raw[6][2:0] == 3'd3);
            6'd24: gfx_valid = (cfg_raw[4][4:0] == 5'd16) &&
                                   !cfg_raw[5][1] && cfg_raw[5][0] &&
                                  (cfg_raw[6][2:0] == 3'd3);
            6'd32: gfx_valid = (cfg_raw[4][4:0] == 5'd18) &&
                                  !cfg_raw[5][1] && !cfg_raw[5][0] &&
                                  ((cfg_raw[6][2:0] == 3'd3) ||
                                   (cfg_raw[6][2:0] == 3'd4));
            7'd64: gfx_valid = (cfg_raw[4][4:0] == 5'd19) &&
                                  !cfg_raw[5][1] && !cfg_raw[5][0] &&
                                  (cfg_raw[6][2:0] == 3'd4);
            default: gfx_valid = 1'b0;
        endcase

        // Four MiB carries one physical stream slot; eight MiB carries two.
        // Only mappings for enabled CR banks matter.
        bank_map_valid = cfg_raw[8][0] ?
            ((cfg_raw[12][5:0] == 6'd8) || (cfg_raw[7][1:0] == 2'd0)) : 1'b1;
        if (cfg_raw[8][1])
            bank_map_valid &= (cfg_raw[12][5:0] == 6'd8) ||
                              (cfg_raw[7][3:2] == 2'd0);
        if (cfg_raw[8][2])
            bank_map_valid &= (cfg_raw[12][5:0] == 6'd8) ||
                              (cfg_raw[7][5:4] == 2'd0);
        if (cfg_raw[8][3])
            bank_map_valid &= (cfg_raw[12][5:0] == 6'd8) ||
                              (cfg_raw[7][7:6] == 2'd0);
        if (cfg_raw[12][5:0] == 6'd8) begin
            if (cfg_raw[8][0]) bank_map_valid &= !cfg_raw[7][1];
            if (cfg_raw[8][1]) bank_map_valid &= !cfg_raw[7][3];
            if (cfg_raw[8][2]) bank_map_valid &= !cfg_raw[7][5];
            if (cfg_raw[8][3]) bank_map_valid &= !cfg_raw[7][7];
        end
        if ((cfg_raw[1] == 8'd3) && cfg_raw[20][0])
            bank_map_valid = (cfg_raw[12][5:0] == 6'd24) &&
                             (cfg_raw[8][3:0] == 4'hf);

        geometry_valid =
            ((cfg_raw[13] == 8'd168) &&
             ((cfg_raw[14] == 8'd238) || (cfg_raw[14] == 8'd240))) ||
            ((cfg_raw[13] == 8'd169) && (cfg_raw[14] == 8'd240)) ||
            ((cfg_raw[13] == 8'd176) && (cfg_raw[14] == 8'd240));

        cfg_domain_valid =
            (cfg_raw[2][7:3] == 5'd0) &&
            ((cfg_raw[2][2:0] == 3'd1) ||
             (cfg_raw[2][2:0] == 3'd2) ||
             (cfg_raw[2][2:0] == 3'd4)) &&
            !cfg_raw[3][7] &&
            (cfg_raw[4][7:5] == 3'd0) &&
            (cfg_raw[5][7:2] == 6'd0) &&
            (cfg_raw[6][7:3] == 5'd0) &&
            (cfg_raw[8][7:4] == 4'd0) && (cfg_raw[8][3:0] != 4'd0) &&
            !cfg_raw[9][2] && (cfg_raw[9][7:6] != 2'd3) &&
            (cfg_raw[10][1:0] != 2'd3) &&
            (cfg_raw[10][7:6] != 2'd3) &&
            (cfg_raw[10][2] == (cfg_raw[10][7:6] != 2'd0)) &&
            (cfg_raw[11][7:4] == 4'd0) &&   // game_id is informational (simulation profile select); any 4-bit id is valid
            (cfg_raw[12][7:6] == 2'd0) &&
            ((cfg_raw[12][5:0] == 6'd4) ||
             (cfg_raw[12][5:0] == 6'd8) ||
             (cfg_raw[12][5:0] == 6'd24)) &&
            gfx_valid && bank_map_valid && geometry_valid &&
            (((cfg_raw[1] == 8'd2) && (cfg_raw[10][4:3] != 2'd3)) ||
             ((cfg_raw[15][7:1] == 7'd0) &&
              (cfg_raw[16][7:4] == 4'd0) &&
              (cfg_raw[17][7:3] == 5'd0) &&
              (cfg_raw[18][7:1] == 7'd0) &&
              (cfg_raw[19][7:6] == 2'd0) &&
              (cfg_raw[20][7:2] == 6'd0) &&
              (cfg_raw[21][7:2] == 6'd0)));
        if (cfg_raw[1] == 8'd3) begin
            cfg_domain_valid &= (cfg_raw[16][3:0] <= 4'd3) &&
                                (cfg_raw[17][2:0] <= 3'd5) &&
                                (cfg_raw[19][2:0] == 3'd0);
            // The implemented matrix modes use the matrix input layout, and
            // SRMP7-only sample/IRQ behavior is valid only with SRMP7 mode.
            cfg_domain_valid &= ((cfg_raw[17][2:0] == 3'd0) ==
                                 (cfg_raw[16][3:0] != 4'd1));
            cfg_domain_valid &= ((cfg_raw[20][1:0] == 2'd0) ||
                                 (cfg_raw[17][2:0] == 3'd5));
            cfg_domain_valid &= ((cfg_raw[10][4:3] != 2'd3) ||
                                 (cfg_raw[17][2:0] == 3'd5));
            cfg_domain_valid &=
                (((cfg_raw[21][1:0] == 2'd2) ||
                  (cfg_raw[21][1:0] == 2'd3)) == (cfg_raw[22] != 8'd0));
            if (cfg_raw[21][1:0] == 2'd1)
                cfg_domain_valid &= (cfg_raw[3][6:0] == 7'd14) &&
                    cfg_raw[9][5] && cfg_raw[10][2] &&
                    (cfg_raw[10][7:6] == 2'd1) &&
                    (cfg_raw[10][1:0] == 2'd0);
            if (cfg_raw[21][1:0] == 2'd2)
                cfg_domain_valid &= cfg_raw[9][5] && cfg_raw[10][2] &&
                    (cfg_raw[10][7:6] == 2'd2) &&
                    (cfg_raw[10][1:0] == 2'd1);
        end
    end
endfunction

// One shared validation cone, sampled only on cfg_commit_pending. Keeping it
// outside the sequential block avoids both duplicated compares and a needless
// validity register in the placement-critical loader neighborhood.
// The checksum is modulo 256, so addition is associative. Reduce the 23
// possible payload bytes as a balanced tree rather than a serial accumulator;
// this preserves the exact v2/v3 byte-selection contract while shortening the
// carry chain that otherwise dominated the loader's clk_sys placement path.
always_comb begin
    for (cfg_sum_i = 0; cfg_sum_i < CFG_BYTES - 1; cfg_sum_i++)
        cfg_sum_byte[cfg_sum_i] =
            ((cfg_raw[1] == 8'd3) || (cfg_sum_i < CFG_V2_BYTES-1))
                ? cfg_raw[cfg_sum_i] : 8'd0;

    cfg_sum_pair[0]  = cfg_sum_byte[0]  + cfg_sum_byte[1];
    cfg_sum_pair[1]  = cfg_sum_byte[2]  + cfg_sum_byte[3];
    cfg_sum_pair[2]  = cfg_sum_byte[4]  + cfg_sum_byte[5];
    cfg_sum_pair[3]  = cfg_sum_byte[6]  + cfg_sum_byte[7];
    cfg_sum_pair[4]  = cfg_sum_byte[8]  + cfg_sum_byte[9];
    cfg_sum_pair[5]  = cfg_sum_byte[10] + cfg_sum_byte[11];
    cfg_sum_pair[6]  = cfg_sum_byte[12] + cfg_sum_byte[13];
    cfg_sum_pair[7]  = cfg_sum_byte[14] + cfg_sum_byte[15];
    cfg_sum_pair[8]  = cfg_sum_byte[16] + cfg_sum_byte[17];
    cfg_sum_pair[9]  = cfg_sum_byte[18] + cfg_sum_byte[19];
    cfg_sum_pair[10] = cfg_sum_byte[20] + cfg_sum_byte[21];
    cfg_sum_pair[11] = cfg_sum_byte[22];

    cfg_sum_quad[0] = cfg_sum_pair[0] + cfg_sum_pair[1];
    cfg_sum_quad[1] = cfg_sum_pair[2] + cfg_sum_pair[3];
    cfg_sum_quad[2] = cfg_sum_pair[4] + cfg_sum_pair[5];
    cfg_sum_quad[3] = cfg_sum_pair[6] + cfg_sum_pair[7];
    cfg_sum_quad[4] = cfg_sum_pair[8] + cfg_sum_pair[9];
    cfg_sum_quad[5] = cfg_sum_pair[10] + cfg_sum_pair[11];

    cfg_sum_octet[0] = cfg_sum_quad[0] + cfg_sum_quad[1];
    cfg_sum_octet[1] = cfg_sum_quad[2] + cfg_sum_quad[3];
    cfg_sum_octet[2] = cfg_sum_quad[4] + cfg_sum_quad[5];

    cfg_sum = (cfg_sum_octet[0] + cfg_sum_octet[1]) + cfg_sum_octet[2];
    cfg_accept = (cfg_raw[0] == 8'h53) &&
                 ((cfg_raw[1] == 8'd2) || (cfg_raw[1] == 8'd3)) &&
                 ((cfg_raw[1] == 8'd3) ?
                    (cfg_raw[CFG_BYTES-1] == (-cfg_sum)) :
                    (cfg_raw[CFG_V2_BYTES-1] == (-cfg_sum))) &&
                 cfg_domain_valid();
end

function automatic logic [SDR_AW:0] stream_byte_address(
    input logic [26:0] stream_addr
);
    logic [26:0] gfx_offset;
    logic [26:0] within_quarter;
    logic  [2:0] quarter;
    logic [26:0] quarter_bytes;
    logic [17:0] raw_tile_code;
    begin
        gfx_offset     = stream_addr - stream_gfx_start_cfg(cfg);
        quarter_bytes  = gfx_quarter_bytes_cfg(cfg);
        // Do not replace this with a shift/mask: 24 MiB and 12 MiB MAME
        // regions have 6 MiB and 3 MiB quarters respectively.
        quarter        = 3'd0;
        within_quarter = gfx_offset;
        if (gfx_offset >= quarter_bytes) begin
            quarter        = 3'd1;
            within_quarter = gfx_offset - quarter_bytes;
        end
        if (gfx_offset >= (quarter_bytes << 1)) begin
            quarter        = 3'd2;
            within_quarter = gfx_offset - (quarter_bytes << 1);
        end
        if (gfx_offset >= (quarter_bytes * 27'd3)) begin
            quarter        = 3'd3;
            within_quarter = gfx_offset - (quarter_bytes * 27'd3);
        end
        raw_tile_code  = within_quarter >> 5;

        if ((stream_addr >= stream_gfx_start_cfg(cfg)) &&
            (stream_addr <  stream_samples_start_cfg(cfg))) begin
            if (cfg.optional_io_mode == 2'd1)
                stream_byte_address = SDR_GFX_BASE +
                    (stream_addr - stream_gfx_start_cfg(cfg));
            else begin
            // All populated quarters collapse into one aligned 16-byte
            // record per 16-pixel tile row, so the row fetcher gets a whole
            // row from a single 128-bit p2 burst. The descriptor determines
            // whether bytes 12..15 carry quarter 3 or remain unwritten; the
            // fetcher independently gates that lane to zero for Q3-absent sets.
            //
            // The "quarters" model is supported by the physical board: a
            // SAM-5127 carries four graphics banks A/B/C/D of four `16M-MASK`
            // sockets each, and Dyna Gear populates six of the sixteen (photos,
            // 28 Jul 2026 — docs/hardware/SSV_BOARD_HARDWARE.md). What is *not*
            // established -- and is UNCHANGED by the repack -- is which
            // physical bank feeds which quarter here. The mapping is known-good
            // only in the sense that Dyna Gear's graphics decode CRC-exact with
            // it. If a second SSV title ever decodes with scrambled graphics
            // under this same loader, this function is the first thing to
            // suspect.
            stream_byte_address = gfx_plane_addr(
                raw_tile_code,
                within_quarter[4:2],
                quarter,
                within_quarter[1:0]
            );
            end
        end
        else if (cfg.has_st010 &&
                 stream_addr >= stream_st010_start_cfg(cfg)) begin
            // st010.bin, placed contiguously in bank 3 after samples. MUST be
            // tested before the sample branch below, which is open-ended `>=`.
            stream_byte_address = st010_stream_dest_cfg(cfg, stream_addr);
        end
        else if (stream_addr >= stream_samples_start_cfg(cfg)) begin
            // The sample region no longer sits at its stream offset: the
            // graphics records displaced it above XRAM and CPU RAM.
            stream_byte_address = SDR_SAMPLES_BASE +
                                  (stream_addr - stream_samples_start_cfg(cfg));
        end
        else begin
            stream_byte_address = stream_addr[SDR_AW:0];  // V60 program, identity
        end
    end
endfunction

wire [SDR_AW:0] mapped_ioctl_addr = stream_byte_address(ioctl_addr);

// The "dspdata" half of st010.bin also feeds the DSP's on-chip 2048 x 16 data
// ROM. MAME's region is ROM_REGION16_BE, so the word at index i is
// { rom[2i], rom[2i+1] } -- the OPPOSITE order from the little-endian pairing
// the SDRAM path uses, which is why wd is {byte_lo, ioctl_dout} and not
// {ioctl_dout, byte_lo}.
wire st010_data_byte = cfg.has_st010 &&
                       (ioctl_addr >= stream_st010_start_cfg(cfg) +
                                      ST010_DATA_OFFSET) &&
                       (ioctl_addr <  stream_st010_start_cfg(cfg) +
                                      STREAM_ST010_SIZE);

// MRA sample streams reproduce MAME's ROM_REGION16_BE byte image.  Keep that
// canonical byte order in SDRAM: the even stream byte is the high half of the
// ES5506 word.  Program and graphics storage remain little-endian because
// their consumers already implement the V60/packed-row layout.
wire sample_data_byte =
    (ioctl_addr >= stream_samples_start_cfg(cfg)) &&
    (ioctl_addr <  stream_samples_start_cfg(cfg) +
                   stream_samples_size_cfg(cfg));

// Byte 15 completes cfg_raw on one edge; hold the first index-0 byte while the
// following edge validates and atomically commits the descriptor.
assign ioctl_wait = busy | ~mem_ready | cfg_commit_pending;

always_ff @(posedge clk) begin
    if (rst) begin
        byte_lo     <= 8'h00;
        busy        <= 1'b0;
        index0_seen <= 1'b0;
        cfg_valid   <= 1'b0;
        cfg_commit  <= 1'b0;
        cfg_received <= '0;
        cfg_commit_pending <= 1'b0;
        cfg         <= '0;
        sdr_wr_req  <= 1'b0;
        sdr_wr_addr <= '0;
        sdr_wr_din  <= '0;
        sdr_wr_be   <= 2'b00;
        rom_loaded  <= 1'b0;
        st010_drom_we <= 1'b0;
        st010_drom_wa <= '0;
        st010_drom_wd <= '0;
    end
    else begin
        st010_drom_we <= 1'b0;
        cfg_commit <= 1'b0;
        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            busy       <= 1'b0;
        end

        // --- index 1: capture the configuration block ---
        if (ioctl_download && ioctl_wr && ioctl_index == 8'd1 &&
            !cfg_commit_pending &&
            ioctl_addr < CFG_BYTES) begin
            if (ioctl_addr == 0)
                for (int cfg_clear_i = 0; cfg_clear_i < CFG_BYTES; cfg_clear_i++)
                    cfg_raw[cfg_clear_i] <= 8'd0;
            cfg_raw[ioctl_addr[4:0]] <= ioctl_dout;
            // Any descriptor byte invalidates the prior profile immediately.
            // Address zero begins a new transaction even if a prior malformed
            // block left a partial receive mask behind.
            cfg_valid <= 1'b0;
            rom_loaded <= 1'b0;
            cfg_received <= cfg_received_after_write;

            if ((cfg_version_after_write == 8'd2 ||
                 cfg_version_after_write == 8'd3) &&
                (cfg_received_after_write == cfg_required_after_write))
                cfg_commit_pending <= 1'b1;
        end

        // Validate one cycle after the final missing byte lands, so cfg_raw is
        // settled. The wait term above holds a back-to-back index-0 byte until
        // cfg and cfg_valid commit together on this edge.
        if (cfg_commit_pending) begin
            cfg_commit_pending <= 1'b0;
            cfg_received <= '0;
            cfg_valid <= cfg_accept;
            // Decode the settled transaction independently of validation.
            // cfg_valid is the ownership qualifier: malformed descriptors
            // remain unusable and cannot load index 0.  Keeping cfg_accept
            // out of cfg's register-enable cone avoids putting the checksum
            // and domain-validation chain in front of every payload bit.
            cfg <= cfg_decode();
            if (cfg_accept) begin
                cfg_commit <= 1'b1;
            end
        end

        if (mem_ready && ioctl_download && ioctl_wr && !busy && cfg_valid &&
            ioctl_index == 8'd0 && ioctl_addr < stream_end_cfg(cfg)) begin
            if (!ioctl_addr[0])
                byte_lo <= ioctl_dout;
            else begin
                sdr_wr_req  <= 1'b1;
                sdr_wr_addr <= mapped_ioctl_addr[SDR_AW:1];
                sdr_wr_din  <= sample_data_byte
                    ? {byte_lo, ioctl_dout}
                    : {ioctl_dout, byte_lo};
                sdr_wr_be   <= 2'b11;
                busy        <= 1'b1;
                // Second destination for the same pair of bytes. Big-endian, so
                // byte_lo (the EVEN stream byte) is the HIGH half of the word.
                if (st010_data_byte) begin
                    st010_drom_we <= 1'b1;
                    st010_drom_wa <= st010_drom_word_cfg(cfg, ioctl_addr);
                    st010_drom_wd <= {byte_lo, ioctl_dout};
                end
            end
        end

        if (mem_ready && ioctl_download && ioctl_wr && cfg_valid &&
            ioctl_index == 8'd0 && ioctl_addr == 27'd0) begin
            rom_loaded  <= 1'b0;
            index0_seen <= 1'b1;
        end

        if (mem_ready && !ioctl_download && index0_seen &&
            !busy && !sdr_wr_req) begin
            rom_loaded  <= 1'b1;
            index0_seen <= 1'b0;
        end
    end
end

endmodule
