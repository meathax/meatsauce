module s24_video_timing (
    input  logic       clk,
    input  logic       reset,
    input  logic       ce_pixel,
    // 315-5292 synchronization-mode bit 0 selects the documented invalid
    // 512-scanline mode.  System 24 uses zero; keeping the mode here still
    // matters for software/ASIC probing because the chip changes its frame
    // terminal count and exposes the known bad blanking phase.
    input  logic       sync_mode,
    output logic [9:0] hcount,
    output logic [9:0] vcount,
    output logic       hblank,
    output logic       vblank,
    output logic       hsync,
    output logic       vsync,
    output logic       hsync_tick
);
    always_comb begin
        hblank = hcount >= 10'd496;
        // The documented mode-1 failure leaves the normal sync window at
        // 395..398 but does not blank until after it, so the display is
        // enabled during vertical sync.  The remainder of the 512-line
        // frame is blank.  This is intentionally the observed invalid mode,
        // not a new usable monitor format.
        vblank = sync_mode ? (vcount >= 10'd400) : (vcount >= 10'd384);
        // Measured 315-5292 raster, rotated so the active display begins at
        // count zero: 496 active, 43 right border, 48 sync, 69 left border;
        // 384 active, 11 bottom border, 4 sync, 25 top border.
        hsync = !((hcount >= 10'd539) && (hcount < 10'd587));
        vsync = !((vcount >= 10'd395) && (vcount < 10'd399));
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            hcount <= 0;
            vcount <= 0;
            hsync_tick <= 0;
        end else begin
            hsync_tick <= 0;
            if (ce_pixel) begin
                if (hcount == 10'd655) begin
                    hcount <= 0;
                    hsync_tick <= 1'b1;
                    vcount <= sync_mode
                              ? ((vcount == 10'd511) ? 10'd0 : vcount + 10'd1)
                              : ((vcount == 10'd423) ? 10'd0 : vcount + 10'd1);
                end else hcount <= hcount + 10'd1;
            end
        end
    end
endmodule
