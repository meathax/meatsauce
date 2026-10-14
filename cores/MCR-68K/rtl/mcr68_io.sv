// -----------------------------------------------------------------------------
// mcr68_io.sv
//
// Bally/Midway MCR-68k (Xenophobe) main-board I/O block: watchdog, the
// IN0/IN1/DSW read mux, and the "493" IPL1 once-per-frame interrupt strobe.
// Address decode into wdog_we/sel_in0/sel_in1/sel_dsw is the top-level
// decoder's job (mcr68_map, mcr68.cpp:598-613); this module only reacts to
// the strobes/pins it is handed. Evidence: MAME `bally/mcr68.cpp` (0.289),
// per the project's frozen hardware spec
// (C:\Users\meath\.claude\plans\you-a-makeing-a-fizzy-rabin.md).
//
//   (1) Watchdog   — 0x0B0000-0x0BFFFF: any write in range pets the dog.
//                     8 consecutive VBLANKs with no write trips it
//                     (mcr68.cpp:1225 -- WATCHDOG_TIMER(8)).
//   (2) IN0/IN1/DSW read mux — 0x0D0000/0x0E0000/0x0F0000. All bits are
//                     active low on real hardware; this module does not
//                     interpret them, it only muxes the raw 16-bit pin
//                     vector the integrator supplies for whichever region is
//                     selected. Bit table (mcr68.cpp:674-731) recorded below
//                     for the board-integration layer that drives
//                     in0_pins/in1_pins/dsw_pins -- NOT decoded here:
//
//        IN0 (0x0D0000, active low):
//          bit 0  = COIN1            bit 8  = P1 up
//          bit 1  = COIN2            bit 9  = P1 down
//          bit 2  = COIN3            bit 10 = P1 left
//          bit 5  = TILT             bit 11 = P1 right
//          bit 6  = SERVICE1         bit 12 = P1 button 1
//          bit 7  = Service DIP      bit 13 = P1 button 3
//                                     bit 14 = P1 button 2
//          (bits 3,4,15 unused/open bus on Xenophobe)
//
//        IN1 (0x0E0000, active low) -- 3-player cab, no START buttons,
//        a coin drop starts that player:
//          bit 0  = P2 up            bit 8  = P3 up
//          bit 1  = P2 down          bit 9  = P3 down
//          bit 2  = P2 left          bit 10 = P3 left
//          bit 3  = P2 right         bit 11 = P3 right
//          bit 4  = P2 button 1      bit 12 = P3 button 1
//          bit 5  = P2 button 3      bit 13 = P3 button 3
//          bit 6  = P2 button 2      bit 14 = P3 button 2
//          (bits 7,15 unused/open bus)
//
//        DSW (0x0F0000, active low, low byte only -- high byte open bus):
//          bit 2   = Free Play
//          bit 3   = Coins per Life Unit
//          bit 4   = Life Unit
//          bit 5   = Demo Sounds
//          bits 6-7 = Difficulty
//          (bits 0,1,8-15 unused/open bus)
//
//   (3) "493" IPL1 strobe -- the MCR family's once-per-frame 30 Hz interrupt.
//                     Asserted ~256 E-clocks (+16 for latency, 272 total,
//                     ~352 us) before the *next* vblank_pulse and held for
//                     exactly one scanline (mcr68.cpp:231-244, :1859). Timed
//                     here purely off two periodic strobes supplied by the
//                     video/PTM timing generator -- eclk_en (one pulse per
//                     68000 E-clock, i.e. CPU/10, the same rate the 6840 PTM
//                     runs at) and hsync_pulse (once per scanline) -- so this
//                     module carries no independent notion of dot clocks or
//                     line counts. See the 493 timing note below the always
//                     blocks for the exact scheme.
//
// Reset (`rst`) is active-high synchronous, matching this project's other
// hand-written blocks (rtl/snd/pia6821.sv). `wdog_trip` is a single
// clk-wide pulse; if the integrator's system-reset input needs to be held
// for longer than one clk to guarantee a clean FX68K reset, stretch it at
// the top level -- this module only reports the trip event.
//
// =============================================================================
// MULTI-TITLE UPDATE (profile-driven, same shape as rtl/mcr68_addr_decode.sv)
// =============================================================================
// Two things genuinely differ per title in THIS module. Both are gated on the
// game profile and both default to the Xenophobe behaviour, so an existing
// instantiation that connects none of the new ports (which is exactly what
// rtl/mcr68_main_board.sv does) is bit-for-bit unchanged -- CONTRACT RULE 1 of
// rtl/mcr68_game_profile.svh, verified by the cycle-by-cycle equivalence sweep
// against a frozen copy of the pre-profile RTL in sim/tb_mcr68_io.sv.
//
// (a) THE READ MUX GAINS TWO PIGSKIN PORTS.
//     pigskin_map has no plain portr("IN1") and no plain portr("DSW")
//     (mcr68.cpp:623-639). Their contents are folded into two COMPOSITE ports
//     that also carry the 49-way stick nibbles:
//         0x080000-0x08FFFF  pigskin_port_1_r = IN1 | 49WAY-P1 (mcr68.cpp:553)
//         0x0A0000-0x0AFFFF  pigskin_port_2_r = DSW | 49WAY-P2 (mcr68.cpp:562)
//     rtl/mcr68_addr_decode.sv emits these as cs_pigskin_port1 /
//     cs_pigskin_port2 and holds cs_in1 / cs_dsw low for the whole address
//     space under MAP_PIGSKIN. This module therefore routes
//     sel_pigskin_port1 -> in1_pins and sel_pigskin_port2 -> dsw_pins: the
//     COMPOSITION (OR-ing the translate49 nibbles onto the port words) is done
//     upstream in rtl/inputs/mcr68_input_map.sv, which is what feeds
//     in1_pins/dsw_pins. This module stays a pure mux and interprets no bit,
//     exactly as before.
//
//     NOT consumed here: cs_protect (0x120000-0x120001, pigskin_protection_r/w,
//     mcr68.cpp:518-551). That is a five-byte write-history state machine, not
//     input conditioning, and it has its own read data path; it is deliberately
//     left to the integrator rather than smuggled into the input mux. See
//     doc/integration_requests/inputs.md.
//
// (b) THE 493 LEAD TIME DIFFERS FOR PIGSKIN.
//     m_timing_factor is (CPU/10)*(256+16) E-clocks for xenophob (:1857),
//     Xenophobe, Blasted and Arch Rivals, but
//     (CPU/10)*115 for pigskin (:1946). IRQ1_OFFSET_ECLKS_PIGSKIN carries that
//     second constant; it is selected only when the profile is GAME_PIGSKIN,
//     so the value the integrator passes in IRQ1_OFFSET_ECLKS is used
//     unchanged for every other title.
// =============================================================================

/* verilator lint_off IMPORTSTAR */
import mcr68_game_pkg::*;
/* verilator lint_on IMPORTSTAR */

`default_nettype none
module mcr68_io #(
  parameter int WDOG_LIMIT         = 8,       // VBLANKs with no watchdog write before trip (mcr68.cpp:1225)
  parameter int E_CLOCKS_PER_FRAME = 25746,   // nominal E-clocks/frame = (CPU/10)/30 = 772_380/30 (mcr68.cpp:1192-1222)
  parameter int IRQ1_OFFSET_ECLKS  = 256 + 16, // 493 lead time before vblank_pulse, in E-clocks (mcr68.cpp:1859)

  // 493 lead time for GAME_PIGSKIN only (mcr68.cpp:1946 -- m_timing_factor =
  // (CPU/10) * 115). Ignored for every other profile.
  parameter int IRQ1_OFFSET_ECLKS_PIGSKIN = 115,

  // Static profile. Default GAME_XENOPHOB so an existing instantiation that
  // connects none of the new ports keeps exactly its previous behaviour.
  parameter mcr68_game_e GAME_STATIC      = GAME_XENOPHOB,
  // When 0 (default) the `game` INPUT PORT IS IGNORED and GAME_STATIC is used.
  parameter bit          RUNTIME_GAME_SEL = 1'b0,

  // ---------------------------------------------------------------------
  // PCB-accurate "493" generation (Arch Rivals schematic sheet 7, manual
  // 16-4001-K-101): the frame interrupt IS the decoded scanline count
  // 493 -- there is no E-clock offset and no per-title lead-time constant
  // on the real board. When USE_SCANLINE_493 is set, irq1 is asserted the
  // instant the video timing generator's own v_count reaches
  // IRQ493_LINE and held for exactly one scanline (cleared on the next
  // hsync_pulse), driven directly off v_count rather than off a computed
  // E-clock countdown. This makes the strobe immune to the video
  // generator's raster totals/dot clock -- unlike the E-clock scheme
  // below, which silently assumes a specific frame period baked into
  // E_CLOCKS_PER_FRAME (see rtl/mcr68_main_board.sv's own comment on that
  // coupling).
  //
  // Default 0 so every existing instantiation (which does not connect
  // v_count or this parameter) is bit-for-bit unchanged -- the MAME-diff
  // -verified E-clock scheme below remains the default for every profile
  // until a PCB-accurate raster profile has been re-verified against a
  // fresh trace. See docs/ARCHRIVALS_PCB_RTL_PLAN.md P0-2.
  // ---------------------------------------------------------------------
  parameter bit       USE_SCANLINE_493 = 1'b0,
  parameter int        IRQ493_LINE      = 493
) (
  input  wire         clk,
  input  wire         rst,

  // ---- profile select (only sampled when RUNTIME_GAME_SEL) ----
  input  mcr68_game_e game,

  // ---- (1) watchdog, 0x0B0000-0x0BFFFF ----
  input  wire         wdog_we,       // asserted for any write cycle decoded in the watchdog range
  input  wire         vblank_pulse,  // once per frame (scanline 0 / VSYNC edge); shared reference with (3) and the PTM's C1
  output logic         wdog_trip,     // one clk-wide pulse -> feed the system/CPU reset network

  // ---- (2) IN0/IN1/DSW read mux, 0x0D0000/0x0E0000/0x0F0000 ----
  input  wire         sel_in0,       // top-level decoder: address in 0x0D0000-0x0DFFFF this cycle
  input  wire         sel_in1,       // address in 0x0E0000-0x0EFFFF
  input  wire         sel_dsw,       // address in 0x0F0000-0x0FFFFF
  // pigskin_map only (mcr68_addr_decode's cs_pigskin_port1/2). Held low by the
  // decoder under every non-pigskin profile; additionally ignored here unless
  // the selected profile is GAME_PIGSKIN, so leaving them unconnected on a
  // Xenophobe build cannot affect the mux.
  input  wire         sel_pigskin_port1, // address in 0x080000-0x08FFFF
  input  wire         sel_pigskin_port2, // address in 0x0A0000-0x0AFFFF
  input  wire [15:0]  in0_pins,      // raw active-low IN0 pins -- bit meaning is board-integration's concern, see header
  input  wire [15:0]  in1_pins,      // raw active-low IN1 pins   (== pigskin_port_1 word under GAME_PIGSKIN)
  input  wire [15:0]  dsw_pins,      // raw active-low DSW pins   (== pigskin_port_2 word under GAME_PIGSKIN)
  output logic [15:0] io_rdata,      // muxed read data; 0xFFFF (all-high / inactive) when none selected

  // ---- (3) "493" IPL1 once-per-frame strobe ----
  input  wire         eclk_en,       // one clk-wide pulse per 68000 E-clock period (CPU/10)
  input  wire         hsync_pulse,   // once per scanline
  // Only sampled when USE_SCANLINE_493 -- the video timing generator's raw
  // line counter (rtl/video/mcr68_video_timing.sv's v_count). Float-safe
  // default so an existing instantiation that leaves this unconnected
  // (every one before this parameter existed) elaborates unchanged.
  input  wire  [9:0]  v_count,
  output logic         irq1           // one-scanline-wide pulse, active high
);

  // ===========================================================================
  // (0) Profile selection. Purely static configuration (contract rule 2):
  //     `is_pigskin` is a constant for the whole run of a given build unless
  //     RUNTIME_GAME_SEL is set and the integrator changes `game`, which is
  //     only legal while the game is held in reset.
  // ===========================================================================
  mcr68_game_e sel_game;
  logic        is_pigskin;

  assign sel_game   = RUNTIME_GAME_SEL ? game : GAME_STATIC;
  assign is_pigskin = (sel_game == GAME_PIGSKIN);

  // ===========================================================================
  // (1) Watchdog: counts vblank_pulse events since the last wdog_we. Trips
  //     (pulses wdog_trip and rearms) on the WDOG_LIMIT-th consecutive VBLANK
  //     with no intervening write. A write in the same cycle as a vblank_pulse
  //     pets the dog rather than counting that VBLANK, matching "any write in
  //     range resets the counter".
  // ===========================================================================
  localparam int WDOG_CNT_W = $clog2(WDOG_LIMIT + 1);
  localparam logic [WDOG_CNT_W-1:0] WDOG_TRIP_CNT = WDOG_CNT_W'(WDOG_LIMIT - 1);
  logic [WDOG_CNT_W-1:0] wdog_cnt;

  always_ff @(posedge clk) begin
    if (rst) begin
      wdog_cnt  <= '0;
      wdog_trip <= 1'b0;
    end else begin
      wdog_trip <= 1'b0; // default: single-cycle pulse
      if (wdog_we) begin
        wdog_cnt <= '0;
      end else if (vblank_pulse) begin
        if (wdog_cnt == WDOG_TRIP_CNT) begin // this is the WDOG_LIMIT-th consecutive VBLANK with no write
          wdog_cnt  <= '0;
          wdog_trip <= 1'b1;
        end else begin
          wdog_cnt <= wdog_cnt + 1'b1;
        end
      end
    end
  end

  // ===========================================================================
  // (2) IN0/IN1/DSW read mux: pure passthrough of whichever raw pin vector is
  //     selected. No bit is interpreted here -- see header comment for the
  //     documented bit table that the board-integration layer must honour
  //     when it builds in0_pins/in1_pins/dsw_pins.
  // ===========================================================================
  //
  //     The two pigskin selects are folded in with an AND against is_pigskin,
  //     so under any non-pigskin profile these three expressions reduce
  //     literally to sel_in0 / sel_in1 / sel_dsw -- the pre-profile mux.
  // ===========================================================================
  logic sel_in1_eff, sel_dsw_eff;
  assign sel_in1_eff = sel_in1 | (is_pigskin & sel_pigskin_port1); // mcr68.cpp:628
  assign sel_dsw_eff = sel_dsw | (is_pigskin & sel_pigskin_port2); // mcr68.cpp:629

  always_comb begin
    unique case (1'b1)
      sel_in0:     io_rdata = in0_pins;
      sel_in1_eff: io_rdata = in1_pins;
      sel_dsw_eff: io_rdata = dsw_pins;
      default:     io_rdata = 16'hFFFF; // nothing selected -- inactive-high default, not a real bus value
    endcase
  end

  // ===========================================================================
  // (3) "493" IPL1 strobe.
  //
  // Timing scheme:
  //   - `ecount` free-runs on `eclk_en`, reset to 0 by every `vblank_pulse`.
  //     Because vblank_pulse recurs every E_CLOCKS_PER_FRAME E-clocks on this
  //     hardware (fixed 30 Hz refresh, mcr68.cpp:1192-1222), resetting the
  //     counter every frame means no drift accumulates across frames even
  //     though E_CLOCKS_PER_FRAME is a nominal constant rather than something
  //     this module measures.
  //   - `armed` is set by vblank_pulse and cleared the instant the strobe
  //     fires, so it fires exactly once per frame regardless of how long
  //     ecount dwells at/after the target value.
  //   - The strobe fires when ecount reaches TRIGGER_COUNT =
  //     E_CLOCKS_PER_FRAME - IRQ1_OFFSET_ECLKS, i.e. IRQ1_OFFSET_ECLKS
  //     E-clocks before the *next* vblank_pulse -- matching mcr68.cpp:1859's
  //     "(256+16) E-clocks before VBLANK".
  //   - Once irq1 is asserted it is held until the next hsync_pulse edge,
  //     which by definition is exactly one scanline later -- giving the
  //     "held for exactly one scanline" behaviour (mcr68.cpp:231-244)
  //     without this module needing to know dot clocks, line counts or
  //     total lines/frame at all. A trigger that happens to land on the
  //     same cycle as an hsync_pulse does not self-clear that same cycle
  //     (irq1 is still 0 going into the compare), so the pulse is never
  //     truncated to zero width; it always spans a full scanline period.
  // ===========================================================================
  localparam int ECNT_W        = $clog2(E_CLOCKS_PER_FRAME + 1);
  localparam int TRIGGER_COUNT = E_CLOCKS_PER_FRAME - IRQ1_OFFSET_ECLKS;
  // `ecount` names the number of completed E-clock intervals since the last
  // VBLANK.  Compare the pre-increment value with one less than the desired
  // elapsed interval count so the assertion edge occurs after exactly
  // TRIGGER_COUNT E-clock enables, matching MAME's timer scheduled at
  // (1/30)-m_timing_factor rather than one enable late.
  localparam int TRIGGER_PRECOUNT = (TRIGGER_COUNT > 0) ? (TRIGGER_COUNT - 1) : 0;

  // Pigskin's shorter lead time (mcr68.cpp:1946). Clamped at 0 so a testbench
  // that shrinks E_CLOCKS_PER_FRAME below this offset still elaborates; the
  // value is unreachable on any non-pigskin profile regardless.
  localparam int TRIGGER_COUNT_PIGSKIN =
      (E_CLOCKS_PER_FRAME > IRQ1_OFFSET_ECLKS_PIGSKIN)
        ? (E_CLOCKS_PER_FRAME - IRQ1_OFFSET_ECLKS_PIGSKIN) : 0;
  localparam int TRIGGER_PRECOUNT_PIGSKIN =
      (TRIGGER_COUNT_PIGSKIN > 0) ? (TRIGGER_COUNT_PIGSKIN - 1) : 0;

  // Static select. Constant-folds to TRIGGER_PRECOUNT for every profile except
  // GAME_PIGSKIN, so Xenophobe's compare is bit-identical to the pre-profile
  // `ecount == TRIGGER_PRECOUNT[ECNT_W-1:0]`.
  logic [ECNT_W-1:0] trigger_precount;
  assign trigger_precount = is_pigskin ? TRIGGER_PRECOUNT_PIGSKIN[ECNT_W-1:0]
                                       : TRIGGER_PRECOUNT[ECNT_W-1:0];

  logic [ECNT_W-1:0] ecount;
  logic              armed;

  // Single always_ff: `armed` is written from both the vblank_pulse rearm and
  // the fire condition below, so it must have exactly one driving process.
  //
  // USE_SCANLINE_493 takes an entirely different, simpler path: irq1 is set
  // the instant hsync_pulse fires while v_count already reads IRQ493_LINE
  // (v_count has been updated to its new value by the same edge that
  // asserts hsync_pulse -- see rtl/video/mcr68_video_timing.sv's counter),
  // and cleared on the following hsync_pulse -- exactly the schematic's
  // "decoded scanline 493, held one line" behaviour, with no E-clock
  // countdown, no armed/rearm bookkeeping and no frame-period assumption.
  always_ff @(posedge clk) begin
    if (rst) begin
      ecount <= '0;
      // MAME reset disables the 493 timer; scanline 0 arms it for the first
      // time, matching m_493_on_timer->adjust() in scanline_cb().
      armed  <= 1'b0;
      irq1   <= 1'b0;
    end else if (USE_SCANLINE_493) begin
      if (hsync_pulse && (v_count == IRQ493_LINE[9:0]))
        irq1 <= 1'b1;
      else if (irq1 && hsync_pulse)
        irq1 <= 1'b0;
    end else begin
      if (vblank_pulse) begin
        ecount <= '0;
        armed  <= 1'b1;
      end else if (eclk_en) begin
        ecount <= ecount + 1'b1;
      end

      if (armed && eclk_en && (ecount == trigger_precount)) begin
        irq1  <= 1'b1;
        armed <= 1'b0;
      end else if (irq1 && hsync_pulse) begin
        irq1 <= 1'b0;
      end
    end
  end

endmodule
`default_nettype wire
