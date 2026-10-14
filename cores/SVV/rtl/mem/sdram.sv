//============================================================================
//  SSV (Sammy System) for MiSTer -- SDRAM controller
//
//  THIS IS THE MiSTer 128 MB MODULE CONTRACT, taken verbatim from the Sega
//  System 32 core (D:\Arcade\AI\S32MULTIONLY
//  this same DE10-Nano + module and from which SSV's controller was originally
//  ported. Commit c429ba4 rewrote it for a single monolithic 64Mx16 part with
//  free-standing DQM pins and nCS folded into a 4-bit command. That part is not
//  what is fitted, and the rewrite is what black-screened and silenced the core:
//
//    * DQML/DQMH are SHORTED to A11/A12 on the module, so the rewrite's column
//      bit on A11 byte-masked its own writes. The on-board probe read 0x007A
//      where 0x207A had been written -- low byte landed, high byte masked away.
//    * nCS is the DEVICE SELECT, not a command bit, so device 1 never received
//      MRS and the upper 64 MB (ST010 + ES5506 samples) was unreachable. That
//      was the missing audio.
//
//  Both failures are reproduced by verif/tb_ssv_sdram_module_contract.sv
//  against verif/ssv_sdram_module.sv, and neither is visible to
//  verif/ssv_sdram_chip.sv, which models the part the board does not have.
//  See docs/issues/SDRAM_MODULE_CONTRACT.md.
//
//  Geometry is FIXED BY THE HARDWARE and is deliberately not parameterised --
//  making it a parameter is how the wrong part got configured in the first
//  place:
//      a[26]    device select -> SDRAM_nCS
//      a[25]    column bit 9
//      a[24:23] bank
//      a[22:10] row (13 bits)
//      a[9:1]   column bits 8:0
//
//============================================================================

`timescale 1ns/1ps

module sdram (
    input             clk,          // clk_ram
    input             init,         // reset/init request
    output reg        ready,

    // SDRAM chip interface
    inout      [15:0] SDRAM_DQ,
    output reg [12:0] SDRAM_A,
    output reg  [1:0] SDRAM_BA,
    output            SDRAM_DQML,
    output            SDRAM_DQMH,
    output            SDRAM_nCS,
    output            SDRAM_nCAS,
    output            SDRAM_nRAS,
    output            SDRAM_nWE,
    output            SDRAM_CKE,

    // download/write port (word writes, ROM load)
    input             wr_req,
    input      [26:1] wr_addr,
    input      [15:0] wr_din,
    input       [1:0] wr_be,
    output reg        wr_ack,

    // p0: V60
    input             p0_req,
    input      [26:1] p0_addr,
    output reg [15:0] p0_dout,
    output reg        p0_ack,

    // p1: tiles — 4-word burst, aligned to 8 bytes
    input             p1_req,
    input      [26:3] p1_addr,
    output reg [63:0] p1_dout,
    output reg        p1_ack,

    // p2: sprites — 8-word burst, aligned to 16 bytes
    input             p2_req,
    input      [26:4] p2_addr,
    output reg [127:0] p2_dout,
    output reg        p2_ack,

    // p3: Z80
    input             p3_req,
    input      [26:1] p3_addr,
    output reg [15:0] p3_dout,
    output reg        p3_ack,

    // p4: MultiPCM
    input             p4_req,
    input      [26:1] p4_addr,
    output reg [15:0] p4_dout,
    output reg        p4_ack,

    // p5: V25 program ROM - 4-word burst, aligned to 8 bytes
    input             p5_req,
    input      [26:3] p5_addr,
    output reg [63:0] p5_dout,
    output reg        p5_ack
);

reg [15:0] dq_out;
reg        dq_oe;

assign SDRAM_CKE  = 1'b1;

// MiSTer 128 MB module: the two devices' DQML/DQMH pins are SHORTED to A11/A12
// (verified against Arcade-IremM92_MiSTer rtl/sdram.sv:69 and jtframe's
// jtframe_sdram_bank_core.v:140 "This is a limitation in MiSTer's 128MB
// module").  DQM is therefore not an independent output: it is whatever the
// address bus carries.  A[12:11] must be 00 for any cycle whose data must not
// be masked, and carries ~be during a WRITE CAS.  Driving these pins separately
// would fight the shorted net.
assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];

localparam BURST_1   = 3'b000;
localparam CL        = 3'd2;

// commands {nRAS,nCAS,nWE}.  nCS is NOT part of the command encoding any more:
// on the 128 MB module it is the device selector, driven from address bit 26.
// CMD_NOP must therefore stay RAS/CAS/WE=111 (a real NOP with the device
// selected) and must never be expressed as a deselect, or the chip bit would
// be destroyed by every idle cycle.
localparam CMD_NOP   = 3'b111;
localparam CMD_ACT   = 3'b011;
localparam CMD_READ  = 3'b101;
localparam CMD_WRITE = 3'b100;
localparam CMD_PRE   = 3'b010;
localparam CMD_REF   = 3'b001;
localparam CMD_MRS   = 3'b000;

reg  [2:0] cmd = CMD_NOP;
reg        chip_sel = 1'b0;      // SDRAM_nCS: 0 = device 0, 1 = device 1
assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
assign SDRAM_nCS = chip_sel;

assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

// init sequencer
reg [15:0] init_cnt = 16'hffff;

// refresh: 8192 rows / 64 ms @96.6MHz -> every ~755 cycles
reg [9:0]  ref_cnt;
reg        ref_pend;

typedef enum logic [3:0] {
    ST_IDLE, ST_DISPATCH, ST_ACT, ST_RCD1, ST_RCD2, ST_RD, ST_RDW,
    ST_WR, ST_WRRC, ST_PRE_CMD, ST_PRE_XFER, ST_PRE_REF_B, ST_PRE_REF,
    ST_REF_B, ST_REFW
} state_t;
state_t state = ST_IDLE;

reg [2:0]  grant;
reg [2:0]  rr_next;
reg [3:0]  rd_total;        // words to read (1/4/8)
reg [3:0]  rd_issued;
reg [3:0]  rd_captured;
reg [26:1] xfer_addr;
// {device, bank} -> open-row slot
wire [2:0] xfer_idx = {xfer_addr[26], xfer_addr[24:23]};
reg        is_write;
reg [15:0] din_r;
reg [1:0]  be_r;
reg [2:0]  wrrc_cnt;
reg [2:0]  refw_cnt;
reg [1:0]  pre_cnt;
// Open-row tracking, indexed by {device, bank} -- eight independent rows.
// The region map (s32_pkg) deliberately gives each hot reader its own bank of
// its own device precisely so these rows never evict one another; that comment
// notes an open-row controller is "the only thing that addresses the real
// SDRAM bottleneck", and this is it.  Reads no longer auto-precharge: a bank
// is closed only on a genuine same-bank row miss, or all-banks before refresh.
reg  [7:0] row_open;
reg [12:0] open_row [0:7];
integer    ri;
reg [1:0]  ack_stretch;     // acks held 2 clk_ram cycles (clk_sys is /2 sync)

// p5 is consumed by the ST010 fetcher in clk_sys, which is the synchronous
// divide-by-two domain of this controller.  The old response register was
// clocked on posedge clk_ram, so its very short local route could launch at
// the same physical edge sampled by clk_sys.  That is a real cross-domain
// hold violation (the retained fit measured -0.606 ns), not a simulation-only
// warning.  Keep the controller's command/read machine on posedge clk_ram,
// but transfer only the p5 response packet to a negedge register.  This gives
// the clk_sys consumer a complete half clk_ram period of data/ack settling
// while preserving the existing two-clk_ram acknowledgement contract.
reg [63:0] p5_dout_pending;
reg        p5_ack_pending;
reg [1:0]  p5_ack_hold;
// p3 is consumed by the NVRAM upload bridge in clk_sys, the synchronous
// divide-by-two domain of this controller. Transfer its response packet on
// the falling edge so data and ack settle before the next clk_sys edge.
reg [15:0] p3_dout_pending;
reg        p3_ack_pending;
reg [1:0]  p3_ack_hold;

reg [15:0] din_pipe_d1, din_pipe_d2;   // unused placeholder (kept for clarity)

// Request mailboxes.  Capture every transaction's metadata with its request;
// arbitration may delay a lower-priority port long after the producer pulses
// req or moves on to its next address.  This mirrors the latched per-slot
// request interfaces used by mature MiSTer SDRAM frameworks.
reg p0_pend, p1_pend, p2_pend, p3_pend, p4_pend, p5_pend, wr_pend;
reg [26:1] p0_addr_p, p3_addr_p, p4_addr_p, wr_addr_p;
reg [26:3] p1_addr_p;
reg [26:3] p5_addr_p;
reg [26:4] p2_addr_p;
reg [15:0] wr_din_p;
reg  [1:0] wr_be_p;

// Reads rotate after every grant.  This prevents continuous V60 cache misses
// from starving sprite/audio traffic while retaining the download write port
// as the sole highest-priority client (game logic is held reset during it).
reg       read_valid;
reg [2:0] read_grant;
// On the real PCB the ES5506 owns a dedicated sample ROM bus and never waits
// for anyone. Here p4 shares one controller with video and the CPU, and its
// two interpolation taps must both land inside a 16-tick voice slot: the voice
// engine paces a slot's FLOOR but cannot cap it, so a fetch that loses
// arbitration stretches the slot, slips the 32-voice scan, and drags the whole
// output stream below 31.25 kHz (measured 31,118 Hz under race load with
// round-robin, against 31,237 Hz on the zero-latency behavioural model).
// Granting p4 ahead of the rotation restores the dedicated-bus property. It
// cannot starve the others: a voice fetches at most twice per 1 us slot and
// only while it is running, so even 32 active voices ask ~2 Mword/s out of a
// ~96 MHz controller, and the rotation pointer below is deliberately NOT
// advanced on these grants so every other port keeps its place in line.
reg       sound_first;
always @* begin
    read_valid = 1'b1;
    read_grant = rr_next;
    sound_first = 1'b0;
    if (p4_pend) begin
        read_grant  = 3'd4;
        sound_first = 1'b1;
    end
    else case (rr_next)
        3'd0: if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else read_valid=0;
        3'd1: if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else read_valid=0;
        3'd2: if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else read_valid=0;
        3'd3: if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else read_valid=0;
        3'd4: if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else read_valid=0;
        default: if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else read_valid=0;
    endcase
end

// Latch each port on the RISING EDGE of its request.  The previous
// level-sampled guard (req && !pend && !ack) had a one-clk_ram drop window: a
// requester that pulses its next request in direct response to an ack (the V60
// icache fill chain does) can present a 2-cycle pulse whose first cycle is
// blocked by the still-clearing pend and whose second is blocked by the
// stretched ack — the transaction vanished and the port hung forever.  Which
// transactions hit the window depended on each ack's clk_ram parity, i.e. on
// arbitration history — so adding V25 p5 traffic could sink the V60 while
// lighter boards never faulted.  Edge-detection latches exactly once per
// request pulse (or per level-request start: the loader holds wr_req until
// wr_ack) regardless of ack overlap.
reg p0_req_d, p1_req_d, p2_req_d, p3_req_d, p4_req_d, p5_req_d, wr_req_d;
reg p0_ack_d2, p1_ack_d2, p2_ack_d2, p3_ack_d2, p4_ack_d2, p5_ack_d2, wr_ack_d2;
reg [5:0] cl_pipe;
always @(posedge clk) begin
    // Completion clears pend on the ack RISING EDGE only, and FIRST, so a
    // same-edge new request edge below overrides it (the later nonblocking
    // assignment wins).  Two hazards are closed together: (1) a chained
    // request whose rising edge lands on the very edge the previous ack
    // clears pend — the V60 icache fill pattern — latches instead of
    // vanishing; (2) the 2-cycle ack stretch must not wipe a request that
    // latched during the stretch window on the stretch's second cycle.
    p0_ack_d2 <= p0_ack; p1_ack_d2 <= p1_ack; p2_ack_d2 <= p2_ack;
    p3_ack_d2 <= p3_ack; p4_ack_d2 <= p4_ack; p5_ack_d2 <= p5_ack;
    wr_ack_d2 <= wr_ack;
    if (p0_ack && !p0_ack_d2) p0_pend <= 1'b0;
    if (p1_ack && !p1_ack_d2) p1_pend <= 1'b0;
    if (p2_ack && !p2_ack_d2) p2_pend <= 1'b0;
    if (p3_ack && !p3_ack_d2) p3_pend <= 1'b0;
    if (p4_ack && !p4_ack_d2) p4_pend <= 1'b0;
    if (p5_ack && !p5_ack_d2) p5_pend <= 1'b0;
    if (wr_ack && !wr_ack_d2) wr_pend <= 1'b0;
    p0_req_d <= p0_req; p1_req_d <= p1_req; p2_req_d <= p2_req;
    p3_req_d <= p3_req; p4_req_d <= p4_req; p5_req_d <= p5_req;
    wr_req_d <= wr_req;
    // Every s32 requester keeps at most one transaction outstanding (pulse, or
    // level held until ack), so an unqualified rising-edge latch is exact.
    if (p0_req && !p0_req_d) begin
        p0_pend <= 1'b1; p0_addr_p <= p0_addr;
    end
    if (p1_req && !p1_req_d) begin
        p1_pend <= 1'b1; p1_addr_p <= p1_addr;
    end
    if (p2_req && !p2_req_d) begin
        p2_pend <= 1'b1; p2_addr_p <= p2_addr;
    end
    if (p3_req && !p3_req_d) begin
        p3_pend <= 1'b1; p3_addr_p <= p3_addr;
    end
    if (p4_req && !p4_req_d) begin
        p4_pend <= 1'b1; p4_addr_p <= p4_addr;
    end
    if (p5_req && !p5_req_d) begin
        p5_pend <= 1'b1; p5_addr_p <= p5_addr;
    end
    if (wr_req && !wr_req_d) begin
        wr_pend <= 1'b1; wr_addr_p <= wr_addr;
        wr_din_p <= wr_din; wr_be_p <= wr_be;
    end
    if (init) begin
        {p0_pend,p1_pend,p2_pend,p3_pend,p4_pend,p5_pend,wr_pend} <= '0;
        {p0_req_d,p1_req_d,p2_req_d,p3_req_d,p4_req_d,p5_req_d,wr_req_d} <= '0;
        {p0_ack_d2,p1_ack_d2,p2_ack_d2,p3_ack_d2,p4_ack_d2,p5_ack_d2,wr_ack_d2} <= '0;
        p0_addr_p <= '0; p1_addr_p <= '0; p2_addr_p <= '0;
        p3_addr_p <= '0; p4_addr_p <= '0; p5_addr_p <= '0; wr_addr_p <= '0;
        wr_din_p <= '0; wr_be_p <= '0;
    end
end

`ifdef SIMULATION
// Contract watchdog (sim only): a request held high long after its pend
// cleared means the requester expects per-ack re-service from a level — the
// pre-edge-latch semantics.  It would receive exactly one transaction and
// hang silently in hardware; make that loud here.  Legitimate level holds
// drop within a few clk_ram of the stretched ack (clk_sys requesters take 2).
generate
    genvar gi;
    for (gi = 0; gi < 7; gi = gi + 1) begin : g_reqwatch
        reg [7:0] held;
        wire req_i  = gi==0 ? p0_req  : gi==1 ? p1_req  : gi==2 ? p2_req  :
                      gi==3 ? p3_req  : gi==4 ? p4_req  : gi==5 ? p5_req  : wr_req;
        wire pend_i = gi==0 ? p0_pend : gi==1 ? p1_pend : gi==2 ? p2_pend :
                      gi==3 ? p3_pend : gi==4 ? p4_pend : gi==5 ? p5_pend : wr_pend;
        always @(posedge clk) begin
            if (init || !req_i || pend_i) held <= 8'd0;
            else if (held != 8'hff) begin
                held <= held + 8'd1;
                if (held == 8'd200)
                    $display("SDRAM CONTRACT WARNING: port %0d req held %0d cycles after service — held levels are serviced once, not per ack", gi, held);
            end
        end
    end
endgenerate

// DQM is the shorted A[12:11] net, and DQM has 2-cycle READ latency.  The FSM
// is strictly serialised today, so A holds its CAS value for the whole return
// window by construction -- but nothing enforces that, and any future attempt
// to pipeline commands across a read would silently mask returning data.  That
// failure looks like sporadic ROM corruption, not like a protocol error, so
// make it loud here.
reg a_mask_flagged = 1'b0;
always @(posedge clk) begin
    if (init) a_mask_flagged <= 1'b0;
    else if (ready && cl_pipe != 0 && SDRAM_A[12:11] != 2'b00 && !a_mask_flagged) begin
        a_mask_flagged <= 1'b1;
        $display("SDRAM ERROR: A[12:11]=%b during read return (cl_pipe=%b) -- DQM is shorted to these pins and would mask read data",
                 SDRAM_A[12:11], cl_pipe);
        $stop;
    end
end
`endif

// Centre the SDRAM board interface with SDRAM_CLK forwarded at 180 degrees.
// Commands and write data launched here have half a cycle of setup at the
// chip. CL2 read data returns to this direct pin-to-register sample under the
// SDC input-delay and multicycle constraints, so Quartus can place dq_in in
// the input IOE. The fourth pipe tap transfers the already-registered word
// into the response buffer one cycle later without a pin-to-core critical path.
reg [15:0] dq_in;
reg [15:0] cap_buf [0:7];

always @(posedge clk) dq_in <= SDRAM_DQ;

task automatic deliver(input [15:0] final_word);
    case (grant)
        // The final buffer write and delivery share an edge.  Use the staged
        // word directly for the last lane instead of returning stale cap_buf.
        3'd0: begin p0_dout <= final_word; p0_ack <= 1'b1; end
        3'd1: begin p1_dout <= {final_word, cap_buf[2], cap_buf[1], cap_buf[0]}; p1_ack <= 1'b1; end
        3'd2: begin p2_dout <= {final_word, cap_buf[6], cap_buf[5], cap_buf[4],
                                cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]}; p2_ack <= 1'b1; end
        3'd3: begin
            p3_dout_pending <= final_word;
            p3_ack_pending   <= 1'b1;
        end
        3'd4: begin p4_dout <= final_word; p4_ack <= 1'b1; end
        // p5 is intentionally phase-transferred below on negedge clk.  Do
        // not drive its externally visible packet from this posedge process.
        3'd5: begin
            p5_dout_pending <= {final_word, cap_buf[2], cap_buf[1], cap_buf[0]};
            p5_ack_pending   <= 1'b1;
        end
        default: ;
    endcase
endtask

always @(posedge clk) begin
    cmd    <= CMD_NOP;
    dq_oe  <= 1'b0;
    // A response is a one-shot request into the negedge phase-transfer
    // register.  deliver() below may override this assignment on the same
    // edge when the final read word arrives.
    p5_ack_pending <= 1'b0;
    p3_ack_pending <= 1'b0;

    // acks: assert for 2 cycles so clk_sys (=clk/2, synchronous) always
    // samples exactly one rising edge with ack high
    if (ack_stretch != 0) ack_stretch <= ack_stretch - 1'd1;
    else begin
        p0_ack <= 1'b0; p1_ack <= 1'b0; p2_ack <= 1'b0;
        p4_ack <= 1'b0; wr_ack <= 1'b0;
    end

    if (init) begin
        init_cnt <= 16'hffff;
        ready    <= 1'b0;
        state    <= ST_IDLE;
        ref_pend <= 1'b0;
        ref_cnt  <= 10'd0;
        row_open <= 8'h00;
        for (ri = 0; ri < 8; ri = ri + 1) open_row[ri] <= 13'd0;
        pre_cnt <= 2'd0;
        chip_sel <= 1'b0;
        cl_pipe  <= 6'b000000;
        ack_stretch <= 0;
        p5_dout_pending <= '0;
        p5_ack_pending   <= 1'b0;
        p3_dout_pending <= '0;
        p3_ack_pending   <= 1'b0;
        rr_next <= 3'd0;
    end
    else if (!ready) begin
        init_cnt <= init_cnt - 1'd1;
        // Default SDRAM_A/SDRAM_BA to a fixed value on every init cycle,
        // rather than implicitly retaining the previous value when init_cnt
        // matches none of the case items below (the overwhelming majority of
        // the ~65535 init cycles). cmd already defaults to CMD_NOP every
        // cycle (top of this block), and a NOP is defined to ignore its
        // address/bank inputs (JEDEC SDR SDRAM), so this default is never
        // chip-visible -- it only removes the synthesized feedback mux
        // ("keep old value unless one of ~17 case items matches") from
        // SDRAM_A's fan-in. That mux measured a real setup violation
        // (-0.299ns, 5 logic levels, init_cnt->SDRAM_A[8]) because deciding
        // "did nothing match" required OR-ing many wide equality compares
        // before selecting retain-vs-new-value. A pure decode-then-select
        // against a fixed default needs no such OR-reduction.
        SDRAM_A  <= 13'h0000;
        SDRAM_BA <= 2'b00;
        // init: wait >100us, then PRE-all / 8x REF / MRS for EACH device.  A
        // device that never receives MRS returns garbage the moment it is first
        // addressed, and one that is never refreshed loses whatever it holds --
        // so both halves are brought up even though device 1 stays unused until
        // the sprite region moves there.
        case (init_cnt)
            // ---- device 0 ----
            16'h0800: begin chip_sel <= 1'b0; cmd <= CMD_PRE; SDRAM_A <= 13'h0400; end
            16'h07c0, 16'h0780, 16'h0740, 16'h0700,
            16'h06c0, 16'h0680, 16'h0640, 16'h0600: begin chip_sel <= 1'b0; cmd <= CMD_REF; end
            16'h0500: begin
                chip_sel <= 1'b0;
                cmd      <= CMD_MRS;
                SDRAM_BA <= 2'b00;
                SDRAM_A  <= 13'b000_0_00_010_0_000; // CL2, sequential, burst 1
            end
            // ---- device 1 ----
            16'h0400: begin chip_sel <= 1'b1; cmd <= CMD_PRE; SDRAM_A <= 13'h0400; end
            16'h03c0, 16'h0380, 16'h0340, 16'h0300,
            16'h02c0, 16'h0280, 16'h0240, 16'h0200: begin chip_sel <= 1'b1; cmd <= CMD_REF; end
            16'h00a0: begin
                chip_sel <= 1'b1;
                cmd      <= CMD_MRS;
                SDRAM_BA <= 2'b00;
                SDRAM_A  <= 13'b000_0_00_010_0_000; // CL2, sequential, burst 1
            end
            16'h0010: begin chip_sel <= 1'b0; SDRAM_A <= 13'h0000; end
            16'h0001: ready <= 1'b1;
            default: ;
        endcase
    end
    else begin
        // refresh scheduling: 8192 rows / 64ms @ 96.65MHz -> every 755 cyc
        ref_cnt <= ref_cnt + 1'd1;
        if (ref_cnt == 10'd700) begin ref_cnt <= 0; ref_pend <= 1'b1; end

        // Fourth pipe tap captures after registered command + CL2 + dq_in.
        cl_pipe <= {cl_pipe[4:0], 1'b0};
        if (cl_pipe[3]) begin
            cap_buf[rd_captured[2:0]] <= dq_in;
            rd_captured <= rd_captured + 1'd1;
            if (rd_captured + 1'd1 == rd_total) begin
                deliver(dq_in);
                ack_stretch <= 2'd1;   // hold ack this cycle + next
            end
        end

        case (state)
        ST_IDLE: begin
            if (ref_pend && cl_pipe == 0) begin
                // Both devices need refreshing, and a deselected device sees
                // nothing, so the sequence is PRE-all dev0, PRE-all dev1, tRP,
                // REF dev0, REF dev1.  ~3 extra cycles in 700 (<0.5%).
                chip_sel <= 1'b0;
                cmd <= CMD_PRE; SDRAM_A <= 13'h0400;   // A10=1: all banks
                row_open <= 8'h00;                     // both devices, all banks
                state <= ST_PRE_REF_B;
            end
            else if (wr_pend | read_valid) begin
                logic [26:1] a;
                if      (wr_pend) begin grant <= 3'd7; a = wr_addr_p;           rd_total <= 4'd1; is_write <= 1'b1; end
                else begin
                    grant <= read_grant;
                    is_write <= 1'b0;
                    // A priority sound grant is inserted into the stream, not
                    // taken from the rotation, so it must not consume the next
                    // port's turn.
                    if (!sound_first)
                        rr_next <= (read_grant == 3'd5) ? 3'd0 : read_grant + 1'd1;
                    case (read_grant)
                        3'd0: begin a = p0_addr_p;           rd_total <= 4'd1; end
                        3'd1: begin a = {p1_addr_p, 2'b00};  rd_total <= 4'd4; end
                        3'd2: begin a = {p2_addr_p, 3'b000}; rd_total <= 4'd8; end
                        3'd3: begin a = p3_addr_p;           rd_total <= 4'd1; end
                        3'd4: begin a = p4_addr_p;           rd_total <= 4'd1; end
                        default: begin a = {p5_addr_p, 2'b00}; rd_total <= 4'd4; end
                    endcase
                end
                xfer_addr <= a;
                din_r     <= wr_din_p;
                be_r      <= wr_be_p;
                rd_issued   <= 0;
                rd_captured <= 0;
                // Register arbitration before command generation.  The
                // dedicated dispatch cycle breaks the dense real-V25 path
                // from p5_pend through the six-port priority mux and row
                // decision into cmd[].  Requesters already wait for ack, so
                // the extra clk_ram cycle changes latency but not semantics.
                state <= ST_DISPATCH;
            end
        end

        ST_DISPATCH: begin
            // The row compare must include the DEVICE and must exclude
            // a[25], which is a COLUMN bit (col[9]), not a row bit.  Getting
            // either wrong reads or writes the wrong row silently.
            //
            // chip_sel is set on every path: a CAS or PRE must be aimed at the
            // device that owns the row.  Deselecting a device does not close
            // its rows, which is what makes per-device tracking valid.
            chip_sel <= xfer_addr[26];
            // This is a NOP cycle, so its address is not sampled by SDRAM.
            // Drive a fixed value on every path instead of conditionally
            // retaining the previous command address.  The conditional hold
            // made the bank-indexed row compare part of SDRAM_A's D-input
            // cone; TimeQuest measured five logic levels followed by a
            // 5.24 ns route to the fixed address DDIO cells.
            SDRAM_A  <= 13'd0;
            if (row_open[xfer_idx] && open_row[xfer_idx] == xfer_addr[22:10]) begin
                // Row hit: skip ACT and both tRCD cycles. Reads and writes
                // alike, now that reads leave the row open.
                if (is_write) state <= ST_WR;
                else          state <= ST_RD;
            end
            else if (row_open[xfer_idx]) begin
                // Register the row-conflict decision before driving the PRE
                // command pins.  This removes the row table compare from the
                // command-output cone.  Only genuine conflicts gain this one
                // NOP cycle; row hits and closed-row ACTs retain their cadence.
                state <= ST_PRE_CMD;
            end
            else begin
                state <= ST_ACT;
            end
        end

        ST_PRE_CMD: begin
            // Same-bank row miss: close only THAT bank on THAT device.
            // A10=0 selects a single bank; A[12:11] are the shorted DQM
            // pins and are don't-care for PRE.
            cmd      <= CMD_PRE;
            SDRAM_BA <= xfer_addr[24:23];
            SDRAM_A  <= 13'd0;
            row_open[xfer_idx] <= 1'b0;
            pre_cnt <= 2'd1;          // tRP >= 2 cycles before ACT
            state <= ST_PRE_XFER;
        end

        ST_PRE_XFER: begin
            if (pre_cnt == 0) state <= ST_ACT;
            else pre_cnt <= pre_cnt - 1'd1;
        end

        ST_ACT: begin
            cmd      <= CMD_ACT;
            chip_sel <= xfer_addr[26];          // device select
            SDRAM_BA <= xfer_addr[24:23];
            SDRAM_A  <= xfer_addr[22:10];       // 13 row bits
            open_row[xfer_idx] <= xfer_addr[22:10];
            row_open[xfer_idx] <= 1'b1;
            state    <= ST_RCD1;
        end

        // tRCD >= 21ns = 3 cycles ACT->READ/WRITE
        ST_RCD1: state <= ST_RCD2;
        ST_RCD2: begin
            if (is_write) state <= ST_WR;
            else          state <= ST_RD;
        end

        ST_WR: begin
            cmd      <= CMD_WRITE;
            SDRAM_BA <= xfer_addr[24:23];
            // A[12:11] = ~be  -> the shorted DQMH/DQML byte mask.
            // A[10]    = 0    -> no auto-precharge, keep row open.
            // A[9]     = a[25]-> col[9], the top address bit (see header).
            // A[8:0]   = a[9:1]
            SDRAM_A  <= {~be_r, 1'b0, xfer_addr[25], xfer_addr[9:1]};
            dq_out   <= din_r;
            dq_oe    <= 1'b1;
            // No auto-precharge is used for download writes. The conservative
            // two-cycle write-recovery gap is enough before another WRITE on
            // the same row and still leaves explicit precharge for row changes.
            wrrc_cnt <= 3'd2;
            state    <= ST_WRRC;
        end
        ST_WRRC: begin
            if (wrrc_cnt == 3'd2) begin wr_ack <= 1'b1; ack_stretch <= 2'd1; end
            if (wrrc_cnt == 0) state <= ST_IDLE;
            else wrrc_cnt <= wrrc_cnt - 1'd1;
        end

        ST_RD: begin
            // issue one READ per cycle until rd_total issued
            cmd      <= CMD_READ;
            SDRAM_BA <= xfer_addr[24:23];
            // A[12:11] MUST be 00: they are the shorted DQM pins and DQM has
            // 2-cycle read latency, so anything else here masks returning data.
            // A[10] = auto-precharge on the final CAS.  A[9] = col[9] = a[25].
            // A[10] = 0: no auto-precharge.  The row stays open for the next
            // transaction that lands on this device+bank.
            SDRAM_A  <= {2'b00, 1'b0, xfer_addr[25], xfer_addr[9:1]};
            cl_pipe[0] <= 1'b1;
            // Advance within the 9 low column bits only.  Bursts are 4 words
            // aligned to 8 bytes and 8 words aligned to 16 bytes, so the carry
            // never escapes a[4:1]; a[25] (col[9]) must not be disturbed.
            xfer_addr[9:1] <= xfer_addr[9:1] + 1'd1;
            rd_issued <= rd_issued + 1'd1;
            if (rd_issued + 1'd1 == rd_total) begin
                state <= ST_RDW;   // row left open
            end
        end
        ST_RDW: begin
            // wait for capture pipeline to finish (delivery in capture logic);
            // also cover tRC for the single-read case with the drain cycles
            if (cl_pipe == 0) state <= ST_IDLE;
        end

        ST_PRE_REF_B: begin
            chip_sel <= 1'b1;
            cmd      <= CMD_PRE; SDRAM_A <= 13'h0400;
            refw_cnt <= 3'd1;   // tRP >= 2 cycles before REF
            state    <= ST_PRE_REF;
        end
        ST_PRE_REF: begin
            if (refw_cnt == 0) begin
                chip_sel <= 1'b0;
                cmd      <= CMD_REF;
                row_open <= 8'h00;
                ref_pend <= 1'b0;
                state    <= ST_REF_B;
            end
            else refw_cnt <= refw_cnt - 1'd1;
        end
        ST_REF_B: begin
            chip_sel <= 1'b1;
            cmd      <= CMD_REF;
            refw_cnt <= 3'd6;   // tRC(ref) >= 63ns = 7 cycles; both devices
            state    <= ST_REFW; // refresh concurrently, so one wait covers them
        end
        ST_REFW: begin
            if (refw_cnt == 0) state <= ST_IDLE;
            else refw_cnt <= refw_cnt - 1'd1;
        end
        default: state <= ST_IDLE;
        endcase
    end
end

// Phase-transfer the ST010 response after the SDRAM read packet has been
// assembled.  p5_ack is held for two clk_ram cycles so a clk_sys edge always
// observes the packet after this negedge transfer, even when the response
// coincides with a clk_sys edge.
always @(negedge clk) begin
    if (init) begin
        p3_dout  <= '0;
        p3_ack   <= 1'b0;
        p3_ack_hold <= 2'd0;
        p5_dout  <= '0;
        p5_ack   <= 1'b0;
        p5_ack_hold <= 2'd0;
    end
    else begin
        if (p3_ack_pending) begin
            p3_dout     <= p3_dout_pending;
            p3_ack      <= 1'b1;
            p3_ack_hold <= 2'd2;
        end
        else if (p3_ack_hold != 0) begin
            if (p3_ack_hold == 2'd1) begin
                p3_ack      <= 1'b0;
                p3_ack_hold <= 2'd0;
            end
            else begin
                p3_ack_hold <= p3_ack_hold - 1'd1;
            end
        end
        else begin
            p3_ack <= 1'b0;
        end

        if (p5_ack_pending) begin
            p5_dout     <= p5_dout_pending;
            p5_ack      <= 1'b1;
            p5_ack_hold <= 2'd2;
        end
        else if (p5_ack_hold != 0) begin
            if (p5_ack_hold == 2'd1) begin
                p5_ack      <= 1'b0;
                p5_ack_hold <= 2'd0;
            end
            else begin
                p5_ack_hold <= p5_ack_hold - 1'd1;
            end
        end
        else begin
            p5_ack <= 1'b0;
        end
    end
end


`ifdef SIMULATION
// Kept so verif/tb_ssv_frame_crc.sv's call site still elaborates. The row-hit,
// conflict and latency histograms that used to live here instrumented the
// pre-module-contract state machine and did not survive the port; re-add them
// against this machine if the bandwidth question comes back.
task automatic sdram_dump_stats(input string tag);
    begin
        $display("=== SDRAM STATS %s ===", tag);
        $display("SDRAM_STATS unavailable: instrumentation retired with the pre-128MB-module controller");
    end
endtask
`endif

endmodule
