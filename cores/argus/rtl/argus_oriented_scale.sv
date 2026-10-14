// Integer scaling follows the displayed orientation of the post-mixer raster.
// Keep video_freak at SCALE=0 upstream for its normal aspect/crop/DE behavior.
module argus_oriented_scale (
    input wire CLK_VIDEO,
    input wire RESET,
    input wire CE_PIXEL,
    input wire VGA_VS,
    input wire VGA_DE,
    input wire ROTATED,
    input wire [11:0] HDMI_WIDTH,
    input wire [11:0] HDMI_HEIGHT,
    input wire [2:0] SCALE,
    input wire [11:0] ARX,
    input wire [11:0] ARY,
    output wire [12:0] VIDEO_ARX,
    output wire [12:0] VIDEO_ARY
);
    reg old_de, old_vs, frame_seen, geometry_valid;
    reg [11:0] line_pixels, frame_width, frame_lines;
    reg [11:0] native_width, native_height;

    always @(posedge CLK_VIDEO) begin
        if (RESET) begin
            old_de <= 1'b0;
            old_vs <= 1'b0;
            frame_seen <= 1'b0;
            geometry_valid <= 1'b0;
            line_pixels <= 12'd0;
            frame_width <= 12'd0;
            frame_lines <= 12'd0;
            native_width <= 12'd0;
            native_height <= 12'd0;
        end else if (CE_PIXEL) begin
            old_de <= VGA_DE;
            old_vs <= VGA_VS;
            if (VGA_DE) line_pixels <= line_pixels + 1'b1;
            if (old_de && !VGA_DE) begin
                if (line_pixels > frame_width) frame_width <= line_pixels;
                frame_lines <= frame_lines + 1'b1;
                line_pixels <= 12'd0;
            end
            if (!old_vs && VGA_VS) begin
                // Ignore the partial frame after reset; publish a complete frame.
                if (frame_seen && frame_width != 0 && frame_lines != 0 && !old_de && !VGA_DE) begin
                    native_width <= frame_width;
                    native_height <= frame_lines;
                    geometry_valid <= 1'b1;
                end
                frame_seen <= 1'b1;
                frame_width <= 12'd0;
                frame_lines <= 12'd0;
                line_pixels <= 12'd0;
            end
        end
    end

    wire [11:0] oriented_width = ROTATED ? native_height : native_width;
    wire [11:0] oriented_height = ROTATED ? native_width : native_height;
    wire [2:0] measured_scale = geometry_valid ? SCALE : 3'd0;
    video_scale_int scale (
        .CLK_VIDEO(CLK_VIDEO),
        .HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),
        .SCALE(measured_scale),.hsize(oriented_width),.vsize(oriented_height),
        .arx_i(ARX),.ary_i(ARY),.arx_o(VIDEO_ARX),.ary_o(VIDEO_ARY)
    );
endmodule
