// Data East Cassette final video mixer.
//
// Implements the ordering and discrete center/object priority behavior described
// by MAME's decocass_v.cpp.  This is project-owned RTL; the hash-pinned upstream
// reference mixer remains under rtl/vendor and is not modified.

module decocass_video_mixer (
    input  logic        clk_sys,
    input  logic        ce_pix,

    input  logic [4:0]  fg_pen,
    input  logic        fg_opaque,
    input  logic [5:0]  bg_pen,
    input  logic        bg_opaque,
    input  logic [4:0]  spr_pen,
    input  logic        spr_opaque,
    input  logic [4:0]  mis_pen,
    input  logic        mis_opaque,

    input  logic [7:0]  mode_set,
    input  logic [7:0]  color_center_bot,
    input  logic [7:0]  color_missiles,
    input  logic [7:0]  back_h_shift,
    input  logic [7:0]  back_vl_shift,
    input  logic [7:0]  back_vr_shift,
    input  logic [7:0]  part_h_shift,
    input  logic [7:0]  part_v_shift,
    input  logic [7:0]  center_h_shift_space,
    input  logic [7:0]  center_v_shift,

    input  logic [8:0]  hcnt,
    input  logic [8:0]  vcnt,

    // Read-only graphics port of the CPU's $D800-$DBff object RAM.
    output logic [9:0]  object_addr,
    input  logic [7:0]  object_data,

    output logic [5:0]  out_pen,
    output logic        out_pen_b4_modulate
);

    localparam logic [5:0] BG_FILL = 6'd8;

    // ------------------------------------------------------------------
    // Four-row center pattern (MAME draw_center).
    // ------------------------------------------------------------------
    logic [7:0] center_sx;
    logic [7:0] center_src_x;
    logic [8:0] center_last_y;
    logic       center_row;
    logic       center_valid;
    logic [2:0] center_color;

    always_comb begin
        center_sx     = {2'b00, center_h_shift_space[7:2]} & 8'h3c;
        center_src_x  = hcnt[7:0] - center_sx;
        center_last_y = {1'b0, center_v_shift} + 9'd3;

        center_row = (hcnt < 9'd256) &&
                     (vcnt >= {1'b0, center_v_shift}) &&
                     (vcnt <= center_last_y) &&
                     (vcnt < 9'd256) &&
                     ((vcnt[1:0] & color_center_bot[1:0]) ==
                      (center_v_shift[1:0] & color_center_bot[1:0]));
        center_valid = center_row &&
                       (center_h_shift_space[0] || center_src_x[4]);

        center_color = color_center_bot[7]
                     ? {color_center_bot[4], color_center_bot[6], color_center_bot[5]}
                     : {color_center_bot[4], color_center_bot[5], color_center_bot[6]};
    end

    // ------------------------------------------------------------------
    // 64x64x1bpp big-object lookup (MAME objlayout).
    //
    // Object RAM's graphics port is clocked every clk_sys cycle while hcnt/vcnt
    // advance only on ce_pix.  The addressed byte is therefore ready before
    // the pixel is committed, without another video-pipeline stage.
    // ------------------------------------------------------------------
    logic signed [9:0] object_sx;
    logic signed [9:0] object_dx;
    logic signed [9:0] object_dy;
    logic [7:0] object_sy;
    logic [5:0] query_row;
    logic [5:0] query_col;
    logic       query_object;
    logic [2:0] query_bit;
    logic       query_valid;
    logic       object_pixel;

    always_comb begin
        object_sx = $signed({1'b0, part_h_shift}) - 10'sd128;
        object_sy = 8'd65 - part_v_shift;
        object_dx = $signed({1'b0, hcnt}) - object_sx;
        object_dy = $signed({1'b0, vcnt}) - $signed({2'b00, object_sy});

        query_row    = 6'd0;
        query_col    = 6'd0;
        query_object = 1'b0;
        query_bit    = 3'd0;
        query_valid  = 1'b0;
        object_addr  = 10'd0;

        if (mode_set[7] && (hcnt < 9'd256) &&
            (vcnt >= 9'd8) && (vcnt <= 9'd247) &&
            (object_dx >= 10'sd0) && (object_dx < 10'sd128) &&
            (object_dy >= -10'sd64) && (object_dy < 10'sd64)) begin
            query_col    = (object_dx < 10'sd64) ? object_dx[5:0]
                                                    : (object_dx - 10'sd64);
            query_object = (object_dx < 10'sd64); // left half is object 1
            query_row    = (object_dy < 10'sd0) ? (-10'sd1 - object_dy)
                                                 : object_dy[5:0];
            query_bit    = 3'd7 - query_col[2:0];
            query_valid  = 1'b1;

            // Row order is bottom-to-top; each row holds object 0 then 1,
            // and each object's eight bytes are right-to-left.
            object_addr = ((10'd63 - {4'd0, query_row}) << 4) +
                          (query_object ? 10'd8 : 10'd0) +
                          (10'd7 - {7'd0, query_col[5:3]});
        end
    end

    always_comb object_pixel = query_valid && object_data[query_bit];

    // ------------------------------------------------------------------
    // Layer order plus the tunnel/headlight special-priority pass.
    // ------------------------------------------------------------------
    logic [5:0] pen_next;
    logic [5:0] bg_effective_pen;
    logic [5:0] object_color;
    logic       special_active;
    logic       priority_two;

    always_comb begin
        // The background renderer masks MAME's synthetic empty tile through
        // bg_opaque, but its BRAM data bus still contains the underlying tile
        // bits.  MAME substitutes an all-zero tile here, whose logical pen is
        // the current background color-bank base.  Genuine pixel zero has the
        // same value, so this normalization is valid for both cases.
        bg_effective_pen = bg_opaque ? bg_pen : {bg_pen[5:3], 3'b000};
        pen_next = BG_FILL;

        // draw_edge(..., opaque=true) writes every source pen, including pen
        // zero and MAME's intentionally empty tile cells.
        if (mode_set[3])
            pen_next = bg_effective_pen;

        if (mode_set[5]) begin
            // Crossing/center is above the opaque edge layer.
            if (center_valid)
                pen_next = {3'b000, center_color};
        end else begin
            // Center is below the transparent edge layer.
            if (center_valid)
                pen_next = {3'b000, center_color};
            // MAME's transparent edge test is `(pix & 3)`, not generic
            // three-bit nonzero. Background pixel 4 is transparent here.
            if (mode_set[3] && (bg_effective_pen[1:0] != 2'b00))
                pen_next = bg_effective_pen;
        end

        if (fg_opaque && (fg_pen != 5'd0))
            pen_next = {1'b0, fg_pen};
        if (spr_opaque && (spr_pen != 5'd0))
            pen_next = {1'b0, spr_pen};
        if (mis_opaque && (mis_pen != 5'd0))
            pen_next = {1'b0, mis_pen};

        special_active = !(((mode_set[1:0] == 2'b00) || mode_set[6]) &&
                           !mode_set[5]);
        case (mode_set[1:0])
            2'b00: priority_two = 1'b1;
            2'b01: priority_two = (hcnt[7:0] >= back_h_shift);
            2'b10: priority_two = 1'b0;
            default: priority_two = (hcnt[7:0] < back_h_shift);
        endcase

        object_color = {color_center_bot[7], 1'b0, 1'b1,
                        color_center_bot[4], color_center_bot[5],
                        color_center_bot[6]};

        if (special_active) begin
            if (mode_set[7] && object_pixel) begin
                priority_two = 1'b1;
                // MAME's priority bitmap is nonzero only for sprites/missiles;
                // foreground pixels remain at priority zero.
                if (mode_set[5] && !spr_opaque && !mis_opaque)
                    pen_next = object_color;
            end
            if (!priority_two)
                pen_next[4] = 1'b1;
        end
    end

    always_ff @(posedge clk_sys) begin
        if (ce_pix) begin
            out_pen             <= pen_next;
            // The special pass directly performs MAME's logical-pen OR 0x10.
            // Keep this compatibility output deterministic for older wrappers.
            out_pen_b4_modulate <= 1'b0;
        end
    end

    // Retained interface registers are consumed by the upstream BG/missile
    // renderers; referencing them here avoids accidental interface erosion.
    logic unused;
    always_comb unused = ^{color_missiles, back_vl_shift, back_vr_shift};

endmodule
