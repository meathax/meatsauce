//============================================================================
//  Sega System 32 — sprite framebuffer interface (DESIGN.md §4.4)
//  Backing store: MiSTer DDR3 (DDRAM 64-bit burst interface).
//  Layout: 4 buffers (A/B x screen0/1), stride 512 pixels x 16 bit,
//  256 lines. Base = FB_BASE + buf*512*256*2.
//  Services (per DESIGN.md):
//    - erase_line(y):     fill line with 0xFFFF
//    - write_run(...):    pixel run writes from the sprite renderer;
//                         wr_shadow runs RMW dest &= 0x7fff instead
//                         (MAME shadow sprites clear framebuffer bit 15)
//    - read_line(y):      whole-line fetch into mixer line buffer
//  A run's untouched pixels are never written: a per-pixel valid mask
//  drives the DDR byte enables (partial head/tail words stay intact).
//  wr_busy holds the renderer off while the previous run drains.
//============================================================================

module s32_fb_if #(
    parameter [31:0] FB_BASE = 32'h3000_0000
)(
    input             clk,      // clk_ram
    input             rst,

    // DDRAM (MiSTer)
    input             DDRAM_BUSY,
    output      [7:0] DDRAM_BURSTCNT,
    output     [28:0] DDRAM_ADDR,
    input      [63:0] DDRAM_DOUT,
    input             DDRAM_DOUT_READY,
    output            DDRAM_RD,
    output     [63:0] DDRAM_DIN,
    output      [7:0] DDRAM_BE,
    output            DDRAM_WE,

    // renderer write port: run of pixels, 1/clk while wvalid.
    // wr_x is PER PIXEL (absolute x) — pixels may arrive in any order and
    // with gaps (flipped sprites sweep right-to-left; clip-out punches holes)
    input             wr_start,        // begin run (latches y/buf/shadow)
    input       [1:0] wr_buf,          // buffer select
    input       [8:0] wr_x,            // x of THIS pixel (valid with wr_valid)
    input       [7:0] wr_y,
    input             wr_valid,        // one pixel this cycle
    input      [15:0] wr_pix,
    input             wr_end,
    input             wr_shadow,       // run is a shadow RMW (dest &= 0x7fff)
    output            wr_busy,         // any run still capturing/queued/flushing
    output            wr_can_start,    // a free capture context is available

    // erase port
    input             er_req,
    input       [1:0] er_buf,
    input       [7:0] er_y,
    output reg        er_ack,

    // line read port -> mixer A
    input             rd_req,
    input       [1:0] rd_buf,
    input       [7:0] rd_y,
    output reg        rd_ack,          // line available in buffer
    input       [8:0] rd_x,            // synchronous read of fetched line
    output     [15:0] rd_pix,

    // line read port -> mixer B (Multi32 second monitor, simultaneous scanout).
    // Both monitors share hcnt/vcnt in lockstep (s32_video.sv single timing
    // generator), so lane B is addressed by the same rd_x as lane A.
    input             rd2_req,
    input       [1:0] rd2_buf,
    input       [7:0] rd2_y,
    output reg        rd2_ack,
    output     [15:0] rd2_pix
);

// line assembly buffer for writes: pixels land at their absolute x, a mask
// tracks which were written; flush covers [run_x0 .. run_xe] with byte
// enables from the mask (order/gap agnostic)
// Store four pixels per entry, matching one 64-bit DDR word.  The explicit
// RAM below has a 16-bit-lane write port for arbitrary-order sprite pixels and
// a synchronous 64-bit flush read port.  Keeping this out of flops removes the
// 8,192-register run buffer and its large read mux from the integrated map.
//
// Two capture contexts ping-pong so the renderer can assemble the next row
// while the previous row's flush drains to DDR (wr_can_start).  Flushes are
// consumed strictly in enqueue order (flush_sel alternates like cap_sel), so
// overwrite and shadow-RMW ordering between consecutive runs is preserved.
reg [511:0] cap_msk    [0:1];      // which pixels each queued run wrote
reg [8:0]   cap_x0     [0:1];      // min written x per context
reg [8:0]   cap_xe     [0:1];      // max written x per context
reg [7:0]   cap_y      [0:1];
reg [1:0]   cap_bufsel [0:1];
reg         cap_shadow [0:1];
reg         cap_any    [0:1];      // at least one pixel written
reg         cap_sel;               // context being captured next/now
reg         flush_sel;             // oldest queued context (FIFO order)
reg [1:0]   pending;               // context queued or flushing
reg         run_active;            // capture in progress on cap_sel

// Two fetched lines keep producer and consumer ownership separate. DDR fills
// one bank while scanout reads the other; a completed line is published only
// at x=0, so a late or early next-line fetch cannot tear the displayed raster.
// Lane B (second Multi32 monitor) gets its own independent bank pair so both
// screens can be resident and addressed every pixel at once; it shares the
// DDR engine (dispatched right after lane A, one line's worth of bandwidth is
// microseconds against a ~63us line period) but not the line storage.
reg  [1:0] rd_lane;
reg        display_bank,  fill_bank,  line_ready;
reg        display_bank2, fill_bank2, line_ready2;
wire       rd_line_publish  = (rd_x == 9'd0) && line_ready;
wire       rd_line_publish2 = (rd_x == 9'd0) && line_ready2;
wire       scan_bank  = rd_line_publish  ? fill_bank  : display_bank;
wire       scan_bank2 = rd_line_publish2 ? fill_bank2 : display_bank2;
// Which lane the in-flight D_RD/D_RD_W fetch belongs to (latched at dispatch).
reg        rd_active2;

// DDR engine
typedef enum logic [3:0] { D_IDLE, D_WR_PF, D_WR, D_ER, D_RD, D_RD_W,
                           D_SH_R, D_SH_RW, D_SH_W,
                           D_WR_SKIP, D_WR_SKIP_PF, D_SH_SKIP } dstate_t;
dstate_t dst = D_IDLE;

reg [28:0] daddr;
reg [7:0]  dburst;
reg        dwe, drd;
reg [63:0] ddin;
reg [7:0]  dbe;
reg [6:0]  beat, beats;
reg [6:0]  rbeat;
// Word currently being serviced by the run flusher.  Capturing this at the
// flush boundary keeps the active byte-enable path independent of run_x0 and
// the beat counter's add chain.
reg [6:0]  run_word_q;
// The mask for the current and following DDR words is advanced with the
// flusher rather than re-sliced from the 512-bit capture mask in the FSM
// state decision.  This preserves the per-word DDR cadence while keeping the
// variable part-select off the state-register timing path.
reg [3:0]  run_cur_mask_q, run_next_mask_q;
wire        line_we  = (dst == D_RD_W) && DDRAM_DOUT_READY && !rd_active2;
wire        line_we_b= (dst == D_RD_W) && DDRAM_DOUT_READY &&  rd_active2;
wire [63:0] line_wdata = DDRAM_DOUT;

// Pack each pair of ping-pong banks into one 256x64 RAM. The bank bit is
// the RAM address MSB; this preserves the existing one-write/one-registered-
// read timing while halving the number of line-memory instances.
wire [7:0] line_waddr_a = {fill_bank,  rbeat};
wire [7:0] line_waddr_b = {fill_bank2, rbeat};
wire [7:0] line_raddr_a = {scan_bank,  rd_x[8:2]};
wire [7:0] line_raddr_b = {scan_bank2, rd_x[8:2]};
wire [63:0] line_q_a, line_q_b;
s32_fb_line_ram_pair line_ram_a (
    .clk(clk), .wr_en(line_we), .wr_addr(line_waddr_a),
    .wr_data(line_wdata), .rd_addr(line_raddr_a), .rd_q(line_q_a)
);
s32_fb_line_ram_pair line_ram_b (
    .clk(clk), .wr_en(line_we_b), .wr_addr(line_waddr_b),
    .wr_data(line_wdata), .rd_addr(line_raddr_b), .rd_q(line_q_b)
);

`ifdef SIMULATION
always @(posedge clk) begin
    // The renderer drains all queued runs (wr_busy) before any erase pass, so
    // an erase must never jump ahead of a queued sprite flush — that would
    // wipe pixels the late flush then re-deposits onto the wrong frame.
    if (!rst && er_req && !er_ack && (pending != 2'b00))
        $fatal(1, "erase requested while sprite run flush still queued");
    if (!rst && line_we && (fill_bank == display_bank))
        $fatal(1, "sprite line fill attempted to overwrite display bank");
    if (!rst && line_ready && line_we)
        $fatal(1, "sprite line fill continued after completion");
    if (!rst && line_we_b && (fill_bank2 == display_bank2))
        $fatal(1, "sprite line fill (B) attempted to overwrite display bank");
    if (!rst && line_ready2 && line_we_b)
        $fatal(1, "sprite line fill (B) continued after completion");
end
`endif

wire [63:0] rd_word  = line_q_a;
wire [63:0] rd_word2 = line_q_b;
assign rd_pix  = (rd_lane == 2'd0) ? rd_word[15:0]   :
                 (rd_lane == 2'd1) ? rd_word[31:16]  :
                 (rd_lane == 2'd2) ? rd_word[47:32]  : rd_word[63:48];
assign rd2_pix = (rd_lane == 2'd0) ? rd_word2[15:0]  :
                 (rd_lane == 2'd1) ? rd_word2[31:16] :
                 (rd_lane == 2'd2) ? rd_word2[47:32] : rd_word2[63:48];

always @(posedge clk) begin
    rd_lane <= rd_x[1:0];
end

function automatic [28:0] pix_addr(input [1:0] buf_i, input [7:0] y,
                                   input [6:0] x_word);
    // 64-bit word address for DDRAM: byte addr / 8
    pix_addr = FB_BASE[31:3] + {{12{1'b0}}, buf_i, 15'b0}
                                + {{14{1'b0}}, y, 7'b0}
                                + {22'b0, x_word};
endfunction

// Synchronous run-buffer read pipeline.  D_WR_PF consumes the base word
// fetched while D_IDLE accepted the flush.  Thereafter the RAM looks one word
// ahead while DDR is stalled, or two words ahead on an accepted write; at the
// accepting edge q still contains the immediately following word.  Thus the
// registered RAM sustains one DDR word per accepted clock without allowing a
// stalled request's data to change.
wire [6:0] run_cur_word  = run_word_q;
wire [6:0] run_next_word = run_word_q + 7'd1;
wire [6:0] run_next2_word = run_word_q + 7'd2;
wire [6:0] run_ram_raddr = (dst == D_IDLE)       ? cap_x0[flush_sel][8:2] :
                            (dst == D_WR_PF)      ? run_next_word :
                            (dst == D_WR_SKIP)    ? run_cur_word :
                            (dst == D_WR_SKIP_PF) ? run_next_word :
                            (dst == D_WR)         ? run_cur_word
                                                     + (DDRAM_BUSY ? 7'd1 : 7'd2) :
                                                    run_cur_word;

// cap_msk[flush_sel] is stable from enqueue until the selected run completes.
// Load the first two slices at dispatch, then shift the registered lookahead
// whenever the flusher advances to another word. The one remaining variable
// slice is only used to fill the lookahead register, not to choose the next
// FSM state in the same cycle.
wire [3:0] run_next2_mask = cap_msk[flush_sel][{run_next2_word, 2'b00} +: 4];
wire [3:0] run_base_mask  = run_cur_mask_q;
wire [3:0] run_cur_mask   = run_cur_mask_q;
wire [3:0] run_next_mask  = run_next_mask_q;
wire [7:0] run_base_be = {{2{run_base_mask[3]}}, {2{run_base_mask[2]}},
                           {2{run_base_mask[1]}}, {2{run_base_mask[0]}}};
wire [7:0] run_cur_be = {{2{run_cur_mask[3]}}, {2{run_cur_mask[2]}},
                          {2{run_cur_mask[1]}}, {2{run_cur_mask[0]}}};
wire [7:0] run_next_be = {{2{run_next_mask[3]}}, {2{run_next_mask[2]}},
                           {2{run_next_mask[1]}}, {2{run_next_mask[0]}}};
// Shadow writes only the high byte of each valid lane (bit 15 lives there).
wire [7:0] run_cur_shadow_be = {run_cur_mask[3], 1'b0,
                                 run_cur_mask[2], 1'b0,
                                 run_cur_mask[1], 1'b0,
                                 run_cur_mask[0], 1'b0};

wire [63:0] run_ram_q;
s32_fb_run_ram run_ram (
    .clk(clk),
    .wr_en(wr_valid && run_active),
    .wr_addr({cap_sel, wr_x[8:2]}),
    .wr_lane(wr_x[1:0]),
    .wr_data(wr_pix),
    .rd_addr({flush_sel, run_ram_raddr}),
    .rd_q(run_ram_q)
);

assign DDRAM_ADDR     = daddr;
assign DDRAM_BURSTCNT = dburst;
assign DDRAM_WE       = dwe;
assign DDRAM_RD       = drd;
assign DDRAM_DIN      = ddin;
assign DDRAM_BE       = dbe;

// Drain indicator (kept under its historical name: white-box benches wait on
// it): any run is queued or flushing.
wire flush_req = pending[0] | pending[1];

// Scanout has a fixed deadline; a completed sprite run may remain queued until
// a pending display-line fetch has been launched.  Keep acceptance explicit so
// deferring the flush cannot discard it.
wire erase_pending = er_req && !er_ack;
// Do not reuse a completed fill bank until the raster boundary publishes it.
wire read_pending  = rd_req  && !rd_ack  && !line_ready;
wire read_pending2 = rd2_req && !rd2_ack && !line_ready2;
wire flush_accept  = (dst == D_IDLE) && !erase_pending &&
                     !read_pending && !read_pending2 && pending[flush_sel];

// capture pixel runs (indexed by the pixel's own x).  wr_end enqueues the
// context and flips cap_sel; the engine below clears pending at flush
// completion.  cap_sel and flush_sel both strictly alternate, so the queue is
// FIFO by construction and the set/clear indices can never collide (a context
// is only recaptured after wr_can_start showed its pending bit clear).
always @(posedge clk) begin
    if (wr_start) begin
        cap_x0[cap_sel]     <= 9'd511;
        cap_xe[cap_sel]     <= 9'd0;
        cap_y[cap_sel]      <= wr_y;
        cap_bufsel[cap_sel] <= wr_buf;
        cap_shadow[cap_sel] <= wr_shadow;
        run_active          <= 1'b1;
        cap_any[cap_sel]    <= 1'b0;
        cap_msk[cap_sel]    <= 512'b0;
    end
    if (wr_valid && run_active) begin
        cap_msk[cap_sel][wr_x] <= 1'b1;
        cap_any[cap_sel] <= 1'b1;
        if (wr_x < cap_x0[cap_sel]) cap_x0[cap_sel] <= wr_x;
        if (wr_x > cap_xe[cap_sel]) cap_xe[cap_sel] <= wr_x;
    end
    if (wr_end && run_active) begin
        run_active <= 1'b0;
        cap_sel    <= ~cap_sel;
    end
    if (rst) begin
        run_active <= 1'b0;
        cap_sel    <= 1'b0;
    end
end

// Full-drain indicator: R_DONE / buffer publication wait on this, and it keeps
// the original interface semantics (asserted from wr_end until every queued
// run has committed to DDR).
assign wr_busy = wr_end | flush_req |
                 (dst == D_WR_PF) | (dst == D_WR) |
                 (dst == D_WR_SKIP) | (dst == D_WR_SKIP_PF) |
                 (dst == D_SH_R) | (dst == D_SH_RW) | (dst == D_SH_W) |
                 (dst == D_SH_SKIP);

// A new run may begin as soon as the other context is free — this is what
// lets row N+1 render while row N flushes.
assign wr_can_start = !wr_end && !run_active && !pending[cap_sel];

always @(posedge clk) begin
    if (rst) begin
        dst <= D_IDLE; dwe <= 0; drd <= 0; er_ack <= 0; rd_ack <= 0;
        rd2_ack <= 0; rd_active2 <= 1'b0;
        run_word_q <= 7'd0;
        run_cur_mask_q <= 4'b0000;
        run_next_mask_q <= 4'b0000;
        pending <= 2'b00;
        flush_sel <= 1'b0;
        display_bank <= 1'b0;
        fill_bank <= 1'b1;
        line_ready <= 1'b0;
        display_bank2 <= 1'b0;
        fill_bank2 <= 1'b1;
        line_ready2 <= 1'b0;
    end
    else begin
        // Enqueue a completed capture (reads cap_sel before its same-cycle
        // toggle in the capture block above).
        if (wr_end && run_active) pending[cap_sel] <= 1'b1;
        if (rd_line_publish) begin
            display_bank <= fill_bank;
            line_ready <= 1'b0;
        end
        if (rd_line_publish2) begin
            display_bank2 <= fill_bank2;
            line_ready2 <= 1'b0;
        end
        case (dst)
        D_IDLE: begin
            dwe <= 0; drd <= 0;
            if (erase_pending) begin
                daddr  <= pix_addr(er_buf, er_y, 7'd0);
                // MiSTer recommends pipelined single writes. With burstcnt=1
                // each accepted beat may advance DDRAM_ADDR legally.
                dburst <= 8'd1;
                ddin   <= 64'hFFFF_FFFF_FFFF_FFFF;
                dbe    <= 8'hFF;
                beat   <= 0; beats <= 7'd127;
                dwe    <= 1'b1;
                dst    <= D_ER;
            end
            else if (read_pending) begin
                daddr  <= pix_addr(rd_buf, rd_y, 7'd0);
                dburst <= 8'd128;
                rbeat  <= 0;
                fill_bank <= ~display_bank;
                rd_active2 <= 1'b0;
                drd    <= 1'b1;
                dbe    <= 8'hFF;  // audit R20 PF-4: reads drive all byte lanes
                dst    <= D_RD;
            end
            else if (read_pending2) begin
                daddr  <= pix_addr(rd2_buf, rd2_y, 7'd0);
                dburst <= 8'd128;
                rbeat  <= 0;
                fill_bank2 <= ~display_bank2;
                rd_active2 <= 1'b1;
                drd    <= 1'b1;
                dbe    <= 8'hFF;  // audit R20 PF-4: reads drive all byte lanes
                dst    <= D_RD;
            end
            else if (pending[flush_sel]) begin
                beat  <= 0;
                beats <= (cap_xe[flush_sel][8:2] - cap_x0[flush_sel][8:2]);
                run_word_q <= cap_x0[flush_sel][8:2];
                run_cur_mask_q <= cap_msk[flush_sel][{cap_x0[flush_sel][8:2], 2'b00} +: 4];
                run_next_mask_q <= cap_msk[flush_sel][{cap_x0[flush_sel][8:2] + 7'd1, 2'b00} +: 4];
                daddr <= pix_addr(cap_bufsel[flush_sel], cap_y[flush_sel],
                                  cap_x0[flush_sel][8:2]);
                if (!cap_any[flush_sel]) begin
                    // fully-transparent row: nothing to flush
                    pending[flush_sel] <= 1'b0;
                    flush_sel <= ~flush_sel;
                end
                else if (cap_shadow[flush_sel]) begin
                    // RMW span: read word, clear bit15 of valid lanes, write
                    dburst <= 8'd1;
                    drd    <= 1'b1;
                    dbe    <= 8'hFF;  // audit R20 PF-4: reads drive all byte lanes
                    dst    <= D_SH_R;
                end
                else begin
                    dburst <= 8'd1;
                    dst    <= D_WR_PF;
                end
            end

        end
        // One synchronous-RAM prefetch cycle.  q is the base word requested
        // while the preceding D_IDLE edge accepted this flush.
        D_WR_PF: begin
            ddin <= run_ram_q;
            dbe  <= run_base_be;
            dwe  <= 1'b1;
            dst  <= D_WR;
        end
        D_ER: if (!DDRAM_BUSY) begin
            dwe <= 1'b1;
            // Erase always spans the fixed 128-word line loaded in D_IDLE.
            // Keep the terminal test local to beat; comparing against the
            // variable beats register was the measured critical cone into
            // the D_ER state bit.
            if (&beat) begin dwe <= 0; er_ack <= 1'b1; dst <= D_IDLE; end
            else begin beat <= beat + 1'd1; daddr <= daddr + 1'd1; end
        end
        D_WR: if (!DDRAM_BUSY) begin
            // The current word is no longer consumed once DWE is cleared or
            // a zero-mask word is skipped.  Keep the data register update
            // independent of the beat/mask decision so that the active
            // DDRAM write-data path does not inherit that control cone.
            ddin <= run_ram_q;
            if (beat == beats) begin
                dwe <= 0; dst <= D_IDLE;
                pending[flush_sel] <= 1'b0;
                flush_sel <= ~flush_sel;
            end
            else if (run_next_mask == 4'b0000) begin
                // Transparent/clipped holes can leave complete 64-bit words
                // empty between the run's first and last written pixels.
                // A zero-BE DDR write has no framebuffer effect, so walk the
                // mask locally instead of consuming external acceptance slots.
                beat  <= beat + 1'd1;
                run_word_q <= run_word_q + 1'd1;
                run_cur_mask_q <= run_next_mask_q;
                run_next_mask_q <= run_next2_mask;
                daddr <= daddr + 1'd1;
                dwe   <= 1'b0;
                dst   <= D_WR_SKIP;
            end
            else begin
                beat  <= beat + 1'd1;
                run_word_q <= run_word_q + 1'd1;
                run_cur_mask_q <= run_next_mask_q;
                run_next_mask_q <= run_next2_mask;
                daddr <= daddr + 1'd1;
                dbe   <= run_next_be;
                dwe   <= 1'b1;
            end
        end
        D_WR_SKIP: begin
            // No DDR request is active in this state, so mask scanning is not
            // coupled to DDRAM_BUSY. Valid words retain ascending write order.
            dwe <= 1'b0;
            if (run_cur_mask != 4'b0000) begin
                dst <= D_WR_SKIP_PF;
            end
            else if (beat == beats) begin
                dst <= D_IDLE;
                pending[flush_sel] <= 1'b0;
                flush_sel <= ~flush_sel;
            end
            else begin
                beat  <= beat + 1'd1;
                run_word_q <= run_word_q + 1'd1;
                run_cur_mask_q <= run_next_mask_q;
                run_next_mask_q <= run_next2_mask;
                daddr <= daddr + 1'd1;
            end
        end
        // Restore the same synchronous-RAM lookahead used by D_WR_PF. During
        // this cycle q is the selected word and the RAM prefetches its successor.
        D_WR_SKIP_PF: begin
            ddin <= run_ram_q;
            dbe  <= run_cur_be;
            dwe  <= 1'b1;
            dst  <= D_WR;
        end
        // shadow RMW loop: one 64-bit word per iteration
        D_SH_R: if (!DDRAM_BUSY) begin
            drd <= 1'b0;
            dst <= D_SH_RW;
        end
        D_SH_RW: if (DDRAM_DOUT_READY) begin
            ddin <= DDRAM_DOUT & 64'h7FFF_7FFF_7FFF_7FFF;
            dbe  <= run_cur_shadow_be;
            dwe  <= 1'b1;
            dst  <= D_SH_W;
        end
        D_SH_W: if (!DDRAM_BUSY) begin
            dwe <= 1'b0;
            if (beat == beats) begin
                dst <= D_IDLE;
                pending[flush_sel] <= 1'b0;
                flush_sel <= ~flush_sel;
            end
            else begin
                beat   <= beat + 1'd1;
                run_word_q <= run_word_q + 1'd1;
                run_cur_mask_q <= run_next_mask_q;
                run_next_mask_q <= run_next2_mask;
                daddr  <= daddr + 1'd1;
                dburst <= 8'd1;
                if (run_next_mask != 4'b0000) begin
                    drd <= 1'b1;
                    dbe <= 8'hFF;  // audit R20 PF-4: reads drive all byte lanes
                    dst <= D_SH_R;
                end
                else begin
                    // Empty shadow words would read DDR and then issue a
                    // zero-BE write. Both are semantic no-ops; skip them while
                    // retaining the RMW ordering of every populated word.
                    drd <= 1'b0;
                    dst <= D_SH_SKIP;
                end
            end
        end
        D_SH_SKIP: begin
            dwe <= 1'b0;
            drd <= 1'b0;
            if (run_cur_mask != 4'b0000) begin
                dburst <= 8'd1;
                drd    <= 1'b1;
                dbe    <= 8'hFF;
                dst    <= D_SH_R;
            end
            else if (beat == beats) begin
                dst <= D_IDLE;
                pending[flush_sel] <= 1'b0;
                flush_sel <= ~flush_sel;
            end
            else begin
                beat  <= beat + 1'd1;
                run_word_q <= run_word_q + 1'd1;
                run_cur_mask_q <= run_next_mask_q;
                run_next_mask_q <= run_next2_mask;
                daddr <= daddr + 1'd1;
            end
        end
        D_RD: if (!DDRAM_BUSY) begin
            drd <= 1'b0;
            dst <= D_RD_W;
        end
        D_RD_W: begin
            if (DDRAM_DOUT_READY) begin
                rbeat <= rbeat + 1'd1;
                if (rbeat == 7'd127) begin
                    if (rd_active2) begin
                        line_ready2 <= 1'b1;
                        rd2_ack <= 1'b1;
                    end
                    else begin
                        line_ready <= 1'b1;
                        rd_ack <= 1'b1;
                    end
                    dst <= D_IDLE;
                end
            end
        end
        default: dst <= D_IDLE;
        endcase
        // Four-phase request/acknowledge: a held request is accepted once,
        // and the acknowledge drops as soon as its producer drops request.
        if (!rd_req)  rd_ack  <= 1'b0;
        if (!rd2_req) rd2_ack <= 1'b0;
        if (!er_req) er_ack <= 1'b0;
    end
end

endmodule

// ---------------------------------------------------------------------------
// 256 x 64 fetched-line RAM. The address MSB selects one of two ping-pong
// line banks; port A writes the fill bank while port B serves scanout from the
// independently selected bank.
// ---------------------------------------------------------------------------
module s32_fb_line_ram_pair (
    input              clk,
    input              wr_en,
    input       [7:0]  wr_addr,
    input      [63:0]  wr_data,
    input       [7:0]  rd_addr,
    output     [63:0]  rd_q
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clk),
    .address_a(wr_addr),
    .data_a(wr_data),
    .wren_a(wr_en),

    .clock1(clk),
    .address_b(rd_addr),
    .q_b(rd_q),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_a(1'b1),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = 256,
    ram.widthad_a = 8,
    ram.width_a = 64,
    ram.numwords_b = 256,
    ram.widthad_b = 8,
    ram.width_b = 64,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "DUAL_PORT",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "TRUE",
    ram.read_during_write_mode_mixed_ports = "DONT_CARE",
    ram.width_byteena_a = 1;
`else
reg [63:0] mem [0:255];
reg [63:0] rd_q_r;
assign rd_q = rd_q_r;

integer __line_init;
initial begin
    rd_q_r = 64'd0;
    for (__line_init = 0; __line_init < 256; __line_init = __line_init + 1)
        mem[__line_init] = 64'd0;
end

always @(posedge clk) begin
    rd_q_r <= mem[rd_addr];
    if (wr_en)
        mem[wr_addr] <= wr_data;
end
`endif

endmodule

// ---------------------------------------------------------------------------
// 256 x 64 captured-run RAM (two 128-word ping-pong contexts selected by the
// address MSB).  Port A writes one 16-bit pixel lane per clock; port B returns
// a complete DDR word one clock after rd_addr is presented.
// Quartus' integrated-synthesis macro selects the Cyclone V primitive, while
// normal simulators use the cycle-equivalent behavioural array.
// ---------------------------------------------------------------------------
module s32_fb_run_ram (
    input              clk,
    input              wr_en,
    input       [7:0]  wr_addr,
    input       [1:0]  wr_lane,
    input      [15:0]  wr_data,
    input       [7:0]  rd_addr,
    output     [63:0]  rd_q
);

wire [63:0] wr_word = {4{wr_data}};
wire  [7:0] wr_be = (wr_lane == 2'd0) ? 8'b0000_0011 :
                     (wr_lane == 2'd1) ? 8'b0000_1100 :
                     (wr_lane == 2'd2) ? 8'b0011_0000 : 8'b1100_0000;

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clk),
    .address_a(wr_addr),
    .data_a(wr_word),
    .byteena_a(wr_be),
    .wren_a(wr_en),

    .clock1(clk),
    .address_b(rd_addr),
    .q_b(rd_q),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = 256,
    ram.widthad_a = 8,
    ram.width_a = 64,
    ram.numwords_b = 256,
    ram.widthad_b = 8,
    ram.width_b = 64,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "DUAL_PORT",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "FALSE",
    ram.read_during_write_mode_mixed_ports = "DONT_CARE",
    ram.width_byteena_a = 8;
`else
reg [63:0] mem [0:255];
reg [63:0] rd_q_r;
assign rd_q = rd_q_r;

integer __run_init;
initial begin
    for (__run_init = 0; __run_init < 256; __run_init = __run_init + 1)
        mem[__run_init] = 64'd0;
end

always @(posedge clk) begin
    rd_q_r <= mem[rd_addr];
    if (wr_en) begin
        case (wr_lane)
            2'd0: mem[wr_addr][15:0]  <= wr_data;
            2'd1: mem[wr_addr][31:16] <= wr_data;
            2'd2: mem[wr_addr][47:32] <= wr_data;
            2'd3: mem[wr_addr][63:48] <= wr_data;
        endcase
    end
end
`endif

endmodule
