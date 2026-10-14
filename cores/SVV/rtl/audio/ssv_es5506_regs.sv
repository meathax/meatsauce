// SPDX-License-Identifier: GPL-3.0-or-later
// Ensoniq ES5506 (OTTO) host interface and register file.
//
// This is original RTL based on the Ensoniq OTTO Specification Rev. 2.3.
// Register masks and reset behavior were cross-checked against MAME's
// BSD-3-Clause es5506.cpp and the zlib-licensed vgsound_emu ES550x model.
// See docs/ES5506_RESEARCH.md.
//
// Voice banks are explicit 32xW MLAB simple-dual-port RAMs (ssv_mlab32_sdp).
// One shared rd_addr: engine refresh, or host byte-0 steal.  Registered MLAB
// reads add one cycle before read_latch fills (ssv_core sound path waits 2).

`timescale 1ns/1ps

module ssv_es5506_regs (
    input  logic        clk,
    input  logic        rst,
    // cold_rst is the power/download reset.  A watchdog reset is a device
    // reset in MAME and must not erase the voice register banks.
    input  logic        cold_rst,

    input  logic        host_we,
    input  logic        host_re,
    input  logic [5:0]  host_addr,
    input  logic [7:0]  host_wdata,
    output logic [7:0]  host_rdata,

    input  logic [9:0]  par_data,
    input  logic        irq_set,
    input  logic [4:0]  irq_voice,
    output logic        irq_n,

    output logic [6:0]  current_page,
    output logic [4:0]  active_voices,
    output logic [4:0]  mode,
    output logic [6:0]  word_clock_start,
    output logic [6:0]  word_clock_end,
    output logic [6:0]  lr_clock_end,

    output logic        commit,
    output logic [6:0]  commit_page,
    output logic [3:0]  commit_reg,
    output logic [31:0] commit_data,
    // Voice-engine port (registered read of current voice; writeback next state).
    input  logic [4:0]  eng_voice,
    // Pulses the one cycle the engine actually latches eng_voice's
    // registers (S_START). Marks the instant it is safe to forget any
    // earlier "host wrote a fresher value" tracking for that voice.
    input  logic         eng_snap,
    // High only when the shared MLAB read port is clean for eng_voice: no
    // host read-steal/hold in flight and no commit to this voice in the
    // last two cycles. The voice engine must not snapshot while low (see
    // the snapshot hold-off comment at snap_ok's assign).
    output logic        snap_ok,
    output logic [15:0] eng_cr,
    output logic        eng_cr_valid,
    output logic [16:0] eng_fc,
    output logic [15:0] eng_lvol,
    output logic [7:0]  eng_lvramp,
    output logic [15:0] eng_rvol,
    output logic [7:0]  eng_rvramp,
    output logic [8:0]  eng_ecount,
    output logic [15:0] eng_k1,
    output logic [8:0]  eng_k1ramp,
    output logic [15:0] eng_k2,
    output logic [8:0]  eng_k2ramp,
    output logic [31:0] eng_start,
    output logic [31:0] eng_end,
    output logic [31:0] eng_accum,
    output logic [17:0] eng_o4n1,
    output logic [17:0] eng_o3n1,
    output logic [17:0] eng_o3n2,
    output logic [17:0] eng_o2n1,
    output logic [17:0] eng_o2n2,
    output logic [17:0] eng_o1n1,

    input  logic        eng_wr_accum,
    input  logic [31:0] eng_accum_w,
    input  logic        eng_wr_cr,
    // Engine CR writeback as set/clear masks (see ssv_es5506_voice.sv's
    // port comment): applied over the live register so the engine's
    // one-shot transitions and concurrent host CR writes compose instead of
    // clobbering each other.
    input  logic [15:0] eng_cr_set,
    input  logic [15:0] eng_cr_clr,
    input  logic        eng_wr_filt,
    input  logic [17:0] eng_o4n1_w,
    input  logic [17:0] eng_o3n1_w,
    input  logic [17:0] eng_o3n2_w,
    input  logic [17:0] eng_o2n1_w,
    input  logic [17:0] eng_o2n2_w,
    input  logic [17:0] eng_o1n1_w,
    input  logic        eng_wr_env,
    input  logic [15:0] eng_lvol_w,
    input  logic [15:0] eng_rvol_w,
    input  logic [15:0] eng_k1_w,
    input  logic [15:0] eng_k2_w,
    input  logic [8:0]  eng_ecount_w
);

logic [31:0] write_latch;
logic [31:0] read_latch;
logic  [7:0] irq_vector;
`ifdef SIMULATION
// Telemetry only (never read by hardware logic): IRQV poll/promotion/race
// rates, so a replay can report whether the driver polls IRQV at all and how
// often the acknowledge race is actually hit.
logic [31:0] dbg_irqv_reads = 32'd0;
logic [31:0] dbg_irqv_promotions = 32'd0;
logic [31:0] dbg_irqv_races = 32'd0;
logic [31:0] dbg_stale_mask_hits = 32'd0;
final $display("ES5506_STALE_CR_MASK_TOTAL=%0d", dbg_stale_mask_hits);
`endif
logic [31:0] voice_control_valid;
logic        cold_init_active;
logic [4:0]  cold_init_voice;

wire [1:0] host_byte = host_addr[1:0];
wire [3:0] host_reg  = host_addr[5:2];
wire [4:0] voice     = current_page[4:0];

wire host_rd_steal = host_re && (host_byte == 2'd0);
wire host_commit   = host_we && (host_byte == 2'd3);

logic [31:0] assembled_write;
always_comb begin
    assembled_write = write_latch;
    unique case (host_byte)
        2'd0: assembled_write[31:24] = host_wdata;
        2'd1: assembled_write[23:16] = host_wdata;
        2'd2: assembled_write[15:8]  = host_wdata;
        2'd3: assembled_write[7:0]   = host_wdata;
    endcase
end

// Shared MLAB read address: host byte-0 steals one cycle for PAGE voice.
wire [4:0] rd_addr = host_rd_steal ? voice : eng_voice;

logic [15:0] q_control;
logic [16:0] q_fc;
logic [15:0] q_lvol;
logic  [7:0] q_lvramp;
logic [15:0] q_rvol;
logic  [7:0] q_rvramp;
logic  [8:0] q_ecount;
logic [15:0] q_k2;
logic  [8:0] q_k2ramp;
logic [15:0] q_k1;
logic  [8:0] q_k1ramp;
logic [31:0] q_start;
logic [31:0] q_end;
logic [31:0] q_accum;
logic [17:0] q_o4n1;
logic [17:0] q_o3n1;
logic [17:0] q_o3n2;
logic [17:0] q_o2n1;
logic [17:0] q_o2n2;
logic [17:0] q_o1n1;

logic        we_control, we_fc, we_lvol, we_lvramp, we_rvol, we_rvramp;
logic        we_ecount, we_k2, we_k2ramp, we_k1, we_k1ramp;
logic        we_start, we_end, we_accum;
logic        we_o4n1, we_o3n1, we_o3n2, we_o2n1, we_o2n2, we_o1n1;
logic [4:0]  wr_addr;
logic [15:0] w_control;
logic [16:0] w_fc;
logic [15:0] w_lvol;
logic  [7:0] w_lvramp;
logic [15:0] w_rvol;
logic  [7:0] w_rvramp;
logic  [8:0] w_ecount;
logic [15:0] w_k2;
logic  [8:0] w_k2ramp;
logic [15:0] w_k1;
logic  [8:0] w_k1ramp;
logic [31:0] w_start;
logic [31:0] w_end;
logic [31:0] w_accum;
logic [17:0] w_o4n1;
logic [17:0] w_o3n1;
logic [17:0] w_o3n2;
logic [17:0] w_o2n1;
logic [17:0] w_o2n2;
logic [17:0] w_o1n1;

logic host_rd_pending;
logic [6:0] page_r;
logic [3:0] reg_r;
logic [7:0] irqv_r;

// Hold engine snapshot while MLAB q carries the host-steal read.
logic        eng_hold;
logic [15:0] eng_cr_h;
logic        eng_cr_valid_h;
logic [16:0] eng_fc_h;
logic [15:0] eng_lvol_h;
logic  [7:0] eng_lvramp_h;
logic [15:0] eng_rvol_h;
logic  [7:0] eng_rvramp_h;
logic  [8:0] eng_ecount_h;
logic [15:0] eng_k1_h;
logic  [8:0] eng_k1ramp_h;
logic [15:0] eng_k2_h;
logic  [8:0] eng_k2ramp_h;
logic [31:0] eng_start_h;
logic [31:0] eng_end_h;
logic [31:0] eng_accum_h;
logic [17:0] eng_o4n1_h;
logic [17:0] eng_o3n1_h;
logic [17:0] eng_o3n2_h;
logic [17:0] eng_o2n1_h;
logic [17:0] eng_o2n2_h;
logic [17:0] eng_o1n1_h;

// Host byte-3 commits and engine state advances share the MLAB write ports.
// Preserve a coincident engine transaction for replay on the following clock;
// per-field masks keep the host authoritative when both update the same field.
logic        eng_pending;
logic [4:0]  pend_voice;
logic        pend_accum;
logic        pend_lvol, pend_rvol, pend_k1, pend_k2, pend_ecount;
logic        pend_o4n1, pend_o3n1, pend_o3n2;
logic        pend_o2n1, pend_o2n2, pend_o1n1;
logic [31:0] pend_accum_w;
logic [15:0] pend_lvol_w, pend_rvol_w, pend_k1_w, pend_k2_w;
logic [8:0]  pend_ecount_w;
logic [17:0] pend_o4n1_w, pend_o3n1_w, pend_o3n2_w;
logic [17:0] pend_o2n1_w, pend_o2n2_w, pend_o1n1_w;

wire eng_write_any = eng_wr_accum | eng_wr_filt | eng_wr_env;

// Engine-owned CR bits: STOP0(0), LEI(2), LPE(3), BLE(4), DIR(6), IRQ(7).
// The engine's end-of-sample transitions touch only these. They are held as
// per-voice sticky set/clear masks in flops -- never through the shared MLAB
// write port, so they can never collide with a host commit and can never be
// dropped. Every CR consumer (engine snapshot, host readback) sees the masks
// applied combinationally; the masks are flushed into the MLAB at the
// voice's next snapshot when the port is free, and a host CR write to the
// voice clears them (the host's later, complete value supersedes the
// transition, exactly as MAME's serialized write ordering would).
function automatic [5:0] cr_pack(input [15:0] m);
    cr_pack = {m[7], m[6], m[4], m[3], m[2], m[0]};
endfunction
function automatic [15:0] cr_unpack(input [5:0] m);
    cr_unpack = {8'd0, m[5], m[4], 1'b0, m[3], m[2], m[1], 1'b0, m[0]};
endfunction
function automatic [15:0] cr_apply(input [15:0] v,
                                   input [5:0] eset, input [5:0] eclr);
    cr_apply = (v | cr_unpack(eset)) & ~cr_unpack(eclr);
endfunction
logic [5:0] cr_eset [32];
logic [5:0] cr_eclr [32];
wire  [5:0] cr_eset_ev = cr_eset[eng_voice];
wire  [5:0] cr_eclr_ev = cr_eclr[eng_voice];
wire        cr_masks_nz_ev = |{cr_eset_ev, cr_eclr_ev};

// The voice engine is a single sequential state machine: it snapshots one
// voice's registers at S_START and writes derived state back several ce
// ticks later at S_MIX. The pend_*/eng_pending scaffolding above only
// protects a host commit that lands on the *same* clock cycle as an engine
// writeback -- nothing previously protected a host write landing a few
// cycles into that in-flight window, so the engine's stale writeback would
// silently clobber a fresh host register write (e.g. a note-on rewriting
// ACCUM/K1/K2 while that voice was already mid-scan). One bit per voice per
// register group tracks "host wrote a fresher value since this voice's
// snapshot"; set on any host commit to that field, cleared only at the next
// snapshot of that voice (eng_snap), and consulted by every engine
// writeback path before it is allowed to touch the register file. See
// docs/debug/ES5506_WARPED_NOTES_ROOT_CAUSE_20260819.md.
logic [31:0] host_fresh_accum;
logic [31:0] host_fresh_lvol, host_fresh_rvol, host_fresh_k1, host_fresh_k2;
logic [31:0] host_fresh_ecount;
logic [31:0] host_fresh_o4n1, host_fresh_o3n1, host_fresh_o3n2;
logic [31:0] host_fresh_o2n1, host_fresh_o2n2, host_fresh_o1n1;

// The engine snapshot reads the MLAB through a registered address plus the
// read_latch stage: the data captured at eng_snap reflects memory as of the
// END OF THE CYCLE BEFORE LAST. A host commit on the immediately preceding
// cycle is therefore invisible to that snapshot -- but eng_snap used to clear
// the voice's host_fresh_* bits anyway, so the engine's later writeback
// reverted the host's write (a lost mute, a lost ACCUM restart). Worse, the
// synthesized MLAB's mixed-port read-during-write is DONT_CARE, so silicon
// and the behavioural model genuinely disagree in that window: the defect is
// timing-random on hardware and near-invisible in simulation. Keep a
// one-cycle-delayed record of the last commit and re-assert its fresh bit
// after the snapshot clear (NBA ordering: the later assignment wins), so a
// write the snapshot could not see keeps its protection until the NEXT
// snapshot, exactly matching MAME's fully serialized write-then-sample order.
logic        d_commit;
logic [4:0]  d_voice;
logic        d_cr;
logic        d_accum, d_lvol, d_rvol, d_k1, d_k2, d_ecount;
logic        d_o4n1, d_o3n1, d_o3n2, d_o2n1, d_o2n2, d_o1n1;

// A scan whose snapshot missed a host CR write (same cycle or the cycle
// before) computed its loop/stop transitions from a stale CR. Its CR mask
// merge and flush must be voided for that pass -- the next snapshot redoes
// the work from the stored (new) value, which is MAME's serialization.
logic [31:0] cr_scan_void;
wire cr_commit_now  = host_commit && (host_reg == 4'h0) && (current_page < 7'h40);
wire cr_snap_missed = (d_commit && d_cr && (d_voice == eng_voice)) ||
                      (cr_commit_now && (voice == eng_voice));

// Snapshot hold-off. The 2026-08-27 hardware video (drifto94, WB detector)
// caught the voice engine consuming another voice's ACCUM at S_START while
// its stored value and bounds were clean, then writing foreign+FC back --
// the random warped/extra-sound teleport. The common factor is the snapshot
// colliding with a host read-steal of the shared MLAB read port (real
// hardware reads the ES5506 ~840x/s; MAME's map shows almost none, so no
// sim reproduced it) or with a same-voice commit still settling into the
// MLAB. Rather than patching each alignment of the steal/hold/commit
// windows, refuse to snapshot until the port has been quiet for the full
// hold span and no commit touched this voice in the last two cycles: the
// engine simply waits in S_START (its 16-tick slot has ~7 spare ticks, and
// a read occupies four clocks, so the wait is invisible). This serializes
// host access against the snapshot exactly as MAME's ordering does, and it
// also closes the same-edge MLAB read-during-write capture window and the
// stale-_h fresh-bit gap by construction.
assign snap_ok = !host_rd_steal && !host_rd_pending && !eng_hold &&
                 !(host_commit && (current_page < 7'h40) &&
                   (voice == eng_voice)) &&
                 !(d_commit && (d_voice == eng_voice));

always_ff @(posedge clk) begin
    if (rst) begin
        host_fresh_accum   <= '0;
        host_fresh_lvol    <= '0;
        host_fresh_rvol    <= '0;
        host_fresh_k1      <= '0;
        host_fresh_k2      <= '0;
        host_fresh_ecount  <= '0;
        host_fresh_o4n1    <= '0;
        host_fresh_o3n1    <= '0;
        host_fresh_o3n2    <= '0;
        host_fresh_o2n1    <= '0;
        host_fresh_o2n2    <= '0;
        host_fresh_o1n1    <= '0;
    end else begin
        // Clear first, then let a same-cycle host commit for this same
        // voice re-set the field it targets -- the later nonblocking
        // assignment in program order wins, so "set" always beats "clear"
        // on a same-cycle race. Never lose a fresh host write.
        if (eng_snap) begin
            host_fresh_accum[eng_voice]   <= 1'b0;
            host_fresh_lvol[eng_voice]    <= 1'b0;
            host_fresh_rvol[eng_voice]    <= 1'b0;
            host_fresh_k1[eng_voice]      <= 1'b0;
            host_fresh_k2[eng_voice]      <= 1'b0;
            host_fresh_ecount[eng_voice]  <= 1'b0;
            host_fresh_o4n1[eng_voice]    <= 1'b0;
            host_fresh_o3n1[eng_voice]    <= 1'b0;
            host_fresh_o3n2[eng_voice]    <= 1'b0;
            host_fresh_o2n1[eng_voice]    <= 1'b0;
            host_fresh_o2n2[eng_voice]    <= 1'b0;
            host_fresh_o1n1[eng_voice]    <= 1'b0;
        end
        if (host_commit) begin
            if (we_accum)   host_fresh_accum[voice]   <= 1'b1;
            if (we_lvol)    host_fresh_lvol[voice]    <= 1'b1;
            if (we_rvol)    host_fresh_rvol[voice]    <= 1'b1;
            if (we_k1)      host_fresh_k1[voice]      <= 1'b1;
            if (we_k2)      host_fresh_k2[voice]      <= 1'b1;
            if (we_ecount)  host_fresh_ecount[voice]  <= 1'b1;
            if (we_o4n1)    host_fresh_o4n1[voice]    <= 1'b1;
            if (we_o3n1)    host_fresh_o3n1[voice]    <= 1'b1;
            if (we_o3n2)    host_fresh_o3n2[voice]    <= 1'b1;
            if (we_o2n1)    host_fresh_o2n1[voice]    <= 1'b1;
            if (we_o2n2)    host_fresh_o2n2[voice]    <= 1'b1;
            if (we_o1n1)    host_fresh_o1n1[voice]    <= 1'b1;
        end
        // Re-assert the previous cycle's commit after a same-cycle snapshot
        // clear: that write is invisible to the snapshot data (see the
        // d_commit declaration comment), so its protection must survive
        // until the voice's NEXT snapshot. Last NBA assignment wins.
        if (d_commit) begin
            if (d_accum)  host_fresh_accum[d_voice]  <= 1'b1;
            if (d_lvol)   host_fresh_lvol[d_voice]   <= 1'b1;
            if (d_rvol)   host_fresh_rvol[d_voice]   <= 1'b1;
            if (d_k1)     host_fresh_k1[d_voice]     <= 1'b1;
            if (d_k2)     host_fresh_k2[d_voice]     <= 1'b1;
            if (d_ecount) host_fresh_ecount[d_voice] <= 1'b1;
            if (d_o4n1)   host_fresh_o4n1[d_voice]   <= 1'b1;
            if (d_o3n1)   host_fresh_o3n1[d_voice]   <= 1'b1;
            if (d_o3n2)   host_fresh_o3n2[d_voice]   <= 1'b1;
            if (d_o2n1)   host_fresh_o2n1[d_voice]   <= 1'b1;
            if (d_o2n2)   host_fresh_o2n2[d_voice]   <= 1'b1;
            if (d_o1n1)   host_fresh_o1n1[d_voice]   <= 1'b1;
        end
    end
end

// Delayed record of the last host commit (one commit per cycle at most).
always_ff @(posedge clk) begin
    if (rst) begin
        d_commit <= 1'b0;
        d_cr     <= 1'b0;
        {d_accum, d_lvol, d_rvol, d_k1, d_k2, d_ecount} <= '0;
        {d_o4n1, d_o3n1, d_o3n2, d_o2n1, d_o2n2, d_o1n1} <= '0;
        d_voice  <= '0;
    end
    else begin
        d_commit <= host_commit;
        d_voice  <= voice;
        d_cr     <= cr_commit_now;
        d_accum  <= host_commit && we_accum;
        d_lvol   <= host_commit && we_lvol;
        d_rvol   <= host_commit && we_rvol;
        d_k1     <= host_commit && we_k1;
        d_k2     <= host_commit && we_k2;
        d_ecount <= host_commit && we_ecount;
        d_o4n1   <= host_commit && we_o4n1;
        d_o3n1   <= host_commit && we_o3n1;
        d_o3n2   <= host_commit && we_o3n2;
        d_o2n1   <= host_commit && we_o2n1;
        d_o2n2   <= host_commit && we_o2n2;
        d_o1n1   <= host_commit && we_o1n1;
    end
end

// The engine (and, via the _h snapshot, a held steal cycle) always sees
// pending CR masks applied -- an unflushed STOP/LEI is real state.
assign eng_cr       = cr_apply(eng_hold ? eng_cr_h : q_control,
                               cr_eset_ev, cr_eclr_ev);
assign eng_cr_valid = (eng_hold ? eng_cr_valid_h : voice_control_valid[eng_voice]) &&
                      !cold_init_active;
assign eng_fc       = eng_hold ? eng_fc_h       : q_fc;
assign eng_lvol     = eng_hold ? eng_lvol_h     : q_lvol;
assign eng_lvramp   = eng_hold ? eng_lvramp_h   : q_lvramp;
assign eng_rvol     = eng_hold ? eng_rvol_h     : q_rvol;
assign eng_rvramp   = eng_hold ? eng_rvramp_h   : q_rvramp;
assign eng_ecount   = eng_hold ? eng_ecount_h   : q_ecount;
assign eng_k1       = eng_hold ? eng_k1_h       : q_k1;
assign eng_k1ramp   = eng_hold ? eng_k1ramp_h   : q_k1ramp;
assign eng_k2       = eng_hold ? eng_k2_h       : q_k2;
assign eng_k2ramp   = eng_hold ? eng_k2ramp_h   : q_k2ramp;
assign eng_start    = eng_hold ? eng_start_h    : q_start;
assign eng_end      = eng_hold ? eng_end_h      : q_end;
assign eng_accum    = eng_hold ? eng_accum_h    : q_accum;
assign eng_o4n1     = eng_hold ? eng_o4n1_h     : q_o4n1;
assign eng_o3n1     = eng_hold ? eng_o3n1_h     : q_o3n1;
assign eng_o3n2     = eng_hold ? eng_o3n2_h     : q_o3n2;
assign eng_o2n1     = eng_hold ? eng_o2n1_h     : q_o2n1;
assign eng_o2n2     = eng_hold ? eng_o2n2_h     : q_o2n2;
assign eng_o1n1     = eng_hold ? eng_o1n1_h     : q_o1n1;

always_comb begin
    we_control = 1'b0;
    we_fc = 1'b0;
    we_lvol = 1'b0;
    we_lvramp = 1'b0;
    we_rvol = 1'b0;
    we_rvramp = 1'b0;
    we_ecount = 1'b0;
    we_k2 = 1'b0;
    we_k2ramp = 1'b0;
    we_k1 = 1'b0;
    we_k1ramp = 1'b0;
    we_start = 1'b0;
    we_end = 1'b0;
    we_accum = 1'b0;
    we_o4n1 = 1'b0;
    we_o3n1 = 1'b0;
    we_o3n2 = 1'b0;
    we_o2n1 = 1'b0;
    we_o2n2 = 1'b0;
    we_o1n1 = 1'b0;
    wr_addr = eng_voice;
    w_control = 16'd0;
    w_fc = 17'd0;
    w_lvol = eng_lvol_w;
    w_lvramp = 8'd0;
    w_rvol = eng_rvol_w;
    w_rvramp = 8'd0;
    w_ecount = eng_ecount_w;
    w_k2 = eng_k2_w;
    w_k2ramp = 9'd0;
    w_k1 = eng_k1_w;
    w_k1ramp = 9'd0;
    w_start = 32'd0;
    w_end = 32'd0;
    w_accum = eng_accum_w;
    w_o4n1 = eng_o4n1_w;
    w_o3n1 = eng_o3n1_w;
    w_o3n2 = eng_o3n2_w;
    w_o2n1 = eng_o2n1_w;
    w_o2n2 = eng_o2n2_w;
    w_o1n1 = eng_o1n1_w;

    if (host_commit) begin
        // Host byte-3 commit owns the write port (engine writebacks held off).
        wr_addr = voice;
        if (current_page < 7'h20) begin
            unique case (host_reg)
                4'h0: begin we_control = 1'b1; w_control = assembled_write[15:0]; end
                4'h1: begin we_fc = 1'b1; w_fc = assembled_write[16:0]; end
                4'h2: begin we_lvol = 1'b1; w_lvol = assembled_write[15:0]; end
                4'h3: begin we_lvramp = 1'b1; w_lvramp = assembled_write[15:8]; end
                4'h4: begin we_rvol = 1'b1; w_rvol = assembled_write[15:0]; end
                4'h5: begin we_rvramp = 1'b1; w_rvramp = assembled_write[15:8]; end
                4'h6: begin we_ecount = 1'b1; w_ecount = assembled_write[8:0]; end
                4'h7: begin we_k2 = 1'b1; w_k2 = assembled_write[15:0]; end
                4'h8: begin
                    we_k2ramp = 1'b1;
                    w_k2ramp = {assembled_write[0], assembled_write[15:8]};
                end
                4'h9: begin we_k1 = 1'b1; w_k1 = assembled_write[15:0]; end
                4'ha: begin
                    we_k1ramp = 1'b1;
                    w_k1ramp = {assembled_write[0], assembled_write[15:8]};
                end
                default: ;
            endcase
        end
        else if (current_page < 7'h40) begin
            unique case (host_reg)
                4'h0: begin we_control = 1'b1; w_control = assembled_write[15:0]; end
                4'h1: begin
                    we_start = 1'b1;
                    w_start = assembled_write & 32'hffff_f800;
                end
                4'h2: begin
                    we_end = 1'b1;
                    w_end = assembled_write & 32'hffff_ff80;
                end
                4'h3: begin we_accum = 1'b1; w_accum = assembled_write; end
                4'h4: begin we_o4n1 = 1'b1; w_o4n1 = assembled_write[17:0]; end
                4'h5: begin we_o3n1 = 1'b1; w_o3n1 = assembled_write[17:0]; end
                4'h6: begin we_o3n2 = 1'b1; w_o3n2 = assembled_write[17:0]; end
                4'h7: begin we_o2n1 = 1'b1; w_o2n1 = assembled_write[17:0]; end
                4'h8: begin we_o2n2 = 1'b1; w_o2n2 = assembled_write[17:0]; end
                4'h9: begin we_o1n1 = 1'b1; w_o1n1 = assembled_write[17:0]; end
                default: ;
            endcase
        end
    end
    else if (eng_pending) begin
        // pend_* recorded a decision taken when the transaction was captured.
        // A host commit landing after that capture but before this replay
        // would otherwise still be overwritten here -- the same stale-writeback
        // class of bug the host_fresh_* flags exist to stop, just displaced
        // into the deferred path. Re-test the flag at the point of use, against
        // pend_voice (the engine may have moved on to another voice since).
        // This can only ever drop a write the host has already superseded.
        wr_addr = pend_voice;
        we_accum = pend_accum && !host_fresh_accum[pend_voice];
        // The OTTO 11.5 group abort must hold on the replay too: a host
        // ECOUNT write landing between capture and this replay aborts the
        // whole LVOL/RVOL/K1/K2 ramp step, not only ECOUNT's own register.
        we_lvol = pend_lvol && !host_fresh_lvol[pend_voice] &&
                  !host_fresh_ecount[pend_voice];
        we_rvol = pend_rvol && !host_fresh_rvol[pend_voice] &&
                  !host_fresh_ecount[pend_voice];
        we_k1 = pend_k1 && !host_fresh_k1[pend_voice] &&
                !host_fresh_ecount[pend_voice];
        we_k2 = pend_k2 && !host_fresh_k2[pend_voice] &&
                !host_fresh_ecount[pend_voice];
        we_ecount = pend_ecount && !host_fresh_ecount[pend_voice];
        we_o4n1 = pend_o4n1 && !host_fresh_o4n1[pend_voice];
        we_o3n1 = pend_o3n1 && !host_fresh_o3n1[pend_voice];
        we_o3n2 = pend_o3n2 && !host_fresh_o3n2[pend_voice];
        we_o2n1 = pend_o2n1 && !host_fresh_o2n1[pend_voice];
        we_o2n2 = pend_o2n2 && !host_fresh_o2n2[pend_voice];
        we_o1n1 = pend_o1n1 && !host_fresh_o1n1[pend_voice];
        w_accum = pend_accum_w;
        w_lvol = pend_lvol_w;
        w_rvol = pend_rvol_w;
        w_k1 = pend_k1_w;
        w_k2 = pend_k2_w;
        w_ecount = pend_ecount_w;
        w_o4n1 = pend_o4n1_w;
        w_o3n1 = pend_o3n1_w;
        w_o3n2 = pend_o3n2_w;
        w_o2n1 = pend_o2n1_w;
        w_o2n2 = pend_o2n2_w;
        w_o1n1 = pend_o1n1_w;
    end
    else begin
        // Each `!host_fresh_*[eng_voice]` guard drops exactly the fields a
        // host write has already refreshed since this voice's snapshot --
        // never the whole writeback -- so an unrelated field on the same
        // voice still commits normally this cycle.
        wr_addr = eng_voice;
        // CR is deliberately absent here: engine CR updates travel through
        // the sticky cr_eset/cr_eclr masks above, never this port.
        if (eng_wr_accum && !host_fresh_accum[eng_voice]) we_accum = 1'b1;
        // Flush pending CR masks into the MLAB at the voice's snapshot tick:
        // rd_addr is on eng_voice so q_control is this voice's live word, the
        // port is free (host_commit/eng_pending own the earlier branches, and
        // writebacks never coincide with a snapshot), and after the flush the
        // stored word equals the adjusted view every reader already saw.
        if (eng_snap && cr_masks_nz_ev && !cold_init_active &&
            !cr_snap_missed) begin
            // cr_snap_missed: q_control predates a host CR write from the
            // last cycle; flushing masks over it would revert that write.
            we_control = 1'b1;
            w_control  = cr_apply(q_control, cr_eset_ev, cr_eclr_ev);
        end
        if (eng_wr_filt) begin
            if (!host_fresh_o4n1[eng_voice]) we_o4n1 = 1'b1;
            if (!host_fresh_o3n1[eng_voice]) we_o3n1 = 1'b1;
            if (!host_fresh_o3n2[eng_voice]) we_o3n2 = 1'b1;
            if (!host_fresh_o2n1[eng_voice]) we_o2n1 = 1'b1;
            if (!host_fresh_o2n2[eng_voice]) we_o2n2 = 1'b1;
            if (!host_fresh_o1n1[eng_voice]) we_o1n1 = 1'b1;
        end
        if (eng_wr_env) begin
            // OTTO Spec Rev 2.3 section 11.5 (p35): ECOUNT is checked
            // "immediately before updating the oscillator" and the whole
            // group -- LVOL/RVOL/K1/K2 as well as ECOUNT itself -- is
            // aborted if it is zero. A host write that zeroes ECOUNT for
            // this voice mid-slot (after the engine's S_START snapshot, so
            // the engine's own check saw a stale nonzero value) must also
            // suppress the ramp step on the other four fields, not just
            // protect ECOUNT's own register from being overwritten.
            if (!host_fresh_lvol[eng_voice]   &&
                !host_fresh_ecount[eng_voice]) we_lvol = 1'b1;
            if (!host_fresh_rvol[eng_voice]   &&
                !host_fresh_ecount[eng_voice]) we_rvol = 1'b1;
            if (!host_fresh_k1[eng_voice]     &&
                !host_fresh_ecount[eng_voice]) we_k1 = 1'b1;
            if (!host_fresh_k2[eng_voice]     &&
                !host_fresh_ecount[eng_voice]) we_k2 = 1'b1;
            if (!host_fresh_ecount[eng_voice]) we_ecount = 1'b1;
        end
    end

    // MAME's ES5506 compute_tables() initializes every voice before the first
    // device reset: stopped CR, half-scale L/R volume, and zero for the rest.
    // Write all banks in parallel through their independent MLAB write ports.
    // This is deliberately a cold-reset-only sweep so watchdog reset retains
    // the programmed voice state, matching es5506_device::device_reset().
    if (cold_init_active) begin
        wr_addr = cold_init_voice;
        we_control = 1'b1;
        w_control = 16'h0003;
        we_fc = 1'b1;
        w_fc = 17'd0;
        we_lvol = 1'b1;
        w_lvol = 16'h8000;
        we_lvramp = 1'b1;
        w_lvramp = 8'd0;
        we_rvol = 1'b1;
        w_rvol = 16'h8000;
        we_rvramp = 1'b1;
        w_rvramp = 8'd0;
        we_ecount = 1'b1;
        w_ecount = 9'd0;
        we_k2 = 1'b1;
        w_k2 = 16'd0;
        we_k2ramp = 1'b1;
        w_k2ramp = 9'd0;
        we_k1 = 1'b1;
        w_k1 = 16'd0;
        we_k1ramp = 1'b1;
        w_k1ramp = 9'd0;
        we_start = 1'b1;
        w_start = 32'd0;
        we_end = 1'b1;
        w_end = 32'd0;
        we_accum = 1'b1;
        w_accum = 32'd0;
        we_o4n1 = 1'b1;
        w_o4n1 = 18'd0;
        we_o3n1 = 1'b1;
        w_o3n1 = 18'd0;
        we_o3n2 = 1'b1;
        w_o3n2 = 18'd0;
        we_o2n1 = 1'b1;
        w_o2n1 = 18'd0;
        we_o2n2 = 1'b1;
        w_o2n2 = 18'd0;
        we_o1n1 = 1'b1;
        w_o1n1 = 18'd0;
    end
end

ssv_mlab32_sdp #(.WIDTH(16)) u_control (
    .clk, .wr_addr, .we(we_control), .wdata(w_control), .rd_addr, .q(q_control));
ssv_mlab32_sdp #(.WIDTH(17)) u_fc (
    .clk, .wr_addr, .we(we_fc), .wdata(w_fc), .rd_addr, .q(q_fc));
ssv_mlab32_sdp #(.WIDTH(16)) u_lvol (
    .clk, .wr_addr, .we(we_lvol), .wdata(w_lvol), .rd_addr, .q(q_lvol));
ssv_mlab32_sdp #(.WIDTH(8)) u_lvramp (
    .clk, .wr_addr, .we(we_lvramp), .wdata(w_lvramp), .rd_addr, .q(q_lvramp));
ssv_mlab32_sdp #(.WIDTH(16)) u_rvol (
    .clk, .wr_addr, .we(we_rvol), .wdata(w_rvol), .rd_addr, .q(q_rvol));
ssv_mlab32_sdp #(.WIDTH(8)) u_rvramp (
    .clk, .wr_addr, .we(we_rvramp), .wdata(w_rvramp), .rd_addr, .q(q_rvramp));
ssv_mlab32_sdp #(.WIDTH(9)) u_ecount (
    .clk, .wr_addr, .we(we_ecount), .wdata(w_ecount), .rd_addr, .q(q_ecount));
ssv_mlab32_sdp #(.WIDTH(16)) u_k2 (
    .clk, .wr_addr, .we(we_k2), .wdata(w_k2), .rd_addr, .q(q_k2));
ssv_mlab32_sdp #(.WIDTH(9)) u_k2ramp (
    .clk, .wr_addr, .we(we_k2ramp), .wdata(w_k2ramp), .rd_addr, .q(q_k2ramp));
ssv_mlab32_sdp #(.WIDTH(16)) u_k1 (
    .clk, .wr_addr, .we(we_k1), .wdata(w_k1), .rd_addr, .q(q_k1));
ssv_mlab32_sdp #(.WIDTH(9)) u_k1ramp (
    .clk, .wr_addr, .we(we_k1ramp), .wdata(w_k1ramp), .rd_addr, .q(q_k1ramp));
ssv_mlab32_sdp #(.WIDTH(32)) u_start (
    .clk, .wr_addr, .we(we_start), .wdata(w_start), .rd_addr, .q(q_start));
ssv_mlab32_sdp #(.WIDTH(32)) u_end (
    .clk, .wr_addr, .we(we_end), .wdata(w_end), .rd_addr, .q(q_end));
ssv_mlab32_sdp #(.WIDTH(32)) u_accum (
    .clk, .wr_addr, .we(we_accum), .wdata(w_accum), .rd_addr, .q(q_accum));
ssv_mlab32_sdp #(.WIDTH(18)) u_o4n1 (
    .clk, .wr_addr, .we(we_o4n1), .wdata(w_o4n1), .rd_addr, .q(q_o4n1));
ssv_mlab32_sdp #(.WIDTH(18)) u_o3n1 (
    .clk, .wr_addr, .we(we_o3n1), .wdata(w_o3n1), .rd_addr, .q(q_o3n1));
ssv_mlab32_sdp #(.WIDTH(18)) u_o3n2 (
    .clk, .wr_addr, .we(we_o3n2), .wdata(w_o3n2), .rd_addr, .q(q_o3n2));
ssv_mlab32_sdp #(.WIDTH(18)) u_o2n1 (
    .clk, .wr_addr, .we(we_o2n1), .wdata(w_o2n1), .rd_addr, .q(q_o2n1));
ssv_mlab32_sdp #(.WIDTH(18)) u_o2n2 (
    .clk, .wr_addr, .we(we_o2n2), .wdata(w_o2n2), .rd_addr, .q(q_o2n2));
ssv_mlab32_sdp #(.WIDTH(18)) u_o1n1 (
    .clk, .wr_addr, .we(we_o1n1), .wdata(w_o1n1), .rd_addr, .q(q_o1n1));

always_comb begin
    unique case (host_byte)
        2'd0: host_rdata = read_latch[31:24];
        2'd1: host_rdata = read_latch[23:16];
        2'd2: host_rdata = read_latch[15:8];
        2'd3: host_rdata = read_latch[7:0];
    endcase
end

function automatic [31:0] assemble_host_read(
    input [6:0] page,
    input [3:0] regn,
    input       cr_valid,
    input [15:0] control,
    input [16:0] fc,
    input [15:0] lvol,
    input [7:0]  lvramp,
    input [15:0] rvol,
    input [7:0]  rvramp,
    input [8:0]  ecount,
    input [15:0] k2,
    input [8:0]  k2ramp,
    input [15:0] k1,
    input [8:0]  k1ramp,
    input [31:0] start_a,
    input [31:0] end_a,
    input [31:0] accum,
    input [17:0] o4n1,
    input [17:0] o3n1,
    input [17:0] o3n2,
    input [17:0] o2n1,
    input [17:0] o2n2,
    input [17:0] o1n1,
    input [4:0]  act_v,
    input [4:0]  mode_v,
    input [9:0]  par,
    input [7:0]  irqv,
    input [6:0]  page_v,
    input [6:0]  wcs,
    input [6:0]  wce,
    input [6:0]  lre
);
    begin
        assemble_host_read = 32'd0;
        if (page < 7'h20) begin
            unique case (regn)
                4'h0: assemble_host_read = {16'd0, control};
                4'h1: assemble_host_read = {15'd0, fc};
                4'h2: assemble_host_read = {16'd0, lvol};
                4'h3: assemble_host_read = {16'd0, lvramp, 8'd0};
                4'h4: assemble_host_read = {16'd0, rvol};
                4'h5: assemble_host_read = {16'd0, rvramp, 8'd0};
                4'h6: assemble_host_read = {23'd0, ecount};
                4'h7: assemble_host_read = {16'd0, k2};
                4'h8: assemble_host_read = {
                    16'd0, k2ramp[7:0], 7'd0, k2ramp[8]
                };
                4'h9: assemble_host_read = {16'd0, k1};
                4'ha: assemble_host_read = {
                    16'd0, k1ramp[7:0], 7'd0, k1ramp[8]
                };
                4'hb: assemble_host_read = {27'd0, act_v};
                4'hc: assemble_host_read = {27'd0, mode_v};
                4'hd: assemble_host_read = {22'd0, par};
                4'he: assemble_host_read = {24'd0, irqv};
                4'hf: assemble_host_read = {25'd0, page_v};
            endcase
        end
        else if (page < 7'h40) begin
            unique case (regn)
                4'h0: assemble_host_read = {16'd0, control};
                4'h1: assemble_host_read = start_a;
                4'h2: assemble_host_read = end_a;
                4'h3: assemble_host_read = accum;
                4'h4: assemble_host_read = {14'd0, o4n1};
                4'h5: assemble_host_read = {14'd0, o3n1};
                4'h6: assemble_host_read = {14'd0, o3n2};
                4'h7: assemble_host_read = {14'd0, o2n1};
                4'h8: assemble_host_read = {14'd0, o2n2};
                4'h9: assemble_host_read = {14'd0, o1n1};
                4'ha: assemble_host_read = {25'd0, wcs};
                4'hb: assemble_host_read = {25'd0, wce};
                4'hc: assemble_host_read = {25'd0, lre};
                4'hd: assemble_host_read = {22'd0, par};
                4'he: assemble_host_read = {24'd0, irqv};
                4'hf: assemble_host_read = {25'd0, page_v};
            endcase
        end
        else begin
            unique case (regn)
                4'hd: assemble_host_read = {22'd0, par};
                4'he: assemble_host_read = {24'd0, irqv};
                4'hf: assemble_host_read = {25'd0, page_v};
                default: assemble_host_read = 32'd0;
            endcase
        end
    end
endfunction

always_ff @(posedge clk) begin
    if (cold_rst) begin
        write_latch      <= 32'd0;
        read_latch       <= 32'hffff_ffff;
        current_page     <= 7'd0;
        active_voices    <= 5'h1f;
        mode             <= 5'h17;
        word_clock_start <= 7'd0;
        word_clock_end   <= 7'd0;
        lr_clock_end     <= 7'd0;
        irq_vector       <= 8'h80;
        commit           <= 1'b0;
        // The MLAB banks are initialized by the cold sweep below.  Keep the
        // engine invalid until all 32 voices have received their defaults.
        voice_control_valid <= 32'd0;
        cold_init_active <= 1'b1;
        cold_init_voice  <= 5'd0;
        commit_page      <= 7'd0;
        commit_reg       <= 4'd0;
        commit_data      <= 32'd0;
        host_rd_pending  <= 1'b0;
        eng_hold         <= 1'b0;
        eng_pending      <= 1'b0;
        for (int i = 0; i < 32; i++) begin
            cr_eset[i] <= '0;
            cr_eclr[i] <= '0;
        end
        cr_scan_void     <= '0;
        page_r           <= 7'd0;
        reg_r            <= 4'd0;
        irqv_r           <= 8'h80;
        // Snapshot data is observable only with eng_hold=1. eng_hold resets low,
        // and host_rd_steal loads every field on the edge that asserts it; omit
        // snapshot resets so Quartus sees a load-enable, not a reset/load/hold mux.
    end
    else begin
        if (rst) begin
            // MAME's es5506_device::device_reset() only restores these
            // device-level timing controls.  Voice banks, PAGE, and IRQV are
            // retained across the watchdog/software reset.
            active_voices <= 5'h1f;
            mode          <= 5'h17;
            commit        <= 1'b0;
            host_rd_pending <= 1'b0;
            eng_hold      <= 1'b0;
            eng_pending   <= 1'b0;
        end
        else begin
            commit <= 1'b0;
            host_rd_pending <= host_rd_steal;
            // Hold engine snapshots through the steal cycle and the following
            // cycle while MLAB q still reflects the host rd_addr (address_reg_b).
            // Dropping hold with steal alone lets eng_* sample host voice data.
            eng_hold        <= host_rd_steal || host_rd_pending;

            // A snapshot that could not see a just-landed host CR write
            // voids this scan's CR transitions: they were computed from the
            // stale word. The next snapshot redoes them from the stored
            // (new) CR -- MAME's serialized write-then-sample order.
            if (eng_snap)
                cr_scan_void[eng_voice] <= cr_snap_missed;

            // Sticky engine-CR masks. Merge on every engine CR writeback
            // (pure flops -- no port, no collision, no drop); newest
            // direction wins per bit. Cleared when they flush into the MLAB
            // at the voice's snapshot, or when a host CR write to the voice
            // supersedes them. A voided scan's transitions are dropped, not
            // merged -- they derive from a CR the host has already replaced.
            if (eng_wr_cr && !cr_scan_void[eng_voice]) begin
                cr_eset[eng_voice] <=
                    (cr_eset[eng_voice] & ~cr_pack(eng_cr_clr)) | cr_pack(eng_cr_set);
                cr_eclr[eng_voice] <=
                    (cr_eclr[eng_voice] & ~cr_pack(eng_cr_set)) | cr_pack(eng_cr_clr);
            end
            else if (eng_snap && cr_masks_nz_ev && !cold_init_active &&
                     !host_commit && !eng_pending && !cr_snap_missed) begin
                // Mirrors the combinational flush branch exactly: the write
                // fired this cycle, so the stored word now equals the
                // adjusted view and the masks retire.
                cr_eset[eng_voice] <= '0;
                cr_eclr[eng_voice] <= '0;
            end
            if (host_commit && (host_reg == 4'h0) && (current_page < 7'h40) &&
                !(eng_wr_cr && (voice == eng_voice))) begin
                // (The eng_wr_cr exclusion: on an exact same-cycle collision
                // the engine transition merges and survives the host write --
                // a one-clock-stale CR bit is recoverable, a dropped BLE->LEI
                // transition is a permanent loop.)
                // Host CR write supersedes any pending engine transition for
                // that voice, exactly as MAME's serialized ordering would --
                // the transition was visible to every read the host did
                // before this write (the masks adjust the read paths), so
                // discarding it now cannot lose information the host lacked.
                //
                // This condition MUST be built from the same-cycle decode
                // (host_reg / current_page / voice), never from
                // commit_reg / commit_page: those are flops that still hold
                // the PREVIOUS commit on the cycle host_commit pulses. The
                // old registered form only cleared the masks when the
                // preceding commit happened to be a CR write to the same
                // voice, so a note-on's trailing CR write usually left the
                // previous note's transition masks armed. cr_apply() then
                // stamped them (LEI set, LPE/BLE cleared, DIR flipped) over
                // the fresh CR and the snapshot flush made it permanent -- a
                // voice with LEI forced on never runs its end-of-loop test
                // and plays straight through the sample bank: the random
                // warped music-fragment/voice playback reported on hardware.
                cr_eset[voice] <= '0;
                cr_eclr[voice] <= '0;
            end
`ifdef SIMULATION
            // Telemetry: how often the OLD (registered) condition would have
            // left armed masks uncleared across a host CR write.
            if (host_commit && (host_reg == 4'h0) && (current_page < 7'h40) &&
                (|{cr_eset[voice], cr_eclr[voice]}) &&
                !((commit_reg == 4'h0) && (commit_page[4:0] == voice) &&
                  (commit_page < 7'h40))) begin
                dbg_stale_mask_hits <= dbg_stale_mask_hits + 32'd1;
                $display("ES5506_STALE_CR_MASK voice=%0d eset=%02x eclr=%02x time=%0t",
                         voice, cr_eset[voice], cr_eclr[voice], $time);
            end
`endif

            if (host_rd_steal) begin
                page_r <= current_page;
                reg_r  <= host_reg;
                irqv_r <= irq_vector;
                // q still holds the prior engine read at this edge.
                eng_cr_h       <= q_control;
                eng_cr_valid_h <= voice_control_valid[eng_voice];
                eng_fc_h       <= q_fc;
                eng_lvol_h     <= q_lvol;
                eng_lvramp_h   <= q_lvramp;
                eng_rvol_h     <= q_rvol;
                eng_rvramp_h   <= q_rvramp;
                eng_ecount_h   <= q_ecount;
                eng_k1_h       <= q_k1;
                eng_k1ramp_h   <= q_k1ramp;
                eng_k2_h       <= q_k2;
                eng_k2ramp_h   <= q_k2ramp;
                eng_start_h    <= q_start;
                eng_end_h      <= q_end;
                eng_accum_h    <= q_accum;
                eng_o4n1_h     <= q_o4n1;
                eng_o3n1_h     <= q_o3n1;
                eng_o3n2_h     <= q_o3n2;
                eng_o2n1_h     <= q_o2n1;
                eng_o2n2_h     <= q_o2n2;
                eng_o1n1_h     <= q_o1n1;
            end

            // MLAB q is one cycle behind rd_addr (steal or eng).
            if (host_rd_pending) begin
                read_latch <= assemble_host_read(
                    page_r, reg_r,
                    voice_control_valid[page_r[4:0]],
                    // Pending engine CR masks are real state; a host read-
                    // modify-write must see them or it re-arms a stopped
                    // voice with stale loop bits.
                    cold_init_active ? 16'h0003
                        : cr_apply(q_control,
                                   cr_eset[page_r[4:0]], cr_eclr[page_r[4:0]]),
                    q_fc, q_lvol, q_lvramp, q_rvol, q_rvramp,
                    q_ecount, q_k2, q_k2ramp, q_k1, q_k1ramp,
                    q_start, q_end, q_accum,
                    q_o4n1, q_o3n1, q_o3n2, q_o2n1, q_o2n2, q_o1n1,
                    active_voices, mode, par_data, irqv_r, page_r,
                    word_clock_start, word_clock_end, lr_clock_end
                );
                // Spec: reading IRQV releases the vector the host just read
                // (after snapshot).  Release only when that snapshot carried
                // a valid vector: a promotion landing on the steal cycle
                // itself was never visible to this read, and its CR.IRQ
                // pending bit was already consumed at promotion, so an
                // unconditional clear here discarded that voice's loop-end
                // event permanently.  MAME's read+ack is atomic and cannot
                // lose it; the OTTO spec ties the release to the vector the
                // host actually observed.
                if ((reg_r == 4'he) && (page_r < 7'h40) && !irqv_r[7])
                    irq_vector <= 8'h80;
`ifdef SIMULATION
                // Race telemetry only: an IRQV read completing while a
                // vector promoted on the steal cycle sits unread.  The old
                // unconditional release destroyed exactly these events.
                if ((reg_r == 4'he) && (page_r < 7'h40)) begin
                    dbg_irqv_reads <= dbg_irqv_reads + 32'd1;
                    if (irqv_r[7] && !irq_vector[7]) begin
                        dbg_irqv_races <= dbg_irqv_races + 32'd1;
                        $display("ES5506_IRQV_RACE_SURVIVED voice=%0d time=%0t",
                                 irq_vector[4:0], $time);
                    end
                    if (dbg_irqv_reads[11:0] == 12'd0)
                        $display({"ES5506_IRQV_STATS reads=%0d promotions=%0d ",
                                  "races=%0d time=%0t"},
                                 dbg_irqv_reads, dbg_irqv_promotions,
                                 dbg_irqv_races, $time);
                end
`endif
            end

            if (irq_set && irq_vector[7]) begin
                irq_vector <= {3'd0, irq_voice};
`ifdef SIMULATION
                dbg_irqv_promotions <= dbg_irqv_promotions + 32'd1;
`endif
            end

            if (host_we) begin
                write_latch <= assembled_write;
                if (host_byte == 2'd3) begin
                    commit      <= 1'b1;
                    commit_page <= current_page;
                    commit_reg  <= host_reg;
                    commit_data <= assembled_write;

                    if (host_reg == 4'hf)
                        current_page <= assembled_write[6:0];
                    else if (current_page < 7'h20) begin
                        unique case (host_reg)
                            4'h0: voice_control_valid[voice] <= 1'b1;
                            4'hb: active_voices <= assembled_write[4:0];
                            4'hc: mode <= assembled_write[4:0];
                            default: ;
                        endcase
                    end
                    else if (current_page < 7'h40) begin
                        unique case (host_reg)
                            4'h0: voice_control_valid[voice] <= 1'b1;
                            4'ha: word_clock_start <= assembled_write[6:0];
                            4'hb: word_clock_end <= assembled_write[6:0];
                            4'hc: lr_clock_end <= assembled_write[6:0];
                            default: ;
                        endcase
                    end

                    write_latch <= 32'd0;
                end
            end

            // Replay one deferred transaction at a time. Engine updates are
            // spaced by the 16 MHz enable, but retaining a new update while a
            // prior one replays makes the ordering explicit and lossless.
            if (eng_pending && !host_commit) begin
                eng_pending <= eng_write_any;
                if (eng_write_any) begin
                    pend_voice <= eng_voice;
                    pend_accum <= eng_wr_accum && !host_fresh_accum[eng_voice];
                    // See the always_comb note above: a host ECOUNT write
                    // for this voice also aborts the LVOL/RVOL/K1/K2 step,
                    // not just its own field.
                    pend_lvol <= eng_wr_env && !host_fresh_lvol[eng_voice] &&
                        !host_fresh_ecount[eng_voice];
                    pend_rvol <= eng_wr_env && !host_fresh_rvol[eng_voice] &&
                        !host_fresh_ecount[eng_voice];
                    pend_k1 <= eng_wr_env && !host_fresh_k1[eng_voice] &&
                        !host_fresh_ecount[eng_voice];
                    pend_k2 <= eng_wr_env && !host_fresh_k2[eng_voice] &&
                        !host_fresh_ecount[eng_voice];
                    pend_ecount <= eng_wr_env && !host_fresh_ecount[eng_voice];
                    pend_o4n1 <= eng_wr_filt && !host_fresh_o4n1[eng_voice];
                    pend_o3n1 <= eng_wr_filt && !host_fresh_o3n1[eng_voice];
                    pend_o3n2 <= eng_wr_filt && !host_fresh_o3n2[eng_voice];
                    pend_o2n1 <= eng_wr_filt && !host_fresh_o2n1[eng_voice];
                    pend_o2n2 <= eng_wr_filt && !host_fresh_o2n2[eng_voice];
                    pend_o1n1 <= eng_wr_filt && !host_fresh_o1n1[eng_voice];
                    pend_accum_w <= eng_accum_w;
                    pend_lvol_w <= eng_lvol_w;
                    pend_rvol_w <= eng_rvol_w;
                    pend_k1_w <= eng_k1_w;
                    pend_k2_w <= eng_k2_w;
                    pend_ecount_w <= eng_ecount_w;
                    pend_o4n1_w <= eng_o4n1_w;
                    pend_o3n1_w <= eng_o3n1_w;
                    pend_o3n2_w <= eng_o3n2_w;
                    pend_o2n1_w <= eng_o2n1_w;
                    pend_o2n2_w <= eng_o2n2_w;
                    pend_o1n1_w <= eng_o1n1_w;
                end
            end
            else if (host_commit && !eng_pending && eng_write_any) begin
                pend_voice <= eng_voice;
                pend_accum <= eng_wr_accum &&
                    !((voice == eng_voice) && we_accum) &&
                    !host_fresh_accum[eng_voice];
                pend_lvol <= eng_wr_env &&
                    !((voice == eng_voice) && we_lvol) &&
                    !host_fresh_lvol[eng_voice] &&
                    !host_fresh_ecount[eng_voice];
                pend_rvol <= eng_wr_env &&
                    !((voice == eng_voice) && we_rvol) &&
                    !host_fresh_rvol[eng_voice] &&
                    !host_fresh_ecount[eng_voice];
                pend_k1 <= eng_wr_env &&
                    !((voice == eng_voice) && we_k1) &&
                    !host_fresh_k1[eng_voice] &&
                    !host_fresh_ecount[eng_voice];
                pend_k2 <= eng_wr_env &&
                    !((voice == eng_voice) && we_k2) &&
                    !host_fresh_k2[eng_voice] &&
                    !host_fresh_ecount[eng_voice];
                pend_ecount <= eng_wr_env &&
                    !((voice == eng_voice) && we_ecount) &&
                    !host_fresh_ecount[eng_voice];
                pend_o4n1 <= eng_wr_filt &&
                    !((voice == eng_voice) && we_o4n1) &&
                    !host_fresh_o4n1[eng_voice];
                pend_o3n1 <= eng_wr_filt &&
                    !((voice == eng_voice) && we_o3n1) &&
                    !host_fresh_o3n1[eng_voice];
                pend_o3n2 <= eng_wr_filt &&
                    !((voice == eng_voice) && we_o3n2) &&
                    !host_fresh_o3n2[eng_voice];
                pend_o2n1 <= eng_wr_filt &&
                    !((voice == eng_voice) && we_o2n1) &&
                    !host_fresh_o2n1[eng_voice];
                pend_o2n2 <= eng_wr_filt &&
                    !((voice == eng_voice) && we_o2n2) &&
                    !host_fresh_o2n2[eng_voice];
                pend_o1n1 <= eng_wr_filt &&
                    !((voice == eng_voice) && we_o1n1) &&
                    !host_fresh_o1n1[eng_voice];
                pend_accum_w <= eng_accum_w;
                pend_lvol_w <= eng_lvol_w;
                pend_rvol_w <= eng_rvol_w;
                pend_k1_w <= eng_k1_w;
                pend_k2_w <= eng_k2_w;
                pend_ecount_w <= eng_ecount_w;
                pend_o4n1_w <= eng_o4n1_w;
                pend_o3n1_w <= eng_o3n1_w;
                pend_o3n2_w <= eng_o3n2_w;
                pend_o2n1_w <= eng_o2n1_w;
                pend_o2n2_w <= eng_o2n2_w;
                pend_o1n1_w <= eng_o1n1_w;
                eng_pending <=
                    (eng_wr_accum && !((voice == eng_voice) && we_accum) &&
                        !host_fresh_accum[eng_voice]) |
                    (eng_wr_env && !((voice == eng_voice) &&
                        we_lvol && we_rvol && we_k1 && we_k2 && we_ecount) &&
                        !(host_fresh_lvol[eng_voice] && host_fresh_rvol[eng_voice] &&
                          host_fresh_k1[eng_voice] && host_fresh_k2[eng_voice] &&
                          host_fresh_ecount[eng_voice])) |
                    (eng_wr_filt && !((voice == eng_voice) &&
                        we_o4n1 && we_o3n1 && we_o3n2 &&
                        we_o2n1 && we_o2n2 && we_o1n1) &&
                        !(host_fresh_o4n1[eng_voice] && host_fresh_o3n1[eng_voice] &&
                          host_fresh_o3n2[eng_voice] && host_fresh_o2n1[eng_voice] &&
                          host_fresh_o2n2[eng_voice] && host_fresh_o1n1[eng_voice]));
            end

`ifdef SIMULATION
            if (host_commit && eng_pending && eng_write_any)
                $fatal(1, "ES5506 writeback skid overflow");

            // Invariant the host_fresh_* flags exist to establish: no engine
            // writeback path -- plain or deferred -- may ever write a field of
            // a voice the host has refreshed since that voice's snapshot.
            // Checked at wr_addr, which is eng_voice on the plain path and
            // pend_voice on the replay path, so one test covers both. The host
            // commit path legitimately writes those fields (it is what sets the
            // flags), and the cold-init sweep deliberately rewrites everything,
            // so both are excluded.
            if (!cold_init_active && !host_commit) begin
                if (we_accum && host_fresh_accum[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host ACCUM, voice %0d", wr_addr);
                if (we_lvol && host_fresh_lvol[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host LVOL, voice %0d", wr_addr);
                if (we_rvol && host_fresh_rvol[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host RVOL, voice %0d", wr_addr);
                if (we_k1 && host_fresh_k1[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host K1, voice %0d", wr_addr);
                if (we_k2 && host_fresh_k2[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host K2, voice %0d", wr_addr);
                if (we_ecount && host_fresh_ecount[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host ECOUNT, voice %0d", wr_addr);
                if (we_o4n1 && host_fresh_o4n1[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host O4N1, voice %0d", wr_addr);
                if (we_o3n1 && host_fresh_o3n1[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host O3N1, voice %0d", wr_addr);
                if (we_o3n2 && host_fresh_o3n2[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host O3N2, voice %0d", wr_addr);
                if (we_o2n1 && host_fresh_o2n1[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host O2N1, voice %0d", wr_addr);
                if (we_o2n2 && host_fresh_o2n2[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host O2N2, voice %0d", wr_addr);
                if (we_o1n1 && host_fresh_o1n1[wr_addr])
                    $fatal(1, "ES5506 engine clobbered fresh host O1N1, voice %0d", wr_addr);
            end

`endif

        end

        if (cold_init_active) begin
            if (cold_init_voice == 5'h1f) begin
                cold_init_active <= 1'b0;
                voice_control_valid <= 32'hffff_ffff;
            end
            else begin
                cold_init_voice <= cold_init_voice + 5'd1;
            end
        end
    end
end

assign irq_n = irq_vector[7];

endmodule
