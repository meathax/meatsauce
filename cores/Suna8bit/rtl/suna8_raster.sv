module suna8_raster
(
    input  logic clk,
    input  logic reset,
    input  logic [2:0] profile_id,
    output logic ce_pix,
    output logic hblank,
    output logic vblank,
    output logic hsync,
    output logic vsync,
    output logic [8:0] pixel_x,
    output logic [8:0] pixel_y,
    output logic [31:0] frame_counter
);

    logic [1:0] div;
    logic [8:0] hcount;
    logic [8:0] vcount;
    logic [8:0] vtotal_last;

    always_comb begin
        ce_pix = (div == 2'd3) && !reset;
        hblank = (hcount >= 9'd256);
        vblank = (vcount < 9'd16) || (vcount >= 9'd240);
        hsync = (hcount >= 9'd288) && (hcount < 9'd320);
        vsync = (vcount >= 9'd248) && (vcount < 9'd252);
        pixel_x = hcount;
        pixel_y = vcount;
        // All six pinned MAME machine configurations use 384x264 timing.
        // Only Hard Head's approximately 59.10 Hz refresh is explicitly
        // identified as PCB-verified; the later-board 260-line variant that
        // was briefly selected here had no qualifying hardware evidence and
        // moved the NMI/VBlank phase away from the behavioral reference.
        // Keep one shared 264-line contract until a board capture proves a
        // profile-specific timing class.
        vtotal_last = 9'd263;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            div <= 2'd0;
            hcount <= 9'd0;
            // MAME's screen device's own phase at CPU-reset-release is at
            // vcount=240 (the start of vblank), not vcount=0 -- confirmed
            // empirically by comparing inter-interrupt T-state intervals
            // against a cycle-stamped MAME hardhead trace: our sim's
            // interrupts landed exactly 240 scanlines (92160 T-states,
            // zero residual) later in-frame than MAME's. See
            // verif/NOTES.md's "Interrupt-phase timing" investigation.
            vcount <= 9'd240;
            frame_counter <= 32'd0;
        end else begin
            if (div == 2'd3) begin
                div <= 2'd0;
                if (hcount == 9'd383) begin
                    hcount <= 9'd0;
                    if (vcount == vtotal_last) begin
                        vcount <= 9'd0;
                    end else begin
                        vcount <= vcount + 1'd1;
                        // MAME's screen_device increments m_frame_number in
                        // its vblank_end callback, which fires at vpos ==
                        // vbend (16 here, suna8.cpp's set_raw(...,16,240)) --
                        // i.e. exactly when vblank ends and active display
                        // begins, not at the vcount wrap to 0. This was
                        // previously incrementing 16 scanlines early (at the
                        // wrap), so any CPU read landing in that window (the
                        // real bug: sparkman's $C0A3 "copyright screen
                        // duration" parity read, suna8.cpp's
                        // sparkman_c0a3_r(): `(m_screen->frame_number()&1)`)
                        // could see the wrong frame parity relative to MAME.
                        if (vcount == 9'd15)
                            frame_counter <= frame_counter + 1'd1;
                    end
                end else begin
                    hcount <= hcount + 1'd1;
                end
            end else begin
                div <= div + 1'd1;
            end
        end
    end

endmodule
