//============================================================================
//  Sega System 32 for MiSTer — SDRAM controller
//  16-bit SDR SDRAM @ clk_ram (96.6 MHz), CL2, strictly serialized
//  transactions. ROM-download writes keep a row open for same-row words and
//  explicitly precharge before row changes, reads, or refreshes.
//  Four request ports, CPU-tier-over-AV-tier priority (see the read_grant
//  comment below for why):
//    p0: V60 fetch/data (latency critical, 16-bit single)  -- CPU tier
//    p3: Z80 ROM         (16-bit single, byte laned)         -- CPU tier
//    p2: sprite fetch    (128-bit burst = 8 words)          -- AV tier
//    p4: MultiPCM        (16-bit single)                     -- AV tier
//  Write port (ROM download only): highest priority while ioctl_download.
//
//  A sixth port (p5, "V25 program ROM") existed here as leftover header text
//  copied from a sibling Sega System 32 core at this project's first commit.
//  Real System 24 hardware has no such subsystem (confirmed against a real
//  PCB schematic) and p5_req/p5_addr were only ever driven to zero -- removed
//  entirely, along with its s24_sdram_cdc bridge instance and dedicated
//  64-bit output register, to free fitter resources on an 87%-ALM design.
//
//  The p1 tile-fetch port was removed the same way: rtl/video/s24_tile.sv's
//  display path was switched to an on-chip character-RAM mirror and its
//  mem_req/mem_addr outputs were left permanently at zero (see git history
//  for the commit that made that switch) -- so p1_req never asserted on any
//  build. Removing the port drops its s24_sdram_cdc bridge (REQ_WIDTH 24,
//  RSP_WIDTH 64) and its round-robin slot. The remaining ports keep their
//  original numbers (p0, p2, p3, p4) rather than renumbering, matching how
//  p5 was dropped from the tail; the round-robin below simply skips grant
//  value 1 instead of ever assigning it.
//
//  REQUEST CONTRACT (all ports, including wr): one transaction per req
//  RISING EDGE; the address (and write data/be) is sampled on that edge.
//  A request held high is serviced exactly ONCE — a requester expecting
//  re-service per ack from a held level will hang.  Requesters must be
//  single-outstanding: drop req after (or pulse it before) each ack, and
//  produce a fresh rising edge for the next transaction.  ack is stretched
//  to 2 clk_ram cycles so clk_sys-domain requesters sample it exactly once.
//============================================================================

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
    output reg        p4_ack
);

reg [15:0] dq_out;
reg        dq_oe;

// Keep CKE asserted during the controller's active lifetime, but hold the
// device in clock-disabled state while the board PLL is still unlocked. This
// preserves the SDRAM protocol and keeps the physical output driven by the
// real reset/init boundary instead of collapsing to a constant VCC net.
// Registered on clk_ram like every other chip control line (cmd/SDRAM_A/
// chip_sel) rather than combinationally tapping `init` directly: `init` is
// only single-flop synchronized into this domain (see the init-cnt/state
// reset below), so an unregistered pin would let CKE glitch independently of
// the FSM's own registered NOP guarantee.
reg sdram_cke_r = 1'b0;
always @(posedge clk) sdram_cke_r <= ~init;
assign SDRAM_CKE  = sdram_cke_r;

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
    ST_WR, ST_WRRC, ST_PRE_XFER, ST_PRE_REF_B, ST_PRE_REF, ST_REF_B, ST_REFW
} state_t;
state_t state = ST_IDLE;

reg [2:0]  grant;
reg        cpu_turn;   // 0=p0(CPU-A) preferred, 1=p3(CPU-B) preferred,
                       // used only when both are pending simultaneously
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


// Request mailboxes.  Capture every transaction's metadata with its request;
// arbitration may delay a lower-priority port long after the producer pulses
// req or moves on to its next address.  This mirrors the latched per-slot
// request interfaces used by mature MiSTer SDRAM frameworks.
reg p0_pend, p2_pend, p3_pend, p4_pend, wr_pend;
reg [26:1] p0_addr_p, p3_addr_p, p4_addr_p, wr_addr_p;
reg [26:4] p2_addr_p;
reg [15:0] wr_din_p;
reg  [1:0] wr_be_p;

// Sprite fetches (p2) have strict priority, followed by the CPU ports (p0,
// p3), then the non-deadline floppy/audio port (p4).
//
// On the PCB, sprite RAM is local to the 315-5293/5295 and CPU work RAM does
// not arbitrate with its pixel fetches.  In this core both live behind one
// SDRAM controller.  Giving the emulated zero-wait CPU RAM priority can hold
// an eight-word sprite burst until after its scanline deadline; the visible
// result is one complete missing sprite scanline while tile video remains
// intact (the Crack Down spray-can/hand attract scene is a deterministic
// reproducer).  A sprite burst is only about 13 clk_ram cycles and cannot be
// preempted once granted, so granting an already-pending p2 first models the
// original independent path without changing burst timing or CPU-to-CPU
// fairness.  p4 remains last: unlike sprite rendering it has no active-raster
// deadline, and the core already limits speculative floppy read-ahead to
// vertical blank.
reg       read_valid;
reg [2:0] read_grant;
always @* begin
    read_valid = 1'b1;
    if (p2_pend)                 read_grant = 3'd2;
    else if (p0_pend && p3_pend) read_grant = cpu_turn ? 3'd3 : 3'd0;
    else if (p0_pend)            read_grant = 3'd0;
    else if (p3_pend)            read_grant = 3'd3;
    else if (p4_pend)            read_grant = 3'd4;
    else begin
        read_grant = 3'd0;
        read_valid = 1'b0;
    end
end

// Latch each port on the RISING EDGE of its request.  The previous
// level-sampled guard (req && !pend && !ack) had a one-clk_ram drop window: a
// requester that pulses its next request in direct response to an ack (the V60
// icache fill chain does) can present a 2-cycle pulse whose first cycle is
// blocked by the still-clearing pend and whose second is blocked by the
// stretched ack — the transaction vanished and the port hung forever.  Which
// transactions hit the window depended on each ack's clk_ram parity, i.e. on
// arbitration history — so heavier read traffic on any port could sink the
// V60 while lighter boards never faulted.  Edge-detection latches exactly once per
// request pulse (or per level-request start: the loader holds wr_req until
// wr_ack) regardless of ack overlap.
reg p0_req_d, p2_req_d, p3_req_d, p4_req_d, wr_req_d;
reg p0_ack_d2, p2_ack_d2, p3_ack_d2, p4_ack_d2, wr_ack_d2;
always @(posedge clk) begin
    // Completion clears pend on the ack RISING EDGE only, and FIRST, so a
    // same-edge new request edge below overrides it (the later nonblocking
    // assignment wins).  Two hazards are closed together: (1) a chained
    // request whose rising edge lands on the very edge the previous ack
    // clears pend — the V60 icache fill pattern — latches instead of
    // vanishing; (2) the 2-cycle ack stretch must not wipe a request that
    // latched during the stretch window on the stretch's second cycle.
    p0_ack_d2 <= p0_ack; p2_ack_d2 <= p2_ack;
    p3_ack_d2 <= p3_ack; p4_ack_d2 <= p4_ack;
    wr_ack_d2 <= wr_ack;
    if (p0_ack && !p0_ack_d2) p0_pend <= 1'b0;
    if (p2_ack && !p2_ack_d2) p2_pend <= 1'b0;
    if (p3_ack && !p3_ack_d2) p3_pend <= 1'b0;
    if (p4_ack && !p4_ack_d2) p4_pend <= 1'b0;
    if (wr_ack && !wr_ack_d2) wr_pend <= 1'b0;
    p0_req_d <= p0_req; p2_req_d <= p2_req;
    p3_req_d <= p3_req; p4_req_d <= p4_req;
    wr_req_d <= wr_req;
    // Every s32 requester keeps at most one transaction outstanding (pulse, or
    // level held until ack), so an unqualified rising-edge latch is exact.
    if (p0_req && !p0_req_d) begin
        p0_pend <= 1'b1; p0_addr_p <= p0_addr;
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
    if (wr_req && !wr_req_d) begin
        wr_pend <= 1'b1; wr_addr_p <= wr_addr;
        wr_din_p <= wr_din; wr_be_p <= wr_be;
    end
    if (init) begin
        {p0_pend,p2_pend,p3_pend,p4_pend,wr_pend} <= '0;
        {p0_req_d,p2_req_d,p3_req_d,p4_req_d,wr_req_d} <= '0;
        {p0_ack_d2,p2_ack_d2,p3_ack_d2,p4_ack_d2,wr_ack_d2} <= '0;
        p0_addr_p <= '0; p2_addr_p <= '0;
        p3_addr_p <= '0; p4_addr_p <= '0; wr_addr_p <= '0;
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
    for (gi = 0; gi < 5; gi = gi + 1) begin : g_reqwatch
        reg [7:0] held;
        wire req_i  = gi==0 ? p0_req  : gi==1 ? p2_req  :
                      gi==2 ? p3_req  : gi==3 ? p4_req  : wr_req;
        wire pend_i = gi==0 ? p0_pend : gi==1 ? p2_pend :
                      gi==2 ? p3_pend : gi==3 ? p4_pend : wr_pend;
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
// chip. CL2 read data returns to this direct pin-to-register sample; the
// SDRAM_CLK generated clock and the SDRAM_DQ input delays that bound it live
// in Arcade-SegaSystem24.sdc, and sys/sys.tcl:95 forces dq_in into the input
// IOE. The budget is exactly half a clk_ram period (5.21 ns) for tAC(CL2)
// plus board flight, and back-to-back READs in a burst have no more than
// that -- unlike an isolated read, whose word stays on the floating bus long
// after the SDRAM stops driving. The fourth pipe tap transfers the word
// into the response buffer one cycle later without a pin-to-core critical path.
reg [15:0] dq_in;
reg [3:0]  cl_pipe;
reg [15:0] cap_buf [0:7];

// Capture DQ on the rising clk_ram edge.
//
// A falling-edge capture (moving the sample point half a period later, to sit
// nearer the centre of the tAC(CL2) valid window for burst reads) was tried
// and hardware-tested bundled with an SDRAM_CLK DDIO-forwarding change in the
// same build. That build made sprite rendering WORSE on real hardware --
// sprites went from corrupt-but-visible to entirely invisible, and Gain
// Ground went to a black screen -- a regression from the last hardware-
// confirmed-good state (this posedge capture, direct PLL-tap SDRAM_CLK, and
// the s24_sdram_cdc multicycle constraint). The same test run also revealed
// rtl/pll/synthesis/submodules/pll_pll_inst.v (generated PLL IP) had been
// edited to explicitly wire previously-unconnected optional ports -- a
// change forbidden by this project's own rules and a known real cause of
// hardware-only failures elsewhere -- and that edit was present for every
// hardware round this session, so it cannot be ruled out as a contributing
// cause. Both unproven changes were reverted together rather than guessing
// which one to keep. Re-attempt falling-edge capture and/or DDIO forwarding
// only as an isolated, independently hardware-tested change once the design
// is back to a confirmed-good baseline.
always @(posedge clk) dq_in <= SDRAM_DQ;

task automatic deliver(input [15:0] final_word);
    case (grant)
        // The final buffer write and delivery share an edge.  Use the staged
        // word directly for the last lane instead of returning stale cap_buf.
        3'd0: begin p0_dout <= final_word; p0_ack <= 1'b1; end
        3'd2: begin p2_dout <= {final_word, cap_buf[6], cap_buf[5], cap_buf[4],
                                cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]}; p2_ack <= 1'b1; end
        3'd3: begin p3_dout <= final_word; p3_ack <= 1'b1; end
        3'd4: begin p4_dout <= final_word; p4_ack <= 1'b1; end
        default: ;
    endcase
endtask

always @(posedge clk) begin
    cmd    <= CMD_NOP;
    dq_oe  <= 1'b0;

    // acks: assert for 2 cycles so clk_sys (=clk/2, synchronous) always
    // samples exactly one rising edge with ack high
    if (ack_stretch != 0) ack_stretch <= ack_stretch - 1'd1;
    else begin
        p0_ack <= 1'b0; p2_ack <= 1'b0;
        p3_ack <= 1'b0; p4_ack <= 1'b0; wr_ack <= 1'b0;
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
        cl_pipe  <= 4'b0000;
        ack_stretch <= 0;
        cpu_turn <= 1'b0;
    end
    else if (!ready) begin
        init_cnt <= init_cnt - 1'd1;
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

        // Read capture after CL2 and the centred IOE register above.
        cl_pipe <= {cl_pipe[2:0], 1'b0};
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
                // A pending sprite burst owns the deadline even when a CPU
                // or FDC write is queued. Writes are serialized here only
                // because the FPGA implementation shares SDRAM; they do not
                // contend with local sprite RAM on the original board.
                if (p2_pend) begin
                    grant <= 3'd2;
                    a = {p2_addr_p, 3'b000};
                    rd_total <= 4'd8;
                    is_write <= 1'b0;
                end
                else if (wr_pend) begin grant <= 3'd7; a = wr_addr_p;           rd_total <= 4'd1; is_write <= 1'b1; end
                else begin
                    grant <= read_grant;
                    is_write <= 1'b0;
                    // Flip the CPU tie-breaker after either CPU grant. A lone
                    // repeatedly-pending port is unaffected; fairness only
                    // matters when both CPU ports contend.
                    if (read_grant == 3'd0 || read_grant == 3'd3)
                        cpu_turn <= ~cpu_turn;
                    case (read_grant)
                        3'd0: begin a = p0_addr_p;           rd_total <= 4'd1; end
                        3'd2: begin a = {p2_addr_p, 3'b000}; rd_total <= 4'd8; end
                        3'd3: begin a = p3_addr_p;           rd_total <= 4'd1; end
                        default: begin a = p4_addr_p;        rd_total <= 4'd1; end
                    endcase
                end
                xfer_addr <= a;
                din_r     <= wr_din_p;
                be_r      <= wr_be_p;
                rd_issued   <= 0;
                rd_captured <= 0;
                // Register arbitration before command generation.  The
                // dedicated dispatch cycle breaks the dense path from any
                // pend flag through the five-port priority mux and row
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
            if (row_open[xfer_idx] && open_row[xfer_idx] == xfer_addr[22:10]) begin
                // Row hit: skip ACT and both tRCD cycles. Reads and writes
                // alike, now that reads leave the row open.
                state <= is_write ? ST_WR : ST_RD;
            end
            else if (row_open[xfer_idx]) begin
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
            else begin
                state <= ST_ACT;
            end
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
        ST_RCD2: state <= is_write ? ST_WR : ST_RD;

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
            // Issue one READ per cycle, back-to-back, for the whole burst.
            //
            // The chip's mode register selects BURST_1 (rtl/mem/sdram.sv
            // MRS init), so every word of an "8-word burst" is actually an
            // independent burst-length-1 transaction -- there is no chip-
            // internal burst counter driving these words out, this FSM
            // fakes it by re-issuing READ every cycle.
            //
            // A one-cycle gap (ST_RD_GAP) was inserted here for a session
            // that traced hardware-only sprite corruption to this back-to-
            // back issuance, on the theory that each transaction's CL2
            // response window landed exactly where the next transaction's
            // response began driving the bus. That diagnosis did not
            // survive: quartus_sta against the fitted netlist showed the
            // capture path (SDRAM_DQ -> dq_in, see the dq_in comment above)
            // failing setup by -9.062ns/TNS -142.306 at every corner --
            // the ENTIRE clk_ram-domain timing failure, and unrelated to
            // burst spacing, since spacing out READs does not change the
            // clk_ram-edge-to-dq_in relationship for any individual word.
            // The real defect was the input-delay constraint modelling
            // capture a full clk_ram cycle before the SDRAM_CLK forwarding
            // latency makes data available; Arcade-SegaSystem24.sdc now
            // declares that relationship with set_multicycle_path, which
            // measured clean at +1.286ns/TNS 0.000 at the same corner with
            // NO RTL change. The corruption that prompted this gap was
            // later re-diagnosed as an unrelated RTL bug (sprite descriptor
            // packing dropping tile_base/palette_base) that produced solid
            // colour boxes, not per-word bus contention, and was fixed in
            // rtl/video/s24_sprite.sv's pack_word/unpack_word.
            //
            // Back-to-back BURST_1 READs are JEDEC-legal (a seamless read
            // stream); the chip does not disable its output drivers between
            // them. The 1-cycle gap bought no capture margin and only cost
            // throughput -- ~13 clk_ram cycles/burst -> ~20 (docs/status.md,
            // s24_sprite.sv's 1024-sprites/line cache ceiling), which
            // measurably slowed 68000 bus cycles that arbitrate against
            // sprite bursts during gameplay. Removing it restores the
            // uncontended per-burst cost; the DQ capture margin comes from
            // the SDC multicycle, not from spacing. If a genuine capture
            // margin regression is ever observed on hardware, re-add
            // spacing as its own isolated, hardware-tested change --
            // do not restore it blind alongside other work.
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
            end else begin
                state <= ST_RD;    // next word, back-to-back
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

endmodule
