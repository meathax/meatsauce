// Action Hollywood host binding for the MIT MeatCore Credits overlay (credits/rtl/credits_overlay.sv, unmodified).
// One clock (clk_sys == CLK_VIDEO, 48 MHz) and the game's own clk/6 pixel enable: no new enable cadence.
// Inserted on the native 352x240 raster after the debug overlay and before CRT Adjust / arcade_video /
// screen_rotate.  RGB, HS, VS, HB and VB all pass through the overlay's three CE-enabled register stages, so they
// stay aligned; ce_out is the input CE itself (the overlay registers update one clock after each CE, like the game).
`default_nettype none
module ah_credits #(parameter integer WIDTH=352, HEIGHT=240) (
    input  wire        clk, reset, ce_pix,
    input  wire        menu_trigger,      // status bit from the OSD "R[120],Credits" action
    input  wire        dismiss,           // any controller / OSD button / key / OSD open
    input  wire        direct_video,
    input  wire  [1:0] rot_menu,          // OSD Rotation (status[45:44]): Normal, 90 CW, 90 CCW, 180
    input  wire  [7:0] r_in, g_in, b_in,
    input  wire        hs_in, vs_in, hb_in, vb_in,
    output wire        ce_out,
    output wire  [7:0] r_out, g_out, b_out,
    output wire        hs_out, vs_out, hb_out, vb_out,
    output wire        active             // credits on screen (clk domain) -> game pause
);
    // Same transform the HDMI framebuffer (sys screen_rotate) applies after this stage:
    // Normal -> 0, 90 CW -> 1 (CW), 90 CCW -> 3 (CCW), 180 -> 0 (picture already flipped by the game renderer).
    // Direct video bypasses the framebuffer, so the CRT sees the native raster (0).
    // 180 is applied upstream in the game renderer, so the overlay itself is upright for Normal/180;
    // only the 90-degree framebuffer rotations need the overlay pre-rotated.
    wire [1:0] rotation = (direct_video || rot_menu == 2'd0 || rot_menu == 2'd3) ? 2'd0 : {rot_menu[1], rot_menu[1] ^ rot_menu[0]};
    credits_overlay #(.WIDTH(WIDTH), .HEIGHT(HEIGHT)) credits (
        .clk_video(clk), .reset(reset), .ce_pixel(ce_pix),
        .menu_trigger(menu_trigger), .dismiss(dismiss), .rotation(rotation),
        .r_in(r_in), .g_in(g_in), .b_in(b_in), .hs_in(hs_in), .vs_in(vs_in),
        .hblank_in(hb_in), .vblank_in(vb_in),
        .r_out(r_out), .g_out(g_out), .b_out(b_out), .hs_out(hs_out), .vs_out(vs_out),
        .hblank_out(hb_out), .vblank_out(vb_out), .de_out(), .active(active)
    );
    assign ce_out = ce_pix;
endmodule
`default_nettype wire
