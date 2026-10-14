// -----------------------------------------------------------------------------
// mcr68_video_timing.sv
//
// Standalone, reusable MCR-68000 ("MCR-68k") scanline/frame timing generator.
// Factored out of rtl/mcr68_main_board.sv's original inline h_count/v_count
// logic (Phase 2) so Phase 3 (tilemap/sprite video) and any future
// consumer can share one timing source instead of re-deriving it.
//
// -----------------------------------------------------------------------------
// Provenance / evidence tiers (per CLAUDE.md's "Evidence order" -- flag every
// one of these before trusting it as hardware truth):
//
//  1. h_count/v_count, H_TOTAL/V_TOTAL defaults (640/520), and the
//     vblank_pulse/hsync_pulse generation logic are a byte-for-byte copy of
//     rtl/mcr68_main_board.sv's Phase-2 generator, which was verified with
//     ZERO divergence against the real MAME reference trace in Phase 2. That
//     logic (and its timing relationship to the PTM's C1/C3 inputs) is
//     load-bearing and MUST NOT be changed here -- see that file's own header
//     assumption 1 for the underlying 640x520/9.984 MHz-dot-clock derivation
//     (self-consistent from mcr68.cpp:1231-1236, NOT PCB-proven).
//  2. hblank/vblank (level), hsync_n/vsync_n (composite-sync-style, active
//     low) and pixel_x/pixel_y are NEW outputs added by this factoring --
//     they were NOT part of the Phase-2 validated signal set and carry NO
//     MAME-diff verification of their own (mcr68.cpp gives no
//     screen_raw_params, so MAME has nothing to diff these against; a real
//     68000-bus event trace has no pixel-level analog). hblank/vblank/
//     pixel_x/pixel_y are derived purely from the same validated h_count/
//     v_count by comparing against H_ACTIVE/V_ACTIVE, so they cannot disturb
//     vblank_pulse/hsync_pulse's timing -- but their own correctness (exact
//     porch widths, sync polarity/placement) is only a "self-consistent,
//     reasonable default" per evidence tier 5 (assumptions), informed by
//     tier-4 evidence (existing FPGA implementation) below. Revisit with
//     real schematic/PLD evidence if it surfaces.
//  3. H_FP/H_SYNC/V_FP/V_SYNC (sync-pulse placement within the blanking
//     interval) have no PCB/schematic source for this board. Their
//     proportions are informed by tier-4 evidence --
//     third_party/Arcade-MCR3Mono_MiSTer/rtl/mcr3mono.vhd's own hsync/vsync
//     generator for the closely-related MCR-III video board (front
//     porch/sync/back porch split within its own, differently-sized,
//     blanking interval) -- scaled to clean round numbers that fit this
//     board's documented 128-dot/40-line blanking totals. Not schematic-
//     proven for THIS board; do not treat as hardware truth.
// -----------------------------------------------------------------------------

`timescale 1ns/10ps
`default_nettype none
module mcr68_video_timing #(
    parameter int H_TOTAL  = 640, // 512 visible + 128 blank (see assumption 1)
    parameter int V_TOTAL  = 520, // 480 visible + 40 blank  (see assumption 1)
    parameter int H_ACTIVE = 512,
    parameter int V_ACTIVE = 480,
    parameter int H_FP     = 16,  // front porch, dots   (see assumption 3)
    parameter int H_SYNC   = 64,  // hsync pulse width, dots (see assumption 3)
    parameter int V_FP     = 8,   // front porch, lines  (see assumption 3)
    parameter int V_SYNC   = 4    // vsync pulse width, lines (see assumption 3)
) (
    input  logic       clk,
    input  logic       rst,      // synchronous, active-high -- same reset the
                                  // original Phase-2 generator used (the raw
                                  // external/system reset, NOT a watchdog-
                                  // stretched CPU reset: the video timing
                                  // generator free-runs independently of the
                                  // CPU, matching real hardware)
    input  logic       ce_dot,   // dot-clock enable, one clk-wide pulse per pixel

    // ---- raw counters ----
    output logic [9:0] h_count,  // 0 .. H_TOTAL-1
    output logic [9:0] v_count,  // 0 .. V_TOTAL-1

    // ---- level blanking/sync signals (new outputs, see assumption 2/3) ----
    output logic       hblank,   // active (1) during horizontal blanking
    output logic       vblank,   // active (1) during vertical blanking
    output logic       hsync_n,  // composite-sync-style, active low
    output logic       vsync_n,  // composite-sync-style, active low

    // ---- active-video pixel coordinates (new outputs, see assumption 2) ----
    output logic [8:0] pixel_x,  // valid 0..H_ACTIVE-1 while !hblank
    output logic [8:0] pixel_y,  // valid 0..V_ACTIVE-1 while !vblank

    // ---- PTM-facing pulse outputs -- byte-identical to the original
    //      mcr68_main_board.sv generator, see assumption 1. DO NOT change
    //      this pair's timing/edge alignment. ----
    output logic       vblank_pulse, // one clk-wide pulse, once/frame, C1
    output logic       hsync_pulse   // one clk-wide pulse, once/scanline, C3
);

    // =========================================================================
    // Scanline/frame counters + PTM pulse outputs -- byte-for-byte copy of
    // the original mcr68_main_board.sv logic (see assumption 1). Any change
    // to this block's structure, reset, or edge behaviour risks moving
    // vblank_pulse/hsync_pulse by a clock and must not be made without
    // re-running the Phase-2 MAME diff.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            h_count      <= '0;
            v_count      <= '0;
            vblank_pulse <= 1'b0;
            hsync_pulse  <= 1'b0;
        end else begin
            vblank_pulse <= 1'b0;
            hsync_pulse  <= 1'b0;
            if (ce_dot) begin
                if (h_count == 10'(H_TOTAL - 1)) begin
                    h_count <= '0;
                    hsync_pulse <= 1'b1;
                    if (v_count == 10'(V_TOTAL - 1)) begin
                        v_count <= '0;
                        vblank_pulse <= 1'b1;
                    end else begin
                        v_count <= v_count + 1'b1;
                    end
                end else begin
                    h_count <= h_count + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Level blanking + composite-sync-style outputs, purely combinational
    // from h_count/v_count -- cannot affect the pulse timing above.
    // See assumptions 2/3.
    // =========================================================================
    localparam int H_SYNC_START = H_ACTIVE + H_FP;
    localparam int H_SYNC_END   = H_SYNC_START + H_SYNC;
    localparam int V_SYNC_START = V_ACTIVE + V_FP;
    localparam int V_SYNC_END   = V_SYNC_START + V_SYNC;

    assign hblank  = (h_count >= 10'(H_ACTIVE));
    assign vblank  = (v_count >= 10'(V_ACTIVE));
    assign hsync_n = ~((h_count >= 10'(H_SYNC_START)) && (h_count < 10'(H_SYNC_END)));
    assign vsync_n = ~((v_count >= 10'(V_SYNC_START)) && (v_count < 10'(V_SYNC_END)));

    // Active-video pixel coordinates. Low 9 bits of the raw counters --
    // meaningful only while !hblank / !vblank (consumers must gate on
    // that), matching this task's "valid during active video" scope.
    assign pixel_x = h_count[8:0];
    assign pixel_y = v_count[8:0];

endmodule
`default_nettype wire
