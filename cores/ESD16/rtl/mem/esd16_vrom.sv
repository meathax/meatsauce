// Video ROM adapter: four-entry block caches and accepted-request lookahead.
// Requests remain FIFO ordered at the response interface. A burst may be
// launched for the earliest already-accepted queued miss behind cached hits.
module esd16_vrom (
    input             clk,
    input             rst,
    input             inv,
    input             rom_req,
    input             rom_sel,
    input      [20:0] rom_addr,
    output            rom_ready,
    output reg        rom_valid,
    output reg [31:0] rom_data,
    output reg        spr_req,
    output     [21:0] spr_waddr,
    input             spr_done,
    input      [63:0] spr_blk,
    output reg        bgs_req,
    output     [21:0] bgs_waddr,
    input             bgs_done,
    input      [63:0] bgs_blk
);
    reg [21:0] fifo [0:7];
    reg [2:0]  wp, rp;
    reg [3:0]  cnt;
    assign rom_ready = (cnt < 4'd7);
    wire push = rom_req && rom_ready;

    reg [19:0] tag_s [0:3], tag_b [0:3];
    reg [3:0]  val_s, val_b;
    reg [63:0] dat_s [0:3], dat_b [0:3];
    reg [1:0]  repl_s, repl_b;
    reg [19:0] rq_blk;
    reg        busy;

    wire [21:0] head = fifo[rp];
    wire        h_sel = head[21];
    wire [19:0] h_blk = head[20:1];
    wire        h_half = head[0];
    wire        have = (cnt != 4'd0);

    reg         hit;
    reg [63:0]  hdat;
    wire        fill_done = busy && (spr_req ? spr_done : bgs_done);
    wire        fill_head = have && fill_done && h_sel == spr_req && h_blk == rq_blk;
    wire [63:0] response_block = hit ? hdat : (spr_req ? spr_blk : bgs_blk);
    wire        pop = !rst && !inv && have && (hit || fill_head);
    integer hscan;
    always @* begin
        hit = 1'b0;
        hdat = 64'd0;
        if (have) begin
            if (h_sel) begin
                for (hscan = 0; hscan < 4; hscan = hscan + 1) begin
                    if (val_s[hscan] && tag_s[hscan] == h_blk) begin
                        hit = 1'b1;
                        hdat = dat_s[hscan];
                    end
                end
            end else begin
                for (hscan = 0; hscan < 4; hscan = hscan + 1) begin
                    if (val_b[hscan] && tag_b[hscan] == h_blk) begin
                        hit = 1'b1;
                        hdat = dat_b[hscan];
                    end
                end
            end
        end
    end

    // Find the earliest accepted FIFO request whose block is not cached.
    // Existing head hits can still pop in order while that one fill is in flight.
    reg        miss_found;
    reg        miss_sel;
    reg [19:0] miss_blk;
    reg        qhit;
    reg [2:0]  qidx;
    reg [21:0] qentry;
    integer    qscan, qway;
    always @* begin
        miss_found = 1'b0;
        miss_sel = 1'b0;
        miss_blk = 20'd0;
        qhit = 1'b0;
        qidx = 3'd0;
        qentry = 22'd0;
        for (qscan = 0; qscan < 7; qscan = qscan + 1) begin
            qidx = rp + qscan[2:0];
            qentry = fifo[qidx];
            qhit = 1'b0;
            if (qscan < cnt) begin
                for (qway = 0; qway < 4; qway = qway + 1) begin
                    if (qentry[21]) begin
                        if (val_s[qway] && tag_s[qway] == qentry[20:1]) qhit = 1'b1;
                    end else begin
                        if (val_b[qway] && tag_b[qway] == qentry[20:1]) qhit = 1'b1;
                    end
                end
                if (!qhit && !miss_found) begin
                    miss_found = 1'b1;
                    miss_sel = qentry[21];
                    miss_blk = qentry[20:1];
                end
            end
        end
    end

    // At fill completion, do not evict a valid block used by the current head
    // or by the next head that is popping on the same edge.
    wire [21:0] next_head = fifo[rp + 3'd1];
    reg [1:0] fill_slot_s, fill_slot_b;
    reg found_slot_s, found_slot_b, blocked_s, blocked_b;
    reg [1:0] cand_slot_s, cand_slot_b;
    integer fill_scan;
    always @* begin
        fill_slot_s = repl_s;
        fill_slot_b = repl_b;
        found_slot_s = 1'b0;
        found_slot_b = 1'b0;
        blocked_s = 1'b0;
        blocked_b = 1'b0;
        cand_slot_s = repl_s;
        cand_slot_b = repl_b;
        for (fill_scan = 0; fill_scan < 4; fill_scan = fill_scan + 1) begin
            cand_slot_s = repl_s + fill_scan[1:0];
            blocked_s = 1'b0;
            if (have && h_sel && hit && val_s[cand_slot_s] && tag_s[cand_slot_s] == h_blk)
                blocked_s = 1'b1;
            // Conservative: protect the next head whether or not it pops on this edge (keeps pop out of the slot cone).
            if (cnt > 4'd1 && next_head[21] && val_s[cand_slot_s] && tag_s[cand_slot_s] == next_head[20:1])
                blocked_s = 1'b1;
            if (!found_slot_s && !blocked_s) begin
                fill_slot_s = cand_slot_s;
                found_slot_s = 1'b1;
            end

            cand_slot_b = repl_b + fill_scan[1:0];
            blocked_b = 1'b0;
            if (have && !h_sel && hit && val_b[cand_slot_b] && tag_b[cand_slot_b] == h_blk)
                blocked_b = 1'b1;
            if (cnt > 4'd1 && !next_head[21] && val_b[cand_slot_b] && tag_b[cand_slot_b] == next_head[20:1])
                blocked_b = 1'b1;
            if (!found_slot_b && !blocked_b) begin
                fill_slot_b = cand_slot_b;
                found_slot_b = 1'b1;
            end
        end
    end

    assign spr_waddr = {rq_blk, 2'b00};
    assign bgs_waddr = {rq_blk, 2'b00};

    // Head-only response ordering is unchanged. A cached head may pop even
    // while a different accepted request is being fetched.
    always @(posedge clk) begin
        rom_valid <= 1'b0;
        if (rst) begin
            wp <= 3'd0;
            rp <= 3'd0;
            cnt <= 4'd0;
        end else begin
            if (push) begin
                fifo[wp] <= {rom_sel, rom_addr};
                wp <= wp + 3'd1;
            end
            if (pop) rp <= rp + 3'd1;
            cnt <= cnt + {3'd0, push} - {3'd0, pop};
        end

        if (pop) begin
            rom_data <= h_half ? response_block[63:32] : response_block[31:0];
            rom_valid <= 1'b1;
        end

        if (rst) begin
            val_s <= 4'd0;
            val_b <= 4'd0;
            repl_s <= 2'd0;
            repl_b <= 2'd0;
            busy <= 1'b0;
            spr_req <= 1'b0;
            bgs_req <= 1'b0;
        end else if (inv) begin
            val_s <= 4'd0;
            val_b <= 4'd0;
            busy <= 1'b0;
            spr_req <= 1'b0;
            bgs_req <= 1'b0;
        end else if (busy) begin
            if (spr_req ? spr_done : bgs_done) begin
                busy <= 1'b0;
                spr_req <= 1'b0;
                bgs_req <= 1'b0;
                if (spr_req) begin
                    dat_s[fill_slot_s] <= spr_blk;
                    tag_s[fill_slot_s] <= rq_blk;
                    val_s[fill_slot_s] <= 1'b1;
                    repl_s <= fill_slot_s + 2'd1;
                end else begin
                    dat_b[fill_slot_b] <= bgs_blk;
                    tag_b[fill_slot_b] <= rq_blk;
                    val_b[fill_slot_b] <= 1'b1;
                    repl_b <= fill_slot_b + 2'd1;
                end
            end
        end else if (have && miss_found) begin
            busy <= 1'b1;
            rq_blk <= miss_blk;
            spr_req <= miss_sel;
            bgs_req <= ~miss_sel;
        end
    end
endmodule
