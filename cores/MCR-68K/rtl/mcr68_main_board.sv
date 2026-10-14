// -----------------------------------------------------------------------------
// mcr68_main_board.sv
//
// Bally/Midway MCR-68000 ("MCR-68k") main-board integration -- Xenophobe,
// Production main-board integration
// (C:\Users\meath\.claude\plans\you-a-makeing-a-fizzy-rabin.md) and
// AGENTS.md/core-debug.toml. Wires together the pieces that already exist
// as independent, individually-documented modules:
//
//   rtl/cpu/mcr68_m68k.sv     -- FX68K bus wrapper (16-bit CPU interface)
//   rtl/mcr68_addr_decode.sv  -- combinational chip-select decode
//   rtl/mcr68_mem_sim.sv      -- host-file bring-up memory path
//   rtl/mcr68_mem_hw.sv       -- synthesizable production RAM path
//   rtl/cpu/ptm6840.sv        -- MC6840 PTM, IPL2 interrupt source
//   rtl/mcr68_io.sv           -- watchdog, IN0/IN1/DSW read mux, "493" IPL1
//                                once-per-frame strobe
//
// Sound-board integration: cs_soundio (0x0C0000-0x0CFFFF,
// xenophobe_control_w) is no longer a stub. rtl/snd/mcr68_sound_board.sv
// (a self-contained "Sounds Good" sound-board subsystem -- second FX68K +
// PIA6821 + AD7533 DAC emulation, see that file's own header for its exact
// port list) is instantiated below and driven from a genuine 16-bit
// control-word latch, written whenever cs_soundio & a write cycle fires,
// decoded per xenophobe_control_w (mcr68.cpp:383-388) and cross-checked
// against a real MAME capture (build/difftest/mame_sound_boot_coin.jsonl --
// see doc/phase4_sound_first_compare.md and
// sim/sim_mcr68_sound_headless.cpp's kCmdScript derivation comment):
// control-word bits 0-3 = sndsel (command nibble), bit 4 = sint (strobe,
// active-high, un-inverted -- sounds_good.sv owns the CA1 inversion
// internally), bit 5 = ctrl_reset_n (schematic-real board reset, commented
// out in MAME 0.289's model but real per the plan -- 1 = sound CPU runs,
// 0 = held in reset). See assumption 6 below for the sound board's own
// reset-domain justification. Reads from cs_soundio still return open bus
// (16'hFFFF) -- xenophobe_control_w has no readback path on real
// hardware/MAME either, so this is unchanged from the earlier stub.
//
// Phase 3 (tilemap/sprite/colormix video pipeline) is now wired in below,
// reconciling 5 modules written in parallel with no live coordination:
//   rtl/video/mcr68_video_timing.sv, mcr68_gfx_rom_sim.sv, mcr68_tilemap.sv,
//   mcr68_sprites.sv, mcr68_colormix.sv.
//
// Port-interface mismatches found and fixed during this integration pass
// (see each file's own header for the full derivation):
//  A. mcr68_gfx_rom_sim.sv PORT 2 (sprite/gfx2 ROM) originally exposed a
//     raw gfx2_byte[1:0]-in/gfx2_data[31:0]-out port built on an assumed
//     BIT-PLANAR packing (1 bit/column/plane spread across a byte) --
//     flagged in its own header as unconfirmed. mcr68_sprites.sv, written
//     in parallel, independently assumed a completely different abstracted
//     req/ack + gfx2_pens[127:0] interface. Neither was fully correct.
//     Re-derived directly from mcr68.cpp's mcr68_sprite_layout and
//     drawgfx.cpp's gfx_element::decode() (the actual plane->pen-bit
//     weighting, NOT just readbit()'s MSB-first bit order -- decode()
//     assigns plane 0 -> pen bit 3 (MSB), not bit 0 as a first read of
//     readbit() alone would suggest): gfx2 pens are NIBBLE-packed (all 4
//     bitplanes of one pixel share one nibble of one ROM byte), with the
//     two bit-order reversals (readbit's MSB-first, decode's plane
//     weighting) exactly cancelling -- pen = nibble, unmodified, no
//     reversal. mcr68_gfx_rom_sim.sv PORT 2 was rewritten to this
//     corrected math AND to mcr68_sprites.sv's already-written interface
//     shape (gfx2_code/gfx2_row/gfx2_req/gfx2_ack/gfx2_pens[127:0]) --
//     mcr68_sprites.sv itself needed no changes. PORT 1 (tile/gfx1 ROM)
//     was independently re-derived the same way and found to already be
//     CORRECT as originally written -- not touched.
//  B. mcr68_tilemap.sv's own header flags an integration item: its 2-cycle
//     VRAM-fetch FSM (needed because rtl/mcr68_mem_sim.sv's vram_rd port is
//     single-byte, and a 16-bit tile word needs 2 sequential byte reads)
//     drops tm_valid low for 2 `clk` cycles at each tile-column/row
//     boundary, and mcr68_colormix.sv has no tm_valid gating input at all.
//     Resolved WITHOUT touching either module's RTL: the video pipeline
//     runs on the free-running `clk` while pixel_x/pixel_y only advance
//     once per `ce_dot` pulse (DOT_CLK_HZ << CLK_HZ, ~10 clk/pixel at the
//     default rates), so a tile boundary's 2-cycle fetch is a small
//     fraction of one pixel's ~10-cycle dwell time. sim/sim_mcr68_visual.cpp
//     (the new PPM-capturing harness) samples r/g/b synchronized to
//     ce_dot -- i.e. only after a full pixel dwell has elapsed since the
//     last sample, comfortably after any same-pixel fetch has completed --
//     so the transient stale window is never actually sampled into the
//     framebuffer. Documented here as the resolution to that module's own
//     explicitly-flagged "not silently worked around" item.
//  C. The sprite RAM read path is now a packed descriptor interface:
//     `sprite_desc_addr`/`sprite_desc_data` in the memory modules and
//     `spriteram_desc_addr`/`spriteram_desc_data` at the renderer boundary.
//     CPU byte access remains compatible with the original sprite window,
//     while the renderer gets one atomic descriptor per slot.
// All other cross-module port shapes (mcr68_tilemap.sv's tm_pen/
// tm_color_bank/tm_category outputs, mcr68_sprites.sv's sp_lo_*/sp_hi_*
// outputs, mcr68_colormix.sv's corresponding inputs) already matched
// byte-for-byte on inspection -- no changes needed there.
//
// -----------------------------------------------------------------------------
// Documented, NOT schematic/PLD-proven assumptions made in this file
// (evidence tier: mame_compatible / self-consistent derivation only, per
// CLAUDE.md's "Evidence order" -- flag every one of these before trusting
// it as hardware truth):
//
//  1. Video timing totals (H_TOTAL=640, V_TOTAL=520; 512x480 visible,
//     9.984 MHz dot clock -> 15.6 kHz H, exactly 30.00 Hz V). This is the plan's own
//     "self-consistent real-hardware derivation" from mcr68.cpp:1231-1236
//     (which gives only the 512x480 *visible* area and 30 Hz refresh, no
//     screen_raw_params) and matches core-debug.toml's [video] section
//     verbatim. mcr68.cpp itself gives no total-dots/total-lines figures,
//     so this is NOT PCB-proven -- treat any future schematic/PLD evidence
//     as authoritative over it. NOTE: the integration task that produced
//     this file described the target as "512x480 total" -- that figure is
//     actually the plan's *visible* resolution; the plan's own totals
//     (640x520, with 128 dots / 40 lines of blanking) are used here instead
//     because they are what makes vblank_pulse/hsync_pulse land at the
//     documented ~30.05 Hz / 15.625 kHz rates. Flagged explicitly in the
//     completion report.
//  2. CLK_HZ (default 100,000,000) is an arbitrary simulation/system clock
//     for this Verilator bring-up model -- nothing in the plan specifies a
//     board `clk_sys` rate for this core yet (no sys_top/PLL integration in
//     this phase). cpu_ce, eclk_en and ce_dot are generated from it via
//     exact-rate phase accumulators (see below); the testbench must drive
//     `clk` at (or an override of) this nominal rate for the derived
//     enables to hit their documented target frequencies. This is a
//     Phase-2-bring-up convenience, not a claim about the real board's PLL.
//  3. Interrupt priority arbitration: MCR-68k's two autovectored interrupt
//     sources (PTM at level 2, "493" at level 1) are not known from any
//     surveyed source to share a diode/resistor priority-encoder network
//     mapping onto the shared 3-bit IPL bus (mcr68.cpp only installs two
//     independent line-level device inputs -- MAME's own bus model doesn't
//     need physical IPL-bus arbitration). Since a real 68000 IPL bus can
//     only present one encoded level at a time, this module arbitrates by
//     always presenting the higher pending level (PTM/level 2 over
//     493/level 1) when both are asserted simultaneously -- the standard
//     assumption for this class of board and the same choice MAME's own
//     interrupt controller effectively makes by delivering the higher
//     level's autovector first. Flagged as mame_compatible, not schematic-
//     proven.
//  4. Watchdog reset stretch length: mcr68_io.sv's wdog_trip is documented as
//     a single clk-wide pulse that "the integrator" must stretch for a clean
//     FX68K reset. MAME's watchdog model has no analog to a physical reset
//     pulse width, so the figure comes from the MC68000 datasheet instead:
//     a non-power-up RESET must be held for at least FOUR clock periods.
//     CORRECTED 2026-09-12 (audit finding CPU-A6): the stretch used to be a
//     fixed count of CLK_HZ cycles (WDOG_RESET_CYCLES, default 16), which at
//     the production 50 MHz / 7,723,800 Hz ratio is 320 ns = only 2.47 68000
//     clock periods -- below the datasheet minimum, i.e. intermittent hangs
//     after a watchdog trip. The stretch now counts cpu_ce pulses, which makes
//     it independent of CLK_HZ and of CPU_HZ; WDOG_RESET_CYCLES is retired.
//  5. DTACK timing: a flat one-wait-state ack (asserted on the first
//     cpu_ce edge after AS_n asserts, for every decoded AND undecoded
//     address alike), matching rtl/mcr68_mem_sim.sv's own documented scope
//     ("SIMULATION / VERILATOR BRING-UP ONLY... should be able to ack in
//     0-1 cycles since they're plain RAM/ROM, not SDRAM yet"). No PLD/
//     schematic evidence exists for real board DTACK timing (see that
//     file's header and mcr68_addr_decode.sv's header) -- revisit when
//     SDRAM lands, per jtframe_68kdtack-style real wait-state generation.
//  6. Sound board reset domain.
//
//     CORRECTED 2026-09-12 (audit findings CPU-A4 / SND-04, audit section 3):
//     both sound boards' `rst` ports are now driven from the watchdog-stretched
//     `cpu_rst`, and the ctrl_word latch is cleared on raw `rst` only. The
//     previous text (kept below for the record) argued the opposite from a
//     reading of MAME that does not survive checking the watchdog device
//     itself: MAME's watchdog does NOT reset one CPU, it schedules a whole-
//     machine SOFT RESET (watchdog.cpp:145-150), which runs device_reset() on
//     every device including midway_sounds_good_device
//     (midway_sound.cpp:647) and the Williams BG board. Conversely
//     `m_control_word` (mcr68.cpp:134,187-191) is a plain member that
//     machine_reset() never re-zeroes, so it SURVIVES that soft reset. The RTL
//     had both axes inverted. Labelled INFERRED: no schematic evidence exists
//     for the RESET~ net's fan-out to the sound connector on any of the four
//     boards, so MAME is the governing evidence here (tier 5) and a future
//     schematic/PCB measurement may overturn it.
//
//     SUPERSEDED (kept for provenance): "rtl/snd/mcr68_sound_board.sv's `rst`
//     port (its "system/global reset", see that file's own header) is wired to
//     this module's raw external `rst`, NOT the watchdog-stretched
//     `cpu_rst` used by the main 68000/PTM/IO block. Justification:
//     mcr68.cpp's watchdog device (WDOG_LIMIT vblank counts) is wired only
//     to the MAIN board's CPU in both MAME's driver and the schematic --
//     midway_sound.cpp's midway_sounds_good_device::device_reset()
//     (line 647) is invoked by MAME's own whole-*machine* reset (which
//     resets every device, main and sound alike, simultaneously and
//     independently) with no watchdog-device coupling anywhere in
//     midway_sound.cpp. Tying the sound board's `rst` to `cpu_rst` would
//     incorrectly reset the sound board every time the main board's
//     watchdog trips -- a coupling that exists nowhere in MAME or the
//     documented schematic. The sound board's `rst` therefore stays the raw
//     system reset."
//
//     SUPERSEDED 2026-09-11: this block previously also claimed that
//     control-word bit 5 is the sound board's main-CPU-controlled reset, and
//     that the ctrl_word latch's 16'h0000 power-up default (board held off)
//     was evidenced by the captured `0x00` then `0x20` boot writes. Measuring
//     the actual times proved that reading cannot be right: the game leaves
//     only 2340.9 ms between the `0x20` write and its first sound command,
//     while the Sounds Good self test needs 2760.1 ms, so a reset there loses
//     the first command every power-up, and the same routine's second
//     occurrence one second into gameplay produced 8.9 s of silence. Bit 5 is
//     no longer wired to the sound CPU's reset for either Sounds Good title;
//     see the GAME_XENOPHOB case below and
//     docs/debug/20260911_xenophobe_sound_board_reset_music_cutout.md.
// -----------------------------------------------------------------------------
// Phase 5 video-adapter pass (this task): made this module's video output
// cleanly consumable by sys/arcade_video.v + sys/video_mixer.sv (the
// vendored, READ-ONLY MiSTer framework modules a future top level will
// instantiate) without touching either of them or any existing Verilator
// harness.
//
// Adapter approach chosen: two new output ports added DIRECTLY to this
// module (video_hsync_o/video_vsync_o) rather than a separate
// rtl/mcr68_video_adapter.sv wrapper. Justification: every piece needed was
// already computed one level down and just not exposed --
// mcr68_video_timing.sv already emits hsync_n/vsync_n (composite-sync-style,
// active low) into local wires (video_hsync_n/video_vsync_n) that were
// wired to u_video_timing but never used anywhere else in this file. The
// only real gap was a plain inversion (composite-sync active-low ->
// video_mixer.sv's documented "Positive pulses" active-high contract) and
// two new ports to carry it out -- a 4-line, purely additive change with no
// new module, no new state, and nothing to reconcile between two
// independently-written files. A wrapper module would have added an extra
// port-forwarding layer for zero benefit here; that pattern is reserved for
// cases needing real logic (packing, CDC, a state machine), not for
// forwarding two `assign`s.
//
// Confirmed already-compatible, no change needed:
//  - ce_pix: video_ce_dot (already a top-level output) IS the ce_pix arcade_
//    video/video_mixer.v expect -- a clk-domain pulse, one per pixel dwell,
//    exactly the "input pixel clock or clock_enable" contract in
//    video_mixer.sv's own port comment. No separate ce_pix generator needed.
//  - HBlank/VBlank polarity: video_hblank_o/video_vblank_o (pre-existing
//    Phase 3 ports) are already active-high level signals ("blanked=1"),
//    matching video_mixer.sv's own "Positive pulses" HBlank/VBlank contract
//    exactly -- no inversion needed, unlike hsync/vsync above.
//  - RGB depth/packing: video_r/g/b (pre-existing Phase 3 ports, driven by
//    mcr68_colormix.sv's already-8-bit-per-gun xRBG_333->pal3bit expansion)
//    are exactly what arcade_video.v's DW=24 path expects once packed as
//    RGB_in={video_r,video_g,video_b} at the point of instantiation -- that
//    packing is a single top-level `assign`/concatenation belonging to the
//    future sys-integration top level (out of scope here, no core RTL
//    change needed), not something this module or an adapter must do.
//  - dbg_audio_out: as of the "Williams background sound board" integration
//    pass (see that block comment near the sound-board instantiations below),
//    this is now a runtime prof_rt.snd_williams_bg mux between
//    rtl/snd/mcr68_sound_board.sv's `audio_out` (Xenophobe/Blasted/
//    Xenophobe/Blasted) and rtl/snd/williams_bg/williams_bg.sv's `audio_out` (Arch
//    Rivals/Pigskin), not a straight passthrough of the former alone.
//    Both sides are already `signed [15:0]` at SAMPLE_HZ=48000 (each
//    module's own SAMPLE_HZ parameter, matched to sys/audio_out.sv's fixed
//    AUDIO_RATE per that module's own header comment) -- exactly the
//    format/rate sys/audio_out.sv's `core_l`/`core_r` inputs expect
//    (is_signed=1). Mono source: a future top level ties
//    `core_l=core_r=dbg_audio_out`, again a single top-level wire fan-out,
//    not an RTL change here. No adapter needed.
//
// None of the above required touching sim/tb_mcr68_headless.sv,
// sim/tb_mcr68_visual.sv, or sim/tb_mcr68_sound_headless.sv: all three use
// named-port instantiation of mcr68_main_board/mcr68_sound_board and
// connect only the pre-existing ports they already used, so two new
// unconnected output ports are a no-op for them (verified by rebuilding all
// three, see the completion report for this task).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none
// mcr68_game_e / mcr68_profile_t -- per-title profile contract.
/* verilator lint_off IMPORTSTAR */
import mcr68_game_pkg::*;
/* verilator lint_on IMPORTSTAR */

module mcr68_main_board #(
    parameter string       MAINCPU_ROM_FILE   = "",         // see rtl/mcr68_mem_sim.sv
    parameter string       GFX1_ROM_FILE      = "",         // see rtl/video/mcr68_gfx_rom_sim.sv
    parameter string       GFX2_ROM_FILE      = "",         // see rtl/video/mcr68_gfx_rom_sim.sv
    parameter string       SNDCPU_ROM_FILE    = "",         // see rtl/snd/mcr68_snd_mem_sim.sv,
                                                              // forwarded through rtl/snd/mcr68_sound_board.sv
    parameter string       BGCPU_ROM_FILE     = "",         // see rtl/snd/williams_bg/williams_bg_mem_sim.sv,
                                                              // forwarded through the williams_bg instance below
                                                              // (Arch Rivals / Pigskin's Williams S11/S11C
                                                              // background board -- see the "Williams background
                                                              // sound board" integration note below)
    parameter int unsigned CLK_HZ             = 100_000_000, // sim system clock, see assumption 2 above
    parameter int unsigned CPU_HZ             = 7_723_800,   // MAME's fudged main-board 68000 rate (mcr68.cpp:1192-1222)
    // PTM/E-clock rate is normally CPU/10.  Keep it independently overrideable
    // for the evidence lane: MAME's 68000 bus cadence and its PTM clock are
    // separate contracts when the FX68K model is run at the real 8 MHz board
    // rate (the default remains bit-identical to CPU_HZ/10).
    parameter int unsigned E_CLOCK_HZ         = CPU_HZ / 10,
    // MAME's Xenophobe screen is locked at 30.000 Hz (verified live via
    // screen refresh/scan timing).  With the retained 640x520 raster this
    // requires a 9.984 MHz dot clock; 10 MHz would run at 30.048 Hz and
    // accumulates nearly one whole animation frame of drift by gameplay
    // frame 508.
    parameter int unsigned DOT_CLK_HZ         = 9_984_000,
    parameter int          H_TOTAL            = 640,         // 512 visible + 128 blank
    parameter int          V_TOTAL            = 520,         // 480 visible + 40 blank
    parameter int          WDOG_LIMIT         = 8,           // mcr68.cpp:1225, passed through to mcr68_io
    parameter int          IRQ1_OFFSET_ECLKS  = 256 + 16,    // mcr68.cpp:1859, passed through to mcr68_io
    // PCB-accurate "493" generation, passed through to mcr68_io (see that
    // module's own header). Default 0/493 -- OFF by default, so the
    // MAME-diff-verified E-clock-offset scheme above remains this module's
    // behaviour unless a hardware-profile instantiation opts in.
    parameter bit          USE_SCANLINE_493   = 1'b0,
    parameter int          IRQ493_LINE        = 493,
    // RETIRED 2026-09-12 (audit finding CPU-A6): the watchdog reset stretch is
    // no longer a raw clk-cycle count -- it counts cpu_ce pulses, so it is
    // correct at any CLK_HZ/CPU_HZ ratio. Kept only so existing
    // instantiations that still pass it keep elaborating; it is unused.
    /* verilator lint_off UNUSEDPARAM */
    parameter int          WDOG_RESET_CYCLES  = 16,          // unused, see assumption 4
    /* verilator lint_on UNUSEDPARAM */
    // Diagnostic-only falsification knob.  When enabled, combinational read
    // cycles are acknowledged once AS and a byte strobe are visible,
    // matching FX68K's PHI2 sampling point.  Ordinary writes use the
    // strobe-qualified completion below in the normal path; SDRAM ROM cycles
    // and FC=111 IACK cycles remain on the registered path.
    parameter bit          FAST_READ_DTACK    = 1'b0,
    // ---- Phase 5 integration point (this task) ----
    // 0 (default): byte-for-byte the pre-existing sim-only behaviour --
    // main-CPU program ROM is served by u_mem's (mcr68_mem_sim) internal
    // $readmemh array, exactly as every existing Verilator harness
    // (sim/tb_mcr68_headless.sv, tb_mcr68_visual.sv, tb_mcr68_sound_headless.sv)
    // already instantiates it, unmodified. Those harnesses never set this
    // parameter, so their elaborated behaviour is unaffected by anything
    // below -- verified by rebuilding all three (see completion report).
    // 1: main-CPU program ROM reads are routed out to mainrom_req/addr/
    // data/ack instead (see those ports below), for a real SDRAM-backed
    // synthesis target (rtl/mem/mcr68_sdram.sv + mcr68_rom_loader.sv +
    // mcr68_rom_fabric.sv, wired up in Arcade-MCR68.sv). u_mem is still
    // instantiated in this mode (its rom_cs input is simply gated off, see
    // below) so no change is needed to rtl/mcr68_mem_sim.sv itself.
    // NOTE -- this parameter DOES also gate both sound boards' own program
    // ROM (rtl/snd/mcr68_sound_board.sv's sndrom_req/addr/data/ack and, as
    // of the "Williams background sound board" integration pass, rtl/snd/
    // williams_bg/williams_bg.sv's bgrom_req/addr/data/ack -- see the sound-
    // board instantiations below), each a separate CPU/bus entirely from the
    // main 68000. NOT covered by this parameter, flagged rather than
    // guessed at: the gfx1/gfx2 tile/sprite ROMs (rtl/video/
    // mcr68_gfx_rom_sim.sv, consumed combinationally, same-cycle, by
    // mcr68_tilemap.sv/mcr68_sprites.sv -- bridging those onto multi-cycle
    // SDRAM fetches needs a real fetch/cache engine that does not exist yet
    // anywhere in this repo, per mcr68_sdram.sv's own header ("a future
    // tile/sprite fetch engine, not part of this task"). Forcing that here
    // would touch the video pixel pipeline's timing model, risking the
    // frame-300 pixel-exact regression gate for no working benefit -- left
    // for a dedicated future phase instead of a partial/incorrect stand-in.
    //
    // Resolved: bgrom_req/addr/data/ack now reach the fabric's dedicated
    // raw-byte `bg` client; unlike the 68000 `snd` client it does not swap
    // the two SDRAM byte lanes.
    // rtl/mem/mcr68_rom_fabric.sv (the shared SDRAM read arbiter instantiated
    // in Arcade-MCR68.sv) now has that client. The existing `snd` client
    // applies an unconditional 68000-word-swap reassembly
    // (`{p1_data[7:0], p1_data[15:8]}`) that is correct for mcr68_sound_
    // board's sg:cpu ROM (staged in the .mra as an `interleave output="16"`
    // block) but WRONG for williams_bg's bg:cpu ROM (staged as a flat,
    // non-interleaved raw byte stream -- confirmed directly against
    // mra/Arch Rivals*.mra's and mra/Pigskin*.mra's own `<rom index="1">`
    // blocks). The dedicated `bg` client provides the same raw-byte,
    // address-LSB-lane-select reassembly and shares the fabric's p1 SDRAM
    // port with `snd` at no extra cost because sg:cpu and bg:cpu are
    // mutually exclusive per title; the loader's
    // header documents the shared index-1 region contract for both layouts.
    parameter bit          SDRAM_ROM          = 1'b0,

    // Elaboration-time title select. Sets graphics region sizes and sprite
    // geometry -- a memory's depth and a port's width are NOT runtime
    // selectable, so this is separate from the runtime `game` input (which
    // drives address decode and I/O only). One bitstream per title, or
    // elaborate the union for a combined build.
    parameter mcr68_game_e GAME_STATIC         = GAME_XENOPHOB,

    // Derived from GAME_STATIC -- DO NOT override at instantiation.
    // These must be declared here (not in the module body) because the port
    // widths below reference them. They are `parameter`, not `localparam`,
    // because Quartus 17 rejects `localparam` in a parameter port list even
    // though IEEE 1800 permits it.
    parameter int GFX1_BYTES  = mcr68_gfx1_bytes(GAME_STATIC),      // 'h10000 / 'h20000
    parameter int GFX2_BYTES  = mcr68_gfx2_bytes(GAME_STATIC),      // 'h40000 / 'h80000
    parameter int GFX1_CODE_W = $clog2(GFX1_BYTES / 32),            // 11 / 12
    parameter int GFX2_CODE_W = $clog2(GFX2_BYTES / 512)            //  9 / 10
    // NOTE: sprite clip / xoffset / slots were derived from GAME_STATIC here
    // and passed as mcr68_sprites parameters. They are NOT build geometry --
    // they are per-title BEHAVIOUR (mcr68_common_init() args and the
    // spriteram window size), so in a union build (GAME_STATIC=GAME_PIGSKIN,
    // chosen only to size the gfx arrays) every title silently ran with
    // pigskin's clip=16 / xoffset=0 / slots=256. They are now runtime inputs
    // of mcr68_sprites, driven from `prof_rt` below -- the same split already
    // used for mcr68_tilemap's gfx1_small and the PTM byte lane.
    // (mcr68_sprite_clip/_xoffset/_slots remain in mcr68_game_pkg for any
    // single-title elaboration that wants the compile-time value.)
) (
    input  logic        clk,
    input  logic        rst,           // synchronous, active-high external/system reset

    // Selected title. Encoding MUST match mcr68_game_e in
    // rtl/mcr68_game_profile.svh (0=XENOPHOB .. 4=PIGSKIN). Static
    // configuration held stable while the game is out of reset (profile
    // contract rule 2). SystemVerilog has no default for an input port, so
    // every harness MUST connect .game(3'd0) explicitly to keep Xenophobe
    // behaviour -- "unconnected means zero" is NOT true, it elaborates to 'z.
    input  logic [2:0]  game,

    // Freeze the GAME while high (OSD pause). Gates the CPU execution enable,
    // the 68000 E-clock (so the PTM and the 493 interrupt stop with it) and
    // the watchdog's vblank tick. Video timing and scanout are deliberately
    // NOT gated: the framebuffer keeps being scanned out, so the paused frame
    // stays on screen. Freezing the E-clock without also freezing the watchdog
    // would let it trip after 8 vblanks and reset the game mid-pause.
    input  logic        pause,

    // ---- raw board inputs, passed straight through to mcr68_io's mux ----
    // Active-low; bit tables documented in rtl/mcr68_io.sv's header. This
    // module performs no interpretation of these bits, per task scope.
    input  logic [15:0] in0_pins,
    input  logic [15:0] in1_pins,
    input  logic [15:0] dsw_pins,

    // ---- SDRAM-backed main-CPU program-ROM port (Phase 5 integration
    // point). Meaningful ONLY when SDRAM_ROM=1; every existing sim-harness
    // instantiation leaves SDRAM_ROM at its default 0 and these ports
    // simply float unconnected (safe -- see the SDRAM_ROM parameter
    // comment above and this file's own header precedent for two other
    // additively-added, harness-safe output ports). Mirrors rtl/mem/
    // mcr68_rom_fabric.sv's `main` client port contract exactly (word
    // address 0..0x1FFFF, single-outstanding level-held req, 1-cycle ack
    // pulse) so this is a direct wire-up at the integration site, no glue
    // logic needed there.
    output logic         mainrom_req,
    output logic [16:0]  mainrom_addr,
    input  logic [15:0]  mainrom_data,
    input  logic         mainrom_ack,

    output logic         sndrom_req,
    output logic [16:0]  sndrom_addr,
    input  logic [15:0]  sndrom_data,
    input  logic         sndrom_ack,

    // ---- Williams S11/S11C background-sound-board program-ROM fetch port
    // (Arch Rivals / Pigskin's "bg:cpu" ROM, see the "Williams background
    // sound board" integration note below). Distinct shape from sndrom_*
    // above -- williams_bg's CPU is an 8-bit-bus MC6809E, not a 16-bit
    // 68000, so this is a RAW BYTE fetch (byte address 0..0x8FFFF, 8-bit
    // data), not the word-swapped 16-bit fetch sndrom_* carries. Meaningful
    // only when SDRAM_ROM=1, mirroring sndrom_*/mainrom_*'s own contract
    // and float-safety precedent (see those ports' comments above).
    output logic         bgrom_req,
    output logic [18:0]  bgrom_addr,
    input  logic [7:0]   bgrom_data,
    input  logic         bgrom_ack,

    // ---- NVRAM save/load port (Arch Rivals 4B battery-backed work-RAM low
    // byte -- see mcr68_mem_hw.sv's own header). Meaningful only when
    // SDRAM_ROM=1 (the sim RAM path has no persistence); float-safe defaults
    // so an existing instantiation that connects none of these keeps its
    // previous behaviour, matching this file's other optional-port precedent.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic         nvram_wr,
    input  logic [12:0]  nvram_addr,
    input  logic [7:0]   nvram_din,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [7:0]   nvram_dout,

    output logic [GFX1_CODE_W-1:0] ext_gfx1_code,
    output logic [2:0]   ext_gfx1_row,
    output logic [1:0]   ext_gfx1_pair,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [3:0]   ext_gfx1_pen0,
    input  logic [3:0]   ext_gfx1_pen1,
    output logic [GFX2_CODE_W-1:0] ext_gfx2_code,
    output logic [4:0]   ext_gfx2_row,
    output logic         ext_gfx2_req,
    input  logic         ext_gfx2_ack,
    input  logic [127:0] ext_gfx2_pens,
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- debug/trace outputs for the Verilator differential-testing harness ----
    output logic [23:1] dbg_cpu_addr,
    output logic [15:0] dbg_cpu_dout,     // CPU write-data bus
    output logic [15:0] dbg_cpu_din,      // CPU read-data bus (post-mux)
    output logic         dbg_as_n,
    output logic         dbg_uds_n,
    output logic         dbg_lds_n,
    output logic         dbg_rw_n,
    output logic         dbg_dtack_n,
    output logic [2:0]   dbg_fc,
    output logic         dbg_ptm_irq,
    output logic         dbg_irq1,
    output logic         dbg_wdog_trip,
    output logic         dbg_vblank_pulse,
    output logic         dbg_hsync_pulse,
    output logic [31:0]  dbg_frame_counter,
    output logic [15:0]  dbg_scanline,        // current v_count, for trace enrichment (see below)
    output logic [31:0]  dbg_pc,              // main CPU's internal PC register (fx68k PcH:PcL),
                                               // debug-only passthrough -- see mcr68_m68k.sv/fx68k.sv
    output logic [31:0]  dbg_d7,
    output logic [7:0]   dbg_ccr,
    output logic [15:0]  dbg_sr,
    output logic [2:0]   dbg_iipl,
    output logic [2:0]   dbg_ripl,
    output logic         dbg_ipl_stable,
    output logic         dbg_ipl_comp,
    output logic         dbg_int_pend,
    output logic [2:0]   dbg_inl,
    output logic         dbg_iac,

    // ---- Phase 3 video pipeline output, for the PPM-capturing harness ----
    // Sample r/g/b synchronized to video_ce_dot -- see integration note B
    // above for why that sampling discipline matters.
    output logic         video_ce_dot,
    output logic         video_hblank_o,
    output logic         video_vblank_o,
    // video_hsync_o/video_vsync_o (Phase 5 addition, see file header
    // "Phase 5 video-adapter" note): POSITIVE (active-high) sync pulses,
    // matching sys/video_mixer.v's own "Positive pulses" contract for its
    // HSync/VSync inputs -- i.e. wire these directly, no external
    // inversion needed. Derived from u_video_timing's composite-sync-style
    // ACTIVE-LOW hsync_n/vsync_n (see mcr68_video_timing.sv), which were
    // already computed internally but never exposed as a top-level port
    // before this change.
    output logic         video_hsync_o,
    output logic         video_vsync_o,
    output logic [8:0]   video_pixel_x_o,
    output logic [8:0]   video_pixel_y_o,
    output logic [7:0]   video_r,
    output logic [7:0]   video_g,
    output logic [7:0]   video_b,
    output logic         dbg_tm_valid,
    output logic         dbg_sp_line_busy,
    output logic         dbg_sp_build_overrun,
    // ---- extra video-pipeline debug taps (bring-up only) ----
    output logic [3:0]   dbg_tm_pen,
    output logic         dbg_sp_lo_valid,
    output logic         dbg_sp_hi_valid,
    output logic [5:0]   dbg_palette_rd_addr,
    output logic [15:0]  dbg_palette_rd_data,
    output logic [10:0]  dbg_vram_rd_addr,
    output logic [7:0]   dbg_vram_rd_data,

    // ---- Sound board (rtl/snd/mcr68_sound_board.sv) integration outputs ----
    // dbg_audio_out is the primary deliverable of this integration pass:
    // this phase is simulation-only, Verilator-verified (no sys/
    // audio-mixing integration -- out of scope, see file header), so a
    // future harness can sample/capture it.
    // The rest are additive debug taps (mirroring this file's existing
    // dbg_* convention) so a harness can distinguish "the main board wrote
    // a command" from "the sound board actually reacted" without reaching
    // into a sub-instance.
    output logic signed [15:0] dbg_audio_out,
    output logic [31:0]        dbg_snd_pc,
    output logic                dbg_snd_irq4,
    output logic [9:0]         dbg_snd_dac10,
    output logic [3:0]         dbg_snd_sndsel,
    output logic                dbg_snd_sint,
    output logic                dbg_snd_ctrl_reset_n,
    // Optional sound-CPU bus taps for the integrated headless differential
    // harness. These are observation-only forwards from mcr68_sound_board;
    // they do not feed any functional path or alter the sound-board contract.
    output logic [23:1]         dbg_snd_cpu_addr,
    output logic [15:0]         dbg_snd_cpu_dout,
    output logic [15:0]         dbg_snd_cpu_din,
    output logic                dbg_snd_as_n,
    output logic                dbg_snd_uds_n,
    output logic                dbg_snd_lds_n,
    output logic                dbg_snd_rw_n,
    output logic                dbg_snd_dtack_n,
    output logic [2:0]          dbg_snd_fc,
    output logic                dbg_snd_ca2,
    // Observation-only forward of the Sounds Good DAC filter's own
    // SAMPLE_HZ sample-valid strobe (mcr68_snd_dac.sv's sample_o).  This is
    // the DUT's authentic audio sample event, required by mister-mame-diff's
    // "capture audio only on the DUT's authentic sample/valid strobe" rule so
    // the headless harness can emit a raw PCM sample ledger instead of a
    // host-loop-cadence approximation.  Purely additive: no functional path
    // reads it.
    output logic                dbg_snd_sample_tick
);

    // =========================================================================
    // Clock-enable generation: exact-rate phase accumulators from `clk`.
    // Standard "accumulate the numerator, subtract the denominator on
    // overflow" NCO divider -- deterministic, no long-term drift, and
    // exact whenever CPU_HZ/DOT_CLK_HZ divide CLK_HZ's timebase evenly over
    // their repeat period (they need not be integer divisors of CLK_HZ).
    // =========================================================================
    localparam int unsigned E_CLK_HZ = E_CLOCK_HZ; // 68000 E-clock = CPU/10 (mcr68.cpp:1227-1228), 772_380 Hz nominal

    // cpu_ce: pulses at 2x CPU_HZ -- mcr68_m68k.sv internally alternates this
    // onto enPhi1/enPhi2 (see that file's header).
    logic [31:0] cpu_ce_acc;
    logic        cpu_ce;
    logic [31:0] cpu_ce_step;
    always_comb cpu_ce_step = 32'(2 * CPU_HZ);
    always_ff @(posedge clk) begin
        if (rst) begin
            cpu_ce_acc <= '0;
            cpu_ce     <= 1'b0;
        end else if (pause) begin
            // Hold: freeze both accumulator and output so the CPU resumes on
            // exactly the phase it stopped on.
            cpu_ce_acc <= cpu_ce_acc;
            cpu_ce     <= 1'b0;
        end else if (cpu_ce_acc + cpu_ce_step >= 32'(CLK_HZ)) begin
            cpu_ce_acc <= cpu_ce_acc + cpu_ce_step - 32'(CLK_HZ);
            cpu_ce     <= 1'b1;
        end else begin
            cpu_ce_acc <= cpu_ce_acc + cpu_ce_step;
            cpu_ce     <= 1'b0;
        end
    end

    // eclk_en: pulses at E_CLK_HZ (CPU/10) -- feeds the PTM's `ena` and
    // mcr68_io's `eclk_en` (both need the same 68000 E-clock reference).
    logic [31:0] eclk_acc;
    logic        eclk_en;
    always_ff @(posedge clk) begin
        if (rst) begin
            eclk_acc <= '0;
            eclk_en  <= 1'b0;
        end else if (pause) begin
            eclk_acc <= eclk_acc;
            eclk_en  <= 1'b0;
        end else if (eclk_acc + 32'(E_CLK_HZ) >= 32'(CLK_HZ)) begin
            eclk_acc <= eclk_acc + 32'(E_CLK_HZ) - 32'(CLK_HZ);
            eclk_en  <= 1'b1;
        end else begin
            eclk_acc <= eclk_acc + 32'(E_CLK_HZ);
            eclk_en  <= 1'b0;
        end
    end

    // ce_dot: pulses at DOT_CLK_HZ -- drives the scanline/frame counter below.
    logic [31:0] dot_acc;
    logic        ce_dot;
    always_ff @(posedge clk) begin
        if (rst) begin
            dot_acc <= '0;
            ce_dot  <= 1'b0;
        end else if (dot_acc + 32'(DOT_CLK_HZ) >= 32'(CLK_HZ)) begin
            dot_acc <= dot_acc + 32'(DOT_CLK_HZ) - 32'(CLK_HZ);
            ce_dot  <= 1'b1;
        end else begin
            dot_acc <= dot_acc + 32'(DOT_CLK_HZ);
            ce_dot  <= 1'b0;
        end
    end

    // =========================================================================
    // Scanline/frame timing generator. Produces vblank_pulse (one clk-wide
    // pulse, once per frame, at the start of scanline 0 -- "C1 = VSYNC,
    // pulsed once/frame at scanline 0" per the plan) and hsync_pulse (one
    // clk-wide pulse, once per scanline -- "C3 = HSYNC, pulsed once/
    // scanline"). Each pulse is a real 0->1->0 transition on a genuine
    // level signal, not just an abstract strobe: the PTM's C1/C3 inputs
    // need an actual falling edge to register a count (ptm6840.sv counts
    // on the falling edge via a 2-flop synchronizer), and a single-clk-wide
    // active-high pulse supplies exactly that -- one rising edge followed
    // one clk later by the qualifying falling edge, i.e. exactly one count
    // per period, matching "each set_cN(0); set_cN(1) pair yields exactly
    // one count" from the PTM's own header. The same signals also serve
    // directly as mcr68_io's level-checked vblank_pulse/hsync_pulse inputs.
    //
    // Factored out to rtl/video/mcr68_video_timing.sv as a standalone,
    // reusable module (see that file's header for the full derivation and
    // its evidence tiers). This instantiation reproduces the original
    // inline generator's h_count/v_count/vblank_pulse/hsync_pulse timing
    // byte-for-byte -- same H_TOTAL/V_TOTAL, same `rst` (the raw external/
    // system reset, not the watchdog-stretched cpu_rst), same ce_dot gating,
    // same edge alignment. No real pixel output is wired up yet (Phase 3
    // does not exist as a consumer here) -- see file header.
    // =========================================================================
    logic [9:0] v_count;
    logic       vblank_pulse;
    logic       hsync_pulse;
    logic       video_hblank, video_vblank, video_hsync_n, video_vsync_n;
    logic [8:0] video_pixel_x, video_pixel_y;

    mcr68_video_timing #(
        .H_TOTAL  (H_TOTAL),
        .V_TOTAL  (V_TOTAL),
        .H_ACTIVE (512),
        .V_ACTIVE (480)
    ) u_video_timing (
        .clk          (clk),
        .rst          (rst),
        .ce_dot       (ce_dot),
        /* verilator lint_off PINCONNECTEMPTY */
        .h_count      (),
        /* verilator lint_on PINCONNECTEMPTY */
        .v_count      (v_count),
        .hblank       (video_hblank),
        .vblank       (video_vblank),
        .hsync_n      (video_hsync_n),
        .vsync_n      (video_vsync_n),
        .pixel_x      (video_pixel_x),
        .pixel_y      (video_pixel_y),
        .vblank_pulse (vblank_pulse),
        .hsync_pulse  (hsync_pulse)
    );
    // Frame counter, for harness/trace convenience (SunA8bit-style
    // frame_counter, not part of any hardware register).
    logic [31:0] frame_counter;
    always_ff @(posedge clk) begin
        if (rst) frame_counter <= '0;
        else if (vblank_pulse) frame_counter <= frame_counter + 1'b1;
    end

    // =========================================================================
    // CPU bus
    // =========================================================================
    logic [23:1] cpu_addr;      // word address (68000 has no A0 pin)
    logic [15:0] cpu_wdata;     // CPU -> bus (write data, "dout" on mcr68_m68k)
    logic [15:0] cpu_rdata;     // bus -> CPU (read data / muxed, "din" on mcr68_m68k)
    logic        as_n, uds_n, lds_n, rw_n, dtack_n;
    logic        uds_n_decoded, lds_n_decoded;
    logic [2:0]  fc;
    logic [2:0]  ipl_n;
    logic [31:0] cpu_dbg_pc;   // debug-only CPU-state passthrough, see mcr68_m68k.sv
    logic [31:0] cpu_dbg_d7;
    logic [7:0]  cpu_dbg_ccr;
    logic [15:0] cpu_dbg_sr;
    logic [2:0]  cpu_dbg_iipl;
    logic [2:0]  cpu_dbg_ripl;
    logic        cpu_dbg_ipl_stable;
    logic        cpu_dbg_ipl_comp;
    logic        cpu_dbg_int_pend;
    logic [2:0]  cpu_dbg_inl;
    logic        cpu_dbg_iac;

    // ---- watchdog-stretched reset feeding the CPU (see assumption 4) ----
    //
    // The MC68000 datasheet requires RESET to be held for at least FOUR clock
    // periods for a non-power-up reset (`extReset`/`pwrUp` into
    // rtl/cpu/mcr68_m68k.sv).  cpu_ce pulses at 2*CPU_HZ -- mcr68_m68k
    // alternates it onto enPhi1/enPhi2, so TWO cpu_ce pulses are one 68000
    // clock period.  Counting cpu_ce pulses rather than clk cycles makes the
    // hold time independent of CLK_HZ and CPU_HZ, which is the whole point:
    // the previous fixed 16-clk stretch was 2.47 68000 clocks at the
    // production 50 MHz / 7,723,800 Hz ratio (audit finding CPU-A6).
    localparam int WDOG_RST_CPU_CE_PULSES = 10;  // = 5 full 68000 clock periods
    logic wdog_trip;
    logic [4:0] wdog_rst_cnt;
    logic       wdog_rst_active;
    always_ff @(posedge clk) begin
        if (rst) begin
            wdog_rst_cnt    <= '0;
            wdog_rst_active <= 1'b0;
        end else if (wdog_trip) begin
            wdog_rst_cnt    <= 5'(WDOG_RST_CPU_CE_PULSES);
            wdog_rst_active <= 1'b1;
        end else if (wdog_rst_active && cpu_ce) begin
            // Held across an OSD pause: cpu_ce is pause-gated, so the stretch
            // simply resumes with the CPU.  The watchdog cannot trip while
            // paused either (its vblank input is gated at u_io below), so this
            // can only extend a trip that was already in flight.
            if (wdog_rst_cnt <= 5'd1) wdog_rst_active <= 1'b0;
            else                      wdog_rst_cnt    <= wdog_rst_cnt - 1'b1;
        end
    end
    wire cpu_rst = rst | wdog_rst_active;

    mcr68_m68k u_cpu (
        .clk      (clk),
        .rst      (cpu_rst),
        .cpu_ce   (cpu_ce),
        .addr     (cpu_addr),
        .din      (cpu_rdata),
        .dout     (cpu_wdata),
        .as_n     (as_n),
        .uds_n    (uds_n),
        .lds_n    (lds_n),
        .rw_n     (rw_n),
        .dtack_n  (dtack_n),
        .fc       (fc),
        .ipl_n    (ipl_n),
        // VPA is an optional 68000 status output; this board has no
        // autovector/VPA consumer beyond the already-wired DTACK path.
        /* verilator lint_off PINCONNECTEMPTY */
        .vpa_n    (),
        /* verilator lint_on PINCONNECTEMPTY */
        .dbg_pc   (cpu_dbg_pc),
        .dbg_d7   (cpu_dbg_d7),
        .dbg_ccr  (cpu_dbg_ccr),
        .dbg_sr   (cpu_dbg_sr),
        .dbg_iipl (cpu_dbg_iipl),
        .dbg_ripl (cpu_dbg_ripl),
        .dbg_ipl_stable (cpu_dbg_ipl_stable),
        .dbg_ipl_comp (cpu_dbg_ipl_comp),
        .dbg_int_pend (cpu_dbg_int_pend),
        .dbg_inl (cpu_dbg_inl),
        .dbg_iac (cpu_dbg_iac)
    );

    // =========================================================================
    // Address decode -- byte address post global_mask(0x1fffff) is
    // {cpu_addr[20:1], 1'b0} (the 68000 has no A0 pin, so the LSB of the
    // reconstructed byte address is always 0).
    // =========================================================================
    // Runtime gfx1 element count for the ACTIVE title (see mcr68_tilemap's
    // gfx1_small port). Elaboration sizes the arrays; this selects behaviour.
    /* verilator lint_off UNUSEDSIGNAL */
    mcr68_profile_t prof_rt;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb prof_rt = mcr68_profile(mcr68_game_e'(game));
    wire gfx1_small_rt = (prof_rt.gfx1_size == GFX_64K);
    wire gfx2_small_rt = (prof_rt.gfx2_size == GFX_256K);

    // Runtime sprite geometry for the ACTIVE title -- see the note in the
    // parameter list above and mcr68_sprites.sv's "RUNTIME sprite geometry"
    // port comment. Taken as PLAIN (unsigned) bit vectors here; mcr68_sprites
    // sign-extends the xoffset explicitly from bit 3, so the signedness of
    // this connection is deliberately not load-bearing (the packed-struct
    // field's declared signedness is not portable across the two front ends
    // this project builds with -- mcr68_game_pkg makes the same caveat).
    wire [5:0]  spr_clip_rt  = prof_rt.sprite_clip;     // 0 / 16
    wire [3:0]  spr_xoff_rt  = prof_rt.sprite_xoffset;  // 0 / -4 (two's complement)
    wire [10:0] spr_slots_rt = prof_rt.sprite_slots;    // 512 / 256

    logic [20:0] byte_addr;
    assign byte_addr = {cpu_addr[20:1], 1'b0};

    logic cs_rom, cs_workram, cs_videoram, cs_auxram, cs_spriteram, cs_paletteram;
    logic cs_ptm, cs_watchdog, cs_soundio, cs_in0, cs_in1, cs_dsw;

    // Pigskin-only chip selects and the profile-derived decode attributes.
    // Under MAP_MCR68 (xenophob/blasted/archrivl) the three pigskin
    // selects are held low by the decoder itself.
    logic cs_pigskin_port1, cs_pigskin_port2, cs_protect;
    logic ptm_lane_upper;

    mcr68_addr_decode #(
        // RUNTIME_GAME_SEL=1 is what makes the `game` port take effect at all;
        // with the default 0 the port is IGNORED and GAME_STATIC is used.
        .RUNTIME_GAME_SEL (1'b1)
    ) u_addr_decode (
        .game          (mcr68_game_e'(game)),
        .addr          (byte_addr),
        .uds_n         (uds_n),
        .lds_n         (lds_n),
        .cs_rom        (cs_rom),
        .cs_workram    (cs_workram),
        .cs_videoram   (cs_videoram),
        .cs_auxram     (cs_auxram),
        .cs_spriteram  (cs_spriteram),
        .cs_paletteram (cs_paletteram),
        .cs_ptm        (cs_ptm),
        .cs_watchdog   (cs_watchdog),
        .cs_soundio    (cs_soundio),
        .cs_in0        (cs_in0),
        .cs_in1        (cs_in1),
        .cs_dsw        (cs_dsw),
        .cs_pigskin_port1 (cs_pigskin_port1),
        .cs_pigskin_port2 (cs_pigskin_port2),
        .cs_protect       (cs_protect),
        .ptm_lane_upper   (ptm_lane_upper),
        // map_valid remains an output of the decoder for the focused
        // decoder harness; this board's simulation DTACK contract also
        // acknowledges undecoded cycles, so it has no local consumer.
        /* verilator lint_off PINCONNECTEMPTY */
        .map_valid        (),
        /* verilator lint_on PINCONNECTEMPTY */
        .uds_n_out     (uds_n_decoded),
        .lds_n_out     (lds_n_decoded)
    );

    // =========================================================================
    // Main-board memory devices.  The bring-up model retains its host-file
    // ROM path when SDRAM_ROM=0; the production path uses the synthesizable
    // on-chip RAM implementation and the shared SDRAM ROM fabric.
    // =========================================================================
    logic [15:0] mem_cpu_dout;

    generate
        if (!SDRAM_ROM) begin : g_sim_mem
            mcr68_mem_sim #(
                .MAINCPU_ROM_FILE (MAINCPU_ROM_FILE)
            ) u_mem (
                .clk             (clk),
                .cpu_addr        (cpu_addr[20:1]),
                .cpu_din         (cpu_wdata),
                .cpu_dout        (mem_cpu_dout),
                .cpu_uds_n       (uds_n_decoded),
                .cpu_lds_n       (lds_n_decoded),
                .cpu_we_n        (rw_n),
                .rom_cs          (cs_rom),
                .work_ram_cs     (cs_workram),
                .vram_cs         (cs_videoram),
                .extra_ram_cs    (cs_auxram),
                .sprite_cs       (cs_spriteram),
                .palette_cs      (cs_paletteram),
                .vram_rd_addr    (vram_rd_addr),
                .vram_rd_data    (vram_rd_data),
                .sprite_desc_addr(spriteram_desc_addr),
                .sprite_desc_data(spriteram_desc_data),
                .palette_rd_addr (palette_rd_addr),
                .palette_rd_data (palette_rd_data)
            );
            // No persistence in the sim RAM path -- see port comment above.
            assign nvram_dout = 8'h00;
        end else begin : g_hw_mem
            mcr68_mem_hw u_mem (
                .clk             (clk),
                .cpu_addr        (cpu_addr[20:1]),
                .cpu_din         (cpu_wdata),
                .cpu_dout        (mem_cpu_dout),
                .cpu_uds_n       (uds_n_decoded),
                .cpu_lds_n       (lds_n_decoded),
                .cpu_we_n        (rw_n),
                .rom_cs          (cs_rom),
                .work_ram_cs     (cs_workram),
                .vram_cs         (cs_videoram),
                .extra_ram_cs    (cs_auxram),
                .sprite_cs       (cs_spriteram),
                .palette_cs      (cs_paletteram),
                .vram_rd_addr    (vram_rd_addr),
                .vram_rd_data    (vram_rd_data),
                .sprite_desc_addr(spriteram_desc_addr),
                .sprite_desc_data(spriteram_desc_data),
                .palette_rd_addr (palette_rd_addr),
                .palette_rd_data (palette_rd_data),
                .nvram_wr        (nvram_wr),
                .nvram_addr      (nvram_addr),
                .nvram_din       (nvram_din),
                .nvram_dout      (nvram_dout)
            );
        end
    endgenerate

    // =========================================================================
    // Phase 3 -- video pipeline: gfx ROMs -> tilemap + sprites -> colormix.
    // See file header "Phase 3 video pipeline" note for the port-mismatch
    // reconciliation performed here across the 5 parallel-written modules.
    //
    // Reset domain: tilemap/sprites use the raw `rst` (matching
    // mcr68_video_timing.sv's own domain), NOT cpu_rst -- the video
    // pipeline is purely a function of the free-running pixel position and
    // VRAM/sprite-RAM/ROM contents, so it stays in the same reset domain as
    // the counters that drive it rather than the watchdog-stretched CPU
    // reset, matching "video free-runs independently of the CPU" (per
    // mcr68_video_timing.sv's own header, assumption 1).
    // =========================================================================
    logic [10:0] vram_rd_addr;
    logic [7:0]  vram_rd_data;
    logic [8:0]  spriteram_desc_addr;
    logic [31:0] spriteram_desc_data;
    logic [5:0]  palette_rd_addr;
    logic [15:0] palette_rd_data;

    // ---- gfx1 (tile) / gfx2 (sprite) ROM staging, shared by tilemap+sprites ----
    logic [GFX1_CODE_W-1:0] gfx1_code;
    logic [2:0]  gfx1_row;
    logic [1:0]  gfx1_pair;
    logic [3:0]  gfx1_pen0, gfx1_pen1;

    logic [GFX2_CODE_W-1:0] gfx2_code;
    logic [4:0]  gfx2_row;
    logic        gfx2_req, gfx2_ack;
    logic [127:0] gfx2_pens;

    generate
        if (!SDRAM_ROM) begin : g_sim_gfx
            mcr68_gfx_rom_sim #(
                .GFX1_ROM_FILE (GFX1_ROM_FILE),
                .GFX2_ROM_FILE (GFX2_ROM_FILE),
                .GFX1_BYTES    (GFX1_BYTES),
                .GFX2_BYTES    (GFX2_BYTES)
            ) u_gfx_rom (
                .gfx1_small(gfx1_small_rt),
                .gfx1_code(gfx1_code), .gfx1_row(gfx1_row), .gfx1_pair(gfx1_pair),
                .gfx1_pen0(gfx1_pen0), .gfx1_pen1(gfx1_pen1),
                // The sim ROM model needs the same runtime bitplane-size
                // selection the SDRAM model already takes: GFX2_BYTES is sized
                // for the largest supported set, so the gfx2 plane stride
                // cannot be derived from it. See
                // docs/debug/20260910_gfx2_plane_stride_sim_rom.md.
                .gfx2_small(gfx2_small_rt),
                .gfx2_code(gfx2_code), .gfx2_row(gfx2_row), .gfx2_req(gfx2_req),
                .gfx2_ack(gfx2_ack), .gfx2_pens(gfx2_pens)
            );
        end else begin : g_ext_gfx
            always_comb begin
                gfx1_pen0 = ext_gfx1_pen0;
                gfx1_pen1 = ext_gfx1_pen1;
                gfx2_ack  = ext_gfx2_ack;
                gfx2_pens = ext_gfx2_pens;
            end
        end
    endgenerate
    assign ext_gfx1_code = gfx1_code;
    assign ext_gfx1_row  = gfx1_row;
    assign ext_gfx1_pair = gfx1_pair;
    assign ext_gfx2_code = gfx2_code;
    assign ext_gfx2_row  = gfx2_row;
    assign ext_gfx2_req  = gfx2_req;

    // ---- tilemap engine ----
    logic        tm_valid;
    logic [3:0]  tm_pen;
    logic [1:0]  tm_color_bank;
    logic        tm_category;

    mcr68_tilemap #(.SYNC_GFX(SDRAM_ROM), .GFX1_BYTES(GFX1_BYTES)) u_tilemap (
        .clk           (clk),
        .gfx1_small    (gfx1_small_rt),
        .rst           (rst),
        .pixel_x       (video_pixel_x),
        .pixel_y       (video_pixel_y),
        .pixel_active  (!(video_hblank || video_vblank)),
        .vram_rd_addr  (vram_rd_addr),
        .vram_rd_data  (vram_rd_data),
        .gfx1_code     (gfx1_code),
        .gfx1_row      (gfx1_row),
        .gfx1_pair     (gfx1_pair),
        .gfx1_pen0     (gfx1_pen0),
        .gfx1_pen1     (gfx1_pen1),
        .tm_valid      (tm_valid),
        .tm_pen        (tm_pen),
        .tm_color_bank (tm_color_bank),
        .tm_category   (tm_category)
    );

    // ---- sprite engine ----
    logic        sp_line_busy, sp_build_overrun;
    logic        sp_lo_valid, sp_hi_valid;
    logic [3:0]  sp_lo_pen, sp_hi_pen;
    logic [1:0]  sp_lo_color, sp_hi_color;

    mcr68_sprites #(
        .SCREEN_WIDTH   (512),
        .V_TOTAL        (V_TOTAL),
        .GFX2_BYTES     (GFX2_BYTES)
    ) u_sprites (
        .clk            (clk),
        .rst            (rst),
        // runtime per-title geometry (was elaboration parameters)
        .sprite_clip    (spr_clip_rt),
        .sprite_xoffset (spr_xoff_rt),
        .sprite_slots   (spr_slots_rt),
        .gfx2_small     (gfx2_small_rt),
        .line_start     (hsync_pulse),
        .target_line    (v_count),
        .line_busy      (sp_line_busy),
        .build_overrun  (sp_build_overrun),
        .pixel_x        (video_pixel_x),
        .display_line   (v_count),
        .spriteram_desc_addr(spriteram_desc_addr),
        .spriteram_desc_data(spriteram_desc_data),
        .gfx2_code      (gfx2_code),
        .gfx2_row       (gfx2_row),
        .gfx2_req       (gfx2_req),
        .gfx2_ack       (gfx2_ack),
        .gfx2_pens      (gfx2_pens),
        .sp_lo_valid    (sp_lo_valid),
        .sp_lo_pen      (sp_lo_pen),
        .sp_lo_color    (sp_lo_color),
        .sp_hi_valid    (sp_hi_valid),
        .sp_hi_pen      (sp_hi_pen),
        .sp_hi_color    (sp_hi_color)
    );

    // ---- final compositor + palette lookup ----
    mcr68_colormix u_colormix (
        .tm_pen          (tm_pen),
        .tm_color_bank   (tm_color_bank),
        .tm_category     (tm_category),
        .sp_lo_valid     (sp_lo_valid),
        .sp_lo_pen       (sp_lo_pen),
        .sp_lo_color     (sp_lo_color),
        .sp_hi_valid     (sp_hi_valid),
        .sp_hi_pen       (sp_hi_pen),
        .sp_hi_color     (sp_hi_color),
        .palette_rd_addr (palette_rd_addr),
        .palette_rd_data (palette_rd_data),
        .r               (video_r),
        .g               (video_g),
        .b               (video_b)
    );

    // tm_valid is intentionally not wired into colormix -- see file header
    // integration note B for why the harness's ce_dot-synchronized sampling
    // makes that safe without adding a gating input to either module. It is
    // exposed below as a debug output (along with the sprite engine's
    // line_busy/build_overrun) for harness/trace visibility instead of
    // being left as a dangling, lint-flagged lonely instance output.

    assign video_ce_dot    = ce_dot;
    assign video_hblank_o  = video_hblank;
    assign video_vblank_o  = video_vblank;
    // Positive-pulse conversion for arcade_video/video_mixer's HSync/VSync
    // contract -- see the port declaration comment above. u_video_timing's
    // hsync_n/vsync_n are composite-sync-style (active low); a plain
    // inversion is the correct and only transform needed since both sides
    // agree on placement/width, only polarity differs.
    assign video_hsync_o   = ~video_hsync_n;
    assign video_vsync_o   = ~video_vsync_n;
    assign video_pixel_x_o = video_pixel_x;
    assign video_pixel_y_o = video_pixel_y;
    assign dbg_tm_valid          = tm_valid;
    assign dbg_sp_line_busy      = sp_line_busy;
    assign dbg_sp_build_overrun  = sp_build_overrun;
    assign dbg_tm_pen            = tm_pen;
    assign dbg_sp_lo_valid       = sp_lo_valid;
    assign dbg_sp_hi_valid       = sp_hi_valid;
    assign dbg_palette_rd_addr   = palette_rd_addr;
    assign dbg_palette_rd_data   = palette_rd_data;
    assign dbg_vram_rd_addr      = vram_rd_addr;
    assign dbg_vram_rd_data      = vram_rd_data;

    // =========================================================================
    // MC6840 PTM -- IPL2 interrupt source. C1<-vblank_pulse, C3<-hsync_pulse,
    // C2 tied off (unused on this board), ena<-eclk_en (CPU/10, the 68000
    // E-clock). Register map: 8 registers, data wired to D7-D0 only
    // (mcr68.cpp:608, umask16(0x00ff)) -- but the SAME install also declares
    // .cswidth(16) (mcr68.cpp:608), which is MAME's explicit modeling of a
    // real-hardware chip-select that spans the FULL 16-bit-aligned word
    // regardless of which byte strobe the CPU asserts: confirmed by reading
    // MAME's own dispatch-table generator (src/emu/emumem_mud.cpp,
    // memory_units_descriptor::generate()) -- with cswidth=16 the device's
    // ACTIVATION mask (amask) is forced to span all 16 bits of the aligned
    // word, decoupled from its narrower 8-bit DATA mask (umask). I.e. this
    // device's chip-select genuinely activates on EITHER UDS-only, LDS-only,
    // or a full word access -- not LDS alone.
    //
    // BUGFIX (found by this task's frame-0..150 long-trace diff, first
    // divergence at MAME event 3,187,337 / RTL frame 59 scanline 95): the
    // original `en` gating here required `!lds_n` exclusively, silently
    // dropping every UDS-only (byte-address-even, "lanes":2) access to this
    // range. Xenophobe's self-test PTM-programming code (first touches the
    // PTM only very deep into the run -- 0 events before seq 3,187,308 in a
    // 150-frame/8.59M-event MAME capture) issues the vast majority of its
    // PTM writes/reads as UDS-only byte accesses (1,683 of 2,147 device=6
    // events in that capture use lanes=2 vs only 460 lanes=1 and 4 lanes=3) --
    // so this dropped essentially all of Timer3's programming, leaving its
    // counter stuck at the power-on-reset value 16'hFFFF forever. Confirmed
    // root cause by hand-reconstructing the exact expected counter reload
    // from the dropped MSBBUF3/LSB3 writes (latch <= 16'h0035) and getting
    // MAME's exact observed MSB readback (0x00) -- RTL previously read back
    // 0xFF (the never-reloaded reset value) at the same point.
    //
    // Safe to widen this way because FX68K genuinely replicates a byte
    // write's data onto BOTH halves of its 16-bit output data bus (see
    // rtl/cpu/fx68k.sv:1845-1846, `dob[15:8] <= byteCycle ? dobInput[7:0] :
    // ...` -- the same real-hardware behaviour MAME's cswidth(16) modeling
    // assumes), so `din(cpu_wdata[7:0])` below already carries the correct
    // byte value on a UDS-only write; only the enable/activation condition
    // needed correcting, not the data path.
    // =========================================================================
    logic [7:0] ptm_dout;
    logic       ptm_irq;

    // The MAME mcr68 machine config wires only C1/C3 and the PTM IRQ to the
    // board; timer output pins 1-3 have no board consumer.
    /* verilator lint_off PINCONNECTEMPTY */
    ptm6840 u_ptm (
        .clk   (clk),
        .rst   (cpu_rst),
        .ena   (eclk_en),
        .en    (cs_ptm & !as_n & (!lds_n_decoded | !uds_n_decoded)),
        .we    (!rw_n),
        .addr  (cpu_addr[3:1]),
        // umask16 byte lane: 0x00ff (D7-D0) for mcr68_map titles, 0xff00
        // (D15-D8) for pigskin_map (mcr68.cpp:637). FX68K replicates a byte
        // write onto both halves of its data bus, so for a byte write either
        // slice carries the value; the selection matters for the WORD writes
        // MAME would route to the upper half under umask16(0xff00).
        .din   (ptm_lane_upper ? cpu_wdata[15:8] : cpu_wdata[7:0]),
        .dout  (ptm_dout),
        // PTM external clock inputs frozen while paused (audit finding
        // CPU-A3).  rtl/cpu/ptm6840.sv counts c1/c3 edges regardless of `ena`,
        // so leaving them live during an OSD pause advanced the timers by one
        // count per frozen frame and per frozen scanline while the CPU could
        // not service them -- PTM state drifts across the pause and Blasted's
        // counter-2 interval check can fail on resume.  Same `& ~pause` form
        // the watchdog's vblank input at u_io already uses.
        .c1    (vblank_pulse & ~pause),
        .c2    (1'b0),           // not connected on this board
        .c3    (hsync_pulse & ~pause),
        .out1  (),
        .out2  (),
        .out3  (),
        .irq   (ptm_irq)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // =========================================================================
    // mcr68_io: watchdog, IN0/IN1/DSW read mux, "493" IPL1 once-per-frame
    // strobe. wdog_we is a plain write-in-range level (idempotent to
    // reassert across a whole bus cycle, matching that module's own
    // "any write in range pets the dog" semantics).
    // =========================================================================
    logic [15:0] io_rdata;
    logic        irq1;

    // mcr68_io's E_CLOCKS_PER_FRAME parameter should track this module's own
    // derived E-clock/frame-timing relationship rather than silently using a
    // different constant than what this module's own eclk_en/vblank_pulse
    // actually produce. E_CLK_HZ (CPU/10) and the video generator's frame
    // rate (DOT_CLK_HZ / (H_TOTAL*V_TOTAL)) are two independently-derived
    // clocks (see assumption 1/2 above) -- the plan's nominal 25746
    // E-clocks/frame (772_380/30) is kept as the default so the 493 strobe's
    // documented ~352us lead time is preserved, but is computed here from
    // E_CLK_HZ so overriding CPU_HZ keeps the two in sync.
    localparam int E_CLOCKS_PER_FRAME_LOCAL = E_CLK_HZ / 30;

    mcr68_io #(
        .WDOG_LIMIT        (WDOG_LIMIT),
        .E_CLOCKS_PER_FRAME (E_CLOCKS_PER_FRAME_LOCAL),
        .IRQ1_OFFSET_ECLKS (IRQ1_OFFSET_ECLKS),
        .USE_SCANLINE_493  (USE_SCANLINE_493),
        .IRQ493_LINE       (IRQ493_LINE),
        .RUNTIME_GAME_SEL  (1'b1)
    ) u_io (
        .clk          (clk),
        .v_count      (v_count),
        .game         (mcr68_game_e'(game)),
        // Pigskin composite port selects. Held low by the decoder under
        // MAP_MCR68, so Xenophobe/Blasted/ArchRivals are
        // unaffected.
        .sel_pigskin_port1 (cs_pigskin_port1),
        .sel_pigskin_port2 (cs_pigskin_port2),
        .rst          (cpu_rst),
        .wdog_we      (cs_watchdog & !as_n & !rw_n),
        // Watchdog tick frozen while paused. The CPU cannot pet the watchdog
        // with its clock enable gated, so an unfrozen watchdog would trip
        // after 8 vblanks and reset the game mid-pause.
        .vblank_pulse (vblank_pulse & ~pause),
        .wdog_trip    (wdog_trip),
        .sel_in0      (cs_in0),
        .sel_in1      (cs_in1),
        .sel_dsw      (cs_dsw),
        .in0_pins     (in0_pins),
        .in1_pins     (in1_pins),
        .dsw_pins     (dsw_pins),
        .io_rdata     (io_rdata),
        .eclk_en      (eclk_en),
        // Frozen while paused for the same reason as the PTM's c3 above
        // (audit finding CPU-A3): mcr68_io.sv clears a pending irq1 on hsync,
        // so a live hsync during an OSD pause can retire the 493/IPL1 strobe
        // the CPU never got to see -- one lost frame interrupt on resume.
        .hsync_pulse  (hsync_pulse & ~pause),
        .irq1         (irq1)
    );

    // =========================================================================
    // Sound I/O control-word latch + "Sounds Good" sound board.
    // See file header "Phase 4/5 update" note and assumption 6 for the full
    // derivation of the bit layout and the reset-domain decision.
    //
    // Latch timing mirrors this file's existing memory-write idiom (see
    // u_mem's cpu_write/*_cs gating above): level-qualified on cs_soundio &
    // write, no as_n gating, independent per-byte-lane update -- consistent
    // with the same pattern already validated by this file's zero-divergence
    // CPU regression, not a new write-timing semantic. Re-writing the same
    // data every clk cycle for the duration of one bus cycle is harmless
    // (idempotent), exactly as for the RAM writes in u_mem.
    //
    // Address offset within the cs_soundio window is intentionally ignored,
    // matching xenophobe_control_w's own MAME behaviour (COMBINE_DATA on a
    // single m_control_word regardless of the mirrored offset within
    // 0x0C0000-0x0CFFFF).
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] ctrl_word;
    /* verilator lint_on UNUSEDSIGNAL */
    // CORRECTED 2026-09-12 (audit findings CPU-A4 / SND-04, audit section 3):
    // this latch is cleared on the POWER-ON / ROM-DOWNLOAD reset (`rst`) ONLY,
    // never on a watchdog-triggered `cpu_rst`.  In MAME `m_control_word`
    // (mcr68.cpp:134,187-191) is a plain member that `machine_reset()` never
    // re-zeroes, so it survives the watchdog's soft reset
    // (watchdog.cpp:145-150).  Clearing it on `cpu_rst` had two wrong
    // consequences: for Arch Rivals / Pigskin, bit 10 falling 1->0 pulsed
    // `host_resetq` and restarted the Williams BG 6809 and its bank register as
    // a side effect of a main-CPU watchdog trip; for Xenophobe / Blasted it
    // dropped the sound command nibble.  INFERRED -- no schematic evidence for
    // the RESET~ net's fan-out to the output latches; if the real board's
    // 10A/6A (LS273/LS374-class, CLR pin) do clear on RESET~, restore the
    // clear and record it as a hardware-correct deviation instead.
    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_word <= 16'h0000; // all-zero latch at power-up: no command
                                    // nibble, strobe low.  NOTE: bit 5 no longer
                                    // gates the Sounds Good reset (see the
                                    // GAME_XENOPHOB case below and
                                    // docs/debug/20260911_xenophobe_sound_board_reset_music_cutout.md),
                                    // so this default no longer holds that board
                                    // off -- the sound CPU is released with the
                                    // rest of the core, which is what the game's
                                    // own command timing requires.
        end else if (!rw_n && cs_soundio) begin
            if (!uds_n_decoded) ctrl_word[15:8] <= cpu_wdata[15:8];
            if (!lds_n_decoded) ctrl_word[7:0]  <= cpu_wdata[7:0];
        end
    end

    logic [3:0] snd_sndsel;
    logic       snd_sint;
    logic       snd_ctrl_reset_n;
    always_comb begin
        snd_sndsel       = 4'h0;
        snd_sint         = 1'b0;
        snd_ctrl_reset_n = 1'b0;
        case (mcr68_game_e'(game))
            GAME_XENOPHOB: begin
                snd_sndsel       = ctrl_word[3:0];
                snd_sint         = ctrl_word[4];
                // *** 2026-09-11: control-word bit 5 no longer gates the
                // Sounds Good 68000's reset (INFERRED, see
                // docs/debug/20260911_xenophobe_sound_board_reset_music_cutout.md).
                //
                // Measured from pinned MAME 0.289 (tools/mame_mcr68_xeno_music_trace.lua):
                //   * the Sounds Good power-on self test -- 4 chained ROM-bank
                //     checksums, a RAM march and a PIA walking-bit test, all
                //     with SR=$2700 so IRQ4 is masked -- takes 2760.1 ms to
                //     reach the idle/DAC loop at PC 0x001FAC;
                //   * Xenophobe's own sound-init routine (main PC 0x00952E /
                //     0x00954A) writes 0x0000 then 0x0020 at t=878.805 /
                //     878.849 ms and then issues its FIRST sound command at
                //     t=3219.757 ms -- only 2340.9 ms later, i.e. 419.2 ms
                //     LESS than the self test that a reset here would start.
                // Driving the sound CPU's reset from this bit therefore makes
                // the game's first command land inside the self test, where it
                // is masked and then silently cleared by the walking-bit
                // subtest's own PORTA read, so it is lost every power-up --
                // which no shipped board can have done.  The same routine runs
                // again at t=7634.9 ms (one second into the game) and the next
                // command is not until t=16534.9 ms, so the reset also produced
                // 8.9 s of dead audio exactly where "the music cuts out" was
                // reported.  Proved on the real Sounds Good board by replaying
                // this exact control-word journal with and without the reset
                // interpretation (sim/sim_mcr68_sound_headless.cpp
                // +CTRL_JOURNAL / +IGNORE_CTRL_RESET).
                //
                // Reference disposition: mcr68.cpp:386 leaves
                // `reset_write(~m_control_word & 0x0020)` COMMENTED OUT for
                // Xenophobe (and :401 for Blasted), while :436 drives the same
                // device's reset live from bit 13 for Spy Hunter II and
                // mcr3.cpp:290/334/377 drive it live on MCR-III.  The reset
                // input is real board-family wiring; its assignment to bit 5 of
                // the MCR-68k Xenophobe control word is not proven -- no
                // MCR-68k PLD is dumped (core-debug.toml) and the repository's
                // own Xenophobe schematic audit of Sounds Good sheets
                // 3-16..3-20 (docs/debug/20260815_raw_schematic_reference_audit.md)
                // records no control-word-driven RESET into that 68000.
                // The latch bit stays observable on dbg_snd_ctrl_reset_n for
                // future PCB work; reopen this if a Xenophobe sheet or PAL dump
                // shows bit 5 wired to the sound board's RESET.
                snd_ctrl_reset_n = 1'b1;
            end
            GAME_BLASTED: begin
                snd_sndsel       = ctrl_word[12:9];
                snd_sint         = ctrl_word[8];
                // MAME's blasted_control_w() never drives the dormant
                // Sounds Good reset handler (midway_sound.cpp:519-523 is
                // commented out), and its sound 68000 executes immediately
                // from the machine-reset vector.  Bit 5 is not part of the
                // high-byte command written by Blasted, so applying the
                // Xenophobe reset latch here would hold this board in reset
                // forever.  Both Sounds Good titles now release the board at
                // system reset, as MAME does, until PCB evidence proves a
                // title-specific reset pulse is required.
                snd_ctrl_reset_n = 1'b1;
            end
            default: begin end
        endcase
    end

    // Sounds Good reset policy: BOTH Sounds Good titles release the board at
    // system reset, which is what MAME does (mcr68.cpp:386/401 leave
    // reset_write() commented out) and what Xenophobe's own command timing
    // requires -- the game allows 2340.9 ms between releasing the bit and its
    // first command, 419.2 ms less than the board's measured 2760.1 ms
    // self test.  `ctrl_reset_n` remains a real port and a real observation
    // (dbg_snd_ctrl_reset_n) so a future PCB-evidenced, per-title reset can be
    // reinstated without another interface change.  No frame-count or watchdog
    // fallback is allowed to invent a release.

    // =========================================================================
    // Williams S11/S11C background sound board (Arch Rivals / Pigskin) --
    // rtl/snd/williams_bg/williams_bg.sv. Instantiated ALONGSIDE (not in
    // place of) mcr68_sound_board below: this is a single runtime-
    // switchable build, exactly like every other per-title decision in this
    // file (gfx1_small_rt, spr_*_rt, ptm_lane_upper,
    // etc.) -- selected at runtime by `prof_rt.snd_williams_bg` /
    // `prof_rt.williams_s11c`, NOT a structural `generate if`.
    //
    // Host interface (archrivl_control_w, mcr68.cpp:486-506, transcribed
    // into williams_bg.sv's own header): the SAME ctrl_word latch this file
    // already maintains for xenophobe_control_w carries archrivl_control_w
    // too -- both are the one 16-bit control word at cs_soundio
    // (0x0C0000-0x0CFFFF); only the bit MEANING differs per title profile
    // (Xenophobe/Blasted: bits[5:0] = sndsel/sint/ctrl_reset_n.
    // Arch Rivals/Pigskin: bits[10:0] = host_data[7:0]/host_ctrl/host_extra/
    // host_resetq). Both interpretations are wired unconditionally below;
    // that is harmless because ONLY the board whose profile bit is set ever
    // gets its ROM-fetch req un-masked (see bgrom_req/sndrom_req masking
    // further down) and only its audio reaches dbg_audio_out (see the
    // dbg_audio_out mux further down) -- the inactive board's CPU may still
    // free-run off whatever garbage bits land in its half of ctrl_word, but
    // it can neither contend on the shared ROM fabric nor reach the output
    // mix, exactly the isolation this task's masking requirement asks for.
    // =========================================================================
    logic signed [15:0] snd_audio_out;
    logic signed [15:0] will_audio_out;
    logic                will_bgrom_req;   // pre-mask, see the assign below
    logic                snd_sndrom_req;   // pre-mask, see the assign below

    mcr68_sound_board #(
        .SNDCPU_ROM_FILE (SNDCPU_ROM_FILE),
        .CLK_HZ          (CLK_HZ),        // match THIS module's own clk domain (the
                                           // single shared sim clock -- see
                                           // mcr68_sound_board.sv's reconciliation
                                           // note 3: its internal cpu_ce NCO and its
                                           // mcr68_snd_dac instance both need CLK_HZ
                                           // to match the clock actually driving
                                           // `clk`, not its own 40 MHz default)
        .CPU_HZ          (8_000_000),     // midway_sound.cpp:607, 16 MHz / 2
        .SAMPLE_HZ       (48_000),
        .SDRAM_ROM       (SDRAM_ROM)
    // Xenophobe never reads the Sounds Good PB5:PB4 status output, and these
    // three internal debug taps are not promoted by the main-board contract.
    /* verilator lint_off PINCONNECTEMPTY */
    ) u_sound_board (
        .clk           (clk),
        // CORRECTED 2026-09-12 (audit finding CPU-A4, audit section 3): now
        // cpu_rst, so a watchdog trip restarts this board's 68000 the same way
        // MAME's watchdog soft-reset (watchdog.cpp:145-150) restarts every
        // device in the machine.  Previously it was raw `rst`, so a Sounds Good
        // title kept playing straight through a watchdog restart of the main
        // CPU.  This changes only WHAT ASSERTS the board's top-level reset
        // input; the board's own internal reset semantics (and the separate
        // ctrl_reset_n path) are untouched.  INFERRED -- no schematic evidence
        // for RESET~'s fan-out to the sound connector.
        .rst           (cpu_rst),
        .ctrl_reset_n  (snd_ctrl_reset_n),
        .sndrom_req    (snd_sndrom_req),  // pre-mask -- see the assign below
        .sndrom_addr   (sndrom_addr),
        .sndrom_data   (sndrom_data),
        .sndrom_ack    (sndrom_ack),

        .sndsel        (snd_sndsel),
        .sint          (snd_sint),
        .stat          (),                // Xenophobe never reads this (PB5:PB4) --
                                           // see plan's "Sound" section

        .audio_out     (snd_audio_out),

        .dbg_pc        (dbg_snd_pc),

        .dbg_cpu_addr  (dbg_snd_cpu_addr),
        .dbg_cpu_dout  (dbg_snd_cpu_dout),
        .dbg_cpu_din   (dbg_snd_cpu_din),
        .dbg_as_n      (dbg_snd_as_n),
        .dbg_uds_n     (dbg_snd_uds_n),
        .dbg_lds_n     (dbg_snd_lds_n),
        .dbg_rw_n      (dbg_snd_rw_n),
        .dbg_dtack_n   (dbg_snd_dtack_n),
        .dbg_fc        (dbg_snd_fc),
        .dbg_ca2       (dbg_snd_ca2),
        .dbg_irq4      (dbg_snd_irq4),
        .dbg_dac10     (dbg_snd_dac10),
        .dbg_rom_cs    (),
        .dbg_ram_cs    (),
        .dbg_sample_tick (dbg_snd_sample_tick)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ROM-fetch masking: never assert sndrom_req toward the shared SDRAM
    // fabric unless this title's profile is actually the Sounds Good board.
    // mcr68_sound_board's own internal 68000 free-runs regardless of `game`
    // (nothing in this file gates ITS cpu_ce on prof_rt), so under an
    // Arch Rivals/Pigskin profile it would otherwise still be fetching
    // "ROM" bytes from whatever ctrl_word[5:0] garbage archrivl_control_w's
    // bit layout happens to leave in the Sounds Good bit positions, and
    // contending with williams_bg's own bgrom_req on the shared fabric's p1
    // client (see mcr68_rom_fabric.sv's header -- the two are meant to be
    // mutually exclusive per title, exactly like its existing snd/bg
    // sharing). Masking at THIS boundary (not inside mcr68_sound_board.sv)
    // keeps that module's own req/ack FSM completely untouched -- an
    // inactive board just never sees an ack and idles quietly.
    assign sndrom_req = snd_sndrom_req & prof_rt.snd_sounds_good;

    assign dbg_snd_sndsel       = snd_sndsel;
    assign dbg_snd_sint         = snd_sint;
    assign dbg_snd_ctrl_reset_n = snd_ctrl_reset_n;

    // -------------------------------------------------------------------
    // Williams S11/S11C background board instance. See the block comment
    // above for the runtime-mux rationale and the ctrl_word bit-layout note.
    // -------------------------------------------------------------------
    // Williams debug taps are observation-only and are not part of the
    // main-board external contract; audio and ROM traffic are the live paths.
    /* verilator lint_off PINCONNECTEMPTY */
    williams_bg #(
        .CLK_HZ      (CLK_HZ),      // match this module's own clk domain, same
                                      // reasoning as mcr68_sound_board's CLK_HZ
                                      // override above (its internal NCOs --
                                      // cpu_ce, ym_ce, the CVSD/mixer sample tick --
                                      // are all derived from CLK_HZ, not a fixed
                                      // default).
        .CPU_HZ      (2_000_000),   // MC68B09E E-clock: 8 MHz XTAL / 4, s11c_bg.cpp:366
        .YM_HZ       (3_579_545),   // YM2151 phi, s11c_bg.cpp:386
        .SAMPLE_HZ   (48_000),      // matches mcr68_sound_board's own SAMPLE_HZ and
                                      // sys/audio_out.sv's fixed AUDIO_RATE
        .BG_ROM_FILE (BGCPU_ROM_FILE),
        .SDRAM_ROM   (SDRAM_ROM)
    ) u_williams_bg (
        .clk          (clk),
        // CORRECTED 2026-09-12 (audit finding CPU-A4, audit section 3): now
        // cpu_rst, same reset domain as u_sound_board above, so a watchdog trip
        // restarts the BG 6809 exactly as MAME's machine soft reset does.  The
        // board's OWN /RESET input remains main-CPU-controlled through
        // host_resetq below and is unchanged -- and with ctrl_word no longer
        // cleared on cpu_rst (see the latch above), host_resetq no longer
        // spuriously pulses on every watchdog trip.
        .rst          (cpu_rst),
        .s11c         (prof_rt.williams_s11c),

        .host_data    (ctrl_word[7:0]),
        .host_ctrl    (ctrl_word[8]),
        .host_extra   (ctrl_word[9]),
        .host_resetq  (ctrl_word[10]),

        .bgrom_req    (will_bgrom_req),  // pre-mask -- see the assign below
        .bgrom_addr   (bgrom_addr),
        .bgrom_data   (bgrom_data),
        .bgrom_ack    (bgrom_ack),

        .audio_out    (will_audio_out),

        .dbg_cpu_addr    (),
        .dbg_cpu_dout    (),
        .dbg_cpu_din     (),
        .dbg_cpu_rw_n    (),
        .dbg_cpu_ce      (),
        .dbg_firq_n      (),
        .dbg_nmi_n       (),
        .dbg_rom_cs      (),
        .dbg_ram_cs      (),
        .dbg_ym_cs       (),
        .dbg_pia_cs      (),
        .dbg_ym_wr       (),
        .dbg_ym_a0       (),
        .dbg_ym_data     (),
        .dbg_ym_irq_n    (),
        .dbg_ym_rst_n    (),
        .dbg_bank        (),
        .dbg_dac8        (),
        .dbg_cvsd_set    (),
        .dbg_cvsd_clr    (),
        .dbg_cvsd_digit  (),
        .dbg_cvsd_sample (),
        .dbg_cvsd_filt   (),
        .dbg_sample_tick ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ROM-fetch masking, same reasoning as sndrom_req above: williams_bg's
    // own 6809 free-runs regardless of `game` too, so its bgrom_req must
    // never reach the shared fabric except when this title's profile is
    // actually the Williams board.
    assign bgrom_req = will_bgrom_req & prof_rt.snd_williams_bg;

    // Audio mux -- same runtime-select idiom as every other prof_rt-driven
    // decision in this file (gfx1_small_rt, spr_*_rt, ptm_lane_upper, etc.):
    // a plain combinational select on the profile bit, not a generate.
    assign dbg_audio_out = prof_rt.snd_williams_bg ? will_audio_out : snd_audio_out;

    // =========================================================================
    // Read-data mux (bus -> CPU)
    // =========================================================================
    always_comb begin
        cpu_rdata = 16'hFFFF; // default: unmapped / open bus (MAME unmap_value_high convention)
        if (cs_rom & SDRAM_ROM)
            // SDRAM_ROM=1: main-CPU ROM data comes from the SDRAM fabric
            // (see mainrom_req/mainrom_data below), not u_mem.
            cpu_rdata = mainrom_data;
        else if (cs_rom | cs_workram | cs_videoram | cs_auxram | cs_spriteram | cs_paletteram)
            cpu_rdata = mem_cpu_dout;
        else if (cs_ptm)
            // umask16(0x00ff): only D7-D0 is a real connection to the PTM;
            // D15-D8 is architecturally unconnected at this address and MAME's
            // unmap_value_high() convention (mcr68.cpp:600) makes an unmapped
            // byte read back as 0xFF, not 0x00. Confirmed discrepancy from the
            // Phase 2 adversarial address-decode audit (2026-08-05): the CPU
            // only looks at whichever byte lane it actually strobed (UDS_n/
            // LDS_n), so unconditionally presenting 0xFF on D15-D8 here is
            // sufficient -- no separate lds_n/uds_n gating needed in this mux.
            //
            // PIGSKIN: pigskin_map installs the PTM with umask16(0xff00)
            // (mcr68.cpp:637) -- the SAME 8-bit device sits on D15-D8 instead.
            // `ptm_lane_upper` from mcr68_addr_decode carries exactly that
            // static per-profile fact; apply it here (and on the write data
            // path at the ptm6840 instance) instead of leaving it
            // informational. Xenophobe/Blasted/Arch Rivals take
            // ptm_lane_upper=0 and keep the bit-identical lower-lane form.
            cpu_rdata = ptm_lane_upper ? {ptm_dout, 8'hFF} : {8'hFF, ptm_dout};
        else if (cs_in0 | cs_in1 | cs_dsw | cs_pigskin_port1 | cs_pigskin_port2)
            cpu_rdata = io_rdata;
        else if (cs_protect)
            cpu_rdata = protect_dout;
        // cs_watchdog: write-only on real hardware/MAME, no readback path.
        // cs_soundio : write-only on real hardware/MAME (xenophobe_control_w has
        // no read handler) -- no readback path, by design, not a stub. See file
        // header "Phase 4/5 update" note.
    end

    // =========================================================================
    // DTACK generation -- see assumption 5 above.
    // =========================================================================
    // Ordinary reads retain the registered one-wait path. Ordinary writes
    // are acknowledged combinationally only after AS_n and at least one byte
    // strobe are both active. This preserves the FX68K write-data/lane
    // boundary while avoiding the extra full CPU cycle caused by waiting for
    // dtack_n_r to be registered at the next enable edge. The write side
    // effects remain synchronous in the memory/peripheral blocks.
    //
    // The AS-only form was tested and rejected: it acknowledges lanes=0
    // before FX68K has presented valid write strobes and drops the write.
    // Keep the strobe qualification here as part of the functional contract.
    // SDRAM_ROM=1 addendum: a main-CPU ROM cycle (cs_rom) can no longer
    // ack on the very next cpu_ce edge like every other (on-chip, single-
    // cycle) region -- it must wait for the SDRAM fabric's real,
    // multi-cycle mainrom_ack. Implemented as a separate branch so the
    // pre-existing flat one-wait-state path below is completely untouched
    // (same instructions, same edges) whenever SDRAM_ROM=0 or the cycle
    // isn't a ROM access -- i.e. zero behavioural change for any existing
    // harness. mainrom_req is held (level, not a pulse) from the first
    // qualifying edge until mainrom_ack fires, matching mcr68_rom_fabric.sv's
    // documented client contract exactly.
    logic dtack_n_r;
    wire  sdram_rom_cycle = SDRAM_ROM & cs_rom;
    always_ff @(posedge clk) begin
        if (cpu_rst) begin
            dtack_n_r   <= 1'b1;
            mainrom_req <= 1'b0;
        end else if (as_n) begin
            dtack_n_r   <= 1'b1;
            mainrom_req <= 1'b0;
        end else if (sdram_rom_cycle) begin
            if (!mainrom_req && dtack_n_r && (!uds_n_decoded | !lds_n_decoded))
                mainrom_req <= 1'b1;
            else if (mainrom_ack) begin
                mainrom_req <= 1'b0;
                dtack_n_r   <= 1'b0;
            end
        end else if (dtack_n_r & cpu_ce & (!uds_n_decoded | !lds_n_decoded)) begin
            dtack_n_r <= 1'b0;
        end
    end
    wire fast_read_cycle = FAST_READ_DTACK && !as_n && rw_n &&
                           (!uds_n_decoded || !lds_n_decoded) && (fc != 3'b111) &&
                           !(SDRAM_ROM && cs_rom);
    wire write_strobe_cycle = !as_n && !rw_n &&
                           (!uds_n_decoded || !lds_n_decoded) && (fc != 3'b111) &&
                              !(SDRAM_ROM && cs_rom);
    assign dtack_n       = (fast_read_cycle || write_strobe_cycle) ? 1'b0 : dtack_n_r;

    // Single-cycle access-completion strobe: DTACK asserting (1 -> 0) happens
    // exactly once per completed bus cycle. pigskin_protect's history shift
    // MUST be edge-driven -- a held level would shift several times per write
    // and break every sequence match.
    logic dtack_n_d;
    always_ff @(posedge clk) begin
        if (cpu_rst) dtack_n_d <= 1'b1;
        else         dtack_n_d <= dtack_n;
    end
    wire cpu_access_strobe = dtack_n_d & ~dtack_n;

    // Pigskin protection device (0x120000-0x120001, mcr68.cpp:633). cs_protect
    // only asserts under MAP_PIGSKIN, so this is inert for every other title --
    // no profile gating needed.
    wire [15:0] protect_dout;
    pigskin_protect u_pigskin_protect (
        .clk   (clk),
        .rst   (cpu_rst),
        .en    (cpu_access_strobe),
        .cs    (cs_protect),
        .we    (~rw_n),
        .lds_n (lds_n_decoded),
        .din   (cpu_wdata),
        .dout  (protect_dout)
    );
    assign mainrom_addr = cpu_addr[17:1];

    // =========================================================================
    // Interrupt priority arbitration -- see assumption 3 above. PTM (level 2)
    // takes priority over "493" (level 1) when both are pending; IPL0 is
    // unused (no level-4/5/6/7 source exists on this board in this phase).
    // =========================================================================
    logic [2:0] ipl_level;
    always_comb begin
        if (ptm_irq)      ipl_level = 3'd2;
        else if (irq1)    ipl_level = 3'd1;
        else              ipl_level = 3'd0;
    end
    assign ipl_n = ~ipl_level;

    // =========================================================================
    // Debug/trace outputs
    // =========================================================================
    assign dbg_cpu_addr      = cpu_addr;
    assign dbg_cpu_dout      = cpu_wdata;
    assign dbg_cpu_din       = cpu_rdata;
    assign dbg_as_n          = as_n;
    assign dbg_uds_n         = uds_n_decoded;
    assign dbg_lds_n         = lds_n_decoded;
    assign dbg_rw_n          = rw_n;
    assign dbg_dtack_n       = dtack_n;
    assign dbg_fc            = fc;
    assign dbg_ptm_irq       = ptm_irq;
    assign dbg_irq1          = irq1;
    assign dbg_wdog_trip     = wdog_trip;
    assign dbg_vblank_pulse  = vblank_pulse;
    assign dbg_hsync_pulse   = hsync_pulse;
    assign dbg_frame_counter = frame_counter;
    assign dbg_scanline      = 16'(v_count);
    assign dbg_pc            = cpu_dbg_pc;
    assign dbg_d7            = cpu_dbg_d7;
    assign dbg_ccr           = cpu_dbg_ccr;
    assign dbg_sr            = cpu_dbg_sr;
    assign dbg_iipl          = cpu_dbg_iipl;
    assign dbg_ripl          = cpu_dbg_ripl;
    assign dbg_ipl_stable    = cpu_dbg_ipl_stable;
    assign dbg_ipl_comp      = cpu_dbg_ipl_comp;
    assign dbg_int_pend      = cpu_dbg_int_pend;
    assign dbg_inl           = cpu_dbg_inl;
    assign dbg_iac           = cpu_dbg_iac;

endmodule
`default_nettype wire
