// =============================================================================
// mcr68_sprites.sv -- MCR-68000 ("MCR-68k") sprite engine, Xenophobe.
//
// Phase 3 (video) per C:\Users\meath\.claude\plans\you-a-makeing-a-fizzy-rabin.md
// and AGENTS.md/core-debug.toml. Produces the two (low/high) priority-group
// resolved sprite pixels that rtl/video/mcr68_colormix.sv composites against
// the tilemap engine's output, per mcr68.cpp's 4-pass render order
// (opaque tilemap -> low sprites -> tilemap category-1 -> high sprites).
//
// Primary source, read directly (not just the plan's paraphrase, per this
// task's explicit instruction and CLAUDE.md's evidence order):
//   D:\Arcade\AI\mame289\src\mame\bally\mcr68.cpp
//     lines 301-349  mcr68_state::mcr68_update_sprites()
//     lines 165-177  mcr68_sprite_layout (gfx2 decode geometry)
//     lines 1179-1182 GFXDECODE_START / gfx_mcr68 (gfx1=tiles scale 2,2; gfx2=sprites, no scale)
//   D:\Arcade\AI\mame289\src\emu\drawgfx.cpp          gfx_element::prio_transmask()
//   D:\Arcade\AI\mame289\src\emu\drawgfxt.ipp          PIXEL_OP_*_TRANSMASK_PRIORITY macros
// =============================================================================
//
// -----------------------------------------------------------------------
// CORRECTION vs. the plan document -- read this before trusting the plan's
// prose on sprite priority ordering or the pass-2 masking condition. Both
// are wrong in ways that matter; the derivation below is from the actual
// drawgfx.cpp/drawgfxt.ipp macro expansion, not from reading mcr68.cpp's
// comments at face value.
//
// (1) "RAM slot 0 drawn topmost" is BACKWARDS. gfx_element::prio_transmask()
//     (drawgfx.cpp:1039) unconditionally forces `pmask |= 1 << 31` on TOP of
//     whatever pmask the caller passed (0x00 for pass 1, 0x02 for pass 2).
//     PIXEL_OP_REBASE_TRANSMASK_PRIORITY (drawgfxt.ipp:270-281) then gates
//     every draw -- pass 1's real pixels AND pass 2's pen-8 pixels alike --
//     on `((1 << (PRIORITY & 0x1f)) & pmask) == 0`, and ALWAYS stamps
//     PRIORITY := 31 afterward whenever the pen survives the pass's
//     trans_mask, regardless of whether the draw itself was permitted. With
//     the forced bit-31, that draw-permission test evaluates to "blocked
//     iff PRIORITY is already 31" for EVERY pass (pass 1's own pmask=0x00
//     is not actually a free pass once the top bit is folded in). Since the
//     priority buffer starts at 1 (screen.priority().fill(1,...), only ever
//     transitions 1->31, and is shared across the WHOLE 511->0 loop for a
//     group (refilled only once per mcr68_update_sprites() call): whichever
//     sprite is *processed first* in the loop claims a pixel and blocks
//     every sprite processed after it (both passes) from touching that
//     pixel again. The loop runs slot 511 downto 0, so **slot 511 is
//     processed first and wins conflicts; slot 0 is processed last and
//     LOSES conflicts.** This is the opposite of the plan's claim, but it
//     is exactly consistent with mcr68.cpp:345's own comment "then draw the
//     mask, behind the background but obscuring *following* sprites" --
//     "following" = processed later in the loop = lower slot numbers = the
//     ones a pen-8 mask can obscure. Implemented below as a per-group
//     claim bit embedded in each priority group's line-buffer entry
//     (semantically identical to the priority buffer's 1-vs-31 states;
//     the intermediate 5-bit priority LEVEL machinery this game never
//     uses is not modelled).
//
// (2) Pass 2's masking condition -- CORRECTED AGAIN (2026-08-06) by the
//     Phase 3 adversarial audit, which found the derivation originally
//     written here (below this note, in earlier revisions of this file)
//     itself landed on the wrong branch after flagging its own
//     contradiction mid-derivation and never resolving it. Fully-resolved
//     truth table, done carefully this time:
//
//     Pass 2's pmask = 0x02, forced to 0x80000002 by prio_transmask()'s
//     unconditional `pmask |= 1<<31`. Draw permission test is
//     `((1<<PRIORITY) & pmask) == 0`. The priority buffer in this game is
//     provably confined to exactly {1 (group fill value), 31 (the only
//     value either pass ever stamps)}:
//       PRIORITY=1  : (1<<1)  & 0x80000002 = 0x00000002 (nonzero) -> BLOCKED
//       PRIORITY=31 : (1<<31) & 0x80000002 = 0x80000000 (nonzero) -> BLOCKED
//     Both reachable priority states are blocked. Pass 2's pixel WRITE is
//     mathematically unreachable for this game, unconditionally -- pen 8
//     NEVER paints a visible pixel, whether the entry is claimed or not. This
//     matches mcr68.cpp:338's own framing exactly: pen 8 is "the 'under
//     tile' pen" -- a pure invisible stencil/eraser, not a mask color that
//     is sometimes visible. Only the unconditional PRIORITY:=31 stamp in
//     the macro is real: any pen-8 pixel still blocks whichever sprite is
//     *processed after* this one (lower RAM slot number, per correction
//     (1) above) from drawing there in either pass, even over bare
//     background -- that stamp-without-draw is what "obscuring following
//     sprites" (mcr68.cpp:345) actually means.
//
//     Independently corroborated by checking 3 sibling MCR-family drivers
//     that use the byte-identical 0x00/0x0101 then 0x02/0xfeff pmask/
//     trans_mask pair with the same "obscuring following sprites" comment
//     (mcr3_v.cpp and related MCR drivers) -- none of them ever
//     rely on pass 2 producing a visible pixel either.
//
//     A PRIOR revision of this file's S_PASS2 implementation had this
//     backwards -- it drew a visible pen-8 pixel whenever the entry
//     was already 1, exactly the opposite of the math above. Fixed: the
//     conditional draw was removed entirely; only the unconditional
//     claim stamp remains, encoded as {claimed=1, pen=8, color=0} when the
//     pixel was previously unclaimed.
//
// This correction was required by this task's explicit instruction to
// verify "every detail against source, not just the plan's paraphrase" --
// the plan document (C:\Users\meath\.claude\plans\you-a-makeing-a-fizzy-rabin.md)
// itself states the wrong pass-2 condition and should be treated as
// superseded by this derivation, not as authoritative, for this specific
// point. Any Xenophobe scene with 2+ overlapping sprites in the same
// priority group where the later-drawn (higher-slot) sprite has pen-8
// pixels over the earlier one's real pixels is a discriminating regression
// test for this fix.
// -----------------------------------------------------------------------
//
// -----------------------------------------------------------------------
// Scanline-vs-frame evaluation strategy: PER-SCANLINE, chosen over a
// frame-ahead ("scan sprite RAM once per frame into scanline-tagged
// buffers") design for three reasons:
//   1. This is genuinely how the real hardware must work -- MCR-68k has no
//      frame buffer (per the plan's own framing, "line-based raster
//      architecture"), so a real board's sprite hardware necessarily
//      re-walks sprite RAM once per scanline into a line buffer ahead of
//      the CRT beam. A frame-ahead RTL design would need PER-SCANLINE
//      tagged storage for up to 512 sprites x 480 lines' worth of
//      pen/color/valid state, which is both an enormous resource cost and
//      not how the silicon being modelled actually operates.
//   2. The two-pass priority-buffer masking is inherently local to "the
//      pixels touched so far, within this one priority group's pass over
//      the whole 511->0 sprite list" -- MAME re-derives it per frame from
//      an all-zero (well, all-1) priority bitmap each time. Re-deriving it
//      per SCANLINE (a 512-wide, not 512x480, scratch buffer) is the
//      natural, minimal-state RTL mirror of that -- no frame-sized scratch
//      needed at all, since only one scanline's worth of claim state ever
//      matters at a time.
//   3. It keeps this module's state bounded (8 flat 256x15-bit parity/group
//      memories per ping-pong bank, with duplicated M10K read views)
//      arrays, see "Storage" below) regardless of
//      how many sprites are actually active, instead of scaling with
//      frame area.
//
// Double-buffered line buffers (ping-pong sets A/B) let this module build
// the NEXT scanline's two resolved groups while the CURRENT scanline's
// buffers are being read out pixel-by-pixel for display -- exactly the
// classic raster-hardware "one line of look-ahead" sprite line buffer.
// See "Timing risk" below for the real-time budget this implies.
// -----------------------------------------------------------------------
//
// -----------------------------------------------------------------------
// gfx2 ROM interface -- ASSUMED (rtl/video/mcr68_gfx_rom_sim.sv is being
// written in parallel by a different agent and did not exist at the time
// this file was written; reconcile at integration if its actual interface
// differs).
//
// Derivation of the abstraction from mcr68_sprite_layout (mcr68.cpp:165-177)
// and the four gfx2 ROMs (xeno_fg.7j/8j/9j/10j, 0x10000 bytes each,
// concatenated as one 0x40000-byte region): `total=RGN_FRAC(1,4)` with
// charincrement=32*32=1024 bits (128 bytes) resolves to exactly 512
// elements (0x40000*8/4 / 1024 = 512) -- matching the RAM-side "code mod
// 512" -- and each of the 512 elements occupies exactly 128 bytes = one
// 0x10000-byte ROM's-worth / 512 within EACH of the 4 ROMs independently
// (128*512 = 0x10000). Per element, per ROM, that is 128 bytes / 32 rows =
// 4 bytes/row/ROM. Working out `planeoffset={0,1,2,3}` (a nibble: all 4
// bitplanes of ONE pixel are 4 consecutive bits, i.e. share a byte) against
// `xoffset`'s `STEP2(RGN_FRAC(k,4)+8g,4)` groups (k=quarter/ROM 0-3,
// g=byte-within-row 0-3) shows that for a fixed screen column c within a
// row, ALL 4 bitplanes (the full 4bpp pen) live in ONE byte of ONE ROM
// (quarter k = (c%8)/2), not spread one-bitplane-per-ROM as the plan's
// prose suggests. Concretely: reading all 4 ROMs at the SAME byte address
// (row_base + g) in parallel -- a genuine 32-bit word, matching the plan's
// "4 ROMs fetched in parallel as a 32-bit word" -- yields the complete
// 4bpp pens for 8 consecutive columns (8g..8g+7):
//   column 8g+0 = ROM0 byte[3:0]   column 8g+4 = ROM2 byte[3:0]
//   column 8g+1 = ROM0 byte[7:4]   column 8g+5 = ROM2 byte[7:4]
//   column 8g+2 = ROM1 byte[3:0]   column 8g+6 = ROM3 byte[3:0]
//   column 8g+3 = ROM1 byte[7:4]   column 8g+7 = ROM3 byte[7:4]
// (ROM0..3 = xeno_fg.7j,8j,9j,10j in load order.)
//
// Rather than exposing that low-level 4x-byte-per-group interface directly
// (which would force THIS module to duplicate the ROM's physical
// interleave, doubling the risk of a transcription error across two
// independently-written files), this module assumes mcr68_gfx_rom_sim.sv
// exposes the already-decoded ABSTRACT per-row interface below, with the
// ROM's own interleave handled once, internally, by that module:
//
//   output logic [8:0]   gfx2_code   -- sprite code, 0..511 (already mod-512)
//   output logic [4:0]   gfx2_row    -- row within sprite, 0..31 (natural/
//                                       unflipped ROM row index; THIS module
//                                       selects 31-row itself for flipy, see
//                                       below, so the ROM side never needs
//                                       to know about flip)
//   output logic         gfx2_req    -- 1 while a request is pending
//   input  logic         gfx2_ack    -- 1 the cycle gfx2_pens is valid for
//                                       the current req (may be combinational
//                                       same-cycle, matching this project's
//                                       existing async sim-RAM style, or
//                                       delayed by any number of cycles for
//                                       a future real burst-ROM/SDRAM path
//                                       -- this module's req/ack handshake
//                                       tolerates either)
//   input  logic [127:0] gfx2_pens   -- 32 pixels x 4 bits, natural
//                                       (unflipped) column order: pen for
//                                       column c (0=leftmost) at bits
//                                       [4*c +: 4]
//
// If mcr68_gfx_rom_sim.sv instead exposes the raw 4x32-bit-word-per-group
// interface, or a different req/ack timing contract, this needs revision --
// flag at integration, do not silently adapt one side to the other without
// re-verifying the interleave math above.
// -----------------------------------------------------------------------
//
// -----------------------------------------------------------------------
// Per-sprite RAM decode (mcr68.cpp:313-336), 4 bytes/slot, byte-wide chip
// (D0-D7 only) modelled by rtl/mcr68_mem_sim.sv as 512 packed four-byte
// descriptors (word index = CPU byte-address-range word offset):
//   slot n (0..511) occupies word offsets n*4 + {0,1,2,3} = {Y, flags, code_lo, X}
//   flags    = ram[slot*4+1]
//   code     = ram[slot*4+2] + 256*flags[3] + 512*flags[7:6], mod GFX2_ELEMENTS
//              (the 512*flags[7:6] term contributes raw code bits [10:9]; it
//              is a no-op under mod 512 for Xenophobe's 512-element gfx2 but
//              bit [9] is LOAD-BEARING for every 0x80000-byte gfx2 title --
//              see "Per-title gfx sizing" below. The formula is kept
//              unsimplified exactly as the original author intended.)
//   code==0  => slot entirely inactive, skip (no claim/stamp side effects).
//              NOTE: MAME tests the FULL pre-modulo code (mcr68.cpp:319-321,
//              `if (code == 0) continue;` sits above the implicit
//              `code %= elements()` inside prio_transmask, drawgfx.cpp:1026),
//              so the zero test uses the full 11-bit value, NOT the masked
//              one.
//   priority = flags[2]        (0=low group, 1=high group)
//   color    = ~flags[1:0]     (ACTIVE LOW; output already inverted here)
//   flipx    = flags[4], flipy = flags[5]
//   x        = ram[slot*4+3]*2 + SPRITE_XOFFSET; if (x>0x1F0) x -= 0x200
//              (SPRITE_XOFFSET = -4 for Xenophobe, mcr68.cpp:1856 -- see the
//              per-title table below)
//   y        = (241 - ram[slot*4+0]) * 2
// Both axes are full 512x480 SCREEN-PIXEL coordinates already (sprites are
// NOT pixel-doubled the way gfx1/tilemap tiles are -- GFXDECODE_ENTRY for
// gfx2 has no GFXDECODE_SCALE, mcr68.cpp:1181 -- the *2 in the x/y formulas
// above is purely coordinate-placement granularity, not a size multiplier).
// This is why this module's line buffers are 512 entries wide, matching
// SCREEN_WIDTH and rtl/video/mcr68_video_timing.sv's confirmed H_ACTIVE=512
// -- NOT the plan's literal "4x256-entry RAMs" (implementation_plan.md line
// 296). 256-wide buffers would silently truncate/misplace every sprite
// whose resolved X falls in the right half of the screen; deviated from
// the plan's stated size deliberately, per direct MAME-source arithmetic
// (mcr68.cpp:332-336) and the already-integrated mcr68_video_timing.sv
// (H_ACTIVE=512, pixel_x is 9 bits), which together leave no ambiguity that
// the sprite compositing space is genuinely 512 pixels wide. The plan's "4
// logical line buffers are represented by eight flat 256-entry parity/group
// memories per ping-pong bank. Each entry holds one 7-bit low/high pixel slice
// plus an 8-bit rebuild serial; duplicated read views preserve the front
// display read and back claim-test read -- see "Storage".
// -----------------------------------------------------------------------
//
// -----------------------------------------------------------------------
// PER-TITLE SIZING / CLIP / OFFSET (added 2026-08-13; every value below was
// read out of MAME 0.289 `src/mame/bally/mcr68.cpp` directly, not inferred
// from doc/mcr68_multigame_staging.md's summary):
//
//   set        gfx2 ROM_REGION   elements   code bits   clip   xoffset   slots
//   xenophob   0x40000 (:1353)   512        [8:0]       0      -4        512
//   blasted    0x80000 (:1471)   1024       [9:0]       0       0        512
//   (removed profile)            --         --          --      --         --
//   archrivl   0x80000 (:1551)   1024       [9:0]      16       0        512
//   pigskin    0x80000 (:1598)   1024       [9:0]      16       0        256
//
//   * elements = RGN_FRAC(1,4) quarter / charincrement. mcr68_sprite_layout
//     (mcr68.cpp:1165-1177) is 32x32x4bpp with charincrement 32*32 bits =
//     128 bytes per quarter, so elements = region_bytes / 4 / 128 =
//     region_bytes / 512. Hence GFX2_ELEMENTS/GFX2_CODE_W below.
//   * clip / xoffset are `mcr68_common_init(clip, xoffset)`'s two arguments
//     (mcr68.cpp:1845-1850), called from each init_<set>() at :1854-1946.
//     `clip` narrows the sprite draw rectangle symmetrically:
//     mcr68_update_sprites() (mcr68.cpp:305-310) takes the screen's visible
//     area -- set_visarea(0, 32*16-1, 0, 30*16-1) = 0..511 x 0..479
//     (mcr68.cpp:1235) -- then `min_x += clip; max_x -= clip`. So a sprite
//     pixel is drawn only for clip <= x <= 511-clip. With clip=0 that is
//     exactly the pre-existing `0 <= x < 512` test, bit-for-bit.
//   * slots: the sprite loop is `for (offs = m_spriteram.bytes()/2 - 4;
//     offs >= 0; offs -= 4)`. mcr68_map gives spriteram 0x1000 bytes
//     (mcr68.cpp:606) -> 512 slots; pigskin_map gives it only 0x800 bytes
//     (0x160000-0x1607ff, mcr68.cpp:637) -> **256 slots**. Pigskin is the
//     only set that differs.
//   * The tile/sprite COLOUR path itself is identical for every set: one
//     GFXDECODE table (gfx_mcr68, mcr68.cpp:1179-1182, 4 colors each) and one
//     PALETTE(xRBG_333, 64) for all of them (mcr68.cpp:1241-1242, inside the
//     shared mcr68_state::mcr68() config -- no per-title override anywhere in
//     the file). color = ~flags & 3 is unconditional. So there is NO per-title
//     colour difference to encode; the real per-title differences are the
//     three above plus the gfx1 category rule documented in
//     rtl/video/mcr68_tilemap.sv.
// -----------------------------------------------------------------------
//
// -----------------------------------------------------------------------
// Storage: per CLAUDE.md's "Diagnosing a design that does not fit" --
// never declare an inferrable memory as a multidimensional unpacked array
// (`mem[0:A][0:B]`), Quartus 17 silently drops the whole thing into logic
// with NO diagnostic. Each physical line memory below is flat and stores one
// pixel-parity group per word. The low seven bits are {claimed, pen, color};
// bits [14:7] are the bank-generation tag. A bank tag invalidates untouched entries
// at build start, replacing the old 512-cycle clear without a wide token or a
// LUT-based read mux. Pen 8 with claimed=1 is the invisible stencil;
// display/claim validity therefore also requires the stored generation to
// match the generation of the current build or displayed bank.
// -----------------------------------------------------------------------
//
// -----------------------------------------------------------------------
// Timing contract after the active-list correction:
//   A steady-state build evaluates one packed descriptor per slot; it does
//   not clear the whole 512-entry line bank. An 8-bit bank generation tag
//   invalidates every untouched entry in O(1) cycles, so the empty-list floor
//   remains 513 clocks for 512 slots and 257 for 256 slots.
//   Active rows fetch one row and resolve two adjacent pixels per clock. The
//   focused stress fixture remains inside the approximately 3205-clock line
//   budget with immediate gfx2 responses. `build_overrun` remains sticky so a
//   real capture can distinguish a deadline miss from a decode or compositor
//   problem. Line tag/epoch publication prevents a late or incomplete line
//   from displaying.
// -----------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

// A sprite line bank needs one front (display) read, one back (claim-test)
// read, and one write port.  Cyclone V M10K dual-port RAM cannot expose two
// independent read addresses on one primitive, so two identical M10K copies
// per bank each carry one read view and both receive every write.
//
// READ LATENCY IS ONE CLOCK -- 2026-08-27 hardware root-cause. The original
// revision requested `address_reg_a = "UNREGISTERED"` with unregistered
// outdata, i.e. a zero-latency asynchronous read. A Cyclone V M10K
// physically registers the port-A address on clock0; Quartus 17 silently
// DROPPED the illegal parameter (proof: the generated db/altsyncram_lrl2.tdf
// carries no ADDRESS_REG_A at all, and cyclonev_ram_block always registers
// portaaddr), so hardware read latency was 1 clock while this module's
// simulation model and consumers assumed 0.  The claim-test read address
// advances every clock in S_PASS1, so on hardware every claim test saw the
// PREVIOUS pair's just-written entry (claim=1, current generation) and
// falsely suppressed its own write -- dropping alternating pixel pairs and
// producing see-through holes in every sprite, in every title, on hardware
// only.  The contract is now: q reflects the address registered at the
// previous rising edge (1-clock latency), identically in synthesis and
// simulation, and the consumer pipelines its addresses accordingly.
/* verilator lint_off DECLFILENAME */
module mcr68_sprite_line_ram #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 15,
    parameter int NUM_WORDS  = (1 << ADDR_WIDTH)
) (
    input  logic                  clk,
    input  logic [ADDR_WIDTH-1:0] front_addr,
    output logic [DATA_WIDTH-1:0] front_data,
    input  logic [ADDR_WIDTH-1:0] back_addr,
    output logic [DATA_WIDTH-1:0] back_data,
    input  logic [ADDR_WIDTH-1:0] write_addr,
    input  logic [DATA_WIDTH-1:0] write_data,
    input  logic                  write_enable
);
`ifdef SYNTHESIS
    altsyncram front_mem (
        .clock0(clk), .address_a(front_addr), .data_a({DATA_WIDTH{1'b0}}),
        .wren_a(1'b0), .q_a(front_data),
        .clock1(clk), .address_b(write_addr), .data_b(write_data),
        .wren_b(write_enable), .q_b(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
    );
    // Port A address is ALWAYS registered on clock0 by the M10K primitive
    // (no address_reg_a parameter exists to change that); read latency 1.
    defparam
        front_mem.address_reg_b = "CLOCK1",
        front_mem.clock_enable_input_a = "BYPASS",
        front_mem.clock_enable_input_b = "BYPASS",
        front_mem.clock_enable_output_a = "BYPASS",
        front_mem.clock_enable_output_b = "BYPASS",
        front_mem.indata_reg_b = "CLOCK1",
        front_mem.intended_device_family = "Cyclone V",
        front_mem.lpm_type = "altsyncram",
        front_mem.numwords_a = NUM_WORDS,
        front_mem.numwords_b = NUM_WORDS,
        front_mem.operation_mode = "BIDIR_DUAL_PORT",
        front_mem.outdata_aclr_a = "NONE",
        front_mem.outdata_aclr_b = "NONE",
        front_mem.outdata_reg_a = "UNREGISTERED",
        front_mem.outdata_reg_b = "UNREGISTERED",
        front_mem.power_up_uninitialized = "FALSE",
        front_mem.ram_block_type = "M10K",
        front_mem.read_during_write_mode_mixed_ports = "DONT_CARE",
        front_mem.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        front_mem.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        front_mem.widthad_a = ADDR_WIDTH,
        front_mem.widthad_b = ADDR_WIDTH,
        front_mem.width_a = DATA_WIDTH,
        front_mem.width_b = DATA_WIDTH,
        front_mem.width_byteena_a = 1,
        front_mem.width_byteena_b = 1;

    altsyncram back_mem (
        .clock0(clk), .address_a(back_addr), .data_a({DATA_WIDTH{1'b0}}),
        .wren_a(1'b0), .q_a(back_data),
        .clock1(clk), .address_b(write_addr), .data_b(write_data),
        .wren_b(write_enable), .q_b(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
    );
    // Port A address is ALWAYS registered on clock0 by the M10K primitive;
    // read latency 1 (see module header).
    defparam
        back_mem.address_reg_b = "CLOCK1",
        back_mem.clock_enable_input_a = "BYPASS",
        back_mem.clock_enable_input_b = "BYPASS",
        back_mem.clock_enable_output_a = "BYPASS",
        back_mem.clock_enable_output_b = "BYPASS",
        back_mem.indata_reg_b = "CLOCK1",
        back_mem.intended_device_family = "Cyclone V",
        back_mem.lpm_type = "altsyncram",
        back_mem.numwords_a = NUM_WORDS,
        back_mem.numwords_b = NUM_WORDS,
        back_mem.operation_mode = "BIDIR_DUAL_PORT",
        back_mem.outdata_aclr_a = "NONE",
        back_mem.outdata_aclr_b = "NONE",
        back_mem.outdata_reg_a = "UNREGISTERED",
        back_mem.outdata_reg_b = "UNREGISTERED",
        back_mem.power_up_uninitialized = "FALSE",
        back_mem.ram_block_type = "M10K",
        back_mem.read_during_write_mode_mixed_ports = "DONT_CARE",
        back_mem.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        back_mem.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        back_mem.widthad_a = ADDR_WIDTH,
        back_mem.widthad_b = ADDR_WIDTH,
        back_mem.width_a = DATA_WIDTH,
        back_mem.width_b = DATA_WIDTH,
        back_mem.width_byteena_a = 1,
        back_mem.width_byteena_b = 1;
`else
    logic [DATA_WIDTH-1:0] front_mem [0:NUM_WORDS-1];
    logic [DATA_WIDTH-1:0] back_mem [0:NUM_WORDS-1];
    // Model the M10K's mandatory port-A address register (1-clock read
    // latency) so simulation matches hardware -- see module header for the
    // hole-in-every-sprite defect the old zero-latency model masked.
    logic [ADDR_WIDTH-1:0] front_addr_r, back_addr_r;
    integer init_i;
    assign front_data = front_mem[front_addr_r];
    assign back_data  = back_mem[back_addr_r];
    initial for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1)
    begin
        front_mem[init_i] = '0;
        back_mem[init_i] = '0;
    end
    always_ff @(posedge clk) begin
        front_addr_r <= front_addr;
        back_addr_r  <= back_addr;
        if (write_enable) begin
            front_mem[write_addr] <= write_data;
            back_mem[write_addr] <= write_data;
        end
    end
`endif
endmodule
/* verilator lint_on DECLFILENAME */

module mcr68_sprites #(
    parameter int         SCREEN_WIDTH   = 512,           // mcr68_video_timing.sv H_ACTIVE
    parameter int         V_ACTIVE       = 480,           // first blanking line; safe line-RAM scrub point
    parameter int         V_TOTAL        = 520,            // mcr68_video_timing.sv V_TOTAL (need the FULL raw v_count range, incl. blanking lines, to wrap correctly -- see target_line)
    // ---- per-title sizing; see "PER-TITLE SIZING / CLIP / OFFSET" header ----
    // Only the gfx2 REGION SIZE is still an elaboration parameter, because it
    // sets the width of the gfx2_code port (an array dimension). The three
    // *behavioural* per-title values (clip / xoffset / slots) are RUNTIME
    // INPUTS -- see the "RUNTIME sprite geometry" note below.
    parameter int         GFX2_BYTES     = 'h40000,        // gfx2 ROM_REGION size in bytes
    // Derived -- do NOT override. elements = GFX2_BYTES/512 (mcr68_sprite_layout
    // RGN_FRAC(1,4), 128 bytes/element/quarter). 512 -> 9 bits, 1024 -> 10.
    parameter int         GFX2_ELEMENTS  = GFX2_BYTES / 512,
    parameter int         GFX2_CODE_W    = $clog2(GFX2_ELEMENTS)
) (
    input  logic        clk,
    input  logic        rst,             // synchronous, active-high

    // ---- RUNTIME sprite geometry (was three elaboration parameters) -------------
    // These were `parameter SPRITE_CLIP / SPRITE_XOFFSET / SPRITE_SLOTS`,
    // derived in mcr68_main_board.sv from GAME_STATIC. That is wrong for a
    // union ("one build, every title") elaboration: both sim harnesses
    // elaborate GAME_STATIC(GAME_PIGSKIN) purely to size the gfx arrays, so
    // EVERY title inherited pigskin's clip=16 / xoffset=0 / slots=256.
    // This is the same class of bug as mcr68_tilemap's gfx1_small and the PTM
    // byte lane (see doc/multigame_attract_status.md, "the governing lesson"):
    // anything MAME derives from the ACTIVE title's init_/region size is
    // RUNTIME BEHAVIOUR, not build geometry. Array DIMENSIONS stay
    // elaboration-time; BEHAVIOUR moved here.
    //
    // Drive from mcr68_game_pkg's runtime profile struct (mcr68_main_board.sv
    // does this from `prof_rt`). Profile contract rule 2 applies: these are
    // static configuration, held stable while the game is out of reset -- they
    // are sampled combinationally every cycle and are NOT expected to change
    // mid-scanline-build.
    //
    //   set        clip   xoffset   slots      (mcr68.cpp)
    //   xenophob     0      -4       512       init_xenophob  :1856
    //   blasted      0       0       512       init_blasted   :1882
    //   archrivl    16       0       512       init_archrivl  :1909
    //   pigskin     16       0       256       init_pigskin   :1944 (2 KiB spriteram :637)
    input  logic [5:0]        sprite_clip,      // mcr68_common_init() arg 1: 0 or 16
    input  logic signed [3:0] sprite_xoffset,   // mcr68_common_init() arg 2: 0 / -4
    input  logic [10:0]       sprite_slots,     // m_spriteram.bytes()/8: 512 or 256

    // ---- scanline build trigger -------------------------------------------------
    // Wire line_start directly to mcr68_video_timing.sv's hsync_pulse, and
    // target_line directly to its v_count (the FULL 10-bit raw counter, NOT
    // the 9-bit pixel_y -- pixel_y truncates the blanking-region line
    // numbers this module needs to see in order to wrap correctly at
    // V_TOTAL). On each line_start pulse (assumed once per scanline,
    // including blanking lines -- harmless, no sprite ever matches a
    // blanking-region row), this module:
    //   1. reveals the just-completed build as the new "front" (display)
    //      buffer set -- this is what the sp_lo_*/sp_hi_* outputs read from
    //      the NEXT cycle onward, and is assumed (by the caller's own
    //      line_start timing) to correspond to whatever scanline is about
    //      to start display, i.e. target_line itself;
    //   2. starts building target_line+1 (mod V_TOTAL) into the newly-freed
    //      "back" set, to be ready by the NEXT line_start.
    // If a build has not finished by the next line_start, that pulse is
    // effectively dropped (no swap, no new build kicked off, sticky
    // `build_overrun` set) and the in-progress build is left to finish;
    // the display briefly repeats a stale line rather than reading
    // half-written data. This self-heals on the next line_start once the
    // FSM returns to idle -- see "Timing risk" above.
    input  logic         line_start,
    input  logic [9:0]   target_line,
    output logic         line_busy,        // combinational: state != S_IDLE
    output logic         build_overrun,    // sticky; cleared only by rst

    // ---- current display position -----------------------------------------------
    input  logic [8:0]   pixel_x,          // mcr68_video_timing.sv pixel_x
    input  logic [9:0]   display_line,     // full raw raster line, including blanking

    // ---- packed sprite descriptor read port --------------------------------------
    // One asynchronous/registered descriptor read replaces four serialized byte
    // reads in the deadline-driven scanner. The memory module preserves the
    // original CPU byte-write contract and assembles the same physical bytes:
    // [31:24]=X, [23:16]=code_lo, [15:8]=flags, [7:0]=Y.
    output logic [8:0]   spriteram_desc_addr,
    input  logic [31:0]  spriteram_desc_data,

    // ---- gfx2 ROM interface -- ASSUMED, see header ---------------------------------
    // The union build keeps a 10-bit code port for the 512 KiB profiles.  A
    // Xenophobe run has only 512 physical elements, so this runtime bit owns
    // the real modulo-512 behavior at the producer boundary.
    input  logic        gfx2_small,
    output logic [GFX2_CODE_W-1:0] gfx2_code,
    output logic [4:0]   gfx2_row,
    output logic         gfx2_req,
    input  logic         gfx2_ack,
    input  logic [127:0] gfx2_pens,

    // ---- resolved sprite pixel for the CURRENT pixel_x, current display line ------
    // Port names match rtl/video/mcr68_colormix.sv's expected inputs
    // directly (see that file's "Sprite engine interface" comment) -- wire
    // straight across, no renaming needed at integration.
    output logic         sp_lo_valid,
    output logic [3:0]   sp_lo_pen,
    output logic [1:0]   sp_lo_color,

    output logic         sp_hi_valid,
    output logic [3:0]   sp_hi_pen,
    output logic [1:0]   sp_hi_color
);

    // =========================================================================
    // Storage -- 8 flat 256-entry physical parity/group memories (ping-pong
    // A/B), each carrying one 7-bit logical group plus an 8-bit rebuild serial.
    // The serial invalidates untouched entries before each build, preserving
    // the claimed pen-8 stencil without a 512-cycle clear. The line-level
    // valid/tag/epoch metadata below gates publication.
    // =========================================================================
    // Explicit dual-port M10K banks preserve the two combinational reads
    // needed by the display and priority claim test while keeping the two
    // adjacent PASS1 writes on independent even/odd banks.
    logic [7:0] line_a_lo_even_waddr, line_a_lo_odd_waddr;
    logic [7:0] line_a_hi_even_waddr, line_a_hi_odd_waddr;
    logic [7:0] line_b_lo_even_waddr, line_b_lo_odd_waddr;
    logic [7:0] line_b_hi_even_waddr, line_b_hi_odd_waddr;
    logic [14:0] line_a_lo_even_wdata, line_a_lo_odd_wdata;
    logic [14:0] line_a_hi_even_wdata, line_a_hi_odd_wdata;
    logic [14:0] line_b_lo_even_wdata, line_b_lo_odd_wdata;
    logic [14:0] line_b_hi_even_wdata, line_b_hi_odd_wdata;
    logic       line_a_lo_even_we, line_a_lo_odd_we;
    logic       line_a_hi_even_we, line_a_hi_odd_we;
    logic       line_b_lo_even_we, line_b_lo_odd_we;
    logic       line_b_hi_even_we, line_b_hi_odd_we;
    wire [14:0] line_a_lo_even_front, line_a_lo_even_back;
    wire [14:0] line_a_lo_odd_front,  line_a_lo_odd_back;
    wire [14:0] line_a_hi_even_front, line_a_hi_even_back;
    wire [14:0] line_a_hi_odd_front,  line_a_hi_odd_back;
    wire [14:0] line_b_lo_even_front, line_b_lo_even_back;
    wire [14:0] line_b_lo_odd_front,  line_b_lo_odd_back;
    wire [14:0] line_b_hi_even_front, line_b_hi_even_back;
    wire [14:0] line_b_hi_odd_front,  line_b_hi_odd_back;

    logic       front_sel;           // 0 = A is front (display), 1 = B is front
    wire        back_is_b = ~front_sel;
    logic [7:0] bank_gen_a, bank_gen_b;
    logic       line_valid_a, line_valid_b;
    logic [9:0] line_tag_a, line_tag_b;
    logic       line_epoch_a, line_epoch_b;
    

    // The epoch is deliberately separate from the line tag. A late line 0
    // from the prior frame must never become valid merely because its 10-bit
    // line number matches the current raster. `display_epoch` remains stable
    // for the line currently being scanned; `epoch_pending` advances it at
    // the following line-0 boundary.
    logic       display_epoch;
    logic       epoch_pending;
    logic [9:0] build_tag_r;
    logic       build_epoch_r;

    wire        front_valid = front_sel ? line_valid_b : line_valid_a;
    wire [9:0]  front_tag   = front_sel ? line_tag_b   : line_tag_a;
    wire        front_epoch = front_sel ? line_epoch_b : line_epoch_a;
    wire        front_matches_line = front_valid &&
                                     (front_tag == display_line) &&
                                     (front_epoch == display_epoch);
    wire        current_line_epoch_w = epoch_pending ? ~display_epoch : display_epoch;
    wire [9:0]  next_line_tag_w = (target_line == 10'(V_TOTAL - 1)) ? 10'd0
                                                                    : (target_line + 10'd1);
    wire        next_line_epoch_w = (target_line == 10'(V_TOTAL - 1)) ?
                                    ~current_line_epoch_w : current_line_epoch_w;
    wire        back_ready_for_line = back_is_b ?
        (line_valid_b && line_tag_b == target_line && line_epoch_b == current_line_epoch_w) :
        (line_valid_a && line_tag_a == target_line && line_epoch_a == current_line_epoch_w);
    // If the just-completed line is promoted, the old front becomes the new
    // build target. Otherwise the existing back remains the build target.
    wire        build_back_is_b_w = back_ready_for_line ? front_sel : back_is_b;

    // Front-side (display) read mux. The line RAM has a 1-clock registered-
    // address read (M10K), so front data settles one clk after pixel_x
    // changes. pixel_x only advances once per ce_dot (5 clk/pixel on the 50
    // MHz board, ~10 in the sim model) and the downstream capture samples at
    // the END of a pixel's dwell, so the settled value is what is consumed;
    // the 1-clk transient after each pixel_x step is never sampled.
    wire [7:0]  front_mem_idx = pixel_x[8:1];
    wire [14:0] line_a_lo_front = pixel_x[0] ? line_a_lo_odd_front : line_a_lo_even_front;
    wire [14:0] line_a_hi_front = pixel_x[0] ? line_a_hi_odd_front : line_a_hi_even_front;
    wire [14:0] line_b_lo_front = pixel_x[0] ? line_b_lo_odd_front : line_b_lo_even_front;
    wire [14:0] line_b_hi_front = pixel_x[0] ? line_b_hi_odd_front : line_b_hi_even_front;
    wire [29:0] line_front = front_sel ? {line_b_hi_front, line_b_lo_front} :
                                              {line_a_hi_front, line_a_lo_front};
    wire [14:0] lo_front = line_front[14:0];
    wire [14:0] hi_front = line_front[29:15];
    wire [7:0] front_gen = front_sel ? bank_gen_b : bank_gen_a;
    assign sp_lo_valid = front_matches_line && lo_front[14:7] == front_gen &&
                         lo_front[6] && lo_front[5:2] != 4'd8;
    assign sp_lo_pen   = lo_front[5:2];
    assign sp_lo_color = lo_front[1:0];
    assign sp_hi_valid = front_matches_line && hi_front[14:7] == front_gen &&
                         hi_front[6] && hi_front[5:2] != 4'd8;
    assign sp_hi_pen   = hi_front[5:2];
    assign sp_hi_color = hi_front[1:0];

`ifndef SYNTHESIS
    // Focused regression guard for the embedded-claim encoding: pen 8 may
    // reserve a pixel against following sprites, but must never reach the
    // compositor as a visible sprite pixel in either priority group.
    always_ff @(posedge clk) begin
        if (!rst) begin
            assert (!(sp_lo_valid && sp_lo_pen == 4'd8));
            assert (!(sp_hi_valid && sp_hi_pen == 4'd8));
        end
    end
`endif

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_CLEAR,          // vblank scrub prevents finite generation-tag alias
        S_XFER,           // vblank staging->packet descriptor snapshot (XFER)
        S_EVAL,           // evaluate the current packed descriptor
        S_GFX_REQ,        // hold gfx2_req until gfx2_ack
        S_PASS1,          // two-pixel/clock claim sweep
        S_DONE             // publish the completed tagged back line
    } state_t;

    state_t      state;
    logic [7:0]  clear_addr;
    logic [8:0]  slot;               // 511..0
    logic [9:0]  build_line_r;       // scanline currently being built (0..V_TOTAL-1)

    // ---------------------------------------------------------------------
    // Frame-snapshot "packet RAM" (2026-08-28 hardware root cause).
    // The real board's CPU never feeds the sprite datapath directly: the CPU
    // writes a staging 6116 (4J) and a once-per-frame XFER (PKA counter
    // 3xLS163, terminal EOPAC) copies it into the packet RAM 2018 (5G) that
    // the line engine actually reads (Arch Rivals schematic 16-4001-K-101,
    // sheet FG). MAME gets the same semantics for free by drawing the whole
    // frame from one snapshot. This module previously read the CPU staging
    // RAM live during every per-line build; Arch Rivals rewrites descriptors
    // continuously across visible scanlines (write-tap measurement
    // 2026-08-28: bursts at raster lines ~23-54 plus sustained writes over
    // lines ~73-209), so every line built during those writes saw a torn or
    // cleared descriptor list -- whole sprites (animated crowd, cheerleader,
    // coach torsos) vanished inside a horizontal band that drifted with the
    // CPU's write phase. The snapshot below is copied from the staging read
    // port once per frame during the same vblank window as the line-RAM
    // scrub (S_CLEAR -> S_XFER, line V_ACTIVE), and every build evaluates
    // descriptors exclusively from it -- mid-frame CPU writes can no longer
    // tear the displayed frame.
    //
    // Storage: one 512x32 MLAB array, written as a whole 32-bit word by a
    // single always_ff assignment (the multi-slice write pattern that
    // defeats inference -- see mcr68_mem_hw.sv's sprite_desc note -- never
    // occurs here) and read asynchronously, exactly like the staging
    // descriptor RAM it mirrors.
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] snap_desc [0:511];
    logic        snap_ready;         // at least one XFER completed since rst
    wire  [31:0] snap_desc_data = snap_desc[spriteram_desc_addr];
`ifndef SYNTHESIS
    initial begin
        for (int snap_i = 0; snap_i < 512; snap_i++) snap_desc[snap_i] = '0;
    end
`endif

    logic [4:0]  oc;                 // first of two pixels, 0,2,..30
    logic [127:0] pens_r;
`ifdef VERILATOR
    logic [9:0]  active_count;

    // Read-only line-builder evidence. The trace is enabled only by an
    // explicit plusarg so ordinary simulations and synthesis have no output
    // or state impact. The line range is the target build-line range, not the
    // line currently being displayed.
    logic       sprite_trace_enabled;
    logic [9:0] sprite_trace_first;
    logic [9:0] sprite_trace_last;
    /* verilator lint_off MULTIDRIVEN */
    time    sprite_trace_start_time;
    /* verilator lint_on MULTIDRIVEN */
    initial begin
        sprite_trace_enabled = $test$plusargs("SPRITE_TRACE");
        sprite_trace_first = 0;
        sprite_trace_last = 1023;
        sprite_trace_start_time = 0;
        void'($value$plusargs("SPRITE_TRACE_FIRST=%d", sprite_trace_first));
        void'($value$plusargs("SPRITE_TRACE_LAST=%d", sprite_trace_last));
    end
`endif

    // Highest sprite-RAM slot index walked by the 511->0 (or 255->0) loop.
    // 512 slots for every mcr68_map set, 256 for pigskin_map -- see header.
    // RUNTIME now: 9'(512-1)=511 and 9'(256-1)=255, i.e. exactly the two
    // values the old localparam produced. The loop still terminates on
    // `slot == 0` termination condition, which is independent of the top
    // value, and the
    // one packed descriptor is read per slot; the scan is performed once and
    // its priority bit selects the destination slice directly. The current
    // descriptor is evaluated directly from the packed async read port, so
    // an inactive slot consumes one cycle rather than a capture/evaluate/
    // next-slot sequence.
    wire [8:0] slot_top_w = 9'(sprite_slots - 11'd1);

    // --- combinational decode of the current packed slot fields ---
    // MAME: code = ram[offs+2] + 256*flags[3] + 512*flags[7:6]  (11 bits),
    // then `code %= elements()` inside prio_transmask (drawgfx.cpp:1026).
    // The multiplies are exact bit placements (256*flags[3] -> bit 8,
    // 512*flags[7:6] -> bits 10:9), so the full raw code is a plain
    // concatenation and the modulo is a plain truncation to GFX2_CODE_W --
    // no adder or multiplier is synthesized either way.
    //   512-element gfx2 (Xenophobe): GFX2_CODE_W=9  -> {flags[3], code_lo}
    //                                                  (bit-identical to the
    //                                                   previous hard-coded
    //                                                   mod-512 expression)
    //  1024-element gfx2 (every 0x80000 set): GFX2_CODE_W=10 -> flags[6] is
    //                                                  now load-bearing.
    // The `code == 0` skip test uses the FULL 11-bit value, matching
    // mcr68.cpp:319-321 which tests before the modulo.
    // Fields decode from the FRAME SNAPSHOT (packet RAM), not the live CPU
    // staging read port -- see the snap_desc header note above. The staging
    // port (spriteram_desc_data) is consumed only by the S_XFER copy.
    wire [7:0]  raw_y_w    = snap_desc_data[7:0];
    wire [7:0]  flags_w    = snap_desc_data[15:8];
    wire [7:0]  code_lo_w  = snap_desc_data[23:16];
    wire [7:0]  raw_x_w    = snap_desc_data[31:24];
    wire [10:0] code_raw_w = {flags_w[7:6], flags_w[3], code_lo_w};
    // Keep the full raw value for the preceding `code == 0` test, then apply
    // the active region's modulo only to the physical ROM code presented to
    // the fetcher. Assignment zero-extends the 9-bit small-title code into
    // the shared 9/10-bit port without relying on a zero-width replication.
    // Xenophobe's 256 KiB gfx2 uses nine code bits inside the union build's
    // ten-bit sprite-code bus.  Make the zero extension explicit at this
    // runtime/elaboration boundary instead of relying on implicit widening.
    wire [GFX2_CODE_W-1:0] code_small_w = GFX2_CODE_W'({1'b0, code_raw_w[8:0]});
    wire [GFX2_CODE_W-1:0] code_w = gfx2_small ? code_small_w
                                                : code_raw_w[GFX2_CODE_W-1:0];
    wire [1:0]  color_w  = ~flags_w[1:0];              // active-low
    wire        flipx_w  = flags_w[4];
    wire        flipy_w  = flags_w[5];
    wire        pri_w    = flags_w[2];

    // xoffset is a 4-bit signed runtime input; sign-extend explicitly to 12
    // bits rather than relying on the port's declared signedness surviving
    // the concatenation (same caution as mcr68_game_pkg's accessor).
    wire signed [11:0] xoff_sx     = $signed({{8{sprite_xoffset[3]}}, sprite_xoffset});
    wire signed [11:0] sx_raw      = $signed({3'b0, raw_x_w, 1'b0}) + xoff_sx;
    wire signed [11:0] sx_wrapped  = (sx_raw > 12'sd496) ? (sx_raw - 12'sd512) : sx_raw;
    wire signed [11:0] sy_w        = 12'sd482 - $signed({3'b0, raw_y_w, 1'b0});
    wire signed [11:0] local_row_w = $signed({2'b0, build_line_r}) - sy_w;
    wire        in_row_range_w = (local_row_w >= 12'sd0) && (local_row_w <= 12'sd31);
    wire [4:0]  local_row5_w   = local_row_w[4:0];
    wire [4:0]  row_index_w    = flipy_w ? (5'd31 - local_row5_w) : local_row5_w;

    // --- per-pixel (oc = 0..31) decode used during PASS1/PASS2 ---
    wire [4:0]  src_col_w  = flipx_w ? (5'd31 - oc) : oc;
    wire [4:0]  src_col2_w = flipx_w ? (5'd30 - oc) : (oc + 5'd1);
    wire [3:0]  pen4_w     = pens_r[4*src_col_w +: 4];
    wire [3:0]  pen4_2_w   = pens_r[4*src_col2_w +: 4];
    wire signed [11:0] px_calc_w   = sx_wrapped + $signed({7'b0, oc});
    wire signed [11:0] px_calc2_w  = sx_wrapped + $signed({7'b0, oc + 5'd1});
    // mcr68_update_sprites()'s sprite_clip: visible area 0..SCREEN_WIDTH-1
    // narrowed symmetrically by m_sprite_clip (mcr68.cpp:305-310). With
    // sprite_clip=0 this is exactly the previous `0 <= px < SCREEN_WIDTH`.
    // sprite_clip is unsigned 6-bit (0 or 16); both bounds stay well inside
    // 12-bit signed range (SCREEN_WIDTH-1 = 511).
    wire signed [11:0] clip_sx      = $signed({6'b0, sprite_clip});
    wire signed [11:0] clip_lo_w    = clip_sx;
    wire signed [11:0] clip_hi_w    = $signed(12'(SCREEN_WIDTH - 1)) - clip_sx;
    wire        px_in_range_w = (px_calc_w >= clip_lo_w) && (px_calc_w <= clip_hi_w);
    wire        px2_in_range_w = (px_calc2_w >= clip_lo_w) && (px_calc2_w <= clip_hi_w);
    wire [8:0]  px_w = px_calc_w[8:0];
    wire [8:0]  px2_w = px_calc2_w[8:0];
    // Claim-test read addresses are PREFETCHED one pair ahead, because the
    // line RAM read has one clock of latency (M10K registered address -- see
    // mcr68_sprite_line_ram's header). While pair `oc` is being written, the
    // addresses for pair `oc+2` are presented; outside S_PASS1 (S_EVAL /
    // S_GFX_REQ) the current sprite's pair 0 is presented, so its claim data
    // is valid on the first S_PASS1 cycle. Adjacent pixels have opposite
    // parity, so each physical bank needs only one back read address while
    // both claim tests remain available. The prefetch address always equals
    // the concurrent write address plus one per bank, so a same-edge
    // same-address mixed-port read-during-write (DONT_CARE on M10K) cannot
    // occur.
    wire [4:0]  oc_rd_w = (state == S_PASS1) ? (oc + 5'd2) : oc;
    wire signed [11:0] px_rd_calc_w  = sx_wrapped + $signed({7'b0, oc_rd_w});
    wire signed [11:0] px_rd_calc2_w = sx_wrapped + $signed({7'b0, oc_rd_w + 5'd1});
    wire [8:0]  px_rd_w  = px_rd_calc_w[8:0];
    wire [8:0]  px2_rd_w = px_rd_calc2_w[8:0];
    wire [7:0]  back_mem_idx_w  = px_rd_w[8:1];
    wire [7:0]  back_mem_idx2_w = px2_rd_w[8:1];
    wire [7:0]  back_even_addr_w = px_rd_w[0] ? back_mem_idx2_w : back_mem_idx_w;
    wire [7:0]  back_odd_addr_w  = px_rd_w[0] ? back_mem_idx_w  : back_mem_idx2_w;

    mcr68_sprite_line_ram u_line_a_lo_even (
        .clk(clk), .front_addr(front_mem_idx), .front_data(line_a_lo_even_front),
        .back_addr(back_even_addr_w), .back_data(line_a_lo_even_back),
        .write_addr(line_a_lo_even_waddr), .write_data(line_a_lo_even_wdata),
        .write_enable(line_a_lo_even_we)
    );
    mcr68_sprite_line_ram u_line_a_lo_odd (
        .clk(clk), .front_addr(front_mem_idx), .front_data(line_a_lo_odd_front),
        .back_addr(back_odd_addr_w), .back_data(line_a_lo_odd_back),
        .write_addr(line_a_lo_odd_waddr), .write_data(line_a_lo_odd_wdata),
        .write_enable(line_a_lo_odd_we)
    );
    mcr68_sprite_line_ram u_line_a_hi_even (
        .clk(clk), .front_addr(front_mem_idx), .front_data(line_a_hi_even_front),
        .back_addr(back_even_addr_w), .back_data(line_a_hi_even_back),
        .write_addr(line_a_hi_even_waddr), .write_data(line_a_hi_even_wdata),
        .write_enable(line_a_hi_even_we)
    );
    mcr68_sprite_line_ram u_line_a_hi_odd (
        .clk(clk), .front_addr(front_mem_idx), .front_data(line_a_hi_odd_front),
        .back_addr(back_odd_addr_w), .back_data(line_a_hi_odd_back),
        .write_addr(line_a_hi_odd_waddr), .write_data(line_a_hi_odd_wdata),
        .write_enable(line_a_hi_odd_we)
    );
    mcr68_sprite_line_ram u_line_b_lo_even (
        .clk(clk), .front_addr(front_mem_idx), .front_data(line_b_lo_even_front),
        .back_addr(back_even_addr_w), .back_data(line_b_lo_even_back),
        .write_addr(line_b_lo_even_waddr), .write_data(line_b_lo_even_wdata),
        .write_enable(line_b_lo_even_we)
    );
    mcr68_sprite_line_ram u_line_b_lo_odd (
        .clk(clk), .front_addr(front_mem_idx), .front_data(line_b_lo_odd_front),
        .back_addr(back_odd_addr_w), .back_data(line_b_lo_odd_back),
        .write_addr(line_b_lo_odd_waddr), .write_data(line_b_lo_odd_wdata),
        .write_enable(line_b_lo_odd_we)
    );
    mcr68_sprite_line_ram u_line_b_hi_even (
        .clk(clk), .front_addr(front_mem_idx), .front_data(line_b_hi_even_front),
        .back_addr(back_even_addr_w), .back_data(line_b_hi_even_back),
        .write_addr(line_b_hi_even_waddr), .write_data(line_b_hi_even_wdata),
        .write_enable(line_b_hi_even_we)
    );
    mcr68_sprite_line_ram u_line_b_hi_odd (
        .clk(clk), .front_addr(front_mem_idx), .front_data(line_b_hi_odd_front),
        .back_addr(back_odd_addr_w), .back_data(line_b_hi_odd_back),
        .write_addr(line_b_hi_odd_waddr), .write_data(line_b_hi_odd_wdata),
        .write_enable(line_b_hi_odd_we)
    );

    // The physical line RAM is 15 bits wide, but this read is arbitration
    // metadata only: generation [14:7] and claim [6] are the complete
    // consumer contract. Pixel payload remains on the front-data path.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [14:0] back_lo_w  = back_is_b ?
        (px_w[0] ? line_b_lo_odd_back : line_b_lo_even_back) :
        (px_w[0] ? line_a_lo_odd_back : line_a_lo_even_back);
    wire [14:0] back_hi_w  = back_is_b ?
        (px_w[0] ? line_b_hi_odd_back : line_b_hi_even_back) :
        (px_w[0] ? line_a_hi_odd_back : line_a_hi_even_back);
    wire [14:0] back_lo2_w = back_is_b ?
        (px2_w[0] ? line_b_lo_odd_back : line_b_lo_even_back) :
        (px2_w[0] ? line_a_lo_odd_back : line_a_lo_even_back);
    wire [14:0] back_hi2_w = back_is_b ?
        (px2_w[0] ? line_b_hi_odd_back : line_b_hi_even_back) :
        (px2_w[0] ? line_a_hi_odd_back : line_a_hi_even_back);
    /* verilator lint_on UNUSEDSIGNAL */
    wire [7:0]  back_gen_w = back_is_b ? bank_gen_b : bank_gen_a;
    wire        group_claimed_w = pri_w ?
        (back_hi_w[14:7] == back_gen_w && back_hi_w[6]) :
        (back_lo_w[14:7] == back_gen_w && back_lo_w[6]);
    wire        group_claimed2_w = pri_w ?
        (back_hi2_w[14:7] == back_gen_w && back_hi2_w[6]) :
        (back_lo2_w[14:7] == back_gen_w && back_lo2_w[6]);

    // One write port per physical bank.  The even/odd split guarantees that
    // the two adjacent PASS1 pixels never contend for the M10K port.
    always_comb begin
        line_a_lo_even_waddr = 8'd0; line_a_lo_odd_waddr = 8'd0;
        line_a_hi_even_waddr = 8'd0; line_a_hi_odd_waddr = 8'd0;
        line_b_lo_even_waddr = 8'd0; line_b_lo_odd_waddr = 8'd0;
        line_b_hi_even_waddr = 8'd0; line_b_hi_odd_waddr = 8'd0;
        line_a_lo_even_wdata = 15'd0; line_a_lo_odd_wdata = 15'd0;
        line_a_hi_even_wdata = 15'd0; line_a_hi_odd_wdata = 15'd0;
        line_b_lo_even_wdata = 15'd0; line_b_lo_odd_wdata = 15'd0;
        line_b_hi_even_wdata = 15'd0; line_b_hi_odd_wdata = 15'd0;
        line_a_lo_even_we = 1'b0; line_a_lo_odd_we = 1'b0;
        line_a_hi_even_we = 1'b0; line_a_hi_odd_we = 1'b0;
        line_b_lo_even_we = 1'b0; line_b_lo_odd_we = 1'b0;
        line_b_hi_even_we = 1'b0; line_b_hi_odd_we = 1'b0;

        if (state == S_CLEAR) begin
            // Vertical blanking leaves both ping-pong sets off-screen. Clear
            // every parity/priority bank in parallel so an old 8-bit serial
            // can never become current again on a later visible line.
            line_a_lo_even_waddr = clear_addr; line_a_lo_odd_waddr = clear_addr;
            line_a_hi_even_waddr = clear_addr; line_a_hi_odd_waddr = clear_addr;
            line_b_lo_even_waddr = clear_addr; line_b_lo_odd_waddr = clear_addr;
            line_b_hi_even_waddr = clear_addr; line_b_hi_odd_waddr = clear_addr;
            line_a_lo_even_we = 1'b1; line_a_lo_odd_we = 1'b1;
            line_a_hi_even_we = 1'b1; line_a_hi_odd_we = 1'b1;
            line_b_lo_even_we = 1'b1; line_b_lo_odd_we = 1'b1;
            line_b_hi_even_we = 1'b1; line_b_hi_odd_we = 1'b1;
        end else if (state == S_PASS1) begin
            if (px_in_range_w && pen4_w != 4'd0 && !group_claimed_w) begin
                if (back_is_b) begin
                    if (!pri_w) begin
                        if (px_w[0]) begin
                            line_b_lo_odd_waddr = px_w[8:1];
                            line_b_lo_odd_wdata = {back_gen_w, 1'b1, pen4_w, (pen4_w == 4'd8) ? 2'b00 : color_w};
                            line_b_lo_odd_we = 1'b1;
                        end else begin
                            line_b_lo_even_waddr = px_w[8:1];
                            line_b_lo_even_wdata = {back_gen_w, 1'b1, pen4_w, (pen4_w == 4'd8) ? 2'b00 : color_w};
                            line_b_lo_even_we = 1'b1;
                        end
                    end else begin
                        if (px_w[0]) begin
                            line_b_hi_odd_waddr = px_w[8:1];
                            line_b_hi_odd_wdata = {back_gen_w, 1'b1, pen4_w, (pen4_w == 4'd8) ? 2'b00 : color_w};
                            line_b_hi_odd_we = 1'b1;
                        end else begin
                            line_b_hi_even_waddr = px_w[8:1];
                            line_b_hi_even_wdata = {back_gen_w, 1'b1, pen4_w, (pen4_w == 4'd8) ? 2'b00 : color_w};
                            line_b_hi_even_we = 1'b1;
                        end
                    end
                end else begin
                    if (!pri_w) begin
                        if (px_w[0]) begin
                            line_a_lo_odd_waddr = px_w[8:1];
                            line_a_lo_odd_wdata = {back_gen_w, 1'b1, pen4_w, (pen4_w == 4'd8) ? 2'b00 : color_w};
                            line_a_lo_odd_we = 1'b1;
                        end else begin
                            line_a_lo_even_waddr = px_w[8:1];
                            line_a_lo_even_wdata = {back_gen_w, 1'b1, pen4_w, (pen4_w == 4'd8) ? 2'b00 : color_w};
                            line_a_lo_even_we = 1'b1;
                        end
                    end else begin
                        if (px_w[0]) begin
                            line_a_hi_odd_waddr = px_w[8:1];
                            line_a_hi_odd_wdata = {back_gen_w, 1'b1, pen4_w, (pen4_w == 4'd8) ? 2'b00 : color_w};
                            line_a_hi_odd_we = 1'b1;
                        end else begin
                            line_a_hi_even_waddr = px_w[8:1];
                            line_a_hi_even_wdata = {back_gen_w, 1'b1, pen4_w, (pen4_w == 4'd8) ? 2'b00 : color_w};
                            line_a_hi_even_we = 1'b1;
                        end
                    end
                end
            end
            if (px2_in_range_w && pen4_2_w != 4'd0 && !group_claimed2_w) begin
                if (back_is_b) begin
                    if (!pri_w) begin
                        if (px2_w[0]) begin
                            line_b_lo_odd_waddr = px2_w[8:1];
                            line_b_lo_odd_wdata = {back_gen_w, 1'b1, pen4_2_w, (pen4_2_w == 4'd8) ? 2'b00 : color_w};
                            line_b_lo_odd_we = 1'b1;
                        end else begin
                            line_b_lo_even_waddr = px2_w[8:1];
                            line_b_lo_even_wdata = {back_gen_w, 1'b1, pen4_2_w, (pen4_2_w == 4'd8) ? 2'b00 : color_w};
                            line_b_lo_even_we = 1'b1;
                        end
                    end else begin
                        if (px2_w[0]) begin
                            line_b_hi_odd_waddr = px2_w[8:1];
                            line_b_hi_odd_wdata = {back_gen_w, 1'b1, pen4_2_w, (pen4_2_w == 4'd8) ? 2'b00 : color_w};
                            line_b_hi_odd_we = 1'b1;
                        end else begin
                            line_b_hi_even_waddr = px2_w[8:1];
                            line_b_hi_even_wdata = {back_gen_w, 1'b1, pen4_2_w, (pen4_2_w == 4'd8) ? 2'b00 : color_w};
                            line_b_hi_even_we = 1'b1;
                        end
                    end
                end else begin
                    if (!pri_w) begin
                        if (px2_w[0]) begin
                            line_a_lo_odd_waddr = px2_w[8:1];
                            line_a_lo_odd_wdata = {back_gen_w, 1'b1, pen4_2_w, (pen4_2_w == 4'd8) ? 2'b00 : color_w};
                            line_a_lo_odd_we = 1'b1;
                        end else begin
                            line_a_lo_even_waddr = px2_w[8:1];
                            line_a_lo_even_wdata = {back_gen_w, 1'b1, pen4_2_w, (pen4_2_w == 4'd8) ? 2'b00 : color_w};
                            line_a_lo_even_we = 1'b1;
                        end
                    end else begin
                        if (px2_w[0]) begin
                            line_a_hi_odd_waddr = px2_w[8:1];
                            line_a_hi_odd_wdata = {back_gen_w, 1'b1, pen4_2_w, (pen4_2_w == 4'd8) ? 2'b00 : color_w};
                            line_a_hi_odd_we = 1'b1;
                        end else begin
                            line_a_hi_even_waddr = px2_w[8:1];
                            line_a_hi_even_wdata = {back_gen_w, 1'b1, pen4_2_w, (pen4_2_w == 4'd8) ? 2'b00 : color_w};
                            line_a_hi_even_we = 1'b1;
                        end
                    end
                end
            end
        end
    end

    assign line_busy = (state != S_IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            state               <= S_IDLE;
            clear_addr          <= 8'd0;
            front_sel           <= 1'b0;
            bank_gen_a          <= 8'd0;
            bank_gen_b          <= 8'd0;
            line_valid_a       <= 1'b0;
            line_valid_b       <= 1'b0;
            line_tag_a         <= 10'd0;
            line_tag_b         <= 10'd0;
            line_epoch_a       <= 1'b0;
            line_epoch_b       <= 1'b0;
            display_epoch      <= 1'b0;
            epoch_pending      <= 1'b0;
            build_tag_r        <= 10'd0;
            build_epoch_r      <= 1'b0;
            build_overrun      <= 1'b0;
            snap_ready         <= 1'b0;
            gfx2_req           <= 1'b0;
            spriteram_desc_addr <= 9'd0;
            slot               <= 9'd0;
            oc                 <= 5'd0;
`ifdef VERILATOR
            active_count       <= 10'd0;
`endif
            build_line_r       <= 10'd0;
        end else begin
            // gfx2_req is asserted only while waiting for the current row.
            if (state != S_GFX_REQ) gfx2_req <= 1'b0;

            // A line-start arriving while the producer is still busy is the
            // original causal failure. Keep the build running, but never
            // promote its incomplete back buffer.
            if (line_start && state != S_IDLE) begin
                build_overrun <= 1'b1;
`ifdef VERILATOR
                if (sprite_trace_enabled && target_line >= sprite_trace_first &&
                    target_line <= sprite_trace_last)
                    $display("MCR68_SP_TRACE kind=overrun target=%0d build=%0d state=%0d slot=%0d active=%0d time=%0t",
                             target_line, build_line_r, state, slot, active_count, $time);
`endif
            end

            unique case (state)
                S_IDLE: begin
                    if (line_start) begin
`ifdef VERILATOR
                        if (target_line != 10'(V_ACTIVE) &&
                            target_line != 10'(V_ACTIVE - 1) &&
                            ((target_line <= 10'(V_ACTIVE)) ||
                             (target_line == 10'(V_TOTAL - 1))) &&
                            sprite_trace_enabled &&
                            next_line_tag_w >= sprite_trace_first &&
                            next_line_tag_w <= sprite_trace_last)
                            $display("MCR68_SP_TRACE kind=start target=%0d build=%0d front=%0d ready=%0d bank=%0d epoch=%0d time=%0t",
                                     target_line, next_line_tag_w, front_sel,
                                     back_ready_for_line, build_back_is_b_w,
                                     next_line_epoch_w, $time);
`endif
                        // Promote only a complete line with both the expected
                        // tag and epoch. Otherwise the current front remains
                        // selected and its valid bit gates the compositor.
                        if (back_ready_for_line)
                            front_sel <= ~front_sel;

                        if (target_line == 10'(V_TOTAL - 1)) epoch_pending <= 1'b1;
                        else begin
                            if (epoch_pending) display_epoch <= current_line_epoch_w;
                            epoch_pending <= 1'b0;
                        end

                        if (target_line == 10'(V_ACTIVE)) begin
                            // Line V_ACTIVE-1 has finished display. Scrub now,
                            // not one line earlier, so no visible front buffer
                            // is modified while it is being scanned out.
                            line_valid_a <= 1'b0;
                            line_valid_b <= 1'b0;
                            clear_addr   <= 8'd0;
                            state        <= S_CLEAR;
                        end else if ((target_line == 10'(V_ACTIVE - 1)) ||
                                     ((target_line > 10'(V_ACTIVE)) &&
                                      (target_line != 10'(V_TOTAL - 1)))) begin
                            // No sprite line is consumed during vertical
                            // blanking. The last blank line is excluded because
                            // it must prepare visible line zero.
                            state <= S_IDLE;
                        end else begin
                            // The line being built is the next raster line. The
                            // buffer becomes invalid immediately and is
                            // published only in S_DONE with matching metadata.
                            build_line_r  <= next_line_tag_w;
                            build_tag_r   <= next_line_tag_w;
                            build_epoch_r <= next_line_epoch_w;
`ifdef VERILATOR
                            active_count  <= 10'd0;
                            sprite_trace_start_time <= $time;
`endif
                            if (build_back_is_b_w) begin
                                line_valid_b <= 1'b0;
                                bank_gen_b   <= bank_gen_b + 8'd1;
                            end else begin
                                line_valid_a <= 1'b0;
                                bank_gen_a   <= bank_gen_a + 8'd1;
                            end
                            slot                <= slot_top_w;
                            spriteram_desc_addr <= slot_top_w;
                            state               <= S_EVAL;
                        end
                    end
                end

                S_CLEAR: begin
                    if (clear_addr == 8'hff) begin
                        bank_gen_a <= 8'd0;
                        bank_gen_b <= 8'd0;
                        // Chain straight into the once-per-frame staging ->
                        // packet descriptor snapshot (XFER). Both fit well
                        // inside line V_ACTIVE (256 + 513 clocks against a
                        // ~3170-clock line), so no line_start is missed.
                        slot                <= 9'd0;
                        spriteram_desc_addr <= 9'd0;
                        state               <= S_XFER;
                    end else begin
                        clear_addr <= clear_addr + 8'd1;
                    end
                end

                S_XFER: begin
                    // One staging descriptor per clock: the staging read port
                    // is asynchronous from the registered address, so the
                    // current address's data is written in the same cycle.
                    snap_desc[spriteram_desc_addr] <= spriteram_desc_data;
                    if (slot == 9'd511) begin
                        snap_ready <= 1'b1;
                        state      <= S_IDLE;
                    end else begin
                        slot                <= slot + 9'd1;
                        spriteram_desc_addr <= spriteram_desc_addr + 9'd1;
                    end
                end

                S_EVAL: begin
                    // !snap_ready: before the first frame's XFER the snapshot
                    // holds no meaningful descriptors -- treat every slot as
                    // inactive rather than rendering power-up garbage.
                    if (!snap_ready || code_raw_w == 11'd0 || !in_row_range_w) begin
                        if (slot == 9'd0) state <= S_DONE;
                        else begin
                            slot                <= slot - 9'd1;
                            spriteram_desc_addr <= slot - 9'd1;
                        end
                    end else begin
                        gfx2_code <= code_w;
                        gfx2_row  <= row_index_w;
                        oc        <= 5'd0;
`ifdef VERILATOR
                        active_count <= active_count + 10'd1;
`endif
                        state     <= S_GFX_REQ;
                    end
                end

                S_GFX_REQ: begin
                    gfx2_req <= 1'b1;
                    if (gfx2_ack) begin
                        pens_r   <= gfx2_pens;
                        gfx2_req <= 1'b0;
                        state    <= S_PASS1;
                    end
                end

                // Two independent pixels are resolved per clock. This is
                // exact because adjacent columns never alias and each pixel's
                // claim bit is tested before its own write. Pen 8 stamps the
                // claim but is rejected by the front-side visible decode.
                S_PASS1: begin
                    if (oc == 5'd30) begin
                        oc <= 5'd0;
                        if (slot == 9'd0) state <= S_DONE;
                        else begin
                            slot                <= slot - 9'd1;
                            spriteram_desc_addr <= slot - 9'd1;
                            state               <= S_EVAL;
                        end
                    end else oc <= oc + 5'd2;
                end

                S_DONE: begin
`ifdef VERILATOR
                    if (sprite_trace_enabled && active_count != 0 &&
                        build_line_r >= sprite_trace_first &&
                        build_line_r <= sprite_trace_last)
                        $display("MCR68_SP_TRACE kind=done build=%0d active=%0d bank=%0d epoch=%0d elapsed=%0t time=%0t",
                                 build_line_r, active_count, back_is_b,
                                 build_epoch_r, $time - sprite_trace_start_time, $time);
`endif
                    if (back_is_b) begin
                        line_valid_b <= 1'b1;
                        line_tag_b   <= build_tag_r;
                        line_epoch_b <= build_epoch_r;
                    end else begin
                        line_valid_a <= 1'b1;
                        line_tag_a   <= build_tag_r;
                        line_epoch_a <= build_epoch_r;
                    end
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
