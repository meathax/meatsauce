// mcr68_game_pkg.sv -- per-title hardware profile contract, as a PACKAGE.
//
// Was rtl/mcr68_game_profile.svh, a plain `include. That broke Quartus: the
// header is included by five separate files which share one compilation unit
// ($unit scope), so every typedef and function ended up declared several
// times --
//   Error (10149): identifier "mcr68_gfx_size_bytes" is already declared in
//   the present scope
// An `ifndef guard cannot prevent this; the guard is per-file-preprocess, the
// scope is shared. A package is the correct SystemVerilog idiom: declared
// once, imported by each consumer.
//
// Consumers use:  import mcr68_game_pkg::*;
// This file MUST be compiled before any module that imports it.

`timescale 1ns / 1ps

package mcr68_game_pkg;

// mcr68_game_profile.svh -- per-title hardware profile contract for the
// MCR-68k core.
//
// The core originally implemented exactly one hardware profile (Xenophobe).
// Every other mcr68.cpp title differs in at least one of: address decode,
// sound board, graphics ROM sizing, or input conditioning. Rather than fork
// the core per game, one profile descriptor selects those variations at
// elaboration/runtime.
//
// CONTRACT RULES (all modules consuming this header must obey):
//
//   1. `GAME_XENOPHOB` (profile value 0) MUST reproduce the pre-existing
//      Xenophobe behaviour bit-for-bit. It is the verified reference profile
//      (see doc/phase5_attract_alignment_20260813.md -- frame 300 is
//      pixel-exact against MAME). Any change that alters Xenophobe output
//      under this profile is a regression, not a feature.
//   2. Profile fields are *static configuration*, not per-cycle control.
//      Treat them as constants held stable while the game is out of reset.
//   3. No profile field may gate a clock. Use clock enables / muxes only.
//   4. Unimplemented profiles must fail loudly in simulation and default to
//      inert (no bus contention) in synthesis -- never silently alias onto
//      Xenophobe's decode.
//
// Source of truth for every per-title difference encoded here is MAME 0.289
// `src/mame/bally/mcr68.cpp` (memory maps, machine configs, GFXDECODE and
// INPUT_PORTS blocks). See doc/mcr68_multigame_staging.md for the per-title
// gap analysis this descriptor was derived from.


typedef enum logic [2:0] {
    GAME_XENOPHOB = 3'd0,  // reference profile -- verified against MAME
    GAME_BLASTED  = 3'd1,  // mcr68_map + Sounds Good, 512K gfx2
    GAME_ARCHRIVL = 3'd3,  // Williams S11 BG sound, 128K gfx1, 49-way
    GAME_PIGSKIN  = 3'd4   // Williams S11C BG sound, pigskin_map decode
} mcr68_game_e;

// gfx region size selectors. Encoded as a size class rather than a raw byte
// count so the video path can size address buses by parameter.
typedef enum logic [1:0] {
    GFX_64K  = 2'd0,
    GFX_128K = 2'd1,
    GFX_256K = 2'd2,
    GFX_512K = 2'd3
} mcr68_gfx_size_e;

typedef struct packed {
    mcr68_game_e     game;

    // ---- address decode -------------------------------------------------
    // Xenophobe/Blasted/Arch Rivals share mcr68_map (mcr68.cpp:602-612).
    // Pigskin installs its own pigskin_map (mcr68.cpp:627-631): ports at
    // 0x080000/0x0a0000, palette relocated to 0x0c0000, watchdog 0x0e0000.
    logic            map_pigskin;

    // ---- sound boards ---------------------------------------------------
    logic            snd_sounds_good;   // "Sounds Good" 68000 board
    logic            snd_williams_bg;   // Williams S11 background board
    logic            williams_s11c;     // S11C mix variant (pigskin) vs S11 (archrivl)

    // ---- graphics sizing ------------------------------------------------
    mcr68_gfx_size_e gfx1_size;         // tiles:   64K (xeno/blasted) or 128K
    mcr68_gfx_size_e gfx2_size;         // sprites: 256K (xeno) or 512K

    // ---- sprite engine geometry (IR-4) ----------------------------------
    // All three come from the per-title init_ functions in mcr68.cpp:
    //   mcr68_common_init(clip, xoffset)  -- mcr68.cpp:1845
    //     init_xenophob  (0,  -4)   :1856
    //     init_blasted   (0,   0)   :1882
    //     init_archrivl  (16,  0)   :1909
    //     init_pigskin   (16,  0)   :1944
    // sprite_slots is NOT from init_; it is m_spriteram.bytes()/8, i.e. the
    // spriteram window in the memory map: mcr68_map 0x080000-0x080fff
    // (4 KiB, :606) -> 512 slots; pigskin_map 0x160000-0x1607ff (2 KiB,
    // :637) -> 256 slots. Pigskin is the only set that differs.
    logic [5:0]        sprite_clip;      // symmetric X clip, 0 or 16
    logic signed [3:0] sprite_xoffset;   // -4 / 0 (Xenophobe / other profiles)
    logic [10:0]       sprite_slots;     // 512 or 256

    // ---- inputs ---------------------------------------------------------
    logic            joy_49way;         // 49-way analog-ish stick (archrivl/pigskin)
} mcr68_profile_t;

// Compile-time profile table. Values are transcribed from mcr68.cpp with the
// line references given above; keep this table and doc/mcr68_multigame_staging.md
// in agreement when either changes.
function automatic mcr68_profile_t mcr68_profile(input mcr68_game_e g);
    mcr68_profile_t p;
    p = '{ game: g, map_pigskin: 1'b0,
           snd_sounds_good: 1'b0,
           snd_williams_bg: 1'b0, williams_s11c: 1'b0,
           gfx1_size: GFX_64K, gfx2_size: GFX_256K,
           sprite_clip: 6'd0, sprite_xoffset: -4'sd4, sprite_slots: 11'd512,
           joy_49way: 1'b0 };
    case (g)
        GAME_XENOPHOB: begin
            p.snd_sounds_good = 1'b1;
            p.gfx1_size = GFX_64K;  p.gfx2_size = GFX_256K;
            p.sprite_clip = 6'd0; p.sprite_xoffset = -4'sd4; p.sprite_slots = 11'd512;
        end
        GAME_BLASTED: begin
            p.snd_sounds_good = 1'b1;
            p.gfx1_size = GFX_64K;  p.gfx2_size = GFX_512K;
            p.sprite_clip = 6'd0; p.sprite_xoffset = 4'sd0; p.sprite_slots = 11'd512;
        end
        GAME_ARCHRIVL: begin
            p.snd_williams_bg = 1'b1;
            p.joy_49way       = 1'b1;
            p.gfx1_size = GFX_128K; p.gfx2_size = GFX_512K;
            p.sprite_clip = 6'd16; p.sprite_xoffset = 4'sd0; p.sprite_slots = 11'd512;
        end
        GAME_PIGSKIN: begin
            p.snd_williams_bg = 1'b1;
            p.williams_s11c   = 1'b1;
            p.map_pigskin     = 1'b1;
            p.joy_49way       = 1'b1;
            p.gfx1_size = GFX_128K; p.gfx2_size = GFX_512K;
            p.sprite_clip = 6'd16; p.sprite_xoffset = 4'sd0; p.sprite_slots = 11'd256;
        end
        default: ;  // inert -- see contract rule 4
    endcase
    return p;
endfunction

// ---------------------------------------------------------------------------
// Elaboration-time accessors.
//
// `mcr68_profile()` returns a packed struct, which is fine for runtime decode
// logic but awkward to use in a parameter expression (port widths must be
// plain ints). These wrappers return `int` so a module can write e.g.
//   parameter int GFX2_BYTES = mcr68_gfx2_bytes(GAME_STATIC)
// and have every derived width constant-fold. Under GAME_XENOPHOB every one
// of them returns exactly the value that was previously hard-coded, so the
// reference profile constant-folds to today's RTL (contract rule 1).
// ---------------------------------------------------------------------------
function automatic int mcr68_gfx_size_bytes(input mcr68_gfx_size_e s);
    case (s)
        GFX_64K:  return 'h10000;
        GFX_128K: return 'h20000;
        GFX_256K: return 'h40000;
        GFX_512K: return 'h80000;
        default:  return 'h10000;
    endcase
endfunction

/* verilator lint_off UNUSEDSIGNAL */
function automatic int mcr68_gfx1_bytes(input mcr68_game_e g);
    mcr68_profile_t p;
    p = mcr68_profile(g);
    return mcr68_gfx_size_bytes(p.gfx1_size);
endfunction
/* verilator lint_on UNUSEDSIGNAL */

/* verilator lint_off UNUSEDSIGNAL */
function automatic int mcr68_gfx2_bytes(input mcr68_game_e g);
    mcr68_profile_t p;
    p = mcr68_profile(g);
    return mcr68_gfx_size_bytes(p.gfx2_size);
endfunction
/* verilator lint_on UNUSEDSIGNAL */

/* verilator lint_off UNUSEDSIGNAL */
function automatic int mcr68_sprite_clip(input mcr68_game_e g);
    mcr68_profile_t p;
    p = mcr68_profile(g);
    return int'(p.sprite_clip);
endfunction
/* verilator lint_on UNUSEDSIGNAL */

// Sign extension is done explicitly rather than relying on the packed-struct
// member's declared signedness surviving field selection (which is not
// portable across Quartus 17 / Verilator).
/* verilator lint_off UNUSEDSIGNAL */
function automatic int mcr68_sprite_xoffset(input mcr68_game_e g);
    mcr68_profile_t p;
    logic [3:0]     v;
    p = mcr68_profile(g);
    v = p.sprite_xoffset;
    return int'($signed(v));
endfunction
/* verilator lint_on UNUSEDSIGNAL */

/* verilator lint_off UNUSEDSIGNAL */
function automatic int mcr68_sprite_slots(input mcr68_game_e g);
    mcr68_profile_t p;
    p = mcr68_profile(g);
    return int'(p.sprite_slots);
endfunction
/* verilator lint_on UNUSEDSIGNAL */

endpackage : mcr68_game_pkg
