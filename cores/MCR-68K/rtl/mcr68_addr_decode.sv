// -----------------------------------------------------------------------------
// mcr68_addr_decode.sv
//
// Bally/Midway MCR-68000 ("MCR-68k") main-CPU bus address decoder.
//
// Combinational chip-select decode of the 68000 main-CPU address bus, after
// application of MAME's global_mask(0x1fffff). Produces one chip-select strobe
// per memory-mapped region. UDS/LDS are passed through unmolested for
// downstream modules to interpret byte-lane semantics; this module makes no
// assumption about and performs no byte-lane logic. It does report, as a
// static profile-derived flag (`ptm_lane_upper`), WHICH byte lane the PTM
// lives on, because that genuinely differs per title (see below).
//
// PROFILE-DRIVEN. Historically this file hard-coded Xenophobe's `mcr68_map`
// ranges as literal compares. It now selects between the two distinct MCR-68k
// main-CPU memory maps that are in scope for this core:
//
//   MAP_MCR68   -- `mcr68_map`   (mcr68.cpp:598-613)
//   MAP_PIGSKIN -- `pigskin_map` (mcr68.cpp:623-639)
//
// Source of truth: D:\Arcade\AI\mame289\src\mame\bally\mcr68.cpp.
//
// PER-TITLE MAP SELECTION (verified by reading each machine_config and
// init_* function, NOT assumed):
//
//   xenophob  mcr68()          -> mcr68_map. init_xenophob (mcr68.cpp:1862)
//                                installs xenophobe_control_w over
//                                0x0c0000-0x0cffff (a range the base map does
//                                not otherwise define).
//   blasted   xenophob()       -> mcr68_map. init_blasted (1890) installs
//                                blasted_control_w at the same 0x0c0000.
//                                REPLACES the 0x0d0000 / 0x0e0000 port reads
//                                with its own handlers. Same ADDRESSES, only
//                                the read semantics differ -> decode is
//                                identical to Xenophobe's.
//   archrivl  archrivl()       -> mcr68_map. mcr68.cpp:1284-1292 calls
//                                mcr68(config) and adds only S11_BG; it does
//                                NOT call set_addrmap, so there is no
//                                `archrivl_map`. init_archrivl (1907-1919)
//                                installs archrivl_control_w at 0x0c0000 and
//                                archrivl_port_1_r over 0x0e0000-0x0effff
//                                (replacing portr("IN1")). Again: same
//                                addresses, different read semantics.
//                                => Arch Rivals' ADDRESS DECODE is bit-
//                                identical to Xenophobe's. The differences
//                                are all downstream (49-way translate table
//                                on the IN1 read, Williams S11 background
//                                sound board on the control word).
//   pigskin   pigskin()        -> pigskin_map (mcr68.cpp:1302 explicitly
//                                calls set_addrmap after mcr68(config)).
//
//   The map_kind_e / per-map decode structure below is deliberately shaped
//   so a further map variant could be added without disturbing either
//   existing map.
//
// -----------------------------------------------------------------------------
// mcr68_map (MAP_MCR68) -- global_mask 0x1fffff
//
//   cs_rom        000000-03FFFF   Program ROM (256K)
//   cs_workram    060000-063FFF   Work RAM (16K)
//   cs_videoram   070000-070FFF   Background video RAM
//   cs_auxram     071000-071FFF   Additional RAM
//   cs_spriteram  080000-080FFF   Sprite RAM (4K)
//   cs_paletteram 090000-09007F   Palette RAM (write-only)
//   cs_ptm        0A0000-0A000F   MC6840 PTM, umask16(0x00ff) -> LOWER byte
//   cs_watchdog   0B0000-0BFFFF   Watchdog reset (write-only)
//   cs_soundio    0C0000-0CFFFF   Control word (sound/board control write)
//   cs_in0        0D0000-0DFFFF   IN0 (read-only)
//   cs_in1        0E0000-0EFFFF   IN1 (read-only)
//   cs_dsw        0F0000-0FFFFF   DSW (read-only)
//
// Unmapped under MAP_MCR68 (e.g. 040000-05FFFF, 064000-06FFFF, 072000-07FFFF,
// 081000-08FFFF, 090080-09FFFF, 100000-1FFFFF) assert no chip select.
//
// -----------------------------------------------------------------------------
// pigskin_map (MAP_PIGSKIN) -- global_mask 0x1fffff
//
//   cs_rom            000000-03FFFF   Program ROM (256K)            [same]
//   cs_pigskin_port1  080000-08FFFF   pigskin_port_1_r  (NEW PORT)
//   cs_pigskin_port2  0A0000-0AFFFF   pigskin_port_2_r  (NEW PORT)
//   cs_paletteram     0C0000-0C007F   Palette RAM       (MOVED from 090000)
//   cs_watchdog       0E0000-0EFFFF   Watchdog          (MOVED from 0B0000)
//   cs_videoram       100000-100FFF   Background video RAM (MOVED from 070000)
//   cs_protect        120000-120001   Protection r/w    (NEW PORT)
//   cs_workram        140000-143FFF   Work RAM (16K)    (MOVED from 060000)
//   cs_spriteram      160000-1607FF   Sprite RAM (2K!)  (MOVED, HALF SIZE)
//   cs_ptm            180000-18000F   PTM, umask16(0xff00) -> UPPER byte
//   cs_soundio        1A0000-1AFFFF   archrivl_control_w (MOVED from 0C0000)
//   cs_in0            1E0000-1EFFFF   IN0               (MOVED from 0D0000)
//
// ABSENT under pigskin_map -- as important as what moved:
//   * NO cs_auxram      -- pigskin_map has no analogue of 071000-071FFF.
//   * NO cs_in1         -- there is no plain portr("IN1") range. IN1's bits
//                          are folded into pigskin_port_1_r together with the
//                          player-1 49-way axes.
//   * NO cs_dsw         -- there is no plain portr("DSW") range. DSW's bits
//                          are folded into pigskin_port_2_r together with the
//                          player-2 49-way axes.
//   These three outputs are held LOW for the whole address space under
//   MAP_PIGSKIN rather than being aliased onto the new port ranges: the
//   pigskin port reads are composite (port bits OR'd with translated 49-way
//   nibbles) and have no direct mcr68_map equivalent, so they get their own
//   chip selects and the integrator must build their read data separately.
//
// Other pigskin-only decode facts the integrator must honour:
//   * Sprite RAM is 2 KiB (0x160000-0x1607FF), HALF the 4 KiB of mcr68_map.
//     Index it with addr[10:1], not addr[11:1].
//   * The PTM is on the UPPER byte lane (umask16(0xff00), i.e. EVEN byte
//     addresses / D8-D15) instead of mcr68_map's lower lane (umask16(0x00ff),
//     odd byte addresses / D0-D7). This module exposes that as the static
//     `ptm_lane_upper` output; it does NOT gate cs_ptm on a byte strobe,
//     keeping the existing "decode is address-only, byte lanes are
//     downstream" contract intact and Xenophobe's cs_ptm bit-identical.
//   * cs_soundio under pigskin is archrivl_control_w feeding a Williams S11C
//     background sound board, NOT xenophobe_control_w feeding Sounds Good.
//     Same chip-select role, entirely different downstream bit meanings.
//
// -----------------------------------------------------------------------------
// IMPORTANT -- decode provenance: all MCR-68k address-decode PLDs for this
// board are undumped (NO_DUMP in MAME's ROM set). This decode is therefore
// MAME_COMPATIBLE, reproducing MAME's emulated memory map exactly -- it is NOT
// hardware-proven against a real PLD dump or schematic. Treat any future PLD
// dump or PCB evidence as authoritative over this file per the project's
// evidence-order policy.
//
// CONTRACT RULE 1 (rtl/mcr68_game_profile.svh): GAME_XENOPHOB output must be
// bit-identical to the pre-profile implementation. That is enforced by
// sim/tb_mcr68_addr_decode.sv, which sweeps ALL 2^21 addresses against a
// verbatim copy of the previous literal-compare decode.
//
// CONTRACT RULE 4: an unsupported/unknown profile decodes MAP_NONE -- every
// chip select low (inert, no bus contention), map_valid low, and a loud
// simulation-only failure.
// -----------------------------------------------------------------------------

/* verilator lint_off IMPORTSTAR */
import mcr68_game_pkg::*;
/* verilator lint_on IMPORTSTAR */

module mcr68_addr_decode #(
    // Static profile. Default GAME_XENOPHOB so an existing instantiation that
    // connects none of the new ports keeps exactly its previous behaviour.
    parameter mcr68_game_e GAME_STATIC = GAME_XENOPHOB,

    // When 0 (default) the `game` INPUT PORT IS IGNORED and GAME_STATIC is
    // used. This is what keeps the current single-title instantiation in
    // rtl/mcr68_main_board.sv correct without editing it: an unconnected
    // `game` input would otherwise be 'z. Set to 1 once the integrator wires
    // a real runtime game select (e.g. from the MRA config byte).
    parameter bit          RUNTIME_GAME_SEL = 1'b0,

    // Simulation-only: $fatal on an unsupported profile. Set 0 in a testbench
    // that deliberately exercises the inert path. Has no synthesis effect.
    parameter bit          SIM_FATAL_ON_BAD_PROFILE = 1'b1
) (
    input  mcr68_game_e  game,       // runtime profile; used only if RUNTIME_GAME_SEL
    input  logic [20:0]  addr,       // 68000 address bus, post global_mask(0x1fffff)
    input  logic         uds_n,      // upper data strobe, active low, passed through
    input  logic         lds_n,      // lower data strobe, active low, passed through

    // ---- chip selects shared by both maps (ranges differ per map) ----------
    output logic cs_rom,
    output logic cs_workram,
    output logic cs_videoram,
    output logic cs_auxram,          // MAP_MCR68 only; always 0 under pigskin
    output logic cs_spriteram,       // 4K on mcr68_map, 2K on pigskin_map
    output logic cs_paletteram,
    output logic cs_ptm,
    output logic cs_watchdog,
    output logic cs_soundio,         // control-word write (semantics per title)
    output logic cs_in0,
    output logic cs_in1,             // MAP_MCR68 only; always 0 under pigskin
    output logic cs_dsw,             // MAP_MCR68 only; always 0 under pigskin

    // ---- pigskin-only chip selects (always 0 under MAP_MCR68) -------------
    output logic cs_pigskin_port1,   // 080000-08FFFF  IN1 | 49WAY P1 (read)
    output logic cs_pigskin_port2,   // 0A0000-0AFFFF  DSW | 49WAY P2 (read)
    output logic cs_protect,         // 120000-120001  protection r/w

    // ---- static profile-derived decode attributes -------------------------
    output logic ptm_lane_upper,     // 1 = PTM on D8-D15 (pigskin umask 0xff00)
                                     // 0 = PTM on D0-D7  (mcr68  umask 0x00ff)
    output logic map_valid,          // 0 = unsupported profile, decode inert

    output logic uds_n_out,          // pass-through, unmolested
    output logic lds_n_out           // pass-through, unmolested
);

    // -------------------------------------------------------------------------
    // Which of the MCR-68k main-CPU maps this profile uses.
    // Kept as a local enum (rather than a new profile field) so the shared
    // cross-agent contract in mcr68_game_profile.svh is not widened; the
    // existing `map_pigskin` field is consumed and cross-checked below.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        MAP_NONE    = 2'd0,   // unsupported profile -- inert
        MAP_MCR68   = 2'd1,   // mcr68_map
        MAP_PIGSKIN = 2'd2    // pigskin_map
    } map_kind_e;

    mcr68_game_e    sel_game;
    // Combinational map state is also observed by simulation-only contract
    // checks below.
    /* verilator lint_off SYNCASYNCNET */
    map_kind_e      map_kind;
    /* verilator lint_on SYNCASYNCNET */
    mcr68_profile_t prof;

    assign sel_game = RUNTIME_GAME_SEL ? game : GAME_STATIC;
    assign prof     = mcr68_profile(sel_game);

    // Explicit enumeration of the profile values whose map is implemented.
    // Anything else (including out-of-range encodings 3'd5..3'd7 and 'x/'z)
    // falls through to MAP_NONE -- contract rule 4. Deliberately NOT derived
    // solely from prof.map_pigskin, because that field is 0 both for
    // "uses mcr68_map" and for the struct's inert default.
    always_comb begin
        case (sel_game)
            GAME_XENOPHOB,
            GAME_BLASTED,
            GAME_ARCHRIVL: map_kind = MAP_MCR68;
            GAME_PIGSKIN:  map_kind = MAP_PIGSKIN;
            default:       map_kind = MAP_NONE;
        endcase
    end

    assign map_valid      = (map_kind != MAP_NONE);
    assign ptm_lane_upper = (map_kind == MAP_PIGSKIN);

    // -------------------------------------------------------------------------
    // Decode. Every output is assigned unconditionally at the top of the
    // always_comb (complete defaults, no inferred latches); the per-map arms
    // then override only what that map defines.
    // -------------------------------------------------------------------------
    always_comb begin
        cs_rom           = 1'b0;
        cs_workram       = 1'b0;
        cs_videoram      = 1'b0;
        cs_auxram        = 1'b0;
        cs_spriteram     = 1'b0;
        cs_paletteram    = 1'b0;
        cs_ptm           = 1'b0;
        cs_watchdog      = 1'b0;
        cs_soundio       = 1'b0;
        cs_in0           = 1'b0;
        cs_in1           = 1'b0;
        cs_dsw           = 1'b0;
        cs_pigskin_port1 = 1'b0;
        cs_pigskin_port2 = 1'b0;
        cs_protect       = 1'b0;

        case (map_kind)
            // -----------------------------------------------------------------
            // mcr68_map -- mcr68.cpp:598-613 (+ the 0x0c0000 control-word
            // handler every init_* in this family installs).
            // These twelve expressions are character-for-character the
            // pre-profile implementation; see the equivalence sweep in
            // sim/tb_mcr68_addr_decode.sv.
            // -----------------------------------------------------------------
            MAP_MCR68: begin
                cs_rom        = (addr <= 21'h03FFFF);
                cs_workram    = (addr >= 21'h060000) && (addr <= 21'h063FFF);
                cs_videoram   = (addr >= 21'h070000) && (addr <= 21'h070FFF);
                cs_auxram     = (addr >= 21'h071000) && (addr <= 21'h071FFF);
                cs_spriteram  = (addr >= 21'h080000) && (addr <= 21'h080FFF);
                cs_paletteram = (addr >= 21'h090000) && (addr <= 21'h09007F);
                cs_ptm        = (addr >= 21'h0A0000) && (addr <= 21'h0A000F);
                cs_watchdog   = (addr >= 21'h0B0000) && (addr <= 21'h0BFFFF);
                cs_soundio    = (addr >= 21'h0C0000) && (addr <= 21'h0CFFFF);
                cs_in0        = (addr >= 21'h0D0000) && (addr <= 21'h0DFFFF);
                cs_in1        = (addr >= 21'h0E0000) && (addr <= 21'h0EFFFF);
                cs_dsw        = (addr >= 21'h0F0000) && (addr <= 21'h0FFFFF);
            end

            // -----------------------------------------------------------------
            // pigskin_map -- mcr68.cpp:623-639.
            // -----------------------------------------------------------------
            MAP_PIGSKIN: begin
                cs_rom           = (addr <= 21'h03FFFF);
                cs_pigskin_port1 = (addr >= 21'h080000) && (addr <= 21'h08FFFF);
                cs_pigskin_port2 = (addr >= 21'h0A0000) && (addr <= 21'h0AFFFF);
                cs_paletteram    = (addr >= 21'h0C0000) && (addr <= 21'h0C007F);
                cs_watchdog      = (addr >= 21'h0E0000) && (addr <= 21'h0EFFFF);
                cs_videoram      = (addr >= 21'h100000) && (addr <= 21'h100FFF);
                cs_protect       = (addr >= 21'h120000) && (addr <= 21'h120001);
                cs_workram       = (addr >= 21'h140000) && (addr <= 21'h143FFF);
                cs_spriteram     = (addr >= 21'h160000) && (addr <= 21'h1607FF);
                cs_ptm           = (addr >= 21'h180000) && (addr <= 21'h18000F);
                cs_soundio       = (addr >= 21'h1A0000) && (addr <= 21'h1AFFFF);
                cs_in0           = (addr >= 21'h1E0000) && (addr <= 21'h1EFFFF);
                // cs_auxram / cs_in1 / cs_dsw intentionally left at 0 -- see
                // the "ABSENT under pigskin_map" note in the header.
            end

            // MAP_NONE: everything stays at its default 0 -- inert.
            default: ;
        endcase
    end

    assign uds_n_out = uds_n;
    assign lds_n_out = lds_n;

    // -------------------------------------------------------------------------
    // Simulation-only guards. No synthesizable effect (Quartus defines
    // SYNTHESIS; the block is additionally free of any driver on a real
    // signal, so even a tool that ignores the guard cannot change behaviour).
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    // Contract rule 4: unsupported profile must fail loudly.
    logic bad_profile_reported;
    initial bad_profile_reported = 1'b0;
    always @(map_kind) begin
        if (map_kind == MAP_NONE && !bad_profile_reported) begin
            bad_profile_reported = 1'b1;
            $display("%%Error: mcr68_addr_decode: UNSUPPORTED GAME PROFILE (game=%0d) -- decode is inert, every chip select held low.", sel_game);
            if (SIM_FATAL_ON_BAD_PROFILE)
                $fatal(1, "mcr68_addr_decode: unsupported game profile");
        end
    end

    // Cross-check the local map selection against the shared profile
    // descriptor. If a future edit to mcr68_game_profile.svh changes
    // map_pigskin for some title, this fires instead of silently diverging.
    always @(map_kind or prof) begin
        if (map_kind == MAP_PIGSKIN && prof.map_pigskin !== 1'b1)
            $fatal(1, "mcr68_addr_decode: profile contract drift -- MAP_PIGSKIN but prof.map_pigskin=0");
        if (map_kind == MAP_MCR68 && prof.map_pigskin !== 1'b0)
            $fatal(1, "mcr68_addr_decode: profile contract drift -- MAP_MCR68 but prof.map_pigskin=1");
    end
`endif

endmodule
