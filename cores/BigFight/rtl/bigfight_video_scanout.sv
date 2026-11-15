// Raster-facing reader for the completed, tagged Big Fight video lines.
// All state and handshakes use clk_sys; ce_pixel_i is data, never a clock.
module bigfight_video_scanout (
    input  logic         cyclwarr_i,
    input  logic         clk_sys,
    input  logic         cold_reset,

    input  logic         ce_pixel_i,
    input  logic [8:0]   raster_x_i,
    input  logic [8:0]   raster_y_i,
    input  logic         hblank_i,
    input  logic         vblank_i,

    // One-cycle pulse on the accepted pipeline frame-prepare transaction.
    input  logic         frame_epoch_valid_i,
    input  logic [15:0]  frame_epoch_id_i,

    input  logic         line_done_valid_i,
    output logic         line_done_ready_o,
    input  logic [15:0]  line_done_frame_id_i,
    input  logic         line_done_bank_i,
    input  logic [8:0]   line_done_y_i,
    input  logic         line_done_late_i,
    input  logic [11:0]  line_done_cycles_i,

    output logic         line_release_valid_o,
    input  logic         line_release_ready_i,
    output logic         line_release_bank_o,

    output logic         pixel_req_valid_o,
    input  logic         pixel_req_ready_i,
    output logic         pixel_req_bank_o,
    output logic [8:0]   pixel_req_y_o,
    output logic [8:0]   pixel_req_x_o,

    input  logic         pixel_rsp_valid_i,
    output logic         pixel_rsp_ready_o,
    input  logic         pixel_rsp_bank_i,
    input  logic [8:0]   pixel_rsp_y_i,
    input  logic [8:0]   pixel_rsp_x_i,
    input  logic [23:0]  pixel_rsp_rgb_i,
    input  logic         pixel_rsp_reject_i,
    input  logic [15:0]  pixel_rsp_latency_i,

    // These outputs are registered on clk_sys. video_ce_o is a one-edge
    // delayed copy of the raster CE; all pixel metadata describes that RGB.
    output logic         video_ce_o,
    output logic [8:0]   raster_x_o,
    output logic [8:0]   raster_y_o,
    output logic         hblank_o,
    output logic         vblank_o,
    output logic         video_active_o,
    output logic [23:0]  rgb_o,

    output logic         deadline_miss_o,
    output logic [31:0]  deadline_miss_count_o,
    output logic         protocol_fault_o,
    output logic [31:0]  protocol_fault_count_o,
    output logic [11:0]  last_line_cycles_o,
    output logic         last_line_late_o,
    output logic [15:0]  max_pixel_latency_o
);
    localparam logic [8:0] H_TOTAL_LAST = 9'd399;
    localparam logic [8:0] H_VISIBLE = 9'd320;
    localparam logic [8:0] V_VISIBLE = 9'd240;
    localparam logic [11:0] LINE_BUDGET = 12'd3200;

    logic [2:0] phase_q;
    logic epoch_valid_q;
    logic [15:0] epoch_id_q;
    logic active_seen_q;

    logic [1:0] bank_valid_q;
    logic [1:0] bank_release_pending_q;
    logic [15:0] bank_frame_id_q [0:1];
    logic [8:0] bank_y_q [0:1];
    logic bank_late_q [0:1];
    logic [11:0] bank_cycles_q [0:1];

    logic release_active_q;
    logic release_bank_q;
    logic release_rr_q;

    logic req_pending_q;
    logic req_bank_q;
    logic [15:0] req_frame_id_q;
    logic [8:0] req_y_q, req_x_q;

    logic row_choice_locked_q;
    logic row_choice_valid_q;
    logic row_choice_bank_q;
    logic [15:0] row_choice_frame_id_q;
    logic [8:0] row_choice_y_q;

    logic txn_valid_q;
    logic txn_bank_q;
    logic [15:0] txn_frame_id_q;
    logic [8:0] txn_y_q, txn_x_q;

    logic candidate0, candidate1;
    logic candidate0_live, candidate1_live;
    logic candidate_valid, candidate_bank;
    logic candidate_duplicate;
    logic row_start_phase;
    logic row_choice_for_phase_valid;
    logic row_choice_for_phase_bank;
    logic [15:0] row_choice_for_phase_frame_id;
    logic [8:0] row_choice_for_phase_y;
    logic active_input;
    logic expected_hblank, expected_vblank;
    logic response_tag_matches;
    logic response_owner_matches;
    logic response_epoch_matches;
    logic response_position_stale;
    logic response_for_pixel_ce;
    logic response_bad;
    logic response_handshake;
    logic request_handshake;
    logic pixel_data_for_ce;
    logic line_done_handshake;
    logic line_done_bad_epoch, line_done_bad_y, line_done_duplicate;
    logic line_done_late_mismatch;
    logic frame_epoch_bad;
    logic bank_has_request0, bank_has_request1;
    logic release_candidate0, release_candidate1;
    logic [3:0] protocol_events;
    logic [1:0] deadline_events;

    function automatic logic [31:0] saturating_add32(
        input logic [31:0] value,
        input logic [3:0] amount
    );
        logic [32:0] sum;
        begin
            sum = {1'b0, value} + amount;
            saturating_add32 = sum[32] ? 32'hffff_ffff : sum[31:0];
        end
    endfunction

    function automatic logic [15:0] saturating_inc16(
        input logic [15:0] value
    );
        saturating_inc16 = (&value) ? value : value + 16'd1;
    endfunction

    assign active_input = !hblank_i && !vblank_i &&
                          (raster_x_i < H_VISIBLE) &&
                          (raster_y_i < V_VISIBLE);
    assign expected_hblank = raster_x_i >= H_VISIBLE;
    assign expected_vblank = raster_y_i >= V_VISIBLE;

    // Pipeline line-done is consumed only into a free local ownership slot.
    // The completed bank itself remains owned until line_release handshake.
    always_comb begin
        line_done_ready_o = 1'b0;
        if (!cold_reset && epoch_valid_q &&
            !bank_valid_q[line_done_bank_i] &&
            !bank_release_pending_q[line_done_bank_i])
            line_done_ready_o = 1'b1;
    end
    assign line_done_handshake = line_done_valid_i && line_done_ready_o;

    assign line_done_bad_epoch = line_done_handshake &&
                                 (line_done_frame_id_i != epoch_id_q);
    assign line_done_bad_y = line_done_handshake &&
                             (line_done_y_i >= V_VISIBLE);
    assign line_done_duplicate = line_done_handshake &&
        bank_valid_q[~line_done_bank_i] &&
        !bank_release_pending_q[~line_done_bank_i] &&
        (bank_frame_id_q[~line_done_bank_i] == line_done_frame_id_i) &&
        (bank_y_q[~line_done_bank_i] == line_done_y_i);
    assign line_done_late_mismatch = line_done_handshake &&
        (line_done_late_i != (line_done_cycles_i > LINE_BUDGET));

    assign row_start_phase = (phase_q == 3'd1) && active_input &&
                             (raster_x_i == 9'd0);
    assign frame_epoch_bad = frame_epoch_valid_i &&
        ((bank_valid_q != 2'b00) || (bank_release_pending_q != 2'b00) ||
         release_active_q || req_pending_q || txn_valid_q ||
         row_choice_locked_q || row_start_phase);

    // A newly completed line can be selected on the same edge it is accepted.
    // This avoids losing X=0 if completion and the first prefetch phase coincide.
    always @* begin
        candidate0_live = line_done_handshake && !line_done_bad_epoch &&
                          !line_done_bad_y && !line_done_duplicate &&
                          (line_done_bank_i == 1'b0);
        candidate1_live = line_done_handshake && !line_done_bad_epoch &&
                          !line_done_bad_y && !line_done_duplicate &&
                          (line_done_bank_i == 1'b1);

        candidate0 = epoch_valid_q &&
            (bank_valid_q[0] && !bank_release_pending_q[0] &&
             (bank_frame_id_q[0] == epoch_id_q) &&
             (bank_y_q[0] == raster_y_i) ? 1'b1 :
             candidate0_live && (line_done_frame_id_i == epoch_id_q) &&
             (line_done_y_i == raster_y_i));
        candidate1 = epoch_valid_q &&
            (bank_valid_q[1] && !bank_release_pending_q[1] &&
             (bank_frame_id_q[1] == epoch_id_q) &&
             (bank_y_q[1] == raster_y_i) ? 1'b1 :
             candidate1_live && (line_done_frame_id_i == epoch_id_q) &&
             (line_done_y_i == raster_y_i));
        candidate_duplicate = candidate0 && candidate1;
        candidate_valid = candidate0 || candidate1;
        candidate_bank = candidate1 && !candidate0;

        // Freeze the row's bank choice at phase 1 of X=0. A completion on
        // this edge may be selected through candidate*_live above; later
        // completions cannot change a row that already started without data.
        row_choice_for_phase_valid = 1'b0;
        row_choice_for_phase_bank = row_choice_bank_q;
        row_choice_for_phase_frame_id = row_choice_frame_id_q;
        row_choice_for_phase_y = row_choice_y_q;
        if (row_start_phase) begin
            row_choice_for_phase_valid = candidate_valid && !candidate_duplicate;
            row_choice_for_phase_bank = candidate_bank;
            row_choice_for_phase_frame_id = epoch_id_q;
            row_choice_for_phase_y = raster_y_i;
        end else if (row_choice_locked_q && row_choice_valid_q &&
                     (row_choice_frame_id_q == epoch_id_q) &&
                     (row_choice_y_q == raster_y_i)) begin
            row_choice_for_phase_valid = 1'b1;
            row_choice_for_phase_bank = row_choice_bank_q;
            row_choice_for_phase_frame_id = row_choice_frame_id_q;
            row_choice_for_phase_y = row_choice_y_q;
        end
    end

    assign pixel_req_valid_o = req_pending_q && !cold_reset;
    assign pixel_req_bank_o = req_bank_q;
    assign pixel_req_y_o = req_y_q;
    assign pixel_req_x_o = req_x_q;
    assign request_handshake = pixel_req_valid_o && pixel_req_ready_i;

    assign response_tag_matches = txn_valid_q &&
        (pixel_rsp_bank_i == txn_bank_q) &&
        (pixel_rsp_y_i == txn_y_q) &&
        (pixel_rsp_x_i == txn_x_q);
    assign response_owner_matches = txn_valid_q &&
        bank_valid_q[txn_bank_q] &&
        (bank_frame_id_q[txn_bank_q] == txn_frame_id_q) &&
        (bank_y_q[txn_bank_q] == txn_y_q);
    assign response_epoch_matches = txn_valid_q && epoch_valid_q &&
                                    (txn_frame_id_q == epoch_id_q);
    assign response_bad = !response_tag_matches || !response_owner_matches ||
                          !response_epoch_matches;
    assign response_position_stale = txn_valid_q &&
        ((txn_y_q < raster_y_i) ||
         ((txn_y_q == raster_y_i) && (txn_x_q < raster_x_i)));
    assign response_for_pixel_ce = txn_valid_q && !response_bad &&
        ce_pixel_i && (phase_q == 3'd7) && active_input &&
        (txn_y_q == raster_y_i) && (txn_x_q == raster_x_i);

    // A matching early result is held until its pixel edge. Results whose
    // requested position has passed, and malformed replies, are drained now.
    always_comb begin
        pixel_rsp_ready_o = 1'b0;
        if (!cold_reset && pixel_rsp_valid_i) begin
            if (response_bad || response_position_stale)
                pixel_rsp_ready_o = 1'b1;
            else if (response_for_pixel_ce)
                pixel_rsp_ready_o = 1'b1;
        end
    end
    assign response_handshake = pixel_rsp_valid_i && pixel_rsp_ready_o;
    assign pixel_data_for_ce = response_handshake && response_for_pixel_ce &&
                               !pixel_rsp_reject_i;

    // Keep the line-release selection stable under backpressure. A completed
    // bank is releasable only after its accepted request and reply are drained.
    assign bank_has_request0 =
        (req_pending_q && (req_bank_q == 1'b0)) ||
        (txn_valid_q && (txn_bank_q == 1'b0));
    assign bank_has_request1 =
        (req_pending_q && (req_bank_q == 1'b1)) ||
        (txn_valid_q && (txn_bank_q == 1'b1));
    assign release_candidate0 = bank_valid_q[0] &&
        bank_release_pending_q[0] && !bank_has_request0;
    assign release_candidate1 = bank_valid_q[1] &&
        bank_release_pending_q[1] && !bank_has_request1;
    assign line_release_valid_o = release_active_q && !cold_reset;
    assign line_release_bank_o = release_bank_q;

    always_comb begin
        protocol_events = 4'd0;
        deadline_events = 2'd0;
        if (!cold_reset && (ce_pixel_i != (phase_q == 3'd7)))
            protocol_events = protocol_events + 4'd1;
        if (!cold_reset && ce_pixel_i &&
            ((hblank_i != expected_hblank) ||
             (vblank_i != expected_vblank) ||
             (raster_x_i > H_TOTAL_LAST) ||
             (raster_y_i >= (cyclwarr_i ? 9'd280 : 9'd261))))
            protocol_events = protocol_events + 4'd1;
        if (!cold_reset && frame_epoch_bad)
            protocol_events = protocol_events + 4'd1;
        if (!cold_reset && line_done_bad_epoch)
            protocol_events = protocol_events + 4'd1;
        if (!cold_reset && line_done_bad_y)
            protocol_events = protocol_events + 4'd1;
        if (!cold_reset && line_done_duplicate)
            protocol_events = protocol_events + 4'd1;
        if (!cold_reset && line_done_late_mismatch)
            protocol_events = protocol_events + 4'd1;
        if (!cold_reset && response_handshake && response_bad)
            protocol_events = protocol_events + 4'd1;

        if (!cold_reset && line_done_handshake &&
            (line_done_late_i || (line_done_cycles_i > LINE_BUDGET)))
            deadline_events = deadline_events + 2'd1;
        if (!cold_reset && ce_pixel_i && (phase_q == 3'd7) && active_input &&
            !pixel_data_for_ce)
            deadline_events = deadline_events + 2'd1;
    end

    integer bank_index;
    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            phase_q <= 3'd0;
            epoch_valid_q <= 1'b0;
            epoch_id_q <= 16'd0;
            active_seen_q <= 1'b0;
            bank_valid_q <= 2'b00;
            bank_release_pending_q <= 2'b00;
            for (bank_index = 0; bank_index < 2; bank_index = bank_index + 1) begin
                bank_frame_id_q[bank_index] <= 16'd0;
                bank_y_q[bank_index] <= 9'd0;
                bank_late_q[bank_index] <= 1'b0;
                bank_cycles_q[bank_index] <= 12'd0;
            end
            release_active_q <= 1'b0;
            release_bank_q <= 1'b0;
            release_rr_q <= 1'b0;
            req_pending_q <= 1'b0;
            req_bank_q <= 1'b0;
            req_frame_id_q <= 16'd0;
            req_y_q <= 9'd0;
            req_x_q <= 9'd0;
            row_choice_locked_q <= 1'b0;
            row_choice_valid_q <= 1'b0;
            row_choice_bank_q <= 1'b0;
            row_choice_frame_id_q <= 16'd0;
            row_choice_y_q <= 9'd0;
            txn_valid_q <= 1'b0;
            txn_bank_q <= 1'b0;
            txn_frame_id_q <= 16'd0;
            txn_y_q <= 9'd0;
            txn_x_q <= 9'd0;
            video_ce_o <= 1'b0;
            raster_x_o <= 9'd0;
            raster_y_o <= 9'd240;
            hblank_o <= 1'b1;
            vblank_o <= 1'b1;
            video_active_o <= 1'b0;
            rgb_o <= 24'd0;
            deadline_miss_o <= 1'b0;
            deadline_miss_count_o <= 32'd0;
            protocol_fault_o <= 1'b0;
            protocol_fault_count_o <= 32'd0;
            last_line_cycles_o <= 12'd0;
            last_line_late_o <= 1'b0;
            max_pixel_latency_o <= 16'd0;
        end else begin
            phase_q <= phase_q + 3'd1;
            video_ce_o <= ce_pixel_i;

            if (frame_epoch_valid_i && !frame_epoch_bad) begin
                epoch_valid_q <= 1'b1;
                epoch_id_q <= frame_epoch_id_i;
                active_seen_q <= 1'b0;
            end else if (ce_pixel_i && (phase_q == 3'd7) &&
                         (raster_y_i < V_VISIBLE)) begin
                active_seen_q <= 1'b1;
            end

            if (protocol_events != 0) begin
                protocol_fault_o <= 1'b1;
                protocol_fault_count_o <= saturating_add32(
                    protocol_fault_count_o, protocol_events);
            end
            if (deadline_events != 0) begin
                deadline_miss_o <= 1'b1;
                deadline_miss_count_o <= saturating_add32(
                    deadline_miss_count_o, {2'b00, deadline_events});
            end

            if (line_done_handshake) begin
                last_line_cycles_o <= line_done_cycles_i;
                last_line_late_o <= line_done_late_i;
            end
            if (response_handshake && response_tag_matches &&
                pixel_rsp_latency_i > max_pixel_latency_o)
                max_pixel_latency_o <= pixel_rsp_latency_i;

            if (ce_pixel_i && (phase_q == 3'd7)) begin
                raster_x_o <= raster_x_i;
                raster_y_o <= raster_y_i;
                hblank_o <= hblank_i;
                vblank_o <= vblank_i;
                video_active_o <= active_input;
                rgb_o <= (active_input && pixel_data_for_ce)
                       ? pixel_rsp_rgb_i : 24'd0;
            end

            // A held source request is never withdrawn. The free request slot
            // can be refilled on the same edge that its previous tuple accepts.
            if (request_handshake)
                req_pending_q <= 1'b0;
            if ((phase_q == 3'd1) && (!req_pending_q || request_handshake) &&
                active_input && row_choice_for_phase_valid) begin
                req_pending_q <= 1'b1;
                req_bank_q <= row_choice_for_phase_bank;
                req_frame_id_q <= row_choice_for_phase_frame_id;
                req_y_q <= row_choice_for_phase_y;
                req_x_q <= raster_x_i;
            end

            if (row_start_phase) begin
                row_choice_locked_q <= 1'b1;
                row_choice_valid_q <= row_choice_for_phase_valid;
                row_choice_bank_q <= row_choice_for_phase_bank;
                row_choice_frame_id_q <= row_choice_for_phase_frame_id;
                row_choice_y_q <= row_choice_for_phase_y;
            end
            if (ce_pixel_i && (phase_q == 3'd7) && active_input &&
                (raster_x_i == 9'd319)) begin
                row_choice_locked_q <= 1'b0;
                row_choice_valid_q <= 1'b0;
            end

            // One request is outstanding at the pixel adapter. It may retire
            // and hand off to a held next request on the same edge.
            case ({request_handshake, response_handshake})
                2'b10, 2'b11: begin
                    txn_valid_q <= 1'b1;
                    txn_bank_q <= req_bank_q;
                    txn_frame_id_q <= req_frame_id_q;
                    txn_y_q <= req_y_q;
                    txn_x_q <= req_x_q;
                end
                2'b01: txn_valid_q <= 1'b0;
                default: ;
            endcase

            // Per-bank residency and retirement are independent of output
            // response timing. No bank is released while a held or accepted
            // request still names it.
            for (bank_index = 0; bank_index < 2; bank_index = bank_index + 1) begin
                if (release_active_q && line_release_ready_i &&
                    (release_bank_q == bank_index[0])) begin
                    bank_valid_q[bank_index] <= 1'b0;
                    bank_release_pending_q[bank_index] <= 1'b0;
                end else begin
                    if (bank_valid_q[bank_index] &&
                        (bank_frame_id_q[bank_index] != epoch_id_q ||
                         bank_y_q[bank_index] >= V_VISIBLE ||
                         (active_seen_q &&
                          ((raster_y_i >= V_VISIBLE) ||
                           (raster_y_i > bank_y_q[bank_index])))))
                        bank_release_pending_q[bank_index] <= 1'b1;

                    if (ce_pixel_i && (phase_q == 3'd7) && active_input &&
                        (raster_x_i == 9'd319) && bank_valid_q[bank_index] &&
                        (bank_frame_id_q[bank_index] == epoch_id_q) &&
                        (bank_y_q[bank_index] == raster_y_i))
                        bank_release_pending_q[bank_index] <= 1'b1;

                    if (line_done_handshake &&
                        (line_done_bank_i == bank_index[0])) begin
                        bank_valid_q[bank_index] <= 1'b1;
                        bank_frame_id_q[bank_index] <= line_done_frame_id_i;
                        bank_y_q[bank_index] <= line_done_y_i;
                        bank_late_q[bank_index] <= line_done_late_i;
                        bank_cycles_q[bank_index] <= line_done_cycles_i;
                        bank_release_pending_q[bank_index] <=
                            line_done_bad_epoch || line_done_bad_y ||
                            line_done_duplicate;
                    end
                end
            end

            if (!release_active_q) begin
                if (release_candidate0 || release_candidate1) begin
                    release_active_q <= 1'b1;
                    if (release_candidate0 && release_candidate1)
                        release_bank_q <= release_rr_q;
                    else
                        release_bank_q <= release_candidate1;
                end
            end else if (line_release_ready_i) begin
                release_active_q <= 1'b0;
                release_rr_q <= ~release_bank_q;
            end
        end
    end
endmodule
