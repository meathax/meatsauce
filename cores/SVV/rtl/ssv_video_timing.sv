// SPDX-License-Identifier: GPL-3.0-or-later
// Raw SSV CRT timing: 42.954545 MHz / 6, 454 x 262, descriptor active area.
`timescale 1ns/1ps

module ssv_video_timing #(
    parameter logic [15:0] PIXEL_INC = ssv_pkg::SSV_PIXEL_INC
) (
    input              clk,
    input              rst,
    input logic [8:0]  active_width,
    input logic [8:0]  active_height,
    output logic       ce_pixel,
    // Exactly twice ce_pixel and phase-locked to it, for the line doubler.
    //
    // It MUST come from here rather than from a second accumulator in the
    // wrapper. Arcade-SSV.sv used to run its own, restarted on the line
    // reference while this one free-runs, and verif/tb_ssv_scandoubler.sv
    // measured the result at a constant 907 ticks per line where exact
    // doubling of a 454-pixel line needs 908 -- so the second copy of every
    // line was one pixel short.
    output logic       ce_pix_x2,
    output logic [8:0] hcnt,
    output logic [8:0] vcnt,
    output logic       hblank,
    output logic       vblank,
    output logic       hsync,
    output logic       vsync,
    output logic       vblank_pulse,
    output logic       irq3_pulse
);

import ssv_pkg::*;

// The accumulator runs at DOUBLE the pixel increment and the native pixel
// enable is every second carry. That makes ce_pix_x2 exactly 2x ce_pixel by
// construction, with no second accumulator to drift against.
//
// It is also bit-identical to the previous single-rate version, which is why
// it does not move a single frame CRC: the k-th native tick used to be the
// smallest N with floor(N*INC/65536) == k, and the 2k-th double-rate carry is
// the smallest N with floor(N*2*INC/65536) == 2k -- the same condition, so
// both land on exactly the same clock cycles.
//
// LINE-PHASE RESET (Direct Video correctness).
//
// The accumulator used to run continuously across the line boundary, carrying
// its residue from one line into the next. 454 pixels cost 908 carries, i.e.
// 908 * 65536 / 19420 = 3064.13 clk, so the residue made the line length
// alternate: 3064 clk on most lines and 3065 clk on 51 lines of every 262-line
// frame -- one long line every ~5 lines -- and because the leftover is 0.13
// clk per line the positions of those long lines walk UP the raster by two
// lines per frame.
//
// On the analog and scaled-HDMI paths that is invisible: both re-capture the
// raster on ce_pixel, so a clk-domain cycle more or less between pixel enables
// has no representation downstream. Direct Video has no such stage. sys_top
// clocks the ADV7513 at CLK_VIDEO (= clk_sys here) and emits one HDMI pixel per
// CLK_VIDEO cycle, so those 51 lines are literally one HDMI pixel longer than
// the rest of the frame. A line-locked external scaler -- a RetroTINK 4K, for
// one -- breaks its sample phase on each of them, and the seams march two
// scanlines per frame: black bars scrolling through the picture at roughly
// 120 lines per second.
//
// Real hardware cannot do this. The board's pixel clock is 42.954545 MHz / 6,
// a fixed integer divide, so every line has an identical pixel phase. Restoring
// the accumulator to a FIXED value on the line wrap restores that property
// here: every line then costs the same number of clk cycles, the 6/7-cycle
// stretch pattern inside a line is identical on every line, and nothing
// downstream sees a moving edge.
//
// The restore value is not zero, and the difference is worth 10x on accuracy.
// A line needs 908 carries; from an accumulator preload R those land inside N
// clocks when R + N*19420 >= 908*65536 = 59506688. From R = 0 the 908th carry
// needs 3065 clocks, giving 7.156952 MHz and 60.1687 Hz -- 265 ppm SLOW. Any
// R in 3808..23227 lands it on 3064 clocks instead (and still keeps the 909th
// out, which needs 3068 clocks even at R = 23227), giving 7.159288 MHz and
// 60.2032 Hz -- 27 ppm fast. 3064 is the integer clock count nearest the true
// 3064.13, so +27 ppm is the smallest error reachable at this clk_sys at all.
// PIXEL_LINE_PRELOAD sits mid-range with margin at both ends.
//
// Residual cost: the CPU-to-pixel ratio that ssv_pkg.sv tunes to -3.7 ppm
// (SSV_CPU_INC) moves by that +27 ppm, since cpu_acc is untouched and only the
// pixel side changes. That is inside the +42 ppm that was measured to move an
// ES5506 four-write group across a Dyna Gear lockstep token, not comfortably
// clear of it -- re-run the audio and lockstep regressions after touching this.
//
// Do NOT chase the rate by re-tuning PIXEL_INC instead. The line length is an
// integer number of clk cycles no matter what PIXEL_INC is, so the reachable
// rates are exactly the 3064 and 3065 above; changing PIXEL_INC only moves
// which one you land on, at the cost of the ratio it was chosen for.
localparam logic [15:0] PIXEL_INC_X2 = PIXEL_INC << 1;

// Accumulator value restored on every line wrap -- see LINE-PHASE RESET above.
// Valid window for a 3064-clock line is 3808..23227; this is mid-range.
localparam logic [15:0] PIXEL_LINE_PRELOAD = 16'd13312;

logic [15:0] pixel_acc;
logic        pix_phase;      // 0 -> next carry is the half tick, 1 -> native

logic [16:0] pixel_sum;
logic        native_tick;
logic        line_wrap;      // native tick that returns hcnt to 0
logic [8:0]  hcnt_next;
logic [8:0]  vcnt_next;
logic        vblank_pulse_next;
logic        irq3_pulse_next;

// Keep the sync outputs registered with the raster state.  The old version
// decoded hcnt/vcnt in an always_comb block; that is functionally equivalent
// at a simulator sample point, but it leaves the sync pins exposed to a
// counter-decode transition while the registered counter bits settle.  The
// ST-0006/X1-007 evidence is consistent with a registered sync boundary, and
// this implementation preserves the existing phase: sync is decoded from the
// very same next counter value that is committed on the native pixel tick.
always_comb begin
    pixel_sum         = {1'b0, pixel_acc} + {1'b0, PIXEL_INC_X2};
    native_tick       = pixel_sum[16] & pix_phase;
    hcnt_next         = hcnt;
    vcnt_next         = vcnt;
    vblank_pulse_next = 1'b0;
    irq3_pulse_next   = 1'b0;
    line_wrap         = 1'b0;

    if (native_tick) begin
        if (hcnt == SSV_HTOTAL - 1) begin
            hcnt_next = 9'd0;
            line_wrap = 1'b1;
            if (vcnt == SSV_VTOTAL - 1)
                vcnt_next = 9'd0;
            else begin
                vcnt_next = vcnt + 1'd1;
                if (vcnt == active_height - 1'd1)
                    vblank_pulse_next = 1'b1;
                // The board IRQ3 source is fixed at physical scanline 240.
                // Drift Out crops the visible area (and therefore its live
                // VBLANK status) at line 238, but MAME's SSV scan timer and
                // raw 262-line raster retain the line-240 interrupt.
                if (vcnt == SSV_VBSTART - 1'd1)
                    irq3_pulse_next = 1'b1;
            end
        end
        else
            hcnt_next = hcnt + 1'd1;
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        pixel_acc    <= PIXEL_LINE_PRELOAD;
        pix_phase    <= 1'b0;
        ce_pixel     <= 1'b0;
        ce_pix_x2    <= 1'b0;
        hcnt         <= 9'd0;
        vcnt         <= 9'd0;
        vblank_pulse <= 1'b0;
        irq3_pulse   <= 1'b0;
        hsync        <= 1'b1;
        vsync        <= 1'b1;
    end
    else begin
        // Restore the carry chain on the line wrap so every line starts from
        // the same pixel phase and therefore takes the same number of clk
        // cycles. Both halves are restored together, which keeps ce_pix_x2
        // exactly 2x ce_pixel and in phase -- the line doubler's invariant.
        if (line_wrap) begin
            pixel_acc <= PIXEL_LINE_PRELOAD;
            pix_phase <= 1'b0;
        end
        else begin
            pixel_acc <= pixel_sum[15:0];
            if (pixel_sum[16]) pix_phase <= ~pix_phase;
        end
        ce_pix_x2 <= pixel_sum[16];
        ce_pixel  <= native_tick;
        hcnt         <= hcnt_next;
        vcnt         <= vcnt_next;
        vblank_pulse <= vblank_pulse_next;
        irq3_pulse   <= irq3_pulse_next;

        if (native_tick) begin
            hsync <= ~((hcnt_next >= 9'd368) && (hcnt_next < 9'd400));
            vsync <= ~((vcnt_next >= 9'd244) && (vcnt_next < 9'd247));
        end
    end
end

always_comb begin
    hblank = (hcnt >= active_width);
    vblank = (vcnt >= active_height);
end

// The exact board sync widths are not documented by MAME's set_raw call.
// These pulses lie wholly in blanking and are suitable for MiSTer output;
// active dimensions and interrupt position remain exact.  Keep this note
// beside the registered decode so a future timing change does not mistake the
// pulse locations for measured ST-0006 hardware values.

`ifdef SIMULATION
// Simulation-only boundary guard.  It has no release hardware cost and makes
// a future edit that accidentally reintroduces a mid-cycle sync transition
// fail at the source rather than only showing up as an HDMI monitor symptom.
always @(hsync or vsync or hblank or vblank) begin
    if (!rst && !ce_pixel)
        $fatal(1, "SSV video boundary changed without native pixel enable");
end
`endif

endmodule
