// =============================================================================
// mcr68_rom_loader.sv -- MCR-68k MiSTer ROM download loader.
//
// SYNTHESIZABLE. This is a purpose-built replacement for the Y Board donor's
// descriptor-parsing loader (rtl/mem/yb_rom_loader_ref.sv, vendored
// read-only reference). Y Board's loader discovers, at load time, which game
// was selected and how big its per-game sprite banks are, via a 16-byte
// board-descriptor header written ahead of the ROM payload. This loader does
// NOT use a descriptor header: the selected title arrives on the `game`
// input (see rtl/mcr68_game_profile.svh) as static configuration, and the
// per-title region sizes are a compile-time table below. This loader is
// otherwise just an ioctl_download-gated byte-stream writer that routes
// incoming bytes to one of four fixed SDRAM regions, chosen by
// ioctl_index, at a running byte offset given directly by ioctl_addr.
//
// -----------------------------------------------------------------------
// Byte-offset-to-region mapping
// -----------------------------------------------------------------------
// mra/*.mra declare four separate `<rom index="N">` blocks (N = 0..3);
// the index assignment is owned by tools/gen_mra.py's REGION_INDEX table and
// reproduced here verbatim. Per standard MiSTer hps_io/ioctl convention,
// each distinct `index` value is its OWN download: hps_io resets ioctl_addr
// to 0 at the start of each one and asserts a fresh ioctl_download pulse.
// That means ioctl_index already tells this loader which region is
// streaming, and ioctl_addr *is* the running byte-count within that region's
// own download -- there is no need (and no way) for a byte count to run
// continuously across regions, because the regions never share one
// ioctl_download assertion.
//
//   ioctl_index | MAME ROM_REGION      | SDRAM base  | present in
//   ------------|----------------------|-------------|--------------------------
//   0           | maincpu              | 0x0000000   | all titles
//   1           | sg:cpu OR bg:cpu     | 0x1000000   | all titles (exactly one)
//   2           | gfx1                 | 0x2000000   | all titles
//   3           | gfx2                 | 0x3000000   | all titles
//   4           | reserved             | --          | rejected
//
// `sg:cpu` (Sounds Good, 68000) and `bg:cpu` (Williams Audio System) share
// index 1 because they are ALTERNATIVE sound boards: verified against MAME
// 0.289 src/mame/bally/mcr68.cpp -- every ROM_START in that driver declares
// exactly one of the two, never both (xenophob/blasted have sg:cpu;
// archrivl/pigskin have bg:cpu). Their
// sizes differ (0x40000 vs 0x90000), which is why the size table is indexed
// by title, not by index alone.
//
// Per-title region sizes, transcribed from the ROM_REGION declarations in
// MAME 0.289 src/mame/bally/mcr68.cpp (line numbers at that revision):
//
//   title      | 0 maincpu | 1 sg/bg:cpu   | 2 gfx1  | 3 gfx2  | ref
//   -----------|-----------|---------------|---------|---------|------
//   xenophob   | 0x40000   | 0x40000 (sg)  | 0x10000 | 0x40000 | 1337
//   blasted    | 0x40000   | 0x40000 (sg)  | 0x10000 | 0x80000 | 1455
//   archrivl   | 0x40000   | 0x90000 (bg)  | 0x20000 | 0x80000 | 1527
//   pigskin    | 0x40000   | 0x90000 (bg)  | 0x20000 | 0x80000 | 1715
//
// Sizes are PER TITLE on purpose: an oversized stream for a title whose
// region is smaller is still rejected. The limits are not raised to the
// maximum across titles.
//
// -----------------------------------------------------------------------
// ioctl_index 8 -- the game-profile CONFIG BYTE, not a ROM region
// -----------------------------------------------------------------------
// tools/gen_mra.py emits `<rom index="8"><part>NN</part></rom>` FIRST in every
// generated .mra (its CONFIG_ROM_INDEX): a one-byte download carrying the
// mcr68_game_e profile value. It is latched at the TOP LEVEL (not here) and
// arrives on this module's `game` input.
//
// This loader's behaviour for index 8 is: SILENTLY IGNORE IT.
//   - no SDRAM write is issued (index 8 has no region base and no size);
//   - `region_active`/`active_index`/`region_bad`/`region_done` are NOT
//     touched, so it cannot start, corrupt or retire a ROM region;
//   - it is NOT treated as an error: `rom_loaded` is unaffected and the
//     download is not stalled or aborted.
// That falls out of the general rule below -- an index with no region in the
// selected profile's mask is simply not accepted -- so index 8 needs no
// special case, and neither would a future index-9 config block.
// NOTE on `ioctl_wait`: it MUST be low whenever no download is in flight.
// hps_io drives it onto HPS_BUS[37] continuously, and sys_top's io_ack
// generator (sys/sys_top.v:259) refuses to complete ANY UIO SPI word while
// io_wait is high -- not just download traffic. The original form
// `busy || !mem_ready` therefore asserted io_wait from power-up (mem_ready
// is 0 until SDRAM init completes), which deadlocked Main's very first SPI
// transaction after core identification: Main spins on the ack with no
// timeout, never reads CONF_STR, never configures video -- the on-hardware
// symptom was instant NO SIGNAL with no ROM progress bar, on every load.
// Root-caused from Main's log (stops after "Identified 8BIT core") plus the
// sys_top/hps_io sources on 2026-08-14. `!mem_ready` may only throttle an
// ACTIVE download, hence the `ioctl_download &&` guard. A config-byte or ROM
// download arriving before SDRAM init completes still waits for `mem_ready`
// exactly as before.
//
// -----------------------------------------------------------------------
// XENOPHOBE EQUIVALENCE CONTRACT (rtl/mcr68_game_profile.svh rule 1)
// -----------------------------------------------------------------------
// With game == GAME_XENOPHOB the four Xenophobe region bases and sizes, the
// accepted index set (0..3; index 4 is absent from Xenophobe's region mask
// and is therefore rejected exactly as `ioctl_index <= 3` rejected it
// before), every rejection condition, `ioctl_wait` and `rom_loaded` are
// exercised by sim/tb_mcr68_rom_loader.sv's focused four-region contract
// checks.
//
// -----------------------------------------------------------------------
// FIXED-4 TRUNCATION BUG (found and fixed 2026-08-13)
// -----------------------------------------------------------------------
// The pre-multigame body carried three hard "there are exactly 4 regions"
// assumptions that would have silently mis-retired a region:
//   1. `logic [3:0] region_done;`
//   2. `region_done[ioctl_index[1:0]] <= 1'b0;`   (start-of-download clear)
//   3. `region_done[active_index[1:0]] <= 1'b1;`  (retirement)
// (2) and (3) truncate the index to 2 bits, so index 4 aliases onto index 0:
// Region completion is four bits and is updated with a one-hot mask from
// `index_onehot()` (an explicit 4-way case that returns all-zero for any
// index outside 0..3), never with a variable bit-select,
// and `rom_loaded` compares against the selected profile's region mask.
//
// SDRAM byte address for any downloaded byte = region_base(ioctl_index) +
// ioctl_addr. The largest per-title footprint (archrivl/pigskin: 0x40000 +
// 0x90000 + 0x20000 + 0x80000 = 1,769,472 bytes) is far below any MiSTer
// SDRAM module's capacity, so the exact base addresses above are a free
// choice on this loader's part, not derived from any external constraint;
// they are repeated verbatim (and must stay numerically identical) in
// rtl/mem/mcr68_rom_fabric.sv's own region-base localparams so the write
// side and the read side agree. A future shared rtl/mem/mcr68_mem_pkg.sv
// would be the right place to de-duplicate that once both modules exist and
// their neighbors are stable.
//
// The four original bases are one 16MB-aligned SDRAM bank each (bank =
// word_addr[25:24]) so back-to-back fetches within one region never contend
// for a row with another region's traffic -- see the RECONCILED note below.
// The four regions occupy one 16MB-aligned SDRAM bank each.
//
// Per-region byte order is NOT touched here for maincpu, sg/bg:cpu and gfx1:
// those streams are written exactly as hps_io delivers them, byte-for-byte,
// into ascending SDRAM byte addresses. Production gfx2 is the deliberate
// exception: PACK_GFX2 permutes only index 3 into `{code,row,plane,byte}`
// rows so the four physical plane ROMs are returned by one atomic p3 row
// response. The external stream order and all ROM contents are unchanged;
// only the internal SDRAM placement differs. The read-side fabric must use
// the matching row address contract when PACK_GFX2 is enabled. Any
// 68000-word-vs-file-byte reassembly (the maincpu/sndcpu case) or raw-byte
// pass-through (gfx1) remains the READ side's job -- see
// mcr68_rom_fabric.sv's header for the exact byte-swap/lane-select math.
//
// ROMREGION_INVERT (gfx1's xeno_bg.*.bin bytes must be XORed with 0xFF
// before tile decode) is likewise NOT done here, matching the .mra's own
// comment ("RTL must XOR every byte with 0xFF at the point of tile decode;
// do not invert at load time") and tools/prep_roms.py's existing
// convention for the Verilator-only sim ROM images.
//
// -----------------------------------------------------------------------
// hps_io wire-width ASSUMPTION (flag for reconciliation with the top-level/
// hps_io integration agent)
// -----------------------------------------------------------------------
// This loader assumes hps_io is instantiated WIDE=1 for the ROM download:
// ioctl_dout carries one 16-bit word per ioctl_wr pulse (first-streamed
// byte in dout[7:0], second in dout[15:8]) and ioctl_addr increments by 2
// per write. This exactly matches the convention already established by
// this project's own donor reference, rtl/mem/yb_rom_loader_ref.sv (see its
// own comment: "the live MiSTer wrapper uses hps_io WIDE=1... advances
// ioctl_addr by two"), and lines up with the .mra's `interleave output="16"`
// tag on the maincpu/sndcpu blocks (the interleave tool already assembles
// the byte-swapped 16-bit stream; WIDE=1 just transports it two bytes at a
// time instead of one). If the eventual top level instead instantiates
// hps_io with WIDE=0 for this download, ioctl_dout narrows to [7:0],
// ioctl_addr increments by 1 per write, and `wr_be` below must become
// address-parity-driven (2'b01/2'b10) instead of the always-2'b11 used now
// -- a small, localized change, but it must be reconciled before hardware
// bring-up.
//
// -----------------------------------------------------------------------
// RECONCILED 2026-08-06 (Phase 5 integration pass): read directly against
// the sibling rtl/mem/mcr68_sdram.sv (not assumed) instead of only against
// the yb_sdram_ref.sv donor pattern below. Two real mismatches were found
// and fixed here:
//   1. Width: mcr68_sdram.sv's wr_addr/p0-p3_addr ports are [25:1] (25-bit
//      word address = 26-bit/64MB byte address space, bank = addr[25:24]),
//      not [24:1]/32MB as originally assumed from the donor pattern alone.
//      Widened to match.
//   2. Base alignment: mcr68_sdram.sv's own header documents a "suggested
//      SDRAM base-address map" giving each ROM region its OWN 16MB-aligned
//      bank (bank = word addr[25:24]) specifically so back-to-back fetches
//      within one region never contend for a row with a different region's
//      traffic. This loader's region bases below are updated to match that
//      map exactly (MAIN=0x0000000, SND=0x1000000, GFX1=0x2000000,
//      GFX2=0x3000000 byte addresses) instead of the previous contiguous
//      0x000000-0x0D0000 layout, which would have placed all four regions
//      in bank 0 and forfeited that isolation.
// Must stay numerically identical to rtl/mem/mcr68_rom_fabric.sv's own
// region-base localparams (see that file's matching note).
// -----------------------------------------------------------------------
// SDRAM write-port ASSUMPTION (flag for reconciliation with the sibling
// mcr68_sdram.sv agent)
// -----------------------------------------------------------------------
// This loader drives wr_req/wr_addr/wr_data/wr_be/wr_ack exactly like
// rtl/mem/yb_rom_loader_ref.sv drives the SAME-NAMED signals on
// rtl/mem/yb_sdram_ref.sv -- i.e. this assumes mcr68_sdram.sv reuses that
// exact write-port shape and contract (see yb_sdram_ref.sv's own header
// comment for the authoritative statement of it):
//   - wr_addr is a WORD address (byte_address[N:1]); this loader outputs
//     wr_addr[25:1] -- see the "RECONCILED" note above for why this is 25
//     (not 24) bits, i.e. a 26-bit/64MB SDRAM byte address space.
//   - wr_data is a full 16-bit word; wr_be is a 2-bit per-byte enable
//     ({high-byte-enable, low-byte-enable} or equivalent -- this loader
//     always writes both bytes of a full word, so it always drives 2'b11
//     and never needs to resolve the exact bit-order convention itself).
//   - "One transaction per req RISING EDGE... single-outstanding: drop req
//     after (or pulse it before) each ack" -- this loader holds wr_req high
//     from the cycle it issues a write until wr_ack pulses, then drops it
//     the same cycle, exactly mirroring yb_rom_loader_ref.sv's own
//     `if (wr_ack) begin wr_req <= 1'b0; busy <= 1'b0; end`.
//   - `mem_ready` here is assumed to be mcr68_sdram.sv's post-init "ready"
//     output (yb_sdram_ref.sv's own `ready`), synchronous to the same
//     `clk` this loader runs on. yb_sdram_ref.sv runs its whole port set at
//     `clk_ram` (its fast SDRAM clock); this loader is therefore ALSO
//     assumed to run at that same clock, not at a slower system clock --
//     if the real mcr68_sdram.sv instead exposes clk_sys-domain ports with
//     internal CDC (the way yb_rom_fabric_ref.sv's pcm_data/pcm_ack path
//     does its own explicit domain-crossing capture for ONE of Y Board's
//     six ports), this loader's `clk` input should simply be tied to
//     whichever clock those write-port signals are actually synchronous
//     to -- no internal change needed here, since this module has no
//     other clock-relative assumption beyond "wr_req/wr_ack/mem_ready are
//     all synchronous to `clk`".
// =============================================================================

`timescale 1ns / 1ps

module mcr68_rom_loader #(
    // Production gfx2 storage is row-packed so the four physical ROM planes
    // can be fetched as one contiguous 16-byte line.  The external MiSTer
    // stream remains the MAME/MRA plane-concatenated byte stream; this is only
    // an internal SDRAM placement permutation.  Keep the default off for the
    // raw-address contract bench and legacy diagnostic consumers.
    parameter bit PACK_GFX2 = 1'b0
) (
    input  logic        clk,
    input  logic        rst,

    // Selected title. Encoding MUST match mcr68_game_e in
    // rtl/mcr68_game_profile.svh (0=XENOPHOB, 1=BLASTED, 3=ARCHRIVL,
    // 4=PIGSKIN; 2 reserved). Static configuration, per that header's
    // contract rule 2: hold it stable across a ROM download. A change on
    // this input invalidates every region (see game_q below), so a
    // mid-flight change is safe, just wasteful.
    input  logic  [2:0]  game,

    // SDRAM controller readiness gate. See header ASSUMPTION above.
    input  logic         mem_ready,

    // hps_io ROM-download stream. See header ASSUMPTION above (WIDE=1).
    input  logic          ioctl_download,
    input  logic  [7:0]   ioctl_index,
    input  logic          ioctl_wr,
    input  logic  [24:0]  ioctl_addr,
    input  logic  [15:0]  ioctl_dout,
    output logic          ioctl_wait,

    // SDRAM write port. See header ASSUMPTION above and the
    // "RECONCILED 2026-08-06" note below for the exact width/base-address
    // agreement with rtl/mem/mcr68_sdram.sv.
    output logic          wr_req,
    output logic [25:1]   wr_addr,
    output logic [15:0]   wr_data,
    output logic  [1:0]   wr_be,
    input  logic          wr_ack,

    // High once EVERY region the selected title actually has (see
    // `region_mask` below -- has
    // completed a contiguous download at exactly its expected size. A new
    // download clears that region's completion bit immediately; this
    // prevents a ROM reload from leaving the core running against a
    // partially refreshed SDRAM image.
    output logic          rom_loaded
);

    // -------------------------------------------------------------------
    // Profile encoding. Kept as local constants rather than by `include`ing
    // rtl/mcr68_game_profile.svh so this module stays buildable from a bare
    // file list with no -I path; the values are asserted to match that
    // header's mcr68_game_e by sim/tb_mcr68_rom_loader.sv.
    // -------------------------------------------------------------------
    localparam logic [2:0] G_XENOPHOB = 3'd0;
    localparam logic [2:0] G_BLASTED  = 3'd1;
    localparam logic [2:0] G_ARCHRIVL = 3'd3;
    localparam logic [2:0] G_PIGSKIN  = 3'd4;

    // -------------------------------------------------------------------
    // Fixed region layout. Base addresses are BYTE addresses. The four
    // original regions get one mcr68_sdram.sv bank each (bank =
    // word_addr[25:24], i.e. every 16MB) -- see the "RECONCILED 2026-08-06"
    // header note.
    // region_base()[25:1] converts to the word address wr_addr expects.
    // -------------------------------------------------------------------
    localparam logic [25:0] MAIN_BASE = 26'h000_0000;  // maincpu,        bank 0
    localparam logic [25:0] SND_BASE  = 26'h100_0000;  // sg:cpu/bg:cpu,  bank 1
    localparam logic [25:0] GFX1_BASE = 26'h200_0000;  // gfx1,           bank 2
    localparam logic [25:0] GFX2_BASE = 26'h300_0000;  // gfx2,           bank 3

    // Region byte counts, transcribed from the ROM_REGION declarations in
    // MAME 0.289 src/mame/bally/mcr68.cpp (see the per-title table in the
    // header). Widths are explicit and unsigned so the size comparisons
    // below are unsigned 32-bit, exactly as they were when this returned a
    // (positive) `int`.
    localparam logic [31:0] SZ_NONE = 32'h0000_0000;
    localparam logic [31:0] SZ_64K  = 32'h0001_0000;
    localparam logic [31:0] SZ_128K = 32'h0002_0000;
    localparam logic [31:0] SZ_256K = 32'h0004_0000;
    localparam logic [31:0] SZ_512K = 32'h0008_0000;
    localparam logic [31:0] SZ_576K = 32'h0009_0000;

    function automatic logic [25:0] region_base(input logic [7:0] idx);
        case (idx)
            8'd0:    region_base = MAIN_BASE;
            8'd1:    region_base = SND_BASE;
            8'd2:    region_base = GFX1_BASE;
            8'd3:    region_base = GFX2_BASE;
            default: region_base = 26'h3FF_FFFF; // out of range, never issued
        endcase
    endfunction

    // PER-TITLE sizes. A zero return means "this title has no such region",
    // which is simultaneously the rejection mechanism (see region_mask /
    // index_valid) -- an index the title does not have is never accepted,
    // and an oversized stream for a title whose region is SMALLER than
    // another title's is still rejected because the limit is this title's,
    // not the maximum across titles.
    //
    // An unimplemented profile value (5..7) returns zero for every index:
    // no region is accepted, `rom_loaded` stays low and the core stays in
    // reset. That is rtl/mcr68_game_profile.svh contract rule 4's "inert in
    // synthesis, never silently alias onto Xenophobe" applied here.
    function automatic logic [31:0] region_bytes(input logic [2:0] g,
                                                 input logic [7:0] idx);
        logic [31:0] sz;
        begin
            sz = SZ_NONE;
            case (idx)
                // maincpu -- 256K on every title in the driver.
                8'd0: if (g <= G_PIGSKIN) sz = SZ_256K;
                // sg:cpu (Sounds Good, 256K) OR bg:cpu (Williams Audio
                // System, 576K). Verified against all 13 ROM_STARTs in
                // mcr68.cpp: every set declares exactly one of the two,
                // never both, so they can share index 1.
                8'd1: case (g)
                          G_XENOPHOB,
                          G_BLASTED: sz = SZ_256K;   // sg:cpu
                          G_ARCHRIVL,
                          G_PIGSKIN:  sz = SZ_576K;   // bg:cpu
                          default:    sz = SZ_NONE;
                      endcase
                // gfx1 tiles.
                8'd2: case (g)
                          G_XENOPHOB,
                          G_BLASTED: sz = SZ_64K;
                          G_ARCHRIVL,
                          G_PIGSKIN:  sz = SZ_128K;
                          default:    sz = SZ_NONE;
                      endcase
                // gfx2 sprites.
                8'd3: case (g)
                          G_XENOPHOB: sz = SZ_256K;
                          G_BLASTED,
                          G_ARCHRIVL,
                          G_PIGSKIN:  sz = SZ_512K;
                          default:    sz = SZ_NONE;
                      endcase
                // Everything else, including ioctl_index 8 (the game-profile
                // config byte -- see the header): no region, never accepted.
                default: sz = SZ_NONE;
            endcase
            region_bytes = sz;
        end
    endfunction

    // One-hot region select. Any index outside 0..3 -- 4..7,
    // the config index 8, anything -- returns all-zero, so it can neither
    // clear nor set a completion bit.
    function automatic logic [3:0] index_onehot(input logic [7:0] idx);
        case (idx)
            8'd0:    index_onehot = 4'b0001;
            8'd1:    index_onehot = 4'b0010;
            8'd2:    index_onehot = 4'b0100;
            8'd3:    index_onehot = 4'b1000;
            default: index_onehot = 4'b0000;
        endcase
    endfunction

    // Convert a byte offset in the downloaded, lane-concatenated gfx2 ROM
    // into the physical row-packed offset used by the production sprite
    // fetcher.  Here `lane` is the RGN_FRAC(quarter) ROM selected by MAME's
    // sprite x-offset layout (the four physical gfx2 ROMs); each source lane
    // contains `code,row,group` bytes. One packed row stores the corresponding
    // four lane groups consecutively:
    //
    //   packed = {group_index, lane, byte_in_group}
    //
    // For Xenophobe each plane is 64 KiB (9-bit code); the other supported
    // profiles use 128 KiB planes (10-bit code).  The source offset is always
    // even because hps_io WIDE=1 advances ioctl_addr by two, so both bytes of
    // a write remain adjacent in the packed destination word.
    function automatic logic [18:0] pack_gfx2_byte_addr(
        input logic [24:0] raw_byte_addr,
        input logic [2:0]  selected_game
    );
        begin
            if (selected_game == G_XENOPHOB)
                pack_gfx2_byte_addr = {1'b0, raw_byte_addr[15:2],
                                       raw_byte_addr[17:16], raw_byte_addr[1:0]};
            else
                pack_gfx2_byte_addr = {raw_byte_addr[16:2],
                                       raw_byte_addr[18:17], raw_byte_addr[1:0]};
        end
    endfunction

    logic        busy;           // one write in flight (wr_req asserted, awaiting wr_ack)
    logic        region_active;  // a download for `active_index` is in progress
    logic [7:0]  active_index;
    logic [24:0] next_addr;      // expected next byte offset in this stream
    logic        region_bad;     // gap, wrong index, or out-of-range write
    logic [3:0]  region_done;    // sticky, one bit per region index 0..3
    logic  [2:0] game_q;         // last-seen profile select (see game_changed)

    // Which regions the selected title actually has.
    wire [3:0] region_mask = { region_bytes(game_q, 8'd3) != SZ_NONE,
                               region_bytes(game_q, 8'd2) != SZ_NONE,
                               region_bytes(game_q, 8'd1) != SZ_NONE,
                               region_bytes(game_q, 8'd0) != SZ_NONE };

    wire [3:0] incoming_bit = index_onehot(ioctl_index);
    wire [3:0] active_bit   = index_onehot(active_index);

    // Accept an index only if the SELECTED TITLE has that region.
    wire index_valid = |(incoming_bit & region_mask);
    wire [25:0] selected_region_base = region_base(ioctl_index);
    wire [18:0] gfx2_packed_byte_addr =
        pack_gfx2_byte_addr(ioctl_addr, game_q);
    wire [24:1] selected_word_offset =
        (PACK_GFX2 && ioctl_index == 8'd3) ?
            {6'd0, gfx2_packed_byte_addr[18:1]} : ioctl_addr[24:1];

    // A change of `game` invalidates every region: the size table it was
    // validated against no longer applies. `game` is static configuration
    // (rtl/mcr68_game_profile.svh contract rule 2), so for a well-behaved
    // top level this never fires -- it exists so that a mid-flight change is
    // safe rather than silently producing a wrongly-sized "loaded" image.
    wire game_changed = (game != game_q);

    // Idle MUST be 0: a high io_wait blocks every UIO SPI ack in sys_top,
    // not just downloads. See the NOTE in the header (root cause of the
    // never-boots-on-hardware NO SIGNAL deadlock, fixed 2026-08-14).
    assign ioctl_wait = busy || (ioctl_download && !mem_ready);
    // Never assert with an empty mask (unimplemented profile) -- `&(done |
    // ~mask)` alone would read as "all done" when nothing can ever load.
    assign rom_loaded = (region_mask != 4'b0000) &&
                        ((region_done & region_mask) == region_mask);

    always_ff @(posedge clk) begin
        if (rst) begin
            busy          <= 1'b0;
            region_active <= 1'b0;
            active_index  <= 8'd0;
            next_addr     <= 25'd0;
            region_bad    <= 1'b0;
            region_done   <= 4'b0000;
            game_q        <= game;
            wr_req        <= 1'b0;
            wr_addr       <= '0;
            wr_data       <= '0;
            wr_be         <= 2'b00;
        end else begin
            game_q <= game;

            // Complete any write already in flight regardless of anything
            // else -- the SDRAM controller's ack must always be consumed.
            if (wr_ack) begin
                wr_req <= 1'b0;
                busy   <= 1'b0;
            end

            if (game_changed) begin
                region_done   <= 4'b0000;
                region_active <= 1'b0;
                region_bad    <= 1'b0;
            end else begin
                if (mem_ready && ioctl_download && ioctl_wr && !busy && index_valid) begin
                    if (!region_active) begin
                        region_active <= 1'b1;
                        active_index  <= ioctl_index;
                        region_done   <= region_done & ~incoming_bit;
                        region_bad    <= (ioctl_addr != 25'd0);
                    end else begin
                        if ((active_index != ioctl_index) || (ioctl_addr != next_addr))
                            region_bad <= 1'b1;
                    end
                    // Widths written out explicitly. The original wrote
                    // `(ioctl_addr + 25'd2) > region_bytes(...)`, whose
                    // context width was ALREADY 32 (the size operand), so
                    // this is the same unsigned 32-bit comparison with no
                    // truncation or wrap -- just without the WIDTHEXPAND
                    // lint warning. The focused loader bench checks the
                    // resulting region bounds and write addresses.
                    if (({7'd0, ioctl_addr} + 32'd2) > region_bytes(game_q, ioctl_index))
                        region_bad <= 1'b1;
                    next_addr  <= ioctl_addr + 25'd2;
                    wr_req     <= 1'b1;
                    busy       <= 1'b1;
                    wr_addr    <= selected_region_base[25:1] + selected_word_offset;
                    wr_data    <= ioctl_dout;
                    wr_be      <= 2'b11;
                end

                // Retire the just-finished download once its last write (if
                // any) has actually landed in SDRAM. Mirrors
                // yb_rom_loader_ref.sv's own region_stream_active retirement
                // gate (`!ioctl_download && region_stream_active && !busy &&
                // !wr_req`).
                if (!ioctl_download && region_active && !busy && !wr_req) begin
                    region_active <= 1'b0;
                    if (!region_bad &&
                        next_addr == 25'(region_bytes(game_q, active_index)))
                        region_done <= region_done | active_bit;
                end
            end
        end
    end

endmodule
