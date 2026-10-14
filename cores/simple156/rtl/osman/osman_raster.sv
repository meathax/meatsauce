// SPDX-License-Identifier: GPL-3.0-or-later
// CRT-standard raster: 512x274 at 58 Hz, visible 320x240 at y=8.
// MAME's simpl156 driver only declares an abstract 512x256 screen at 58 Hz.
// Emitting that literally gave 14.85 kHz lines and 256-line frames, which
// consumer and arcade CRTs fail to lock (rolling picture). The 28 MHz DECO
// boards in MAME (boogwing, cninja robocop2/mutantf) and the hardware-tested
// Boogie Wings/Night Slashers donors run 274 lines with VS on lines 250-252
// (15.84 kHz). Keeping the 512-pixel, 3072-clock line (render budget, x range,
// even pixel cadence for the scandoubler) and adding those vblank lines at
// SYS_HZ = 58*274*3072 gives 15.89 kHz and exactly MAME's 58 Hz.
//
// y is the 8-bit picture coordinate used by the renderer and blanking logic.
// It saturates at 255 for the extra vblank lines 255..273; line holds the
// full 9-bit count.
module osman_raster #(
    parameter integer SYS_HZ = 48820224,
    parameter integer PIXEL_DIV = 6,
    parameter integer VBLANK_US = 800
)(
    input wire clk, reset, pause,
    output wire ce_pixel,
    output reg [8:0] x,
    output wire [7:0] y,
    output wire display_enable, hblank, vblank, irq_level,
    output wire hs, vs,
    output reg line_start, frame_start, irq_event,
    output reg [31:0] frame_count
);
    localparam integer HTOTAL = 512, VTOTAL = 274;
    localparam integer DIV_BITS = PIXEL_DIV > 1 ? $clog2(PIXEL_DIV) : 1;
    localparam integer VBLANK_CLKS = integer'((SYS_HZ * 64'(VBLANK_US) + 999999)/1000000);
    localparam integer VB_BITS = VBLANK_CLKS > 1 ? $clog2(VBLANK_CLKS+1) : 1;
    reg [DIV_BITS-1:0] divider;
    reg [8:0] line;
    reg [VB_BITS-1:0] vb_remaining;
    reg frame_counter_armed;
    assign y = line > 9'd255 ? 8'd255 : line[7:0];
    assign ce_pixel = !reset && !pause && divider == DIV_BITS'(PIXEL_DIV-1);
    assign hblank = x >= 320;
    // The game input and IRQ use MAME's explicit 800us pulse. Video blanking
    // uses the visible rectangle; these are intentionally distinct signals.
    assign vblank = vb_remaining != 0;
    // Native initial blanking is an input state, not a scheduled IRQ callback.
    assign irq_level = vblank && frame_counter_armed;
    assign display_enable = !hblank && line >= 8 && line < 248;
    // HSync x384-415. Set so the 320-pixel picture centres 35.4 us after HSync
    // starts, the middle of a 15 kHz TV/arcade monitor's visible window
    // (picture and its 9.4 us back-porch offset); 368-399 put it 37.4 us out, a
    // visible blank strip on the left of the tube.
    assign hs = !(x >= 384 && x < 416);
    assign vs = !(line >= 250 && line < 253);
    always @(posedge clk) begin
        line_start <= 0;
        frame_start <= 0;
        irq_event <= 0;
        if (reset) begin
            divider <= 0;
            // Native cold blank state does not itself assert an IRQ.
            x <= 0; line <= 248;
            frame_count <= 0;
            vb_remaining <= VB_BITS'(VBLANK_CLKS);
            frame_counter_armed <= 0;
        end else if (!pause) begin
            if (vb_remaining != 0) begin
                vb_remaining <= vb_remaining - 1'b1;
                // Native screen frame_number advances at actual vblank end.
                // The cold initial countdown has no scheduled end callback.
                if (vb_remaining == 1 && frame_counter_armed)
                    frame_count <= frame_count + 1'b1;
            end
            if (ce_pixel) begin
                divider <= 0;
                if (x == 9'(HTOTAL-1)) begin
                    x <= 0;
                    line_start <= 1;
                    if (line == 9'(VTOTAL-1)) begin
                        line <= 0;
                        frame_start <= 1;
                    end else line <= line + 1'b1;
                    if (line == 247) begin
                        vb_remaining <= VB_BITS'(VBLANK_CLKS);
                        irq_event <= 1;
                        frame_counter_armed <= 1;
                    end
                end else x <= x + 1'b1;
            end else divider <= divider + 1'b1;
        end
    end
endmodule
