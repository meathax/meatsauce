//============================================================================
//  Tilemap layer-position register capture.
//
//  Scroll and page-select are ONE coupled address, not two independent
//  register groups.  s32_tilemap computes
//
//      sx_base = scrollx[lay][9:0] - offsx[lay][8:0]
//      sx      = sx_base + x
//      pg      = sx[9] ? pg_word[14:8] : pg_word[6:0]
//
//  so scroll chooses which page slot of the 1024-pixel torus is on screen and
//  the page word says which page lives in that slot.  Sampling the two groups
//  at different instants lets the renderer pair a scroll value with page
//  words that never coexisted in the CPU's register file.
//
//  That is not hypothetical.  A game that scrolls a layer past the 512-pixel
//  slot boundary wraps its scroll register and rotates the page word in the
//  SAME vblank burst to compensate.  Measured on Spider-Man (MAME 0.289,
//  attract chapter 1): NBG2/NBG3 ($1FF22/$1FF2A) step -7 px/frame and wrap
//  +505 every 73 frames, each wrap accompanied by a page rotation on
//  $1FF48-$1FF4E in the same frame.  Pairing the pre-wrap scroll with the
//  post-rotation pages renders that layer ~505 px away for exactly one frame,
//  or drops it onto a page not yet populated so it disappears.
//
//  Capture is therefore once per frame AND atomic across both groups:
//
//   - once per frame, because these are whole-layer quantities.  The 315-5387
//     exposes rowscroll/rowselect tables ($1FF04) precisely so software can
//     vary scroll per scanline, which would be redundant if the scroll
//     registers themselves took effect mid-frame.  Capturing per line also let
//     a mid-frame update land between the integer and fractional halves of one
//     scroll value, tearing the picture into horizontal bands.
//
//   - at the first line snapshot of the frame, not at the vblank edge.  The
//     vblank-start pulse is the same one that raises the CPU's vblank
//     interrupt, so the game's register burst is causally AFTER it.  Capturing
//     on that edge samples the previous frame's values; capturing at the first
//     line of the following frame samples the burst the game just wrote, which
//     is also when the page words are taken.
//
//  arm/consume rather than a decode of the line counter: if the frame's first
//  render kick is dropped because the renderer is still busy, the arm survives
//  to the next line start and the pair is still captured together -- late, but
//  never incoherent.
//============================================================================

module s32_tilemap_regcap (
    input             clk,
    input             rst,

    // frame and line boundaries
    input             vbl_start,   // start of vblank; arms the frame capture
    input             line_start,  // a line render snapshot is being taken

    // CPU-domain register file (clk_sys shadows, quasi-static in this domain)
    input      [15:0] w_pages       [0:7],
    input      [15:0] w_scrollx     [0:3],
    input      [15:0] w_scrolly     [0:3],
    input      [15:0] w_offsx       [0:3],
    input      [15:0] w_offsy       [0:3],
    input      [15:0] w_scrollfracx [0:1],
    input      [15:0] w_scrollfracy [0:1],
    input      [15:0] w_zoomx       [0:1],
    input      [15:0] w_zoomy       [0:1],

    // renderer-domain snapshot
    output reg [15:0] tm_pages       [0:7],
    output reg [15:0] tm_scrollx     [0:3],
    output reg [15:0] tm_scrolly     [0:3],
    output reg [15:0] tm_offsx       [0:3],
    output reg [15:0] tm_offsy       [0:3],
    output reg [15:0] tm_scrollfracx [0:1],
    output reg [15:0] tm_scrollfracy [0:1],
    output reg [15:0] tm_zoomx       [0:1],
    output reg [15:0] tm_zoomy       [0:1],

    // asserted on the cycle the frame pair is captured (verification aid)
    output reg        frame_capture
);

reg     frame_arm;
integer i;

initial begin
    frame_arm = 1'b1;
    frame_capture = 1'b0;
    for (i = 0; i < 8; i = i + 1) tm_pages[i] = 16'h0000;
    for (i = 0; i < 4; i = i + 1) begin
        tm_scrollx[i] = 16'h0000; tm_scrolly[i] = 16'h0000;
        tm_offsx[i]   = 16'h0000; tm_offsy[i]   = 16'h0000;
    end
    for (i = 0; i < 2; i = i + 1) begin
        tm_scrollfracx[i] = 16'h0000; tm_scrollfracy[i] = 16'h0000;
        // neutral 1.0 zoom default
        tm_zoomx[i] = 16'h0200; tm_zoomy[i] = 16'h0200;
    end
end

always @(posedge clk) begin
    frame_capture <= 1'b0;

    if (line_start) begin
        // Page words are a per-line snapshot: a game may legitimately rotate
        // them mid-frame, and the renderer must see that on the next line.
        for (i = 0; i < 8; i = i + 1) tm_pages[i] <= w_pages[i];

        // The frame's coupled scroll lands in this same snapshot.
        if (frame_arm) begin
            frame_arm     <= 1'b0;
            frame_capture <= 1'b1;
            for (i = 0; i < 4; i = i + 1) begin
                tm_scrollx[i] <= w_scrollx[i];
                tm_scrolly[i] <= w_scrolly[i];
                tm_offsx[i]   <= w_offsx[i];
                tm_offsy[i]   <= w_offsy[i];
            end
            for (i = 0; i < 2; i = i + 1) begin
                tm_scrollfracx[i] <= w_scrollfracx[i];
                tm_scrollfracy[i] <= w_scrollfracy[i];
                tm_zoomx[i]       <= w_zoomx[i];
                tm_zoomy[i]       <= w_zoomy[i];
            end
        end
    end

    // Last, so a coincident vblank edge re-arms rather than being lost.
    if (rst)            frame_arm <= 1'b1;
    else if (vbl_start) frame_arm <= 1'b1;
end

endmodule
