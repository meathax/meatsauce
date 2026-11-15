// Big Fight nominal PCB raster: 50MHz/8, 400x261, visible 320x240.
// CRTC R0=49,R4=31,R5=5,R9=7 and80-frame PCB blink qualify cadence.
// MAME0.289 hardcodes272 lines (TODO CRTC); see docs/PCB_TIMING.md.
// Target board cadence glue. Sync placement awaits HD6445/PCB qualification.
module bigfight_raster #(
    // 272 is retained only as an explicit historical MAME test profile.
    parameter integer V_TOTAL = 261
) (
    input logic clk, cold_start,
    input logic cyclwarr_i,
    output logic ce_pixel,
    output logic [8:0] x,y,
    output logic hblank,vblank,
    output logic line_start,frame_start,vblank_start
);
    logic [2:0] pixel_div_q;
    // Cycle Warriors programs HD6445 R4=34,R5=0,R9=7: 35*8=280.
    // Profile changes only during the loader's reset/drain sequence.
    wire [8:0] last_line = cyclwarr_i ? 9'd279 : 9'(V_TOTAL-1);
    assign ce_pixel = !cold_start && pixel_div_q == 3'd7;
    assign hblank = x >= 9'd320;
    assign vblank = y >= 9'd240;
    assign line_start = ce_pixel && x == 9'd399;
    assign frame_start = line_start && y == last_line;
    // Pulse on the edge that advances the counters into vertical blanking.
    assign vblank_start = line_start && y == 9'd239;
    always_ff @(posedge clk) begin
        if (cold_start) begin
            pixel_div_q <= '0;
            x <= '0;
            // Declared logical cold epoch starts at blank line240; physical reset
            // origin is not measured by the PCB footage.
            y <= 9'd240;
        end else begin
            pixel_div_q <= pixel_div_q + 3'd1;
            if (ce_pixel) begin
                if (x == 9'd399) begin
                    x <= '0;
                    y <= y == last_line ? 9'd0 : y + 9'd1;
                end else x <= x + 9'd1;
            end
        end
    end
endmodule
