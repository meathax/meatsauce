// SPDX-License-Identifier: GPL-3.0-or-later
// Private Mad Motor framebuffer writer, adapted from the MiSTer/HeavyUnit
// screen_rotate packet and completed-frame ownership contracts.  The
// transform/address walk is expressed here as coordinate arithmetic so the
// DDR tuple and its target slot can be retained atomically under backpressure.
//
// Rotation codes: 0=CW90, 1=CCW90, 2=180, 3=disabled/direct-video.
module madmotor_framebuffer_rotation #(
    parameter integer INPUT_WIDTH = 256,
    parameter integer INPUT_HEIGHT = 240,
    parameter integer FIFO_DEPTH = 64,
    parameter logic [6:0] MEM_BASE = 7'b0010010
) (
    input  logic        clk,
    input  logic        reset,
    input  logic [1:0]  rotation,
    input  logic        ce_pixel,
    input  logic        source_vs,
    input  logic        source_de,
    input  logic [7:0]  source_r,
    input  logic [7:0]  source_g,
    input  logic [7:0]  source_b,
    input  logic        fb_vblank,
    input  logic        fb_low_latency,
    input  logic        ddram_busy,

    output logic        video_rotated,
    output logic        fb_enable,
    output logic [4:0]  fb_format,
    output logic [11:0] fb_width,
    output logic [11:0] fb_height,
    output logic [31:0] fb_base,
    output logic [13:0] fb_stride,

    output logic        ddram_clk,
    output logic [7:0]  ddram_burstcount,
    output logic [28:0] ddram_address,
    output logic [63:0] ddram_data,
    output logic [7:0]  ddram_byteenable,
    output logic        ddram_we,
    output logic        ddram_rd,

    output logic [7:0]  queue_level,
    output logic [31:0] accepted_writes,
    output logic [31:0] dropped_frames,
    output logic        frame_overflow,
    output logic        protocol_error
);
    localparam integer PTR_W = $clog2(FIFO_DEPTH);
    localparam integer COUNT_W = $clog2(FIFO_DEPTH + 1);
    localparam integer FRAME_PIXELS = INPUT_WIDTH * INPUT_HEIGHT;
    localparam logic [11:0] INPUT_WIDTH_12 = 12'(INPUT_WIDTH);
    localparam logic [11:0] INPUT_HEIGHT_12 = 12'(INPUT_HEIGHT);
    localparam logic [12:0] INPUT_WIDTH_13 = 13'(INPUT_WIDTH);
    localparam logic [12:0] INPUT_HEIGHT_13 = 13'(INPUT_HEIGHT);
    localparam logic [COUNT_W-1:0] FIFO_DEPTH_COUNT = COUNT_W'(FIFO_DEPTH);

    (* ramstyle = "logic" *) logic [28:0] fifo_address [0:FIFO_DEPTH-1];
    (* ramstyle = "logic" *) logic [31:0] fifo_pixel [0:FIFO_DEPTH-1];
    (* ramstyle = "logic" *) logic [7:0] fifo_byteenable [0:FIFO_DEPTH-1];
    logic [1:0] fifo_slot [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0] fifo_read_ptr;
    logic [PTR_W-1:0] fifo_write_ptr;
    logic [COUNT_W-1:0] fifo_count;

    logic [COUNT_W-1:0] outstanding [0:2];
    logic [31:0] slot_sequence [0:2];
    logic [1:0] slot_rotation [0:2];
    logic [2:0] pending_slots;
    logic [2:0] ready_slots;
    logic [1:0] producer_slot;
    logic producer_slot_valid;
    logic [1:0] producer_rotation;
    logic [1:0] consumer_slot;
    logic consumer_slot_valid;
    logic [1:0] consumer_rotation;
    logic [31:0] next_sequence;

    logic old_source_vs;
    logic old_source_de;
    logic old_fb_vblank;
    // sys_top samples HDMI blank into clk_vid once. Retain two local stages
    // before any ownership decision; never use the first-stage level in logic.
    (* async_reg = "true", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    logic fb_vblank_meta, fb_vblank_sync;
    always_ff @(posedge clk) begin
        if (reset) begin fb_vblank_meta <= 1'b0; fb_vblank_sync <= 1'b0; end
        else begin fb_vblank_meta <= fb_vblank; fb_vblank_sync <= fb_vblank_meta; end
    end
    logic [11:0] x_position;
    logic [11:0] y_position;
    logic [12:0] line_pixel_count;
    logic [12:0] frame_line_count;
    logic [31:0] frame_pixel_count;
    logic line_open;
    logic frame_has_pixels;
    logic frame_bad;

    wire source_eof = ce_pixel && source_vs && !old_source_vs;
    wire consumer_vblank = fb_vblank_sync && !old_fb_vblank;
    wire pixel_event = ce_pixel && source_de;
    wire de_rise = ce_pixel && source_de && !old_source_de;
    wire de_fall = ce_pixel && !source_de && old_source_de;

    wire [11:0] x_for_pixel = de_rise ? 12'd0 : x_position;
    wire [11:0] y_for_pixel = de_rise ? frame_line_count[11:0] : y_position;
    wire [1:0] pixel_rotation = frame_has_pixels ? producer_rotation : rotation;
    wire [12:0] line_pixels_before = de_rise ? 13'd0 : line_pixel_count;
    wire pixel_bad_now = pixel_event &&
        ((x_for_pixel >= INPUT_WIDTH_12) || (y_for_pixel >= INPUT_HEIGHT_12) ||
         (frame_pixel_count >= FRAME_PIXELS) ||
         (frame_has_pixels && !source_eof && (rotation != producer_rotation)));
    wire line_bad_now = de_fall &&
        (!line_open || (line_pixel_count != INPUT_WIDTH_13));
    wire mode_bad_now = !source_eof && frame_has_pixels &&
        (rotation != producer_rotation);

    // Only the non-reset sequential branch consumes this look-ahead result.
    // Public WE remains reset-gated; feeding reset through ownership selection
    // adds a redundant reset->count->sequence->slot path to every slot register.
    wire ddram_pop = (fifo_count != 0) && !ddram_busy;
    wire push_attempt = pixel_event && producer_slot_valid &&
        (pixel_rotation != 2'd3) && !frame_bad && !pixel_bad_now &&
        (line_pixels_before < INPUT_WIDTH_13) &&
        (frame_pixel_count < FRAME_PIXELS);
    wire fifo_overflow_now = push_attempt &&
        (fifo_count == FIFO_DEPTH_COUNT) && !ddram_pop;
    wire fifo_push = push_attempt && !fifo_overflow_now;

    wire [31:0] frame_pixels_at_eof = frame_pixel_count +
        (pixel_event ? 32'd1 : 32'd0);
    wire [12:0] lines_at_eof = frame_line_count +
        (de_fall ? 13'd1 : 13'd0);
    wire line_open_at_eof = de_fall ? 1'b0 : de_rise ? 1'b1 : line_open;
    wire mode_change_new_frame = pixel_event && !frame_has_pixels &&
        (rotation != producer_rotation);
    wire frame_good_at_eof = source_eof && producer_slot_valid &&
        (producer_rotation != 2'd3) &&
        frame_has_pixels && !frame_bad && !pixel_bad_now && !line_bad_now &&
        !fifo_overflow_now && !line_open_at_eof &&
        (frame_pixels_at_eof == FRAME_PIXELS) &&
        (lines_at_eof == INPUT_HEIGHT_13);

    logic [31:0] byte_stride_for_write;
    logic [11:0] destination_x;
    logic [11:0] destination_y;
    logic [31:0] destination_offset;
    logic [31:0] pixel_word;
    logic [28:0] pixel_address;
    logic [7:0] pixel_byteenable;

    always_comb begin
        if ((pixel_rotation == 2'd0) || (pixel_rotation == 2'd1))
            byte_stride_for_write = ((INPUT_HEIGHT + 3) / 4) * 16;
        else
            byte_stride_for_write = ((INPUT_WIDTH + 3) / 4) * 16;

        destination_x = 12'd0;
        destination_y = 12'd0;
        case (pixel_rotation)
            2'd0: begin // 90 degrees clockwise
                destination_x = INPUT_HEIGHT_12 - 12'd1 - y_for_pixel;
                destination_y = x_for_pixel;
            end
            2'd1: begin // 90 degrees counter-clockwise
                destination_x = y_for_pixel;
                destination_y = INPUT_WIDTH_12 - 12'd1 - x_for_pixel;
            end
            2'd2: begin // 180 degrees
                destination_x = INPUT_WIDTH_12 - 12'd1 - x_for_pixel;
                destination_y = INPUT_HEIGHT_12 - 12'd1 - y_for_pixel;
            end
            default: begin
                destination_x = 12'd0;
                destination_y = 12'd0;
            end
        endcase

        destination_offset = destination_y * byte_stride_for_write +
            ({20'd0, destination_x} << 2);
        pixel_word = {8'd0, source_b, source_g, source_r};
        pixel_address = {MEM_BASE, producer_slot, destination_offset[22:3]};
        pixel_byteenable = destination_offset[2] ? 8'hf0 : 8'h0f;
    end

    logic [COUNT_W-1:0] outstanding_after [0:2];
    logic [2:0] pending_after;
    logic [2:0] ready_after;
    logic [2:0] ready_commit;
    logic [31:0] sequence_after [0:2];
    logic [31:0] sequence_commit [0:2];
    logic [31:0] sequence_counter_after;
    logic [2:0] occupied_for_writer;
    logic [1:0] selected_consumer_slot;
    logic selected_consumer_valid;
    logic [2:0] consumer_eligible;
    logic [1:0] next_producer_slot;
    logic next_producer_valid;
    integer state_comb_index;
    integer sequential_index;
    wire close_pending = frame_good_at_eof;

    // Compare existing and newly published sequence values in parallel.
    // EOF/DDR backpressure then selects one-bit results instead of feeding
    // a 32-bit sequence mux into the ownership comparators. Keep unsigned
    // comparisons, including counter wrap and the lower-slot tie priority.
    wire [31:0] published_sequence = next_sequence + 32'd1;
    wire closing_slot0 = close_pending && (producer_slot == 2'd0);
    wire closing_slot1 = close_pending && (producer_slot == 2'd1);
    wire closing_slot2 = close_pending && (producer_slot == 2'd2);
    wire sequence_ge01 = closing_slot0 ? (published_sequence >= slot_sequence[1]) :
                         closing_slot1 ? (slot_sequence[0] >= published_sequence) :
                                         (slot_sequence[0] >= slot_sequence[1]);
    wire sequence_ge02 = closing_slot0 ? (published_sequence >= slot_sequence[2]) :
                         closing_slot2 ? (slot_sequence[0] >= published_sequence) :
                                         (slot_sequence[0] >= slot_sequence[2]);
    wire sequence_ge12 = closing_slot1 ? (published_sequence >= slot_sequence[2]) :
                         closing_slot2 ? (slot_sequence[1] >= published_sequence) :
                                         (slot_sequence[1] >= slot_sequence[2]);

    always_comb begin
        for (state_comb_index = 0; state_comb_index < 3; state_comb_index = state_comb_index + 1) begin
            outstanding_after[state_comb_index] = outstanding[state_comb_index];
            if (fifo_push && (producer_slot == state_comb_index[1:0]))
                outstanding_after[state_comb_index] = outstanding_after[state_comb_index] + 1'b1;
            if (ddram_pop && (fifo_slot[fifo_read_ptr] == state_comb_index[1:0]))
                outstanding_after[state_comb_index] = outstanding_after[state_comb_index] - 1'b1;
            sequence_after[state_comb_index] = slot_sequence[state_comb_index];
        end

        pending_after = pending_slots;
        ready_after = ready_slots;
        sequence_counter_after = next_sequence;

        if (mode_change_new_frame) begin
            for (state_comb_index = 0; state_comb_index < 3; state_comb_index = state_comb_index + 1) begin
                if (slot_rotation[state_comb_index] != rotation) begin
                    pending_after[state_comb_index] = 1'b0;
                    ready_after[state_comb_index] = 1'b0;
                end
            end
        end

        for (state_comb_index = 0; state_comb_index < 3; state_comb_index = state_comb_index + 1) begin
            if (pending_after[state_comb_index] && (outstanding_after[state_comb_index] == 0)) begin
                pending_after[state_comb_index] = 1'b0;
                ready_after[state_comb_index] = 1'b1;
            end
        end

        if (close_pending) begin
            sequence_counter_after = published_sequence;
            sequence_after[producer_slot] = sequence_counter_after;
            if (outstanding_after[producer_slot] == 0)
                ready_after[producer_slot] = 1'b1;
            else
                pending_after[producer_slot] = 1'b1;
        end

        selected_consumer_slot = consumer_slot;
        selected_consumer_valid = 1'b0;
        for (state_comb_index = 0; state_comb_index < 3; state_comb_index = state_comb_index + 1)
            consumer_eligible[state_comb_index] = ready_after[state_comb_index] &&
                (slot_rotation[state_comb_index] == rotation);
        if (consumer_vblank && (rotation != 2'd3)) begin
            // Compare the three sequence pairs in parallel. The previous
            // running maximum muxed a 32-bit result into the next comparator
            // on the same ownership path. Equal sequences retain the lower
            // slot index, exactly as the original ascending scan did.
            if (consumer_eligible[0] &&
                (!consumer_eligible[1] || sequence_ge01) &&
                (!consumer_eligible[2] || sequence_ge02)) begin
                selected_consumer_slot = 2'd0;
                selected_consumer_valid = 1'b1;
            end else if (consumer_eligible[1] &&
                (!consumer_eligible[0] || !sequence_ge01) &&
                (!consumer_eligible[2] || sequence_ge12)) begin
                selected_consumer_slot = 2'd1;
                selected_consumer_valid = 1'b1;
            end else if (consumer_eligible[2]) begin
                selected_consumer_slot = 2'd2;
                selected_consumer_valid = 1'b1;
            end
        end

        ready_commit = ready_after;
        sequence_commit[0] = sequence_after[0];
        sequence_commit[1] = sequence_after[1];
        sequence_commit[2] = sequence_after[2];
        if (consumer_vblank && selected_consumer_valid)
            ready_commit[selected_consumer_slot] = 1'b0;

        occupied_for_writer = pending_after | ready_commit;
        for (state_comb_index = 0; state_comb_index < 3; state_comb_index = state_comb_index + 1) begin
            if (outstanding_after[state_comb_index] != 0)
                occupied_for_writer[state_comb_index] = 1'b1;
        end
        if (consumer_slot_valid && !selected_consumer_valid)
            occupied_for_writer[consumer_slot] = 1'b1;
        if (selected_consumer_valid)
            occupied_for_writer[selected_consumer_slot] = 1'b1;

        next_producer_slot = producer_slot;
        next_producer_valid = 1'b0;
        if (source_eof) begin
            // Three slots need only a cyclic priority encoder. A widened
            // signed add/modulo plus dynamic bit select puts integer division
            // logic on the frame ownership path in Quartus 17.
            case (producer_slot)
                2'd0: begin
                    if (!occupied_for_writer[1]) begin next_producer_slot=2'd1; next_producer_valid=1'b1; end
                    else if (!occupied_for_writer[2]) begin next_producer_slot=2'd2; next_producer_valid=1'b1; end
                    else if (!occupied_for_writer[0]) begin next_producer_slot=2'd0; next_producer_valid=1'b1; end
                end
                2'd1: begin
                    if (!occupied_for_writer[2]) begin next_producer_slot=2'd2; next_producer_valid=1'b1; end
                    else if (!occupied_for_writer[0]) begin next_producer_slot=2'd0; next_producer_valid=1'b1; end
                    else if (!occupied_for_writer[1]) begin next_producer_slot=2'd1; next_producer_valid=1'b1; end
                end
                2'd2: begin
                    if (!occupied_for_writer[0]) begin next_producer_slot=2'd0; next_producer_valid=1'b1; end
                    else if (!occupied_for_writer[1]) begin next_producer_slot=2'd1; next_producer_valid=1'b1; end
                    else if (!occupied_for_writer[2]) begin next_producer_slot=2'd2; next_producer_valid=1'b1; end
                end
                default: begin end // unreachable: reset/all selections are 0..2
            endcase
        end
    end

    always_comb begin
        ddram_clk = clk;
        ddram_burstcount = 8'd1;
        ddram_address = fifo_count != 0 ? fifo_address[fifo_read_ptr] : 29'd0;
        ddram_data = fifo_count != 0 ? {fifo_pixel[fifo_read_ptr], fifo_pixel[fifo_read_ptr]} : 64'd0;
        ddram_byteenable = fifo_count != 0 ? fifo_byteenable[fifo_read_ptr] : 8'd0;
        ddram_we = (fifo_count != 0) && !reset;
        ddram_rd = 1'b0;
        queue_level = {{(8-COUNT_W){1'b0}}, fifo_count};
        fb_format = 5'b00110;
        fb_enable = consumer_slot_valid && (rotation != 2'd3);
        fb_base = {MEM_BASE, consumer_slot, 23'd0};

        if (fb_enable)
            video_rotated = (consumer_rotation == 2'd0) || (consumer_rotation == 2'd1);
        else
            video_rotated = 1'b0;

        if (consumer_slot_valid) begin
            if ((consumer_rotation == 2'd0) || (consumer_rotation == 2'd1)) begin
                fb_width = INPUT_HEIGHT_12;
                fb_height = INPUT_WIDTH_12;
                fb_stride = 14'(((INPUT_HEIGHT + 3) / 4) * 16);
            end else begin
                fb_width = INPUT_WIDTH_12;
                fb_height = INPUT_HEIGHT_12;
                fb_stride = 14'(((INPUT_WIDTH + 3) / 4) * 16);
            end
        end else if ((rotation == 2'd0) || (rotation == 2'd1)) begin
            fb_width = INPUT_HEIGHT_12;
            fb_height = INPUT_WIDTH_12;
            fb_stride = 14'(((INPUT_HEIGHT + 3) / 4) * 16);
        end else begin
            fb_width = INPUT_WIDTH_12;
            fb_height = INPUT_HEIGHT_12;
            fb_stride = 14'(((INPUT_WIDTH + 3) / 4) * 16);
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            fifo_read_ptr <= '0;
            fifo_write_ptr <= '0;
            fifo_count <= '0;
            accepted_writes <= 32'd0;
            dropped_frames <= 32'd0;
            frame_overflow <= 1'b0;
            protocol_error <= 1'b0;
            pending_slots <= 3'b000;
            ready_slots <= 3'b000;
            producer_slot <= 2'd0;
            producer_slot_valid <= 1'b1;
            producer_rotation <= rotation;
            consumer_slot <= 2'd0;
            consumer_slot_valid <= 1'b0;
            consumer_rotation <= 2'd3;
            next_sequence <= 32'd0;
            old_source_vs <= 1'b0;
            old_source_de <= 1'b0;
            old_fb_vblank <= 1'b0;
            x_position <= 12'd0;
            y_position <= 12'd0;
            line_pixel_count <= 13'd0;
            frame_line_count <= 13'd0;
            frame_pixel_count <= 32'd0;
            line_open <= 1'b0;
            frame_has_pixels <= 1'b0;
            frame_bad <= 1'b0;
            for (sequential_index = 0; sequential_index < 3; sequential_index = sequential_index + 1) begin
                outstanding[sequential_index] <= '0;
                slot_sequence[sequential_index] <= 32'd0;
                slot_rotation[sequential_index] <= 2'd3;
            end
            slot_rotation[0] <= rotation;
        end else begin
            if (ce_pixel) begin
                old_source_vs <= source_vs;
                old_source_de <= source_de;
            end
            old_fb_vblank <= fb_vblank_sync;

            if (fifo_push) begin
                fifo_address[fifo_write_ptr] <= pixel_address;
                fifo_pixel[fifo_write_ptr] <= pixel_word;
                fifo_byteenable[fifo_write_ptr] <= pixel_byteenable;
                fifo_slot[fifo_write_ptr] <= producer_slot;
                fifo_write_ptr <= fifo_write_ptr + 1'b1;
            end
            if (ddram_pop) begin
                fifo_read_ptr <= fifo_read_ptr + 1'b1;
                accepted_writes <= accepted_writes + 1'b1;
            end
            case ({fifo_push, ddram_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase

            for (sequential_index = 0; sequential_index < 3; sequential_index = sequential_index + 1)
                outstanding[sequential_index] <= outstanding_after[sequential_index];

            pending_slots <= pending_after;
            ready_slots <= ready_commit;
            for (sequential_index = 0; sequential_index < 3; sequential_index = sequential_index + 1)
                slot_sequence[sequential_index] <= sequence_commit[sequential_index];

            if (consumer_vblank && selected_consumer_valid) begin
                consumer_slot <= selected_consumer_slot;
                consumer_slot_valid <= 1'b1;
                consumer_rotation <= slot_rotation[selected_consumer_slot];
            end

            if (close_pending)
                next_sequence <= sequence_counter_after;

            if (source_eof) begin
                producer_slot <= next_producer_slot;
                producer_slot_valid <= next_producer_valid;
                producer_rotation <= rotation;
                if (next_producer_valid)
                    slot_rotation[next_producer_slot] <= rotation;

                if (frame_has_pixels && (producer_rotation != 2'd3) &&
                    !frame_good_at_eof)
                    dropped_frames <= dropped_frames + 1'b1;
                if (frame_has_pixels && (producer_rotation != 2'd3) &&
                    (frame_bad || pixel_bad_now || line_bad_now || mode_bad_now ||
                     fifo_overflow_now || !producer_slot_valid))
                    frame_overflow <= frame_overflow || fifo_overflow_now;
                if (!next_producer_valid)
                    frame_bad <= 1'b1;
                else
                    frame_bad <= 1'b0;

                x_position <= 12'd0;
                y_position <= 12'd0;
                line_pixel_count <= 13'd0;
                frame_line_count <= 13'd0;
                frame_pixel_count <= 32'd0;
                line_open <= 1'b0;
                frame_has_pixels <= 1'b0;
            end else begin
                if (de_rise) begin
                    if (line_open)
                        protocol_error <= 1'b1;
                    line_open <= 1'b1;
                    line_pixel_count <= 13'd0;
                    x_position <= 12'd0;
                    y_position <= frame_line_count[11:0];
                    if (frame_line_count >= INPUT_HEIGHT_13)
                        frame_bad <= 1'b1;
                end
                if (pixel_event) begin
                    frame_has_pixels <= 1'b1;
                    frame_pixel_count <= frame_pixel_count + 1'b1;
                    line_pixel_count <= line_pixels_before + 1'b1;
                    x_position <= x_for_pixel + 1'b1;
                    if (!frame_has_pixels) begin
                        producer_rotation <= rotation;
                        if (producer_slot_valid)
                            slot_rotation[producer_slot] <= rotation;
                    end
                    if (pixel_bad_now) begin
                        frame_bad <= 1'b1;
                        protocol_error <= 1'b1;
                    end
                end
                if (de_fall) begin
                    line_open <= 1'b0;
                    frame_line_count <= frame_line_count + 1'b1;
                    if (line_bad_now) begin
                        frame_bad <= 1'b1;
                        protocol_error <= 1'b1;
                    end
                end
                if (mode_bad_now || fifo_overflow_now || !producer_slot_valid)
                    frame_bad <= 1'b1;
                if (fifo_overflow_now)
                    frame_overflow <= 1'b1;
            end

            if (ddram_pop && (outstanding[fifo_slot[fifo_read_ptr]] == 0))
                protocol_error <= 1'b1;
        end
    end

    initial begin
        if ((FIFO_DEPTH < 2) || ((FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0))
            $error("FIFO_DEPTH must be a power of two >= 2");
        if ((INPUT_WIDTH < 1) || (INPUT_WIDTH > 4095) ||
            (INPUT_HEIGHT < 1) || (INPUT_HEIGHT > 4095))
            $error("frame dimensions must fit the framebuffer interface");
        if ((FRAME_PIXELS * 4) > 8388608)
            $error("one image must fit within its 8 MiB framebuffer slot");
    end

    // FB_LL is intentionally ignored: publication waits for a complete,
    // physically accepted frame and only changes the consumer slot in VBlank.
    logic unused_fb_low_latency;
    always_comb unused_fb_low_latency = fb_low_latency;
endmodule
