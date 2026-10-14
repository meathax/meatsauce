// SPDX-License-Identifier: GPL-3.0-or-later
// Ordered texture-RAM write queue between the shared bus arbiter and the memory fabric.
// Concept (and the display-list front ordering) from BrezzaSoft_Crystal_System_MiSTer crystal_texq.sv
// (Kyle Lester, GPL-3.0-or-later); reimplemented for this core's request path.
//
// Why: MAME renders every display-list packet almost immediately, long before the CPU goes on to rewrite
// the texture RAM for the next frame. The Crystal of Kings rewrites animation textures in place right after
// submitting a list. This renderer draws pixel by pixel and may still be drawing that list, so without ordering
// it mixes the next pose into the current frame (sprite jitter, flashing lines). Measured on the board
// simulation (attract, 4.5 G clocks): 189,567 renderer texture-line reads of lines the CPU wrote after the
// reading packet had been submitted.
//
// How: CPU/DMA word writes to texture RAM (SDRAM target 2) and the CPU's display-list queue-front updates go
// through ONE in-order queue. A texture write is applied to SDRAM only when the renderer has caught up with the
// front it can see (drain_ok), so everything submitted before the write is drawn with the old data; a
// queue-front update reaches the renderer only when it is at the head, so packets queued after a write are
// drawn once the write is in SDRAM. The CPU never waits for a write (it is acknowledged when queued; it only
// stalls when the queue is full). A read of a 64-byte block with a write still queued is answered from the
// forwarding shadow (below) when that holds the newest bytes it asks for, and otherwise waits until that write has
// drained (read-after-write); all other requests pass through untouched, one clock apart. The sound engine
// (b_realtime) is never held: its sample deadline (one 44.19 kHz period) is shorter than a queue backlog, and
// samples are uploaded long before they are played.
//
// Forwarding shadow (FORWARD=1, as the reference crystal_texq): 1024 words, direct mapped on the texture word
// offset. Every queued texture write merges its lanes into the entry of its word (replacing an entry that held
// another word), so an entry whose tag matches holds the newest value of the lanes in its mask; all CPU/DMA
// texture writes pass through here, so it stays correct after the writes drain. Top Blade V and Office Yeoin
// Cheonha re-read texture words they have just written; without forwarding each such read holds the shared bus
// (CPU and DMA) until the renderer has drawn every earlier packet, i.e. up to a whole frame of rendering.
module cs_texq #(
    parameter int AW = 12, // 2**AW entries (Evolution Soccer peaks above 2,000)
    parameter bit FORWARD = 1
) (
    input logic clk, reset,
    // arbiter side
    input logic b_valid,
    output logic b_ready,
    input logic [3:0] b_target,
    input logic [31:0] b_offset, b_data,
    input logic [3:0] b_strobe,
    input logic b_write,
    input logic b_realtime, // the requester has a hard deadline (sound): never held behind queued writes
    input logic rt_waiting, // a real-time client is requesting at the arbiter: drain writes keep off the fabric
    output logic b_rsp_valid,
    output logic [31:0] b_rsp_data,
    output logic b_rsp_error,
    // fabric side
    output logic f_valid,
    input logic f_ready,
    output logic [3:0] f_target,
    output logic [31:0] f_offset, f_data,
    output logic [3:0] f_strobe,
    output logic f_write,
    output logic f_drain, // the request on the fabric side is a queue drain write (not a board request)
    input logic f_rsp_valid,
    input logic [31:0] f_rsp_data,
    input logic f_rsp_error,
    // GPU display-list queue front
    input logic front_wr,
    input logic [15:0] front_wr_val,
    output logic front_set,
    output logic [15:0] front_set_val,
    input logic drain_ok,
    output logic empty
);
    localparam int DEPTH = 1 << AW;
    localparam int PW = AW + 1;
    localparam int EW = 1 + 4 + 21 + 32; // {front, strobe, word offset, data}
    logic [EW-1:0] mem [0:DEPTH-1];
    logic [PW-1:0] wr_ptr, rd_ptr;
    wire [PW-1:0] occupancy = wr_ptr - rd_ptr;
    logic [1:0] settle; // clocks until the RAM output shows the head after a pop/push-to-empty
    logic [EW-1:0] head;
    logic ack_q, drain_inflight, pt_inflight;
    logic [3:0] starve;
    logic drain_issue;
    // push is registered before the RAM write: the CPU request -> arbiter -> push -> RAM write-enable path is too long
    logic push_q, push_write_q;
    logic [EW-1:0] push_data_q;
    logic [AW-1:0] push_idx_q;
    logic [6:0] push_bucket_q;
    logic [PW-1:0] push_seq_q;
    logic [4:0] rt_hold; // drain writes also stay out for a while after a real-time request (gaps between sound reads)

    wire is_tex = b_target == 4'd2;
    wire tex_wr = b_valid && b_write && is_tex;
    wire tex_rd = b_valid && !b_write && is_tex;
    assign empty = occupancy == 0;

    // ---- read-after-write check: per 64-byte bucket (128), the queue position of its last pushed write
    logic [PW-1:0] bucket_seq [0:127];
    logic [PW-1:0] bucket_q;
    logic [6:0] bucket_addr_q;
    // valid bits: set by a queued write, all cleared whenever the queue is empty (so a bucket never written
    // since the queue last drained cannot look pending through a stale or power-up sequence number)
    logic [127:0] bucket_valid;
    logic bucket_valid_q;
    logic seen_q, seen1_q, seen2_q, free_q; // lookup pipeline: address register -> RAM -> pending compare -> free_q
    wire [PW-1:0] distance = bucket_q - rd_ptr;
    wire pending = bucket_valid_q && distance < occupancy;
    wire rd_ok = !tex_rd || b_realtime || (seen_q && free_q && !push_q);

    // ---- forwarding shadow: {tag = word offset[20:10], lane mask, data}. Read address follows the arbiter-side
    // offset every clock; a held read's hit is registered three clocks after it appears (same as free_q).
    localparam int SW = 11 + 4 + 32;
    logic [SW-1:0] shadow [0:1023];
    logic [9:0] sh_ra, sh_wa, clr_a;
    logic [SW-1:0] sh_q, sh_wd;
    logic sh_we, clr_busy;
    logic [20:0] rd_word1_q, rd_word2_q;
    logic [3:0] rd_strobe1_q, rd_strobe2_q;
    logic pw2_q;
    logic [20:0] pw2_word;
    logic [3:0] pw2_strobe;
    logic [31:0] pw2_data;
    logic fhit_q, fwd_ack_q;
    logic [31:0] fdata_q, fwd_data_q;
    wire sh_hit = sh_q[SW-1:36] == rd_word2_q[20:10] && (sh_q[35:32] & rd_strobe2_q) == rd_strobe2_q && rd_strobe2_q != 0;
    wire fwd_go = FORWARD && tex_rd && !b_realtime && seen_q && !free_q && fhit_q && !push_q && !pt_inflight
                  && !ack_q && !fwd_ack_q && !clr_busy && !reset;

    // ---- push
    wire push_front = front_wr;
    wire push_write = tex_wr && b_ready;
    wire push = push_front || push_write;
    wire [EW-1:0] push_data = push_front ? {1'b1, 4'd0, 21'd0, 16'd0, front_wr_val}
                                         : {1'b0, b_strobe, b_offset[22:2], b_data};
    assign b_ready = is_tex && b_write
        ? (!reset && !front_wr && !ack_q && occupancy < PW'(DEPTH - 16))
        : (fwd_go || (f_ready && !drain_inflight && !drain_issue && rd_ok && !reset));

    // ---- drain decision
    wire head_ok = settle == 0 && occupancy != 0;
    wire head_front = head[EW-1];
    wire want_drain = head_ok && !head_front && drain_ok;
    wire board_wants_fabric = b_valid && !(b_write && is_tex) && rd_ok;
    assign drain_issue = want_drain && f_ready && !drain_inflight && !pt_inflight
                         && (!board_wants_fabric || starve[3]) && rt_hold == 0 && !rt_waiting && !reset;
    wire pop_front = head_ok && head_front && !reset;
    wire pop_write = drain_inflight && f_rsp_valid;
    wire pop = pop_front || pop_write;

    always_comb begin
        f_drain = drain_issue;
        if (drain_issue) begin
            f_valid = 1; f_write = 1; f_target = 4'd2;
            f_offset = {9'b0, head[52:32], 2'b00}; // word offset -> byte offset
            f_data = head[31:0]; f_strobe = head[56:53];
        end else begin
            f_valid = b_valid && !(b_write && is_tex) && rd_ok && !drain_inflight;
            f_write = b_write; f_target = b_target; f_offset = b_offset; f_data = b_data; f_strobe = b_strobe;
        end
        b_rsp_valid = ack_q || fwd_ack_q || (pt_inflight && f_rsp_valid);
        b_rsp_data = fwd_ack_q ? fwd_data_q : ack_q ? 32'b0 : f_rsp_data;
        b_rsp_error = (ack_q || fwd_ack_q) ? 1'b0 : f_rsp_error;
    end

    always_ff @(posedge clk) begin
        front_set <= 0;
        head <= mem[rd_ptr[AW-1:0]];
        bucket_addr_q <= b_offset[12:6];
        bucket_q <= bucket_seq[bucket_addr_q];
        bucket_valid_q <= bucket_valid[bucket_addr_q];
        if (occupancy == 0) bucket_valid <= 128'b0;
        push_q <= push && !reset;
        push_write_q <= push_write && !reset;
        push_data_q <= push_data;
        push_idx_q <= wr_ptr[AW-1:0];
        push_bucket_q <= b_offset[12:6];
        push_seq_q <= wr_ptr;
        if (push_q) mem[push_idx_q] <= push_data_q;
        if (push_write_q) begin bucket_seq[push_bucket_q] <= push_seq_q; bucket_valid[push_bucket_q] <= 1'b1; end
        // shadow: one read port (address from the arbiter side), one write port (merge of a push, else the
        // post-reset sweep). A push at clock t reads its word's old entry at t+1 and writes the merge at t+2.
        sh_ra <= b_offset[11:2];
        sh_q <= shadow[sh_ra];
        if (sh_we) shadow[sh_wa] <= sh_wd;
        rd_word1_q <= b_offset[22:2]; rd_strobe1_q <= b_strobe;
        rd_word2_q <= rd_word1_q; rd_strobe2_q <= rd_strobe1_q;
        fhit_q <= sh_hit;
        fdata_q <= sh_q[31:0];
        fwd_data_q <= fdata_q;
        pw2_q <= push_write_q && !reset;
        pw2_word <= push_data_q[52:32]; pw2_strobe <= push_data_q[56:53]; pw2_data <= push_data_q[31:0];
        sh_we <= 0;
        if (pw2_q) begin
            sh_we <= 1; sh_wa <= pw2_word[9:0];
            if (sh_q[SW-1:36] == pw2_word[20:10] && !clr_busy) begin
                for (int lane = 0; lane < 4; lane++) sh_wd[8*lane +: 8] <= pw2_strobe[lane] ? pw2_data[8*lane +: 8] : sh_q[8*lane +: 8];
                sh_wd[SW-1:32] <= {pw2_word[20:10], sh_q[35:32] | pw2_strobe};
            end else sh_wd <= {pw2_word[20:10], pw2_strobe, pw2_data};
        end else if (clr_busy) begin
            sh_we <= 1; sh_wa <= clr_a; sh_wd <= '0;
            clr_a <= clr_a + 1'b1;
            if (clr_a == 10'h3ff) clr_busy <= 0;
        end
        if (reset) begin
            bucket_valid <= 128'b0; wr_ptr <= 0; rd_ptr <= 0; settle <= 2'd2; ack_q <= 0; drain_inflight <= 0; pt_inflight <= 0;
            starve <= 0; rt_hold <= 0; seen_q <= 0; seen2_q <= 0; seen1_q <= 0; free_q <= 0;
            fwd_ack_q <= 0; clr_busy <= 1; clr_a <= 0;
        end else begin
            ack_q <= push_write;
            fwd_ack_q <= fwd_go;
            if (rt_waiting || (b_valid && b_realtime)) rt_hold <= 5'd31;
            else if (rt_hold != 0) rt_hold <= rt_hold - 1'b1;
            if (push) wr_ptr <= wr_ptr + 1'b1;
            if (pop) rd_ptr <= rd_ptr + 1'b1;
            if (pop) settle <= push ? 2'd3 : 2'd2;
            else if (push && occupancy == 0) settle <= 2'd3;
            else if (settle != 0) settle <= settle - 1'b1;
            if (pop_front) begin front_set <= 1; front_set_val <= head[15:0]; end
            if (drain_issue) drain_inflight <= 1;
            else if (drain_inflight && f_rsp_valid) drain_inflight <= 0;
            if (b_valid && b_ready && !(b_write && is_tex) && !drain_issue && !fwd_go) pt_inflight <= 1;
            else if (pt_inflight && f_rsp_valid) pt_inflight <= 0;
            // starvation guard: a drain waiting behind pass-through traffic gets the fabric after 8 requests
            if (drain_issue || !want_drain) starve <= 0;
            else if (b_valid && b_ready && !(b_write && is_tex) && !starve[3]) starve <= starve + 1'b1;
            seen_q <= seen2_q && tex_rd;
            seen2_q <= seen1_q && tex_rd;
            seen1_q <= tex_rd;
            free_q <= !pending;
            // accepted read: the next presented read looks its bucket up afresh
            if (b_valid && b_ready && tex_rd) begin seen_q <= 0; seen2_q <= 0; seen1_q <= 0; free_q <= 0; end
            // a shadow merge in flight (push_write_q: old entry being read, pw2_q: merge being written) may not
            // be visible to a lookup started now: restart it
            if (push_write_q || pw2_q) begin seen_q <= 0; seen2_q <= 0; seen1_q <= 0; end
        end
    end
endmodule
