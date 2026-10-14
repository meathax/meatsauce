// SPDX-License-Identifier: GPL-3.0-or-later
// Shared live line scheduler, board read arbitration, mixer and xBGR555 output.
//
// Lines are built into a ring of 2**LINE_BITS display line buffers, up to
// LOOKAHEAD lines before the raster reaches them, so a run of heavy sprite
// lines borrows the slack of the lighter lines built ahead of it. A build that
// is still running when its line is about to be scanned is aborted (remaining
// sprite descriptors are not drawn, as the PCB's sprite chip drops what it
// cannot fit) and composed from what has been fetched, so a line is never left
// black.
module osman_video #(
    // Raster x of the previous line from which an undone build reserves SDRAM
    // for graphics (osman_memory withholds new CPU ROM fetches). ~960 clocks.
    parameter integer URGENT_X = 160,
    // Raster x of the previous line at which an undone build is aborted.
    // Leaves 192 clocks: ~80 to compose, the rest to drain outstanding reads.
    parameter integer ABORT_X = 480,
    // Display line ring: 2**LINE_BITS buffers of 80 packed four-pixel words.
    // Builds run up to LOOKAHEAD lines ahead. The ring keeps 8 lines of
    // headroom behind the raster, so a line that is not ready when it is scanned
    // can repeat the previous good line (see scan_slot) without that buffer
    // being rebuilt underneath it.
    parameter integer LINE_BITS = 5,
    parameter integer LOOKAHEAD = (1 << LINE_BITS) - 8
)(
    input wire clk, reset, pause,
    input wire [7:0] profile,
    input wire ce_pixel, line_start,
    input wire [8:0] x,
    input wire [7:0] y,
    input wire hs, vs, display_enable, frame_parity, global_flip,
    input wire commit_valid, commit_we,
    input wire [25:0] commit_addr,
    input wire [3:0] commit_be,
    input wire [31:0] commit_data,
    output wire board_req,
    output wire [25:0] board_addr,
    input wire board_valid,
    input wire [31:0] board_data,
    output wire tile_req,
    output wire [20:0] tile_byte_addr,
    input wire tile_valid,
    input wire [63:0] tile_data,
    output wire sprite_req,
    output wire [22:0] sprite_byte_addr,
    input wire sprite_valid,
    input wire [63:0] sprite_data,
    output reg video_ce, video_de, video_hs, video_vs,
    output reg [8:0] video_x,
    output reg [7:0] video_y,
    output wire [7:0] red, green, blue,
    output reg render_done, render_urgent,
    output reg [7:0] render_y,
    output reg [31:0] rendered_lines, missed_lines, max_line_cycles, aborted_lines, late_lines
);
    wire [25:0] mirror_commit_addr = profile == 8'd2 && commit_addr[25:19] == 7'd2
        ? commit_addr + 26'h080000
        : profile == 8'd2 && commit_addr[25:19] == 7'd3 ? 26'h3ffffff : commit_addr;
    localparam [1:0] IDLE=0, BUILD=1, COMPOSE=2;
    reg [1:0] phase;
    reg cfg_start, sprite_start, line_abort;
    wire cfg_done, tile_pixel_ready, tile_pixel_valid, sprite_busy, sprite_done;
    reg cfg_ready, tile_finished, sprite_finished, tile_inflight;
    reg [8:0] tile_next_x, compose_x;
    reg [7:0] next_y;
    wire tile_pixel_req = phase == BUILD && cfg_ready && !tile_finished && !line_abort && tile_pixel_ready
        && (!tile_inflight || tile_pixel_valid) && !(tile_pixel_valid && tile_next_x == 319);
    wire [8:0] requested_x = tile_pixel_valid ? tile_next_x + 1'b1 : tile_next_x;
    wire tile_flip;
    reg [31:0] line_cycles;
    // Tile line buffer: four block RAMs, one per x[1:0] lane, each word holding
    // {pf1 opaque, pf1 index, pf2 opaque, pf2 index}. The composer always reads
    // four aligned pixels, so one registered read per lane replaces four
    // 320-entry multiplexers.
    (* ramstyle = "M10K" *) reg [19:0] tile_line0 [0:127];
    (* ramstyle = "M10K" *) reg [19:0] tile_line1 [0:127];
    (* ramstyle = "M10K" *) reg [19:0] tile_line2 [0:127];
    (* ramstyle = "M10K" *) reg [19:0] tile_line3 [0:127];
    reg [19:0] tile_q0, tile_q1, tile_q2, tile_q3;
    wire [8:0] pf1_index, pf2_index;
    wire pf1_opaque, pf2_opaque;
    wire [9:0] sprite_index, mixed_index, sprite_index_next, mixed_index_next;
    wire [1:0] sprite_priority, sprite_priority_next;
    wire sprite_opaque, sprite_opaque_next;
    // The line RAMs are read one clock ahead of compose_x, so the registered
    // word is the one for the pixel group being composed. compose_x holds 0
    // (group 0) throughout BUILD, so group 0 is already present when COMPOSE starts.
    wire [6:0] tile_read_group = compose_x[8:2] + {6'd0, phase == COMPOSE};
    // The sprite line RAMs are read one clock ahead of compose_x as well.
    wire [8:0] sprite_read_x = compose_x + (phase == COMPOSE ? 9'd4 : 9'd0);
    always @(posedge clk) begin
        tile_q0 <= tile_line0[tile_read_group];
        tile_q1 <= tile_line1[tile_read_group];
        tile_q2 <= tile_line2[tile_read_group];
        tile_q3 <= tile_line3[tile_read_group];
    end
    wire tile_line_write = phase == BUILD && tile_pixel_valid;
    wire [19:0] tile_line_word = {pf1_opaque, pf1_index, pf2_opaque, pf2_index};
    always @(posedge clk) begin
        if (tile_line_write && tile_next_x[1:0] == 2'd0) tile_line0[tile_next_x[8:2]] <= tile_line_word;
        if (tile_line_write && tile_next_x[1:0] == 2'd1) tile_line1[tile_next_x[8:2]] <= tile_line_word;
        if (tile_line_write && tile_next_x[1:0] == 2'd2) tile_line2[tile_next_x[8:2]] <= tile_line_word;
        if (tile_line_write && tile_next_x[1:0] == 2'd3) tile_line3[tile_next_x[8:2]] <= tile_line_word;
    end
    wire [9:0] sprite_index_next2, sprite_index_next3, mixed_index_next2, mixed_index_next3;
    wire [1:0] sprite_priority_next2, sprite_priority_next3;
    wire sprite_opaque_next2, sprite_opaque_next3;
    // Display line ring (one packed four-pixel write and one packed four-pixel
    // read per clock), indexed by line[LINE_BITS-1:0].
    (* ramstyle = "M10K" *) reg [39:0] display_lines [0:(1 << (LINE_BITS + 7)) - 1];
    // Two palette banks (front/back), see the frame-latched tile state.
    (* ramstyle = "M10K" *) reg [7:0] palette_lo [0:2047];
    (* ramstyle = "M10K" *) reg [7:0] palette_hi [0:2047];
    integer i;
    initial begin
        for (i=0;i<2048;i=i+1) begin palette_lo[i]=0; palette_hi[i]=0; end
        for (i=0;i<(1 << (LINE_BITS + 7));i=i+1) display_lines[i]={4{10'h100}};
    end

    // Both renderers issue pulses with at most one outstanding read each.
    // One pending slot per client handles simultaneous requests. The board
    // memory accepts one read per clock; response ownership pipelines with it.
    // The frame-latched state refresh (below) is a third client. It reads
    // only on clocks when neither renderer is waiting, so renderer latency
    // and ordering are unchanged.
    localparam [1:0] OWNER_TILE=0, OWNER_SPRITE=1, OWNER_COPY=2;
    wire tile_state_req, sprite_state_req;
    wire [25:0] tile_state_addr, sprite_state_addr;
    reg tile_pending, sprite_pending, board_turn;
    reg [1:0] board_owner;
    reg [25:0] tile_pending_addr, sprite_pending_addr;
    wire tile_waiting = tile_pending || tile_state_req;
    wire sprite_waiting = sprite_pending || sprite_state_req;
    wire choose_sprite = sprite_waiting && (!tile_waiting || board_turn);
    wire state_copy_issue, frame_swap;
    wire [25:0] state_copy_addr;
    assign board_req = !reset && (tile_waiting || sprite_waiting || state_copy_issue);
    assign board_addr = choose_sprite
        ? (sprite_pending ? sprite_pending_addr : sprite_state_addr)
        : tile_waiting ? (tile_pending ? tile_pending_addr : tile_state_addr)
        : state_copy_addr;
    always @(posedge clk) begin
        if (reset) begin
            tile_pending <= 0; sprite_pending <= 0;
            tile_pending_addr <= 0; sprite_pending_addr <= 0;
            board_owner <= OWNER_TILE; board_turn <= 0;
        end else begin
            if (tile_state_req) begin tile_pending <= 1; tile_pending_addr <= tile_state_addr; end
            if (sprite_state_req) begin sprite_pending <= 1; sprite_pending_addr <= sprite_state_addr; end
            if (board_req) begin
                board_owner <= choose_sprite ? OWNER_SPRITE : tile_waiting ? OWNER_TILE : OWNER_COPY;
                if (choose_sprite || tile_waiting) board_turn <= !choose_sprite;
                if (choose_sprite) sprite_pending <= 0;
                else if (tile_waiting) tile_pending <= 0;
            end
        end
    end

    // Frame-latched sprite list. MAME0.289 simpl156.cpp draws a frame's
    // sprites from one sprite-RAM image, so a list the CPU changes and
    // restores inside the visible raster (the boot OBJ RAM test) never shows.
    // Two banks mirror the 1280 descriptor words the scanner addresses. CPU
    // commits land in the back bank; the banks swap with the tile state
    // (frame_swap) before line8 renders, so the front equals sprite RAM at
    // that instant. A copy then refreshes the
    // new back bank from the front, skipping bytes the CPU rewrote since the
    // swap (epoch tags). CPU reads and checkpoints keep using the bus RAM.
    localparam [1:0] COPY_READ=0, COPY_CAPTURE=1, COPY_WRITE=2, COPY_DONE=3;
    (* ramstyle = "M10K" *) reg [7:0] sprite_list_lo [0:4095];
    (* ramstyle = "M10K" *) reg [7:0] sprite_list_hi [0:4095];
    (* ramstyle = "M10K" *) reg sprite_list_tag_lo [0:2047], sprite_list_tag_hi [0:2047];
    reg [7:0] sprite_list_q_lo, sprite_list_q_hi;
    reg [1:0] list_tag_q, copy_hit, copy_step;
    reg list_front, list_epoch;
    reg [10:0] copy_index;
    reg [15:0] copy_word;
    initial begin
        for (i=0;i<4096;i=i+1) begin sprite_list_lo[i]=8'hff; sprite_list_hi[i]=8'hff; end
        for (i=0;i<2048;i=i+1) begin sprite_list_tag_lo[i]=0; sprite_list_tag_hi[i]=0; end
        list_front=0; list_epoch=0; copy_step=COPY_DONE; copy_index=0; copy_hit=0; copy_word=0;
    end
    wire [10:0] commit_index = commit_addr[12:2];
    wire sprite_commit = commit_valid && commit_we && mirror_commit_addr[25:13] == 13'h0c8
        && commit_index < 11'd1280;
    wire [1:0] commit_lanes = sprite_commit ? commit_be[1:0] : 2'b00;
    wire [1:0] copy_match = commit_index == copy_index ? commit_lanes : 2'b00;
    wire list_swap = frame_swap;
    wire render_list_read = board_req && choose_sprite;
    wire copy_issue = copy_step == COPY_READ && !render_list_read;
    wire [1:0] copy_written = {list_tag_q[1] == list_epoch, list_tag_q[0] == list_epoch} | copy_hit;
    wire copy_commit = copy_step == COPY_WRITE && !sprite_commit;
    wire [10:0] list_read_index = render_list_read ? board_addr[12:2] : copy_index;
    wire [11:0] list_read_addr = {list_front, list_read_index};
    wire [11:0] list_write_addr = {!list_front, sprite_commit ? commit_index : copy_index};
    wire [1:0] list_write = sprite_commit ? commit_lanes : copy_commit ? ~copy_written : 2'b00;
    wire [15:0] list_write_data = sprite_commit ? commit_data[15:0] : copy_word;
    wire [31:0] sprite_board_data = {16'hffff, sprite_list_q_hi, sprite_list_q_lo};
    always @(posedge clk) begin
        sprite_list_q_lo <= sprite_list_lo[list_read_addr];
        sprite_list_q_hi <= sprite_list_hi[list_read_addr];
        if (list_write[0]) sprite_list_lo[list_write_addr] <= list_write_data[7:0];
        if (list_write[1]) sprite_list_hi[list_write_addr] <= list_write_data[15:8];
        list_tag_q <= {sprite_list_tag_hi[copy_index], sprite_list_tag_lo[copy_index]};
        // Tags record the epoch of each lane's last back-bank write.
        if (commit_lanes[0] || copy_commit) sprite_list_tag_lo[list_write_addr[10:0]] <= list_epoch;
        if (commit_lanes[1] || copy_commit) sprite_list_tag_hi[list_write_addr[10:0]] <= list_epoch;
    end
    // Unreset: the mirror tracks every bus write, including video-disabled time.
    always @(posedge clk) begin
        if (list_swap) begin
            list_front <= !list_front; list_epoch <= !list_epoch;
            copy_index <= 0; copy_step <= COPY_READ;
        end else case (copy_step)
            COPY_READ: if (copy_issue) begin copy_hit <= copy_match; copy_step <= COPY_CAPTURE; end
            COPY_CAPTURE: begin
                copy_word <= {sprite_list_q_hi, sprite_list_q_lo};
                copy_hit <= copy_hit | copy_match; copy_step <= COPY_WRITE;
            end
            COPY_WRITE: if (copy_commit) begin
                copy_index <= copy_index + 1'b1;
                copy_step <= copy_index == 11'd1279 ? COPY_DONE : COPY_READ;
            end else copy_hit <= copy_hit | copy_match;
            default: ;
        endcase
    end
    // Frame-latched tile state. MAME0.289 simpl156.cpp composes each frame's
    // playfields and palette from one RAM image, taken when the frame is
    // drawn, so RAM the CPU fills with test patterns and restores while the
    // frame is scanned never shows. The boot RAM TEST does that to FIX RAM,
    // BACK RAM, both rowscroll RAMs and the palette. Read live, they drew
    // pattern tiles and purple/white palette bars over the RAM TEST text.
    // MAME 0.289 write tap (work/ramtest, .mame_mcp/line_tap.lua): OBJ
    // L151-192, FIX L192-232, rowscroll1 L232-252, BACK L252-36, rowscroll2
    // L36-56, palette L56-77; the BACK test straddles the start of the picture.
    //
    // Two banks per RAM. Every accepted CPU commit lands in the back bank, and
    // a refresh copies every mirrored word from the bus RAM into the back
    // bank after each swap (via the board port, yielding to both renderers;
    // a copy write skips any lane the CPU rewrote while that word was in
    // flight). The tile renderer and the output palette read only the front
    // bank. At line_start y=7, before line8 renders, the banks and the sprite
    // list swap together if both refreshes are done and no latched-region
    // commit landed in the last QUIET_CLOCKS (8 lines): a write burst still running at
    // the start of the picture (a RAM test, a scene load) holds the previous
    // frame's image instead of showing a half-written one, for at most
    // MAX_HOLDS consecutive frames. Ordinary game frames finish their writes
    // early in vblank (MAME: <= 1.25 ms after vblank start in 6000 attract
    // frames per game; the latch is at 2.08 ms), so they swap every frame,
    // exactly as the live renderer showed them. The control words (0x1c0000)
    // stay live. CPU reads and checkpoints keep using the bus RAM.
    // Eight lines: longer than the pauses inside the boot's screen-clear and
    // text bursts (<= 6.5 lines), shorter than the >= 13 lines between ordinary
    // game frames' last write and the latch.
    localparam integer QUIET_CLOCKS = 24576;
    localparam [1:0] MAX_HOLDS = 2'd2;
    localparam [12:0] STATE_WORDS = 13'd7168; // pf1 2048, pf2 2048, rows1 1024, rows2 1024, palette 1024
    localparam [2:0] REGION_PF1=0, REGION_PF2=1, REGION_ROWS1=2, REGION_ROWS2=3, REGION_PALETTE=4, REGION_NONE=7;
    (* ramstyle = "M10K" *) reg [7:0] pf1_mirror_lo [0:4095], pf1_mirror_hi [0:4095];
    (* ramstyle = "M10K" *) reg [7:0] pf2_mirror_lo [0:4095], pf2_mirror_hi [0:4095];
    (* ramstyle = "M10K" *) reg [7:0] rows1_mirror_lo [0:2047], rows1_mirror_hi [0:2047];
    (* ramstyle = "M10K" *) reg [7:0] rows2_mirror_lo [0:2047], rows2_mirror_hi [0:2047];
    reg [7:0] pf1_mirror_q_lo, pf1_mirror_q_hi, pf2_mirror_q_lo, pf2_mirror_q_hi;
    reg [7:0] rows1_mirror_q_lo, rows1_mirror_q_hi, rows2_mirror_q_lo, rows2_mirror_q_hi;
    reg [2:0] tile_read_region;
    reg state_front;
    reg [14:0] quiet_count;
    reg [1:0] frame_holds;
    reg [1:0] state_copy_step, state_copy_hit;
    reg [12:0] state_copy_index;
    reg [15:0] state_copy_word;
    initial begin
        for (i=0;i<4096;i=i+1) begin
            pf1_mirror_lo[i]=0; pf1_mirror_hi[i]=0; pf2_mirror_lo[i]=0; pf2_mirror_hi[i]=0;
        end
        for (i=0;i<2048;i=i+1) begin
            rows1_mirror_lo[i]=0; rows1_mirror_hi[i]=0; rows2_mirror_lo[i]=0; rows2_mirror_hi[i]=0;
        end
        tile_read_region=REGION_NONE; state_front=0; quiet_count=0; frame_holds=0;
        // Power-up: fill the back bank from the bus RAM before the first swap.
        state_copy_step=COPY_READ; state_copy_hit=0; state_copy_index=0; state_copy_word=0;
    end
    // Standard-map decode; Charlie Ninja commits arrive through mirror_commit_addr.
    // The rowscroll mirrors hold the 1024 words the renderer can address.
    function automatic logic [2:0] state_region(input logic [25:12] address);
        if (address[25:14] == 12'h074) state_region = REGION_PF1;
        else if (address[25:13] == 13'h0ea) state_region = REGION_PF2;
        else if (address[25:13] == 13'h0f0 && !address[12]) state_region = REGION_ROWS1;
        else if (address[25:13] == 13'h0f2 && !address[12]) state_region = REGION_ROWS2;
        else if (address[25:12] == 14'h1a0) state_region = REGION_PALETTE;
        else state_region = REGION_NONE;
    endfunction
    wire [2:0] commit_region = commit_valid && commit_we ? state_region(mirror_commit_addr[25:12]) : REGION_NONE;
    wire state_commit = commit_region != REGION_NONE;
    wire [10:0] state_commit_index = commit_addr[12:2];
    // Copy order: pf1, pf2, rows1, rows2, palette; index[12:10] select the region.
    wire [2:0] state_copy_region = !state_copy_index[12] ? (state_copy_index[11] ? REGION_PF2 : REGION_PF1)
        : state_copy_index[11] ? REGION_PALETTE : state_copy_index[10] ? REGION_ROWS2 : REGION_ROWS1;
    wire [10:0] state_copy_local = state_copy_index[12] ? {1'b0, state_copy_index[9:0]} : state_copy_index[10:0];
    wire [25:0] state_copy_base =
        state_copy_region == REGION_PF1 ? 26'h1d0000 :
        state_copy_region == REGION_PF2 ? 26'h1d4000 :
        state_copy_region == REGION_ROWS1 ? 26'h1e0000 :
        state_copy_region == REGION_ROWS2 ? 26'h1e4000 : 26'h1a0000;
    assign state_copy_addr = state_copy_base + {13'd0, state_copy_local, 2'b00};
    assign state_copy_issue = !reset && state_copy_step == COPY_READ && !tile_waiting && !sprite_waiting;
    wire state_copy_capture = board_valid && board_owner == OWNER_COPY;
    // CPU commits own the back-bank write port on their clock; the copy waits.
    wire state_copy_commit = state_copy_step == COPY_WRITE && !state_commit;
    wire [1:0] state_copy_match = state_commit && commit_region == state_copy_region
        && state_commit_index == state_copy_local ? commit_be[1:0] : 2'b00;
    wire [2:0] state_write_region = state_commit ? commit_region : state_copy_commit ? state_copy_region : REGION_NONE;
    wire [11:0] state_write_index = {!state_front, state_commit ? state_commit_index : state_copy_local};
    wire [10:0] state_write_short = {!state_front, state_write_index[9:0]};
    wire [1:0] state_write_lanes = state_commit ? commit_be[1:0] : state_copy_commit ? ~state_copy_hit : 2'b00;
    wire [15:0] state_write_data = state_commit ? commit_data[15:0] : state_copy_word;
    wire pf1_mirror_write = state_write_region == REGION_PF1;
    wire pf2_mirror_write = state_write_region == REGION_PF2;
    wire rows1_mirror_write = state_write_region == REGION_ROWS1;
    wire rows2_mirror_write = state_write_region == REGION_ROWS2;
    wire palette_mirror_write = state_write_region == REGION_PALETTE;
    // Swap: refreshes done, and no burst running into the picture start.
    wire latched_commit = state_commit || sprite_commit;
    wire quiet = quiet_count == 15'(QUIET_CLOCKS);
    wire frame_point = line_start && y == 8'd7;
    assign frame_swap = frame_point && copy_step == COPY_DONE && state_copy_step == COPY_DONE
        && (quiet || frame_holds == MAX_HOLDS);
    // The tile renderer's board read is answered from the front bank holding
    // its address, one clock later, exactly as the bus RAM answered it.
    wire tile_board_issue = board_req && !choose_sprite && tile_waiting;
    wire [11:0] tile_board_index = {state_front, board_addr[12:2]};
    wire [10:0] tile_board_short = {state_front, board_addr[11:2]};
    always @(posedge clk) begin
        tile_read_region <= tile_board_issue ? state_region(board_addr[25:12]) : REGION_NONE;
        pf1_mirror_q_lo <= pf1_mirror_lo[tile_board_index];
        pf1_mirror_q_hi <= pf1_mirror_hi[tile_board_index];
        pf2_mirror_q_lo <= pf2_mirror_lo[tile_board_index];
        pf2_mirror_q_hi <= pf2_mirror_hi[tile_board_index];
        rows1_mirror_q_lo <= rows1_mirror_lo[tile_board_short];
        rows1_mirror_q_hi <= rows1_mirror_hi[tile_board_short];
        rows2_mirror_q_lo <= rows2_mirror_lo[tile_board_short];
        rows2_mirror_q_hi <= rows2_mirror_hi[tile_board_short];
        if (pf1_mirror_write && state_write_lanes[0]) pf1_mirror_lo[state_write_index] <= state_write_data[7:0];
        if (pf1_mirror_write && state_write_lanes[1]) pf1_mirror_hi[state_write_index] <= state_write_data[15:8];
        if (pf2_mirror_write && state_write_lanes[0]) pf2_mirror_lo[state_write_index] <= state_write_data[7:0];
        if (pf2_mirror_write && state_write_lanes[1]) pf2_mirror_hi[state_write_index] <= state_write_data[15:8];
        if (rows1_mirror_write && state_write_lanes[0]) rows1_mirror_lo[state_write_short] <= state_write_data[7:0];
        if (rows1_mirror_write && state_write_lanes[1]) rows1_mirror_hi[state_write_short] <= state_write_data[15:8];
        if (rows2_mirror_write && state_write_lanes[0]) rows2_mirror_lo[state_write_short] <= state_write_data[7:0];
        if (rows2_mirror_write && state_write_lanes[1]) rows2_mirror_hi[state_write_short] <= state_write_data[15:8];
    end
    wire [31:0] tile_board_data =
        tile_read_region == REGION_PF1 ? {16'hffff, pf1_mirror_q_hi, pf1_mirror_q_lo} :
        tile_read_region == REGION_PF2 ? {16'hffff, pf2_mirror_q_hi, pf2_mirror_q_lo} :
        tile_read_region == REGION_ROWS1 ? {16'hffff, rows1_mirror_q_hi, rows1_mirror_q_lo} :
        tile_read_region == REGION_ROWS2 ? {16'hffff, rows2_mirror_q_hi, rows2_mirror_q_lo} : board_data;
    // Unreset banks: they track every bus write, including video-disabled time.
    // A reset can drop an in-flight refresh read, so it restarts the refresh.
    always @(posedge clk) begin
        if (latched_commit) quiet_count <= 0;
        else if (!quiet) quiet_count <= quiet_count + 1'b1;
        if (frame_point) frame_holds <= frame_swap ? 2'd0 : frame_holds == MAX_HOLDS ? MAX_HOLDS : frame_holds + 1'b1;
        if (frame_swap) state_front <= !state_front;
        if (reset || frame_swap) begin
            state_copy_index <= 0; state_copy_hit <= 0; state_copy_step <= COPY_READ;
        end else case (state_copy_step)
            COPY_READ: if (state_copy_issue) begin state_copy_hit <= state_copy_match; state_copy_step <= COPY_CAPTURE; end
            COPY_CAPTURE: begin
                state_copy_hit <= state_copy_hit | state_copy_match;
                if (state_copy_capture) begin state_copy_word <= board_data[15:0]; state_copy_step <= COPY_WRITE; end
            end
            COPY_WRITE: if (state_copy_commit) begin
                state_copy_index <= state_copy_index + 1'b1;
                state_copy_step <= state_copy_index == STATE_WORDS - 1'b1 ? COPY_DONE : COPY_READ;
            end else state_copy_hit <= state_copy_hit | state_copy_match;
            default: ;
        endcase
    end
    osman_tiles u_tiles (
        .clk(clk), .reset(reset), .profile(profile), .cfg_load(cfg_start), .abort(line_abort), .cfg_done(cfg_done),
        .pixel_req(tile_pixel_req), .pixel_x(global_flip ? 9'd319-requested_x : requested_x),
        .pixel_y(global_flip ? 9'd255-{1'b0,render_y} : {1'b0,render_y}),
        .pixel_ready(tile_pixel_ready), .pixel_valid(tile_pixel_valid),
        .pf1_index(pf1_index), .pf2_index(pf2_index), .pf1_opaque(pf1_opaque), .pf2_opaque(pf2_opaque),
        .flip_screen(tile_flip), .state_req(tile_state_req), .state_addr(tile_state_addr),
        .state_valid(board_valid && board_owner == OWNER_TILE), .state_data(tile_board_data),
        .tile_req(tile_req), .tile_byte_addr(tile_byte_addr), .tile_valid(tile_valid), .tile_data(tile_data)
    );
    osman_sprites u_sprites (
        .clk(clk), .reset(reset), .profile(profile), .line_start(sprite_start), .abort(line_abort), .line_y({1'b0,render_y}),
        .frame_parity(frame_parity), .global_flip(global_flip ^ tile_flip), .busy(sprite_busy), .line_done(sprite_done),
        .read_x(sprite_read_x), .sprite_index(sprite_index), .sprite_priority(sprite_priority),
        .sprite_opaque(sprite_opaque), .sprite_index_next(sprite_index_next),
        .sprite_priority_next(sprite_priority_next), .sprite_opaque_next(sprite_opaque_next),
        .sprite_index_next2(sprite_index_next2), .sprite_priority_next2(sprite_priority_next2),
        .sprite_opaque_next2(sprite_opaque_next2), .sprite_index_next3(sprite_index_next3),
        .sprite_priority_next3(sprite_priority_next3), .sprite_opaque_next3(sprite_opaque_next3),
        .state_req(sprite_state_req), .state_addr(sprite_state_addr),
        .state_valid(board_valid && board_owner == OWNER_SPRITE), .state_data(sprite_board_data),
        .sprite_req(sprite_req), .sprite_byte_addr(sprite_byte_addr), .sprite_valid(sprite_valid), .sprite_data(sprite_data)
    );
    osman_mixer u_mixer (
        .pf1_index(tile_q0[18:10]), .pf2_index(tile_q0[8:0]),
        .pf1_opaque(tile_q0[19]), .pf2_opaque(tile_q0[9]),
        .sprite_index(sprite_index), .sprite_priority(sprite_priority), .sprite_opaque(sprite_opaque),
        .palette_index(mixed_index)
    );
    osman_mixer u_mixer_next (
        .pf1_index(tile_q1[18:10]), .pf2_index(tile_q1[8:0]),
        .pf1_opaque(tile_q1[19]), .pf2_opaque(tile_q1[9]),
        .sprite_index(sprite_index_next), .sprite_priority(sprite_priority_next),
        .sprite_opaque(sprite_opaque_next), .palette_index(mixed_index_next)
    );
    osman_mixer u_mixer_next2 (
        .pf1_index(tile_q2[18:10]), .pf2_index(tile_q2[8:0]),
        .pf1_opaque(tile_q2[19]), .pf2_opaque(tile_q2[9]),
        .sprite_index(sprite_index_next2), .sprite_priority(sprite_priority_next2),
        .sprite_opaque(sprite_opaque_next2), .palette_index(mixed_index_next2)
    );
    osman_mixer u_mixer_next3 (
        .pf1_index(tile_q3[18:10]), .pf2_index(tile_q3[8:0]),
        .pf1_opaque(tile_q3[19]), .pf2_opaque(tile_q3[9]),
        .sprite_index(sprite_index_next3), .sprite_priority(sprite_priority_next3),
        .sprite_opaque(sprite_opaque_next3), .palette_index(mixed_index_next3)
    );
    // Scheduling. next_y is the next line to build (0 = nothing pending).
    // A build may start once its buffer is free: the line it last held
    // (next_y-2**LINE_BITS) has been scanned, i.e. next_y <= y + LOOKAHEAD. The first
    // build of a frame waits for raster line 7, after the sprite list swap
    // and the CPU's vblank work. A build whose line is the next to be
    // scanned becomes urgent at URGENT_X and is aborted at ABORT_X.
    wire [8:0] y_lead = {1'b0, y} + 9'(LOOKAHEAD);
    wire build_pending = next_y != 0;
    wire build_allowed = build_pending && !pause && y >= 8'd7 && {1'b0, next_y} <= y_lead && next_y > y;
    wire build_start = phase == IDLE && build_allowed && tile_pixel_ready && !sprite_busy && !cfg_start;
    wire line_due_next = {1'b0, y} + 9'd1 >= {1'b0, render_y};
    wire line_overdue = {1'b0, y} >= {1'b0, render_y};
    wire abort_now = phase == BUILD && ((line_due_next && x >= 9'(ABORT_X)) || line_overdue);
    wire tile_side_done = tile_finished || (line_abort && tile_pixel_ready && !tile_pixel_req);
    always @(posedge clk) begin
        cfg_start <= 0; sprite_start <= 0; render_done <= 0;
        if (reset) begin
            phase <= IDLE; render_y <= 0; next_y <= 0; compose_x <= 0; tile_next_x <= 0;
            cfg_ready <= 0; tile_finished <= 0; sprite_finished <= 0; tile_inflight <= 0; line_abort <= 0;
            rendered_lines <= 0; missed_lines <= 0; max_line_cycles <= 0; aborted_lines <= 0; line_cycles <= 0;
        end else begin
            if (phase != IDLE) line_cycles <= line_cycles + 1'b1;
            if (line_start && y == 8'd7) next_y <= 8'd8;
            else if (line_start && y >= 8'd8 && y <= 8'd247 && build_pending && next_y <= y &&
                     !(phase != IDLE && render_y == y)) begin
                // The line being scanned was never built: skip it (its
                // buffer shows the previous content) and count the miss.
                missed_lines <= missed_lines + 1'b1;
                next_y <= y == 8'd247 ? 8'd0 : y + 1'b1;
            end
            if (build_start) begin
                render_y <= next_y;
                next_y <= next_y == 8'd247 ? 8'd0 : next_y + 1'b1;
                cfg_start <= 1;
                cfg_ready <= 0; tile_finished <= 0; sprite_finished <= 0; tile_inflight <= 0; line_abort <= 0;
                tile_next_x <= 0; compose_x <= 0; line_cycles <= 0; phase <= BUILD;
            end
            if (phase == BUILD) begin
                if (cfg_done) begin cfg_ready <= 1; sprite_start <= 1; end
                if (sprite_done) sprite_finished <= 1;
                if (tile_pixel_valid) begin
                    tile_inflight <= 0;
                    if (tile_next_x == 319) tile_finished <= 1;
                    else tile_next_x <= tile_next_x + 1'b1;
                end
                if (tile_pixel_req) tile_inflight <= 1;
                if (abort_now && !line_abort && cfg_ready) begin
                    line_abort <= 1; aborted_lines <= aborted_lines + 1'b1;
                end
                if (tile_side_done && sprite_finished) begin compose_x <= 0; phase <= COMPOSE; end
            end else if (phase == COMPOSE) begin
                display_lines[{render_y[LINE_BITS-1:0],compose_x[8:2]}] <=
                    {mixed_index_next3,mixed_index_next2,mixed_index_next,mixed_index};
                if (compose_x == 316) begin
                    render_done <= 1; rendered_lines <= rendered_lines + 1'b1;
                    if (line_cycles + 1 > max_line_cycles) max_line_cycles <= line_cycles + 1'b1;
                    phase <= IDLE;
                end else compose_x <= compose_x + 9'd4;
            end
        end
    end
    // Line deadline guard. The PCB's tile/sprite chips own their ROM buses;
    // here they share one SDRAM port with CPU ROM fetches, and a stream of
    // CPU cache misses (e.g. straight-line vblank code) can slow a heavy line.
    // Once the line being built is the next to be scanned and the raster has
    // passed URGENT_X, the build is served at near-exclusive speed.
    always @(posedge clk)
        render_urgent <= !reset && phase == BUILD && line_due_next && x >= 9'(URGENT_X);
    // Line completion tracking and the scan slot. A buffer is ready once its
    // line has been composed (a line aborted for time is composed from what was
    // fetched and counts as ready). If the line the raster is about to scan is
    // not ready, the scan repeats the previous good line instead of showing what
    // an earlier use of that buffer held, so an overrun can only ever duplicate
    // a line, never show a stale one.
    reg [(1 << LINE_BITS) - 1:0] line_ready;
    reg [LINE_BITS-1:0] scan_slot;
    reg scan_late;   // this raster line repeats the previous one (simulation observable)
    always @(posedge clk) begin
        if (reset) begin
            line_ready <= 0; scan_slot <= 0; scan_late <= 0; late_lines <= 0;
        end else begin
            if (build_start) line_ready[next_y[LINE_BITS-1:0]] <= 1'b0;
            if (phase == COMPOSE && compose_x == 316) line_ready[render_y[LINE_BITS-1:0]] <= 1'b1;
            if (line_start) begin
                if (!(y >= 8'd8 && y <= 8'd247) || line_ready[y[LINE_BITS-1:0]]) begin
                    scan_slot <= y[LINE_BITS-1:0]; scan_late <= 0;
                end else begin
                    scan_late <= 1; late_lines <= late_lines + 1'b1;
                end
            end
        end
    end
    // Index then palette are clocked separately. All presentation signals
    // carry the same delay; the MiSTer wrapper uses video_ce, not raw ce_pixel.
    reg index_valid, index_de, index_hs, index_vs;
    reg [8:0] index_x;
    reg [7:0] index_y;
    reg [9:0] pixel_index;
    reg [7:0] pixel_colour_lo, pixel_colour_hi;
    wire [15:0] pixel_colour = {pixel_colour_hi,pixel_colour_lo};
    // Keep the palette read directly clocked so Quartus can infer a byte-enabled
    // block RAM. Expand its registered word after the edge rather than placing
    // RGB conversion logic between the RAM read and its output register.
    // Writes land in the back bank (frame-latched state above); the output
    // reads the front bank. The banks swap at line_start y=7, long after the
    // last line247 pixel and before the first line8 pixel.
    // Independent full-byte RAMs avoid partial-word write inference differences
    // between Quartus versions while retaining the native byte-enable lanes.
    always @(posedge clk) begin
        if (palette_mirror_write && state_write_lanes[0]) palette_lo[state_write_short] <= state_write_data[7:0];
        if (!reset && index_valid) pixel_colour_lo <= palette_lo[{state_front, pixel_index}];
    end
    always @(posedge clk) begin
        if (palette_mirror_write && state_write_lanes[1]) palette_hi[state_write_short] <= state_write_data[15:8];
        if (!reset && index_valid) pixel_colour_hi <= palette_hi[{state_front, pixel_index}];
    end
    assign red = video_de ? {pixel_colour[4:0],pixel_colour[4:2]} : 8'd0;
    assign green = video_de ? {pixel_colour[9:5],pixel_colour[9:7]} : 8'd0;
    assign blue = video_de ? {pixel_colour[14:10],pixel_colour[14:12]} : 8'd0;
    // Clocked read so the buffer stays in block RAM. x/y change only on
    // ce_pixel and the read is consumed on the next one, >=5 clocks later,
    // so the registered word equals the old async read.
    reg [39:0] display_group;
    always @(posedge clk) display_group <= display_lines[{scan_slot,x[8:2]}];
    wire [9:0] display_index = x[1:0]==3 ? display_group[39:30] :
                               x[1:0]==2 ? display_group[29:20] :
                               x[1:0]==1 ? display_group[19:10] : display_group[9:0];
    always @(posedge clk) begin
        if (reset) begin
            index_valid <= 0; index_de <= 0; index_hs <= 1; index_vs <= 1;
            index_x <= 0; index_y <= 0; pixel_index <= 10'h100;
            video_ce <= 0; video_de <= 0; video_hs <= 1; video_vs <= 1;
            video_x <= 0; video_y <= 0;
        end else begin
            index_valid <= ce_pixel;
            if (ce_pixel) begin
                index_x <= x; index_y <= y; index_hs <= hs; index_vs <= vs;
                index_de <= display_enable;
                pixel_index <= display_enable ? display_index : 10'h100;
            end
            video_ce <= index_valid;
            if (index_valid) begin
                video_de <= index_de; video_hs <= index_hs; video_vs <= index_vs;
                video_x <= index_x; video_y <= index_y;
            end
        end
    end
endmodule
