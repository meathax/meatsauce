// MAME-compatible development timing; physical PCB porches remain unqualified.
// Single game clock, fixed /10 pixel cadence, exact 54 Hz at 54 MHz.
module argus_raster (
    input logic clk_sys, storage_reset,
    input logic [1:0] game_id,
    output wire ce_pixel, active, hblank, vblank, hs, vs, line_start, frame_start,
    output wire [9:0] hpos, vpos,
    output logic [8:0] ref_scanline,
    output logic ref_line_tick
);
    logic [3:0] pixel_div;
    logic [8:0] hcount;
    logic [7:0] vcount;
    logic [19:0] ref_phase;
    wire [20:0] ref_sum = {1'b0, ref_phase} + 21'd512;
    wire [7:0] first_y = game_id == 2'd2 ? 8'd8 : 8'd16;
    wire [7:0] last_y = game_id == 2'd2 ? 8'd247 : 8'd239;
    assign ce_pixel = pixel_div == 4'd9 && !storage_reset;
    assign hblank = hcount < 9'd72 || hcount >= 9'd328;
    assign vblank = vcount < first_y || vcount > last_y;
    assign active = !hblank && !vblank;
    assign hs = !(hcount >= 9'd344 && hcount < 9'd376);
    assign vs = !(vcount < 8'd4);
    assign hpos = hblank ? 10'd0 : {1'b0, hcount} - 10'd72;
    assign vpos = {2'b0, vcount};
    assign line_start = ce_pixel && hcount == 0;
    assign frame_start = line_start && vcount == 0;
    always_ff @(posedge clk_sys) begin
        if (storage_reset) begin
            pixel_div <= 0;
            hcount <= 0;
            vcount <= 0;
            ref_scanline <= 0;
            ref_phase <= 0;
            ref_line_tick <= 0;
        end else begin
            ref_line_tick <= 0;
            if (ref_sum >= 21'd1000000) begin
                ref_phase <= 20'(ref_sum - 21'd1000000);
                ref_scanline <= ref_scanline + 1'b1;
                ref_line_tick <= 1;
            end else ref_phase <= ref_sum[19:0];
            if (ce_pixel) begin
                pixel_div <= 0;
                if (hcount == 9'd399) begin
                    hcount <= 0;
                    if (vcount == 8'd249) vcount <= 0;
                    else vcount <= vcount + 1'b1;
                end else hcount <= hcount + 1'b1;
            end else pixel_div <= pixel_div + 1'b1;
        end
    end
endmodule
