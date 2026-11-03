// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5
//
// Asylum native-raster CRT adjustment candidate.
//
// The geometry and active signal conventions are derived from
// rtl/video/leland_video.sv (424 x 256 total, 320 x 240 active, positive
// sync/blank). The design idea of ping-pong line storage is informed by
// HeavyUnit/rtl/crt_adjust.sv (GPL-3.0-or-later, upstream SHA-256
// C3618517A1C1474A79C0C2CB4992B36F6F53418F21490B8A671AF316BA467B87).
// This is a new implementation: the HeavyUnit donor uses its pxl2_cen for
// both line-buffer reads and visible RGB/blank/sync updates, so it cannot be
// connected to Asylum's fixed /8 output cadence without changing cadence.

module leland_crt_fixed (
    input  logic              clk_sys,
    input  logic              reset,
    input  logic              ce_pix,

    input  logic signed [6:0] hsize_pixels,
    input  logic signed [7:0] hposition,
    input  logic signed [5:0] vshift,

    // Caller-provided mode facts. Eligibility is deliberately independent of
    // direct_video and forced_scandoubler; both are forwarded unchanged.
    input  logic              native_profile,
    input  logic              retimer_selected,
    input  logic              rotation_active,
    input  logic              direct_video,
    input  logic              forced_scandoubler,
    output logic              direct_video_out,
    output logic              forced_scandoubler_out,
    output logic              crt_eligible,
    output logic              pixel_cadence_ok,
    output logic              raster_qualified,
    output logic              range_clamped,
    output logic              cadence_fault,
    output logic              raster_fault,

    input  logic [23:0]       rgb_in,
    input  logic              hs_in,
    input  logic              vs_in,
    input  logic              hb_in,
    input  logic              vb_in,

    output logic              ce_out,
    output logic [23:0]       rgb_out,
    output logic              hs_out,
    output logic              vs_out,
    output logic              hb_out,
    output logic              vb_out
);

    localparam integer H_TOTAL       = 424;
    localparam integer V_TOTAL       = 256;
    localparam integer H_ACTIVE      = 320;
    localparam integer V_ACTIVE      = 240;
    localparam integer H_SYNC_WIDTH  = 48;
    localparam integer H_ACTIVE_START= 88;  // coordinates are HSync-rise relative
    localparam integer H_ACTIVE_END  = H_ACTIVE_START + H_ACTIVE;
    localparam integer V_SYNC_START  = 241;
    localparam integer V_SYNC_END    = 245;
    localparam integer MAX_H_DELTA   = 16;
    localparam integer MAX_HPOS      = 32;
    localparam integer MIN_VSHIFT    = -1;
    localparam integer MAX_VSHIFT    = 11;

    // Two 320x24 line stores. Writes use input active pixels; reads use the
    // previous complete line. At HSync-relative x=423/0 the just-completed
    // bank is selected for the next output line. All RGB/DE/sync outputs are
    // registered on ce_pix and share the same read-coordinate pipeline.
    (* ramstyle = "M10K" *) logic [23:0] line_mem [0:1023];
    logic [1:0]  line_valid;
    logic        write_bank;
    logic [8:0]  active_written;
    logic [8:0]  x_count;
    logic [7:0]  y_count;
    logic        line_started;
    logic        hs_prev;
    logic        vb_prev_line;

    logic [23:0] read_rgb_q;
    logic        read_valid_q;
    logic        read_window_q;
    logic [8:0]  read_x_q;
    logic [7:0]  read_y_q;

    logic signed [6:0] hsize_q;
    logic signed [7:0] hposition_q;
    logic signed [5:0] vshift_q;
    logic              settings_seen;
    logic              range_clamped_q;

    logic [3:0] ce_gap;
    logic       ce_seen;
    logic       ce_error;
    logic       saw_vblank;
    logic       raster_error;

    integer requested_hsize;
    integer clamped_hsize;
    integer requested_hpos;
    integer clamped_hpos;
    integer requested_vshift;
    integer clamped_vshift;
    integer destination_width;
    integer centered_start;
    integer min_hpos;
    integer max_hpos;
    integer row_after_edge;
    integer x_now;
    integer request_x;
    integer request_y;
    integer request_source_x;
    integer request_destination_width;
    integer request_destination_start;
    integer output_x_unsigned;
    integer output_y_unsigned;
    integer output_vsync_start;
    integer output_vsync_end;
    logic   range_clamped_now;
    logic   request_window;
    logic   request_bank;
    logic   hs_rise;
    logic   vb_rise;
    logic   vb_fall;
    logic [8:0] scale_source_q;
    logic [9:0] scale_remainder_q;
    logic [9:0] scale_remainder;
    logic [9:0] scale_sum;
    logic [9:0] scale_width;
    logic [8:0] scale_source_next;
    logic [9:0] scale_remainder_next;

    always_comb begin
        // Explicitly zero-extend raster coordinates before signed shift math.
        // Mixing an unsigned packed row with a signed negative VShift can
        // otherwise sign-extend rows 128..255 during relational comparison.
        output_x_unsigned = {23'd0, read_x_q};
        output_y_unsigned = {24'd0, read_y_q};
        output_vsync_start = V_SYNC_START + $signed(vshift_q);
        output_vsync_end   = V_SYNC_END   + $signed(vshift_q);

        requested_hsize = $signed(hsize_pixels);
        clamped_hsize = requested_hsize;
        if (clamped_hsize < -MAX_H_DELTA) clamped_hsize = -MAX_H_DELTA;
        if (clamped_hsize >  MAX_H_DELTA) clamped_hsize =  MAX_H_DELTA;
        destination_width = H_ACTIVE + clamped_hsize;

        centered_start = H_ACTIVE_START + ((H_ACTIVE - destination_width) / 2);
        requested_hpos = $signed(hposition);
        clamped_hpos = requested_hpos;
        if (clamped_hpos < -MAX_HPOS) clamped_hpos = -MAX_HPOS;
        if (clamped_hpos >  MAX_HPOS) clamped_hpos =  MAX_HPOS;

        min_hpos = H_SYNC_WIDTH - centered_start;
        max_hpos = H_TOTAL - destination_width - centered_start;
        if (clamped_hpos < min_hpos) clamped_hpos = min_hpos;
        if (clamped_hpos > max_hpos) clamped_hpos = max_hpos;

        requested_vshift = $signed(vshift);
        clamped_vshift = requested_vshift;
        if (clamped_vshift < MIN_VSHIFT) clamped_vshift = MIN_VSHIFT;
        if (clamped_vshift > MAX_VSHIFT) clamped_vshift = MAX_VSHIFT;

        range_clamped_now = (requested_hsize != clamped_hsize) ||
                            (requested_hpos != clamped_hpos) ||
                            (requested_vshift != clamped_vshift);
    end

    assign direct_video_out      = direct_video;
    assign forced_scandoubler_out= forced_scandoubler;
    assign ce_out                = ce_pix;
    assign hs_rise               = ce_pix && hs_in && !hs_prev;
    assign vb_rise               = hs_rise && vb_in && !vb_prev_line;
    assign vb_fall               = hs_rise && !vb_in && vb_prev_line;

    // Track the native pixel enable spacing independently from any candidate
    // image resampling. A malformed /7 retimer stream never qualifies.
    always_ff @(posedge clk_sys) begin
        if (reset) begin
            ce_gap          <= 4'd0;
            ce_seen         <= 1'b0;
            ce_error        <= 1'b0;
            pixel_cadence_ok<= 1'b0;
        end else begin
            if (ce_pix) begin
                if (ce_seen) begin
                    if (ce_gap != 4'd7) ce_error <= 1'b1;
                    else pixel_cadence_ok <= 1'b1;
                end
                ce_seen <= 1'b1;
                ce_gap  <= 4'd0;
            end else if (ce_seen && ce_gap < 4'd8) begin
                ce_gap <= ce_gap + 1'b1;
            end
        end
    end

    assign crt_eligible = native_profile && pixel_cadence_ok && !ce_error &&
                          raster_qualified && !raster_error &&
                          !retimer_selected && !rotation_active;
    assign cadence_fault = ce_error;
    assign raster_fault  = raster_error;

    // Latch geometry at the start of the first output-blank line (input
    // VBlank falling edge). The line pipeline delays visible content by one
    // line, so this update occurs while the corresponding output row is
    // blank and takes effect at output row zero.
    always_ff @(posedge clk_sys) begin
        if (reset) begin
            hsize_q        <= 7'(clamped_hsize);
            hposition_q    <= 8'(clamped_hpos);
            vshift_q       <= 6'(clamped_vshift);
            settings_seen  <= 1'b1;
            range_clamped_q<= range_clamped_now;
        end else if (ce_pix && vb_fall) begin
            hsize_q         <= 7'(clamped_hsize);
            hposition_q     <= 8'(clamped_hpos);
            vshift_q        <= 6'(clamped_vshift);
            settings_seen   <= 1'b1;
            range_clamped_q <= range_clamped_now;
        end
    end

    assign range_clamped = range_clamped_q;

    // Keep an exact HSync-relative x coordinate. The row counter is anchored
    // to the observed VBlank edges and Asylum's 240+16 line split.
    always_comb begin
        if (hs_rise) x_now = 0;
        else if (x_count == H_TOTAL-1) x_now = 0;
        else x_now = x_count + 1;

        if (!hs_rise) row_after_edge = y_count;
        else if (!line_started) row_after_edge = 0;
        else if (vb_rise) row_after_edge = V_ACTIVE;
        else if (vb_fall) row_after_edge = 0;
        else if (y_count == V_TOTAL-1) row_after_edge = 0;
        else row_after_edge = y_count + 1;

        request_x = (x_now == H_TOTAL-1) ? 0 : x_now + 1;
        if (x_now == H_TOTAL-1) request_y = row_after_edge;
        else if (row_after_edge == 0) request_y = V_TOTAL-1;
        else request_y = row_after_edge - 1;

        request_destination_width = H_ACTIVE + $signed(hsize_q);
        request_destination_start = H_ACTIVE_START +
            ((H_ACTIVE - request_destination_width) / 2) + $signed(hposition_q);
        request_window = settings_seen && (request_y < V_ACTIVE) &&
                         (request_x >= request_destination_start) &&
                         (request_x < request_destination_start + request_destination_width);
        if (request_destination_width <= 0 ||
            request_destination_start < H_SYNC_WIDTH ||
            request_destination_start + request_destination_width > H_TOTAL)
            request_window = 1'b0;

        // Exact floor(j*320/width), without a variable hardware divider.
        // Width is304..336, so remainder+320 needs at most two subtractions.
        request_source_x = 0;
        scale_remainder = 10'd0;
        if (request_window && request_x != request_destination_start) begin
            request_source_x = {23'd0, scale_source_q};
            scale_remainder = scale_remainder_q;
        end
        scale_width = 10'(request_destination_width);
        scale_sum = scale_remainder + 10'd320;
        scale_source_next = 9'(request_source_x);
        scale_remainder_next = scale_sum;
        if (scale_sum >= (scale_width << 1)) begin
            scale_source_next = 9'(request_source_x) + 9'd2;
            scale_remainder_next = scale_sum - (scale_width << 1);
        end else if (scale_sum >= scale_width) begin
            scale_source_next = 9'(request_source_x) + 9'd1;
            scale_remainder_next = scale_sum - scale_width;
        end

        // At x=423 and the following HSync edge, the just-completed bank is
        // the source for output x=0/1. Else the previous bank is read.
        request_bank = (hs_rise || x_now == H_TOTAL-1) ? write_bank : ~write_bank;
    end

    // Reset the valid/control path, not the RAM output. Invalid bank data is
    // masked by read_valid_q. Each bank uses a512-address stride; unused tail
    // addresses are never exposed as active pixels.
    always_ff @(posedge clk_sys) begin
        if (!reset && ce_pix && x_now >= H_ACTIVE_START && x_now < H_ACTIVE_END)
            line_mem[{write_bank, 9'(x_now-H_ACTIVE_START)}] <= rgb_in;
    end

    always_ff @(posedge clk_sys) begin
        if (ce_pix)
            read_rgb_q <= line_mem[{request_bank, 9'(request_source_x)}];
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            scale_source_q <= 9'd0;
            scale_remainder_q <= 10'd0;
        end else if (ce_pix) begin
            scale_source_q <= request_window ? scale_source_next : 9'd0;
            scale_remainder_q <= request_window ? scale_remainder_next : 10'd0;
        end
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            line_valid    <= 2'b00;
            write_bank    <= 1'b0;
            active_written<= 9'd0;
            x_count       <= 9'd0;
            y_count       <= 8'd0;
            line_started  <= 1'b0;
            hs_prev       <= 1'b0;
            vb_prev_line  <= 1'b0;
            read_valid_q  <= 1'b0;
            read_window_q <= 1'b0;
            read_x_q      <= 9'd0;
            read_y_q      <= 8'd0;
            rgb_out       <= 24'd0;
            hs_out        <= 1'b0;
            vs_out        <= 1'b0;
            hb_out        <= 1'b1;
            vb_out        <= 1'b1;
            raster_qualified <= 1'b0;
            saw_vblank       <= 1'b0;
            raster_error     <= 1'b0;
        end else if (ce_pix) begin
            hs_prev <= hs_in;
            x_count <= 9'(x_now);
            if (hs_rise) begin
                line_started <= 1'b1;
                y_count      <= 8'(row_after_edge);
                vb_prev_line <= vb_in;
                write_bank   <= ~write_bank;
                active_written <= 9'd0;
                if (vb_rise) saw_vblank <= 1'b1;
                if (vb_fall && saw_vblank) begin
                    raster_qualified <= !raster_error;
                    saw_vblank <= 1'b0;
                end
            end

            // The source has exactly 320 active pixels at x=88..407. Mark a
            // bank ready only after every ordered source pixel was captured.
            if (x_now >= H_ACTIVE_START && x_now < H_ACTIVE_END) begin
                if (active_written == H_ACTIVE-1)
                    line_valid[write_bank] <= 1'b1;
                active_written <= active_written + 1'b1;
            end

            read_valid_q  <= request_window && line_valid[request_bank];
            read_window_q <= request_window;
            read_x_q      <= 9'(request_x);
            read_y_q      <= 8'(request_y);

            // Source profile monitor. A single mismatch permanently removes
            // eligibility until reset; no timing or image data is fabricated.
            if (hs_in != (x_now < H_SYNC_WIDTH) ||
                hb_in != !((x_now >= H_ACTIVE_START) && (x_now < H_ACTIVE_END)) ||
                vb_in != (row_after_edge >= V_ACTIVE) ||
                vs_in != ((row_after_edge >= V_SYNC_START) && (row_after_edge < V_SYNC_END)))
                raster_error <= 1'b1;

            // One registered read step followed by one registered output
            // step. Both stages carry the same coordinate/blanking tuple.
            rgb_out <= read_valid_q ? read_rgb_q : 24'd0;
            hs_out  <= (output_x_unsigned < H_SYNC_WIDTH);
            vs_out  <= (output_y_unsigned >= output_vsync_start) &&
                       (output_y_unsigned <  output_vsync_end);
            vb_out  <= (output_y_unsigned >= V_ACTIVE);
            hb_out  <= !read_window_q || (output_y_unsigned >= V_ACTIVE);
        end
    end

endmodule
