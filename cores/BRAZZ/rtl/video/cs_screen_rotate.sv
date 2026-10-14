// SPDX-License-Identifier: GPL-3.0-or-later
// Fixed native raster tap. Only complete, accepted DDR frames are published.
// Bank reservation: three 8MiB buffers at 0x24000000, outside game ROM DDR.
module cs_screen_rotate #(
    parameter WIDTH = 320, HEIGHT = 240, FIFO_BITS = 8
) (
    input logic clk, reset, ce_pix, frame_start, display_enable,
    input logic [11:0] pixel_x, pixel_y,
    input logic [23:0] rgb,
    input logic [1:0] orientation, // 0 native, 1 CW, 2 CCW, 3 180 degrees
    input logic direct_video, fb_vbl, ddram_busy,
    output logic fb_en,
    output logic [11:0] fb_width, fb_height,
    output logic [31:0] fb_base,
    output logic [13:0] fb_stride,
    output logic [28:0] ddram_addr,
    output logic [63:0] ddram_din,
    output logic [7:0] ddram_be,
    output logic ddram_we, overflow
);
    localparam DEPTH = 1 << FIFO_BITS;
    localparam COORD_BITS = $clog2(WIDTH > HEIGHT ? WIDTH : HEIGHT);
    localparam OFFSET_BITS = $clog2(WIDTH * HEIGHT * 4);
    // {mode,buffer,last,byte_address,data}. Registered show-ahead FIFO.
    (* ramstyle = "M10K" *) logic [68:0] fifo [0:DEPTH-1];
    logic [68:0] head, packet, ram_head, direct_head = 0;
    logic head_from_ram = 0;
    logic [FIFO_BITS-1:0] rd_ptr = 0, wr_ptr = 0;
    logic [FIFO_BITS:0] count = 0;
    logic [1:0] active_mode = 0, capture_buffer = 0;
    logic [1:0] pending_buffer = 1, pending_mode = 0;
    logic [1:0] shown_buffer = 2, shown_mode = 0;
    logic pending_valid = 0, shown_valid = 0, capture = 0;
    logic vbl_meta = 0, vbl_sync = 0, vbl_previous = 0;
    logic push, pop;
    logic prepare_pixel, prepared_valid = 0, prepared_last = 0;
    logic [COORD_BITS-1:0] prepared_x = 0, prepared_y = 0;
    logic [1:0] prepared_mode = 0, prepared_buffer = 0;
    logic [31:0] prepared_color = 0;
    logic [OFFSET_BITS-1:0] row_offset, byte_offset;
    logic [31:0] destination;
    logic [1:0] write_mode, write_buffer;
    logic write_capture;
    integer dx, dy, stride;
    function automatic [1:0] free_buffer(input [1:0] shown, pending);
        if (shown != 0 && pending != 0) free_buffer = 0;
        else if (shown != 1 && pending != 1) free_buffer = 1;
        else free_buffer = 2;
    endfunction
    assign head = head_from_ram ? ram_head : direct_head;
    // A dedicated synchronous RAM read register permits M10K inference. Empty
    // queue arrivals bypass it; the selected head still advances on each pop.
    always_ff @(posedge clk) begin
        if (push) fifo[wr_ptr] <= packet;
        if (pop && count > 1) ram_head <= fifo[FIFO_BITS'(rd_ptr + 1'b1)];
    end
    always_comb begin
        write_mode = frame_start ? orientation : active_mode;
        write_buffer = frame_start ? free_buffer(shown_buffer, pending_buffer) : capture_buffer;
        write_capture = frame_start ? (orientation != 0 && count == 0 && !prepared_valid) : capture;
        dx = int'(pixel_x); dy = int'(pixel_y); stride = WIDTH * 4;
        case (write_mode)
            1: begin dx = HEIGHT-1-int'(pixel_y); dy = int'(pixel_x); stride = HEIGHT*4; end
            2: begin dx = int'(pixel_y); dy = WIDTH-1-int'(pixel_x); stride = HEIGHT*4; end
            3: begin dx = WIDTH-1-int'(pixel_x); dy = HEIGHT-1-int'(pixel_y); end
            default: ;
        endcase
        // Coordinate selection is captured before constant-stride arithmetic.
        // Buffer bits and the native frame offset occupy disjoint fields.
        row_offset = (prepared_mode == 1 || prepared_mode == 2)
                     ? OFFSET_BITS'(prepared_y * (HEIGHT*4)) : OFFSET_BITS'(prepared_y * (WIDTH*4));
        byte_offset = row_offset + (OFFSET_BITS'(prepared_x) << 2);
        destination = 32'h24000000 | (32'(prepared_buffer) << 23) | 32'(byte_offset);
        packet = {prepared_mode,prepared_buffer,prepared_last,destination,prepared_color};
        pop = count != 0 && !ddram_busy && !reset;
        push = prepared_valid && !reset && (count < (FIFO_BITS+1)'(DEPTH) || pop);
        prepare_pixel = ce_pix && display_enable && write_capture && !direct_video && !reset &&
                        pixel_x < 12'(WIDTH) && pixel_y < 12'(HEIGHT);
        ddram_we = count != 0 && !reset; // held stable throughout BUSY
        ddram_addr = head[63:35];
        ddram_din = {head[31:0],head[31:0]};
        ddram_be = head[34] ? 8'hf0 : 8'h0f;
        fb_en = shown_valid && active_mode != 0 && shown_mode == active_mode && !direct_video;
        fb_width = (shown_mode == 1 || shown_mode == 2) ? 12'(HEIGHT) : 12'(WIDTH);
        fb_height = (shown_mode == 1 || shown_mode == 2) ? 12'(WIDTH) : 12'(HEIGHT);
        fb_stride = 14'(fb_width * 4);
        fb_base = 32'h24000000 + (32'(shown_buffer) << 23);
    end
    always_ff @(posedge clk) begin
        vbl_meta <= fb_vbl; vbl_sync <= vbl_meta; vbl_previous <= vbl_sync;
        if (reset) begin
            rd_ptr <= 0; wr_ptr <= 0; count <= 0; direct_head <= 0; head_from_ram <= 0;
            active_mode <= 0; capture_buffer <= 0; capture <= 0;
            pending_buffer <= 1; pending_mode <= 0; pending_valid <= 0;
            shown_buffer <= 2; shown_mode <= 0; shown_valid <= 0; overflow <= 0;
            prepared_valid <= 0;
        end else begin
            if (push) prepared_valid <= 0;
            if (prepare_pixel) begin
                if (!prepared_valid || push) begin
                    prepared_valid <= 1;
                    prepared_x <= COORD_BITS'(dx); prepared_y <= COORD_BITS'(dy);
                    prepared_mode <= write_mode; prepared_buffer <= write_buffer;
                    prepared_last <= pixel_x == 12'(WIDTH-1) && pixel_y == 12'(HEIGHT-1);
                    prepared_color <= {8'd0,rgb[7:0],rgb[15:8],rgb[23:16]};
                end else begin capture <= 0; overflow <= 1; end
            end
            if (push) wr_ptr <= wr_ptr + 1'd1;
            if (pop) rd_ptr <= rd_ptr + 1'd1;
            case ({push,pop})
                2'b10: count <= count + 1'd1;
                2'b01: count <= count - 1'd1;
                default: ;
            endcase
            if (pop && count > 1) head_from_ram <= 1;
            else if (push && (count == 0 || (pop && count == 1))) begin
                direct_head <= packet; head_from_ram <= 0;
            end
            if (pop && head[64]) begin
                pending_buffer <= head[66:65]; pending_mode <= head[68:67]; pending_valid <= 1;
            end
            // Publish at the HDMI reader's vertical blank. Keep the previous
            // complete image when DDR is blocked or the new frame was dropped.
            if (vbl_sync && !vbl_previous && pending_valid) begin
                shown_buffer <= pending_buffer; shown_mode <= pending_mode;
                shown_valid <= 1; pending_valid <= 0;
                // Completion on this same clock is the next pending frame.
                if (pop && head[64]) pending_valid <= 1;
            end
            if (prepare_pixel && prepared_valid && !push) begin
                capture <= 0; overflow <= 1;
            end
            if (frame_start) begin
                active_mode <= direct_video ? 2'd0 : orientation;
                capture_buffer <= free_buffer(shown_buffer, pending_buffer);
                capture <= orientation != 0 && !direct_video && count == 0 && !prepared_valid;
            end
            if (direct_video) capture <= 0;
            if (ce_pix && display_enable && capture && (pixel_x >= 12'(WIDTH) || pixel_y >= 12'(HEIGHT))) begin
                capture <= 0; overflow <= 1;
            end
        end
    end
endmodule
