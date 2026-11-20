// SPDX-License-Identifier: GPL-3.0-or-later
// Presentation only: native game pixels, sync and CE remain unchanged.
module gs_video_presentation (
    input wire clk, ce, vs, de_in,
    input wire [11:0] hdmi_width, hdmi_height,
    input wire [1:0] aspect,
    input wire [2:0] scale,
    input wire crop, scandoubled,
    output wire de_out,
    output wire [12:0] arx, ary
);
    wire [11:0] base_arx = aspect == 0 ? 12'd4 : {10'b0,aspect} - 12'd1;
    wire [11:0] base_ary = aspect == 0 ? 12'd3 : 12'd0;
    wire [2:0] selected_scale = scale <= 4 && hdmi_width != 0 && hdmi_height != 0 ?
                               scale : 3'd0;
    // video_freak measures post-mixer rows. Scandoubling emits two rows
    // per native line, so an explicit 224-line crop becomes 448 rows.
    wire [11:0] crop_size = !crop ? 12'd0 : scandoubled ? 12'd448 : 12'd224;
    wire cropped_de;
    wire [12:0] adjusted_arx,adjusted_ary;
    video_freak presentation (
        .CLK_VIDEO(clk),.CE_PIXEL(ce),.VGA_VS(vs),
        .HDMI_WIDTH(hdmi_width),.HDMI_HEIGHT(hdmi_height),
        .VGA_DE(cropped_de),.VIDEO_ARX(adjusted_arx),.VIDEO_ARY(adjusted_ary),
        .VGA_DE_IN(de_in),.ARX(base_arx),.ARY(base_ary),
        .CROP_SIZE(crop_size),.CROP_OFF(5'd0),.SCALE(selected_scale));
    // Keep default DE and aspect exact, including initial measurement frames.
    assign de_out = crop ? cropped_de : de_in;
    assign arx = !crop && selected_scale == 0 ? {1'b0,base_arx} : adjusted_arx;
    assign ary = !crop && selected_scale == 0 ? {1'b0,base_ary} : adjusted_ary;
endmodule


// Keep slow presentation controls out of combinational 64->96 MHz paths.
// The PLL clocks remain related and both capture stages retain normal timing
// analysis; no false-path or multicycle exception is required.
module gs_video_settings (
    input wire clk, reset,
    input wire [33:0] raw,
    output wire [33:0] captured
);
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [33:0] capture1=0,capture2=0;
    always @(posedge clk) begin
        capture1<=raw;capture2<=capture1;
        if(reset)begin capture1<=0;capture2<=0;end
    end
    assign captured=capture2;
endmodule


// Exact menu decode. Constant truth tables avoid comparison/subtraction chains
// on the related 64->96 MHz CRT control path, without adding latency.
module gs_crt_controls (
    input wire [14:0] raw,
    output wire enable,
    output reg signed [4:0] hsize,
    output reg signed [8:0] hoffset,
    output wire signed [5:0] voffset
);
    assign enable=raw[0];
    assign voffset={raw[14],raw[14:10]};
    always @* begin
        case(raw[4:1])
            4'd0: hsize=5'sd0;
            4'd1: hsize=5'sd1;
            4'd2: hsize=5'sd2;
            4'd3: hsize=5'sd3;
            4'd4: hsize=5'sd4;
            4'd5: hsize=-5'sd4;
            4'd6: hsize=-5'sd3;
            4'd7: hsize=-5'sd2;
            4'd8: hsize=-5'sd1;
            default: hsize=5'sd0;
        endcase
        case(raw[9:5])
            5'd0: hoffset=9'sd0;
            5'd1: hoffset=9'sd4;
            5'd2: hoffset=9'sd8;
            5'd3: hoffset=9'sd12;
            5'd4: hoffset=9'sd16;
            5'd5: hoffset=9'sd20;
            5'd6: hoffset=9'sd24;
            5'd7: hoffset=9'sd28;
            5'd8: hoffset=9'sd32;
            5'd9: hoffset=-9'sd32;
            5'd10: hoffset=-9'sd28;
            5'd11: hoffset=-9'sd24;
            5'd12: hoffset=-9'sd20;
            5'd13: hoffset=-9'sd16;
            5'd14: hoffset=-9'sd12;
            5'd15: hoffset=-9'sd8;
            5'd16: hoffset=-9'sd4;
            default: hoffset=9'sd0;
        endcase
    end
endmodule
