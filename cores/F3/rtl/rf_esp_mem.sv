// ES5510 delay memory for the F3 sound board: an 8K x 16 on-chip window
// around DBASE plus, only where a program needs it, the full 64K-word ring
// in DDR behind per-instruction prefetch buffers.
//
// Every ESP instruction makes a RAM cycle at (DBASE + GPR[pc]) and DBASE
// steps one word per sample, so each instruction's address falls by exactly
// one word per sample. Measured over all 36 F3 games' uploaded programs
// (MAME 0.289 host writes, build/esp-budget), the accesses whose data is
// used (writes, and reads whose DIL an instruction consumes) lie in
//   window_neg = 0: offsets 0 .. 8191 above DBASE         (31 games)
//   window_neg = 1: offsets -8191 .. 0, plus one tap at +28673
//                   (Arkanoid Returns, Cleopatra Fortune, Gekirindan,
//                    Land Maker, Puchi Carat)
// Window accesses use the on-chip RAM, addressed by addr[12:0]: the ring is
// 64K words (or shorter than 8K, then it is never aliased), so any 8192
// consecutive words map to distinct slots.
//
// Outside the window, with window_neg = 0, an access is only ever an unused
// coefficient read (verified offline for every program) and is answered from
// the alias slot. With window_neg = 1:
//   - a write is posted to DDR,
//   - a read is answered at once from a one-word buffer kept for its
//     instruction (hit when the buffer holds this address), then that buffer
//     prefetches address-1 from DDR for the next sample; a miss (only the
//     first sample after a discontinuity) returns 0 rather than stalling,
//   - at each DBASE step the word leaving the top of the window (offset +1)
//     is written back to DDR before the new sample can overwrite its slot.
// Clears and host writes outside execution go to the window AND to DDR.
// The ESP never waits for DDR.
module rf_esp_mem (
    input  wire        clk, reset,
    input  wire        window_neg,
    input  wire [15:0] dbase,          // word address (DBASE[23:8])
    input  wire [16:0] ring,           // ring length in words (65536 or less)
    input  wire        exec,           // the request is an executing instruction's
    input  wire [7:0]  pc,             // instruction index of that request
    input  wire        dil_use,        // an instruction consumed DIL ...
    input  wire [7:0]  dil_pc,         // ... loaded by this instruction's read
    // engine side: request held until ack (one-cycle pulse)
    input  wire        c_req, c_write,
    input  wire [15:0] c_addr, c_wdata,
    output reg         c_ack,
    output reg  [15:0] c_rdata,
    // DDR side: request held until ack
    output reg         f_req, f_write,
    output reg  [15:0] f_addr, f_data,
    input  wire        f_ack,
    input  wire [15:0] f_q
);
    // ---- the window -----------------------------------------------------
    reg [15:0] win [0:8191];
    reg [12:0] w_addr;
    reg [15:0] w_wdata, w_q;
    reg        w_we;
    // M10K powers up 0 on the device; simulators need it spelled out (the
    // loop exceeds Quartus's 5000-iteration elaboration limit, Error 10106)
    // synthesis translate_off
    integer wi;
    initial for (wi = 0; wi < 8192; wi = wi + 1) win[wi] = 16'd0;
    // synthesis translate_on
    always @(posedge clk) begin
        if (w_we) win[w_addr] <= w_wdata;
        w_q <= win[w_addr];
    end

    wire [15:0] rel     = c_addr - dbase;
    wire        short   = ring <= 17'd8192;
    wire        in_win  = short || (window_neg ? (rel == 16'd0 || rel >= 16'd57345) : (rel < 16'd8192));
    wire        far     = window_neg && !short;

    reg        sweeping;                 // clear every buffer's valid bit after reset
    // ---- prefetch buffers, one per instruction ----------------------------
    reg [32:0] pf [0:255];             // {valid, tag, data}
    reg [7:0]  pf_ra;
    reg [32:0] pf_q;
    reg        pf_we;
    reg [7:0]  pf_wa;
    reg [32:0] pf_wd;
    always @(posedge clk) begin
        if (pf_we) pf[pf_wa] <= pf_wd;
        pf_q <= pf[pf_ra];
    end

    // instructions whose read data has ever been consumed: only those are
    // prefetched (most far reads are coefficient GPRs nobody uses)
    // (a 256 x 1 RAM read with the buffer; cleared by the reset sweep)
    reg used_mem [0:255];
    reg used_q;
    wire       used_we = sweeping || dil_use;
    wire [7:0] used_wa = sweeping ? pf_wa : dil_pc;
    always @(posedge clk) begin
        if (used_we) used_mem[used_wa] <= !sweeping;
        used_q <= used_mem[pf_ra];
    end

    // ---- DDR queue: posted writes and prefetch reads, in order -----------
    // {write, pc, addr, data}; 64 entries cover a sample's far traffic
    reg [40:0] q [0:63];
    reg [5:0]  q_wp, q_rp;
    wire [6:0] q_used = {1'b0, q_wp} - {1'b0, q_rp};
    wire       q_full = q_used >= 7'd62;
    reg        q_we;
    reg [40:0] q_wd;
    reg [40:0] q_head;
    always @(posedge clk) begin
        if (q_we) q[q_wp] <= q_wd;
        q_head <= q[q_rp];
    end
    // recent far writes this sample: a read after a write to the same word
    // takes the written value (the prefetch was issued a sample earlier)
    reg [15:0] rw_addr [0:3];
    reg [15:0] rw_data [0:3];
    reg [3:0]  rw_valid;
    reg [1:0]  rw_next;
    wire [3:0] rw_hit;
    genvar gi;
    generate for (gi = 0; gi < 4; gi = gi + 1) begin: g_rw
        assign rw_hit[gi] = rw_valid[gi] && rw_addr[gi] == c_addr;
    end endgenerate

    // DDR-side state (driven by the FSM at the end of the file)
    reg        f_busy, f_head_ok;
    reg [7:0]  f_pc;
    reg [15:0] f_tag, f_q_l;
    reg        f_done_we;
    reg        f_demand, dem_done;
    reg [15:0] dem_q;

    // ---- engine-side FSM ---------------------------------------------------
    localparam S_IDLE = 4'd0, S_WRD = 4'd1, S_PFR = 4'd2, S_FLR = 4'd3, S_FLQ = 4'd4, S_GAP = 4'd5,
               S_FAR = 4'd6, S_FLW = 4'd7, S_DEM = 4'd8;
    reg [3:0]  st;
    reg [15:0] last_dbase;
    reg        flush_pend;
    reg [15:0] flush_addr;
    reg [15:0] req_addr;
    reg [7:0]  req_pc;

    always @(posedge clk) begin
        c_ack <= 1'b0;
        w_we  <= 1'b0;
        pf_we <= 1'b0;
        q_we  <= 1'b0;
        if (reset) begin
            st <= S_IDLE; flush_pend <= 1'b0; last_dbase <= 16'd0;
            rw_valid <= 4'd0; rw_next <= 2'd0;
            q_wp <= 6'd0;
            sweeping <= 1'b1; pf_wa <= 8'd0;
        end else if (sweeping) begin
            pf_we <= 1'b1; pf_wd <= 33'd0;
            if (pf_we) pf_wa <= pf_wa + 8'd1;
            if (pf_we && pf_wa == 8'd255) begin sweeping <= 1'b0; pf_we <= 1'b0; end
        end else begin
            // the word leaving the window's top edge, once per DBASE step
            if (dbase != last_dbase) begin
                last_dbase <= dbase;
                if (far) begin flush_pend <= 1'b1; flush_addr <= last_dbase; end
                rw_valid <= 4'd0;
            end
            case (st)
            S_IDLE: begin
                if (flush_pend && !c_req && !q_full) begin
                    w_addr <= flush_addr[12:0];
                    flush_pend <= 1'b0;
                    st <= S_FLR;
                end else if (c_req) begin
                    req_addr <= c_addr; req_pc <= pc;
                    if (c_write) begin
                        if (in_win || !far || !exec) begin
                            w_addr <= c_addr[12:0]; w_wdata <= c_wdata; w_we <= 1'b1;
                        end
                        if (far && (!in_win || !exec)) begin
                            if (!q_full) begin
                                q_we <= 1'b1; q_wd <= {1'b1, 8'd0, c_addr, c_wdata};
                                if (exec && !in_win) begin
                                    rw_addr[rw_next] <= c_addr; rw_data[rw_next] <= c_wdata;
                                    rw_valid[rw_next] <= 1'b1; rw_next <= rw_next + 2'd1;
                                end
                                c_ack <= 1'b1; st <= S_GAP;
                            end
                        end else begin
                            c_ack <= 1'b1; st <= S_GAP;
                        end
                    end else if (!far || in_win || !exec) begin
                        w_addr <= c_addr[12:0];
                        st <= S_WRD;
                    end else begin
                        pf_ra <= pc;
                        st <= S_PFR;
                    end
                end
            end
            S_WRD: st <= S_FLQ;                       // RAM latency: data next cycle
            S_FLQ: begin                              // (shared with the flush read)
                c_rdata <= w_q; c_ack <= 1'b1; st <= S_GAP;
            end
            S_PFR: st <= S_FAR;                       // pf_q valid next cycle
            S_FAR: begin
                // far read: recent write, then this instruction's buffer. A
                // used read that misses (its offset was modulated, or after a
                // discontinuity) fetches the word and waits; an unused one
                // (a coefficient GPR) is answered 0 at once.
                if (|rw_hit || (pf_q[32] && pf_q[31:16] == req_addr) || !used_q) begin
                    if (|rw_hit)
                        c_rdata <= rw_hit[0] ? rw_data[0] : rw_hit[1] ? rw_data[1] : rw_hit[2] ? rw_data[2] : rw_data[3];
                    else if (pf_q[32] && pf_q[31:16] == req_addr)
                        c_rdata <= pf_q[15:0];
                    else
                        c_rdata <= 16'd0;
                    c_ack <= 1'b1;
                    // prefetch next sample's word for this instruction
                    if (!q_full && used_q) begin q_we <= 1'b1; q_wd <= {1'b0, req_pc, req_addr - 16'd1, 16'd0}; end
                    st <= S_GAP;
                end else if (!q_full) begin
                    q_we <= 1'b1; q_wd <= {1'b0, req_pc, req_addr, 16'd1};   // demand fetch
                    st <= S_DEM;
                end
            end
            S_DEM: if (dem_done) begin
                c_rdata <= dem_q; c_ack <= 1'b1;
                if (!q_full) begin q_we <= 1'b1; q_wd <= {1'b0, req_pc, req_addr - 16'd1, 16'd0}; end
                st <= S_GAP;
            end
            S_FLR: st <= S_FLW;
            S_FLW: begin
                q_we <= 1'b1; q_wd <= {1'b1, 8'd0, flush_addr, w_q};
                st <= S_IDLE;
            end
            S_GAP: if (!c_req) st <= S_IDLE;          // the engine drops req after ack
            endcase
            if (q_we) q_wp <= q_wp + 6'd1;
            // prefetch data returning (below) writes the buffer
            if (f_done_we) begin pf_we <= 1'b1; pf_wa <= f_pc; pf_wd <= {1'b1, f_tag, f_q_l}; end
        end
    end

    // ---- DDR-side FSM: one request at a time, held until ack ---------------
    always @(posedge clk) begin
        f_done_we <= 1'b0;
        dem_done  <= 1'b0;
        if (reset) begin
            f_req <= 1'b0; f_busy <= 1'b0; q_rp <= 6'd0; f_head_ok <= 1'b0;
        end else if (!f_busy) begin
            // q_head is a registered read of q[q_rp]: wait one cycle after
            // the pointer moves, and one after a write lands at q_rp
            f_head_ok <= (q_used != 0) && !(q_we && q_wp == q_rp);
            if (f_head_ok && q_used != 0) begin
                f_req <= 1'b1; f_write <= q_head[40]; f_pc <= q_head[39:32];
                f_addr <= q_head[31:16]; f_data <= q_head[15:0]; f_tag <= q_head[31:16];
                f_demand <= !q_head[40] && q_head[0];
                f_busy <= 1'b1; f_head_ok <= 1'b0;
                q_rp <= q_rp + 6'd1;
            end
        end else if (f_ack) begin
            f_req <= 1'b0; f_busy <= 1'b0;
            if (!f_write) begin
                f_done_we <= 1'b1; f_q_l <= f_q;
                if (f_demand) begin dem_done <= 1'b1; dem_q <= f_q; end
            end
        end
    end
endmodule
