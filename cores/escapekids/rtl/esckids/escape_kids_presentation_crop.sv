`timescale 1ns/1ps

// Escape Kids presentation-only active-window crop.
//
// The game and its K053252 timing remain native.  This module only changes
// the final DE presented to the MiSTer shell: source columns [LEFT,RIGHT)
// remain active while the rest of the source active interval is blanked.
module escape_kids_presentation_crop #(
    parameter integer LEFT  = 12,
    parameter integer RIGHT = 300
)(
    input  wire clk_video,
    input  wire reset,
    input  wire ce_pixel,
    input  wire de_in,
    output wire de_out
);

    localparam integer INDEX_W = 9;
    localparam [INDEX_W-1:0] LEFT_VALUE  = LEFT[INDEX_W-1:0];
    localparam [INDEX_W-1:0] RIGHT_VALUE = RIGHT[INDEX_W-1:0];
    reg [INDEX_W-1:0] pixel_index;

    // pixel_index is the source active-window column sampled on the current
    // CE_PIXEL.  Saturating at RIGHT keeps the counter bounded through the
    // remainder of the 321-pixel active interval.
    assign de_out = de_in &&
                    (pixel_index >= LEFT_VALUE) &&
                    (pixel_index < RIGHT_VALUE);

    always @(posedge clk_video) begin
        if (reset) begin
            pixel_index <= {INDEX_W{1'b0}};
        end else if (ce_pixel) begin
            if (!de_in)
                pixel_index <= {INDEX_W{1'b0}};
            else if (pixel_index < RIGHT_VALUE)
                pixel_index <= pixel_index + 1'b1;
        end
    end

endmodule
