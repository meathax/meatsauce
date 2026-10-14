`timescale 1ns / 1ps
`default_nettype none

// SDRAM-backed graphics fetcher.
// gfx1 is warmed into a decoded-row cache before the game CPUs are released;
// gfx2 rows are fetched on demand behind the sprite engine's existing req/ack
// interface. The production row path requests one complete 32-pixel row from
// the packed gfx2 storage layout. The SDRAM controller performs eight
// adjacent 16-bit reads internally and returns their 128-bit response
// atomically, so the sprite line builder never sees a partially assembled
// plane row. The legacy raw-byte/word/pair fabric pins remain present for
// compatibility with diagnostic consumers; they are idle on this path.
module mcr68_gfx_rom_sdram #(
    // ------------------------------------------------------------------
    // Region sizing (rtl/mcr68_game_profile.svh). Defaults are Xenophobe's,
    // i.e. exactly what this file previously hard-coded.
    //   gfx1: 'h10000 Xenophobe/Blasted, 'h20000 Arch Rivals/Pigskin
    //   gfx2: 'h40000 xenophob,                  'h80000 everything else
    //
    // *** MEMORY WARNING ***  `tile_rows` below is the decoded-gfx1 cache and
    // it scales linearly with GFX1_BYTES: 2048 tiles x 8 rows x 32 bits =
    // 524,288 bits today, but 4096 tiles x 8 rows x 32 bits = 1,048,576 bits
    // for archrivl/pigskin. That is +512 Kbit of block RAM on a device whose
    // M10K budget is already ~98.6% committed. Do NOT elaborate a 'h20000
    // gfx1 build expecting it to fit -- see doc/rtl_video_multigame.md §2.
    // gfx2 is fetched on demand and caches nothing, so its widening is free.
    // ------------------------------------------------------------------
    parameter int GFX1_BYTES = 'h10000,
    parameter int GFX2_BYTES = 'h40000,

    // Derived -- do NOT override.
    parameter int GFX1_ELEMENTS = GFX1_BYTES / 32,        // 2048 or 4096
    parameter int GFX1_CODE_W   = $clog2(GFX1_ELEMENTS),  // 11 or 12
    parameter int GFX1_ADDR_W   = $clog2(GFX1_BYTES),     // 16 or 17
    parameter int GFX1_ROWS     = GFX1_ELEMENTS * 8,      // 16384 or 32768
    parameter int GFX1_ROW_W    = $clog2(GFX1_ROWS),      // 14 or 15
    parameter int GFX2_ELEMENTS = GFX2_BYTES / 512,       // 512 or 1024
    parameter int GFX2_CODE_W   = $clog2(GFX2_ELEMENTS),  // 9 or 10
    parameter int GFX2_ADDR_W   = $clog2(GFX2_BYTES),     // 18 or 19
    // Production can use the two-word plane-pair path or the packed 16-byte
    // row path. Both remain disabled by default for focused compatibility
    // benches and a simple raw-word fallback.
    parameter bit USE_GFX2_BURST     = 1'b0,
    parameter bit USE_GFX2_ROW_BURST = 1'b0
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         load_enable,
    output logic         gfx1_ready,

    // 1 = active title's gfx1 is the small (elaborated-size/2) region --
    // e.g. Xenophobe/Blasted at 0x10000 when this module is
    // elaborated at the union/largest profile (0x20000, Pigskin/Arch Rivals).
    // Selects where the 12d (upper-bitplane) half begins; see
    // mcr68_gfx_rom_sim.sv's `gfx1_small`/`gfx1_plane_base` for the
    // runtime-vs-elaborated-size derivation this mirrors. Tie to 0 for a
    // title whose actual gfx1 matches the elaborated GFX1_BYTES.
    input  logic         gfx1_small,

    // 1 = Xenophobe's 256 KiB gfx2 region. The union build keeps a 19-bit
    // address/code path for the 512 KiB profiles; this bit restores the
    // active title's 9-bit code modulo and 18-bit plane/code/row packing
    // before the shared 19-bit fabric port.
    input  logic         gfx2_small,

    input  logic [GFX1_CODE_W-1:0] gfx1_code,
    input  logic [2:0]   gfx1_row,
    input  logic [1:0]   gfx1_pair,
    output logic [3:0]   gfx1_pen0,
    output logic [3:0]   gfx1_pen1,

    input  logic [GFX2_CODE_W-1:0] gfx2_code,
    input  logic [4:0]   gfx2_row,
    input  logic         gfx2_req,
    output logic         gfx2_ack,
    output logic [127:0] gfx2_pens,

    output logic         fab_gfx1_req,
    output logic [GFX1_ADDR_W-1:0] fab_gfx1_addr,
    input  logic [7:0]   fab_gfx1_data,
    input  logic         fab_gfx1_ack,

    output logic         fab_gfx2_req,
    output logic [GFX2_ADDR_W-1:0] fab_gfx2_addr,
    input  logic [7:0]   fab_gfx2_data,
    input  logic         fab_gfx2_ack,

    // Bounded row-fetch path: byte address of an aligned SDRAM word and the
    // two raw ROM bytes at [7:0] (even address) / [15:8] (odd address).
    output logic         fab_gfx2_word_req,
    output logic [GFX2_ADDR_W-1:0] fab_gfx2_word_addr,
    input  logic [15:0]  fab_gfx2_word_data,
    input  logic         fab_gfx2_word_ack,

    output logic         fab_gfx2_burst_req,
    output logic [GFX2_ADDR_W-1:0] fab_gfx2_burst_addr,
    input  logic [31:0]  fab_gfx2_burst_data,
    input  logic         fab_gfx2_burst_ack,

    // Packed row path: one request returns the four gfx2 ROM-lane groups for
    // one complete 32-pixel sprite row in bytes [127:0], lane 0 first.
    output logic         fab_gfx2_row_req,
    output logic [GFX2_ADDR_W-1:0] fab_gfx2_row_addr,
    input  logic [127:0] fab_gfx2_row_data,
    input  logic         fab_gfx2_row_ack
);
    // One word is one decoded source row: four raw bytes, two per ROM half.
    (* ramstyle = "M10K, no_rw_check" *) logic [31:0] tile_rows [0:GFX1_ROWS-1];
    logic [GFX1_ROW_W-1:0] tile_fill_row;
    logic [1:0]  tile_fill_byte;
    logic [31:0] tile_fill_data;
    logic        tile_gap;
    logic [31:0] tile_row_q;

    // Each decoded tile row consumes two bytes in one of the two gfx1 ROM
    // halves.  This is row*2 plus the byte-in-row bit; expressing it as a
    // concatenation preserves the exact address while avoiding a synthesized
    // adder for the within-half offset.
    //
    // The 12d (upper-bitplane) half sits immediately ABOVE the 11d half in
    // the actual title's ROM, so its base is half of the ACTIVE TITLE's gfx1
    // region -- NOT half of the elaborated GFX1_BYTES. This module elaborates
    // at the union/largest profile (128K, Pigskin/Arch Rivals); for a title
    // whose real gfx1 is smaller (64K: Xenophobe/Blasted), a
    // fixed {1'b1, tile_half_off} split points 32K past the real ROM data
    // into SDRAM space the loader never wrote, corrupting gfx1_pen[3:2] for
    // essentially every tile. Mirrors mcr68_gfx_rom_sim.sv's runtime
    // `gfx1_small`/`gfx1_plane_base` derivation (see that file for the
    // measured-impact note).
    localparam int GFX1_HALF_BIG   = GFX1_BYTES / 2;  // 128K title -> 0x10000
    localparam int GFX1_HALF_SMALL = GFX1_BYTES / 4;  //  64K title -> 0x08000
    wire [GFX1_ADDR_W-1:0] gfx1_plane_base =
        gfx1_small ? GFX1_ADDR_W'(GFX1_HALF_SMALL) : GFX1_ADDR_W'(GFX1_HALF_BIG);

    wire [GFX1_ADDR_W-2:0] tile_half_off = {tile_fill_row, tile_fill_byte[0]};
    wire [GFX1_ADDR_W-1:0] tile_off0 = {1'b0, tile_half_off};
    always_comb begin
        fab_gfx1_addr = tile_fill_byte[1] ? (gfx1_plane_base + tile_off0) :
                                             tile_off0;
    end

    always_ff @(posedge clk) begin
        tile_row_q <= tile_rows[{gfx1_code, gfx1_row}];
        if (rst || !load_enable) begin
            gfx1_ready     <= 1'b0;
            fab_gfx1_req   <= 1'b0;
            tile_fill_row  <= '0;
            tile_fill_byte <= 2'd0;
            tile_fill_data <= 32'd0;
            tile_gap       <= 1'b0;
        end else if (!gfx1_ready) begin
            if (tile_gap) begin
                tile_gap     <= 1'b0;
                fab_gfx1_req <= 1'b1;
            end else if (!fab_gfx1_req) begin
                fab_gfx1_req <= 1'b1;
            end else if (fab_gfx1_ack) begin
                fab_gfx1_req <= 1'b0;
                tile_gap     <= 1'b1;
                case (tile_fill_byte)
                    // gfx1 is ROMREGION_INVERT in the original set.  The
                    // SDRAM loader preserves the raw dump, so apply the
                    // inversion exactly once at the production decode edge.
                    2'd0: tile_fill_data[7:0]   <= fab_gfx1_data ^ 8'hFF;
                    2'd1: tile_fill_data[15:8]  <= fab_gfx1_data ^ 8'hFF;
                    2'd2: tile_fill_data[23:16] <= fab_gfx1_data ^ 8'hFF;
                    default: begin
                        tile_rows[tile_fill_row] <=
                            {fab_gfx1_data ^ 8'hFF, tile_fill_data[23:0]};
                        if (tile_fill_row == GFX1_ROW_W'(GFX1_ROWS-1)) begin
                            gfx1_ready   <= 1'b1;
                            tile_gap     <= 1'b0;
                        end else begin
                            tile_fill_row <= tile_fill_row + GFX1_ROW_W'(1);
                        end
                    end
                endcase
                tile_fill_byte <= tile_fill_byte + 2'd1;
            end
        end else begin
            fab_gfx1_req <= 1'b0;
        end
    end

    logic [7:0] t0, t1;
    logic [3:0] n0, n1;
    always_comb begin
        t0 = gfx1_pair[1] ? tile_row_q[15:8]  : tile_row_q[7:0];
        t1 = gfx1_pair[1] ? tile_row_q[31:24] : tile_row_q[23:16];
        n0 = gfx1_pair[0] ? t0[3:0] : t0[7:4];
        n1 = gfx1_pair[0] ? t1[3:0] : t1[7:4];
        gfx1_pen0 = {n1[3:2], n0[3:2]};
        gfx1_pen1 = {n1[1:0], n0[1:0]};
    end

    localparam logic [2:0] SP_IDLE = 3'd0, SP_FETCH = 3'd1,
                           SP_GAP = 3'd2, SP_DECODE = 3'd3,
                           SP_ACK = 3'd4, SP_WAIT_LOW = 3'd5;
    logic [2:0] sp_state;
    logic [GFX2_CODE_W-1:0] sp_code;
    logic [4:0] sp_row;
    logic [2:0] sp_word;
    logic [7:0] sp_bytes [0:15];
    integer c;

    // Word 0/1 belong to plane 0, word 2/3 to plane 1, etc. The low bit of
    // sp_word selects the pair of adjacent byte-groups within that plane.
    // This is exactly the flat gfx2 layout used by the sim ROM path:
    // {plane, code, row, group}. The final zero makes the request an aligned
    // byte address while retaining the original byte-addressed fabric API.
    always_comb begin
        fab_gfx2_addr      = '0;
        fab_gfx2_row_addr  = '0;
        if (gfx2_small) begin
            // Xenophobe: 2 plane bits + 9 code bits + 5 row bits + 2
            // alignment bits = 18 physical address bits. Keep the shared
            // union port 19 bits wide by inserting one leading zero. Without
            // it, plane 1/2/3 land at 0x20000/0x40000/0x60000 instead of the
            // four physical 64 KiB planes at 0x10000/0x20000/0x30000.
            fab_gfx2_word_addr  = {1'b0, sp_word[2:1], sp_code[8:0], sp_row,
                                   sp_word[0], 1'b0};
            fab_gfx2_burst_addr = {1'b0, sp_word[2:1], sp_code[8:0], sp_row,
                                   1'b0, 1'b0};
            // Row-packed storage is {code,row,plane,byte}; all four plane
            // groups for one row are therefore one contiguous 16-byte line.
            fab_gfx2_row_addr = {1'b0, sp_code[8:0], sp_row, 4'b0000};
        end else begin
            fab_gfx2_word_addr  = {sp_word[2:1], sp_code, sp_row,
                                    sp_word[0], 1'b0};
            fab_gfx2_burst_addr = {sp_word[2:1], sp_code, sp_row,
                                   1'b0, 1'b0};
            fab_gfx2_row_addr = {sp_code, sp_row, 4'b0000};
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sp_state     <= SP_IDLE;
            fab_gfx2_req <= 1'b0;
            fab_gfx2_word_req <= 1'b0;
            fab_gfx2_burst_req <= 1'b0;
            fab_gfx2_row_req <= 1'b0;
            gfx2_ack     <= 1'b0;
            gfx2_pens    <= '0;
            sp_code      <= '0;
            sp_row       <= '0;
            sp_word      <= '0;
        end else begin
            gfx2_ack <= 1'b0;
            case (sp_state)
                SP_IDLE: if (gfx2_req) begin
                    sp_code      <= gfx2_code;
                    sp_row       <= gfx2_row;
                    sp_word      <= 3'd0;
                    if (USE_GFX2_ROW_BURST)
                        fab_gfx2_row_req <= 1'b1;
                    else if (USE_GFX2_BURST)
                        fab_gfx2_burst_req <= 1'b1;
                    else
                        fab_gfx2_word_req <= 1'b1;
                    sp_state     <= SP_FETCH;
                end
                SP_FETCH: if (USE_GFX2_ROW_BURST ? fab_gfx2_row_ack :
                              (USE_GFX2_BURST ? fab_gfx2_burst_ack : fab_gfx2_word_ack)) begin
                    if (USE_GFX2_ROW_BURST) begin
                        sp_bytes[0]  <= fab_gfx2_row_data[7:0];
                        sp_bytes[1]  <= fab_gfx2_row_data[15:8];
                        sp_bytes[2]  <= fab_gfx2_row_data[23:16];
                        sp_bytes[3]  <= fab_gfx2_row_data[31:24];
                        sp_bytes[4]  <= fab_gfx2_row_data[39:32];
                        sp_bytes[5]  <= fab_gfx2_row_data[47:40];
                        sp_bytes[6]  <= fab_gfx2_row_data[55:48];
                        sp_bytes[7]  <= fab_gfx2_row_data[63:56];
                        sp_bytes[8]  <= fab_gfx2_row_data[71:64];
                        sp_bytes[9]  <= fab_gfx2_row_data[79:72];
                        sp_bytes[10] <= fab_gfx2_row_data[87:80];
                        sp_bytes[11] <= fab_gfx2_row_data[95:88];
                        sp_bytes[12] <= fab_gfx2_row_data[103:96];
                        sp_bytes[13] <= fab_gfx2_row_data[111:104];
                        sp_bytes[14] <= fab_gfx2_row_data[119:112];
                        sp_bytes[15] <= fab_gfx2_row_data[127:120];
                        fab_gfx2_row_req <= 1'b0;
                        sp_state <= SP_DECODE;
                    end else if (USE_GFX2_BURST) begin
                        sp_bytes[{sp_word, 1'b0}]       <= fab_gfx2_burst_data[7:0];
                        sp_bytes[{sp_word, 1'b1}]       <= fab_gfx2_burst_data[15:8];
                        sp_bytes[{sp_word, 1'b0} + 4'd2] <= fab_gfx2_burst_data[23:16];
                        sp_bytes[{sp_word, 1'b0} + 4'd3] <= fab_gfx2_burst_data[31:24];
                        fab_gfx2_burst_req <= 1'b0;
                    end else begin
                        sp_bytes[{sp_word, 1'b0}] <= fab_gfx2_word_data[7:0];
                        sp_bytes[{sp_word, 1'b1}] <= fab_gfx2_word_data[15:8];
                        fab_gfx2_word_req <= 1'b0;
                    end
                    if ((USE_GFX2_ROW_BURST) ||
                        (USE_GFX2_BURST && sp_word == 3'd6) ||
                        (!USE_GFX2_BURST && sp_word == 3'd7))
                        sp_state <= SP_DECODE;
                    else begin
                        sp_word <= sp_word + (USE_GFX2_BURST ? 3'd2 : 3'd1);
                        sp_state <= SP_GAP;
                    end
                end
                SP_GAP: begin
                    if (USE_GFX2_ROW_BURST)
                        fab_gfx2_row_req <= 1'b1;
                    else if (USE_GFX2_BURST)
                        fab_gfx2_burst_req <= 1'b1;
                    else
                        fab_gfx2_word_req <= 1'b1;
                    sp_state <= SP_FETCH;
                end
                SP_DECODE: begin
                    for (c = 0; c < 32; c = c + 1) begin
                        if (c[0])
                            gfx2_pens[4*c +: 4] <= sp_bytes[{c[2:1], c[4:3]}][3:0];
                        else
                            gfx2_pens[4*c +: 4] <= sp_bytes[{c[2:1], c[4:3]}][7:4];
                    end
                    sp_state <= SP_ACK;
                end
                SP_ACK: begin
                    gfx2_ack <= 1'b1;
                    sp_state <= SP_WAIT_LOW;
                end
                SP_WAIT_LOW: if (!gfx2_req) sp_state <= SP_IDLE;
                default: sp_state <= SP_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
