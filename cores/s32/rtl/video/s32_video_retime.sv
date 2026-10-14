`timescale 1ns/1ps
//============================================================================
//  System 32 output retimer: uniform CE_PIXEL for direct video.
//
//  The native pixel enable is generated in the clk_sys (48.317 MHz) domain by
//  a fractional accumulator (s32_video.sv): 320-wide mode needs a 7.5-clock
//  pixel, so ce_pix alternates 8,7,8,7 clk_sys periods.  The MiSTer HDMI
//  scaler retimes through a framebuffer and never shows this, but direct
//  video transmits each pixel with its true duration; a downstream sampler
//  that assumes a uniform pixel width (e.g. RetroTink 4K DV decimation) then
//  duplicates/drops samples in a fixed column pattern, visible as tile-column
//  separation whenever the image scrolls (arabfgt/ga2 report, 2026-08-29).
//
//  In the clk_ram (96.635 MHz = 2x clk_sys, same PLL) domain both pixel
//  periods are exact integers: 15 clocks (320 mode) and 12 clocks (416 mode).
//  This module re-samples the finished output stream onto that uniform grid.
//  The grid is anchored at each HSync rising edge; a line is 410*15 = 6150
//  (320) or 512*12 = 6144 (416) clk_ram cycles, both exact multiples of the
//  period, so the anchor is a no-op in steady state and only corrects
//  startup/mode changes.  The mid-pixel sample point (8 of 15, 6 of 12) has
//  >= 5 cycles of margin against the bounded (+/-2 clk_ram) accumulator
//  jitter of the source stream, so every uniform tick samples strictly
//  inside its source pixel.
//
//  bypass=1 (CRT Adjust active): that feature's read cadence is deliberately
//  fractional (quarter-cycle H-Size stretch, analog CRT output only), so the
//  source cadence is preserved 1:1 - each source tick is re-emitted as a
//  single clk_ram CE pulse with the settled pixel data.
//============================================================================

module s32_video_retime (
    input             clk,        // clk_ram (2x clk_sys, same PLL, in phase)
    input             rst,
    input             mode_416,
    input             bypass,     // preserve source cadence (CRT Adjust path)

    // source stream, clk_sys domain (synchronous 1:2 relation)
    input             raw_ce,     // one clk_sys cycle per pixel
    input      [23:0] raw_rgb,
    input             raw_hs,
    input             raw_vs,
    input             raw_de,

    // uniform stream, clk domain
    output reg        ce,         // single-cycle pulse
    output reg [23:0] rgb,
    output reg        hs,
    output reg        vs,
    output reg        de
);

reg [3:0] cnt;
reg       raw_ce_d, raw_hs_d;

wire [3:0] period_m1 = mode_416 ? 4'd11 : 4'd14;
wire [3:0] sample_at = mode_416 ? 4'd6  : 4'd8;

// Source registers update on the clk_sys posedge that ends the raw_ce-high
// cycle; sampling on the falling edge seen from clk_ram (one cycle later)
// reads the settled new pixel.  The uniform path samples mid-pixel, which is
// safe under either update convention.
wire raw_ce_fall = ~raw_ce & raw_ce_d;
wire take = bypass ? raw_ce_fall : (cnt == sample_at);

always @(posedge clk) begin
    raw_ce_d <= raw_ce;
    raw_hs_d <= raw_hs;
    ce <= 1'b0;

    // HSync rises on a pixel-boundary tick edge E (a shared clk_sys/clk_ram
    // posedge).  The registered value is first visible here at E+1, where a
    // free-running in-phase grid holds cnt==1, so restarting at 1 makes the
    // per-line anchor an exact no-op in steady state.
    if (raw_hs & ~raw_hs_d) cnt <= 4'd1;
    else                    cnt <= (cnt == period_m1) ? 4'd0 : cnt + 1'd1;

    if (take) begin
        rgb <= raw_rgb;
        hs  <= raw_hs;
        vs  <= raw_vs;
        de  <= raw_de;
        ce  <= 1'b1;
    end

    if (rst) begin
        cnt      <= 4'd0;
        raw_ce_d <= 1'b0;
        raw_hs_d <= 1'b0;
        ce       <= 1'b0;
        rgb      <= 24'h000000;
        hs       <= 1'b0;
        vs       <= 1'b0;
        de       <= 1'b0;
    end
end

endmodule
