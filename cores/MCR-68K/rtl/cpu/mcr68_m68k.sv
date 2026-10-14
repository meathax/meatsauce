// mcr68_m68k.sv
//
// Generic 68000 CPU-instance wrapper around the vendored FX68K core
// (Jorge Cwik's fx68k.sv / fx68kAlu_synth.sv / uaddrPla_synth.sv,
// rtl/cpu/microrom.mif, rtl/cpu/nanorom.mif).
//
// This module instantiates fx68k DIRECTLY -- not jtframe_m68k -- because
// this project has no dependency on jtframe's math-coprocessor plumbing
// (yb_m68k.sv's use of jtframe_m68k exists only to host the Y Board's
// private 315-5248/315-5249 arithmetic chips, which have no MCR68
// equivalent). Comparing against jtframe_m68k.v confirms fx68k is a
// two-port passthrough: cpu_cen/cpu_cenb map straight onto fx68k's
// enPhi1/enPhi2, and VPAn/BERRn/BGACKn/IPLn map straight onto fx68k's
// pins of the same purpose, so nothing is lost by dropping the wrapper.
//
// This module is deliberately free of any board-specific address decode,
// wait-state, or peripheral logic. It is instantiated TWICE:
//   - main board CPU  (cpu_ce equivalent to 7,723,800 Hz)
//   - sound board CPU ("Sounds Good", cpu_ce equivalent to 8 MHz)
// with different external bus wiring and different cpu_ce rates, both
// derived from a common system clock elsewhere (e.g. a shared clock-enable
// generator analogous to apache3_clock_enables.sv's ce_68k_phi1/phi2 pair).
//
// ---------------------------------------------------------------------
// Clocking: cpu_ce -> enPhi1/enPhi2
// ---------------------------------------------------------------------
// FX68K is fully synchronous but two-phase: it needs a PHI1 clock-enable
// pulse and a PHI2 clock-enable pulse per 68000 bus/clock cycle (see
// fx68k.sv's s_clks.enPhi1/enPhi2 and jtframe_m68k.v, which passes its
// cpu_cen/cpu_cenb straight through as enPhi1/enPhi2 with no other
// transformation). This wrapper takes a single external cpu_ce enable
// (one pulse per 68000 half-cycle, i.e. cpu_ce must pulse at 2x the
// nominal 68000 clock frequency) and alternately routes it onto enPhi1
// then enPhi2 using a toggle flip-flop. This is the same pattern already
// used in this project family for fx68k -- see
// D:\Arcade\AI\aCORES\apache 3\rtl\apache3_clock_enables.sv, where a
// single per-cycle pulse (div4==3) is alternately assigned to
// ce_68k_phi1/ce_68k_phi2 via a phi_sel toggle register -- and it matches
// yb_m68k.sv's free-running cen_p/cen_n phase pair feeding jtframe_m68k's
// cpu_cen/cpu_cenb. Keeping the toggle inside this wrapper (rather than
// requiring two separate external enables) is what lets a single cpu_ce
// input serve both the 7,723,800 Hz-equivalent main board and the 8 MHz
// sound board from whatever shared clock-enable divider the caller uses.
//
// ---------------------------------------------------------------------
// DTACK design choice: external input, not jtframe_68kdtack
// ---------------------------------------------------------------------
// dtack_n is exposed as an INPUT, driven by the caller's own address
// decode + memory/peripheral-latency logic, rather than generated
// internally with jtframe_68kdtack/jtframe_68kdtack_cen.
//
// Justification:
//   1. Genericity is the explicit contract of this module ("keep it free
//      of any board-specific address decode or peripheral references").
//      DTACK timing is inherently board- and peripheral-specific: ROM,
//      RAM, and the 6840 PTM on the main board (and whatever the Sounds
//      Good sound board maps) each have different access latency. A
//      single internal DTACK generator cannot know those latencies
//      without the address decode this module is required not to have.
//   2. This is the same division of responsibility already used in this
//      codebase: yb_m68k.sv (the documented reference) does NOT generate
//      its own DTACK either -- it takes bus_ack from the external memory
//      arbiter and combines it with its own data_cycle/math_mul/math_div
//      qualifiers, all of which are yb-board-specific and properly live
//      outside the generic CPU instantiation.
//   3. jtframe_68kdtack(_cen) is designed to synthesize a fixed one-wait
//      DTACK pattern (with optional extra wait states / cycle recovery)
//      from ASn/DSn and a bus_busy/bus_cs signal that the caller still
//      has to derive from its own address decode -- adopting it here
//      would not remove any board-specific logic from the caller, it
//      would just relocate a fixed-policy DTACK generator into a module
//      that is supposed to have no opinion on bus timing. Each board top
//      (main vs. sound) remains free to instantiate jtframe_68kdtack (or
//      jtframe_68kdtack_cen, or a hand-built latency counter) itself if
//      that pattern fits its own memory map -- that decision, and the
//      wait-state count, is exactly the kind of board-specific detail
//      this module must not bake in.
//
// vpa_n, by contrast, IS generated internally: the task states no
// vectored interrupt controller exists on either board, so autovectoring
// on FC==111 is not board-specific -- it is simply "how every interrupt
// on this project is acknowledged" and is identical for both CPU
// instances. Restricting the match to the full 3'b111 encoding (not just
// the low two bits) avoids yb_m68k.sv's noted hazard of a false VPA
// assertion on ordinary user-program fetches (FC==3'b011).
//
// No HALT/BR/BGACK/BERR support is exposed: each of the two boards has a
// single bus master and no bus error condition modeled, so HALTn, BERRn,
// BRn and BGACKn are tied off internally exactly as in yb_m68k.sv
// (BERRn=1, BRn=1) and apache3_machine.sv (BGACKn tied off via BRn/BGACKn
// not being externally driven). E and VMAn (6800-bus-cycle support) are
// left unconnected internally; add them as ports only if/when a real
// E-clock peripheral is wired to one of these two CPUs.

module mcr68_m68k (
    input  logic        clk,
    input  logic        rst,
    input  logic        cpu_ce,      // pulses at 2x the nominal 68000 clock
                                      // rate; internally divided into the
                                      // alternating enPhi1/enPhi2 pair

    output logic [23:1] addr,
    input  logic [15:0] din,
    output logic [15:0] dout,
    output logic        as_n,
    output logic        uds_n,
    output logic        lds_n,
    output logic        rw_n,
    input  logic        dtack_n,     // driven externally by the caller's
                                      // own address-decode + latency logic

    output logic [2:0]  fc,
    input  logic [2:0]  ipl_n,       // interrupt input, active-low level
    output logic        vpa_n,       // autovector output: asserted
                                      // whenever fc==3'b111 && as_n==0

    // Debug-only: passthrough of fx68k's internal PC/register state
    // (PcL/PcH), for simulation trace visibility only. Purely additive --
    // does not alter any existing port or synthesizable behaviour of this
    // wrapper.
    output logic [31:0] dbg_pc,
    output logic [31:0] dbg_d7,
    output logic [7:0]  dbg_ccr,
    output logic [15:0] dbg_sr,
    output logic [2:0]  dbg_iipl,
    output logic [2:0]  dbg_ripl,
    output logic        dbg_ipl_stable,
    output logic        dbg_ipl_comp,
    output logic        dbg_int_pend,
    output logic [2:0]  dbg_inl,
    output logic        dbg_iac
);

    // ---------------------------------------------------------------
    // Two-phase clock-enable generation from the single cpu_ce input
    // ---------------------------------------------------------------
    logic phi_sel;
    logic en_phi1, en_phi2;

    always_ff @(posedge clk) begin
        if (rst) phi_sel <= 1'b0;
        else if (cpu_ce) phi_sel <= ~phi_sel;
    end

    assign en_phi1 = cpu_ce & ~phi_sel;
    assign en_phi2 = cpu_ce &  phi_sel;

    // ---------------------------------------------------------------
    // Autovector generation (no vectored interrupt controller exists)
    // ---------------------------------------------------------------
    // AS precedes UDS/LDS on a 68000 bus cycle; FC==111 marks the
    // interrupt-acknowledge cycle. Matching the full 3-bit code (not just
    // the low two bits) avoids a false VPA assertion on ordinary
    // user-program fetches (FC==3'b011) -- see yb_m68k.sv's comment on
    // the same hazard.
    logic interrupt_ack;
    assign interrupt_ack = !as_n && (fc == 3'b111);
    assign vpa_n = !interrupt_ack;

    // ---------------------------------------------------------------
    // FX68K instance
    // ---------------------------------------------------------------
    // This board has no 6800 bus, bus-arbitration, reset-status, or halt-status
    // consumer for these FX68K outputs; see the wrapper contract above.
    /* verilator lint_off PINCONNECTEMPTY */
    fx68k cpu (
        .clk        (clk),
        .HALTn      (1'b1),
        .extReset   (rst),
        .pwrUp      (rst),
        .enPhi1     (en_phi1),
        .enPhi2     (en_phi2),

        .eRWn       (rw_n),
        .ASn        (as_n),
        .LDSn       (lds_n),
        .UDSn       (uds_n),
        .E          (),
        .VMAn       (),

        .FC0        (fc[0]),
        .FC1        (fc[1]),
        .FC2        (fc[2]),
        .BGn        (),
        .oRESETn    (),
        .oHALTEDn   (),
        .DTACKn     (dtack_n),
        .VPAn       (vpa_n),
        .BERRn      (1'b1),
        .BRn        (1'b1),
        .BGACKn     (1'b1),
        .IPL0n      (ipl_n[0]),
        .IPL1n      (ipl_n[1]),
        .IPL2n      (ipl_n[2]),
        .iEdb       (din),
        .oEdb       (dout),
        .eab        (addr),
        .dbgPC      (dbg_pc),
        .dbgD7      (dbg_d7),
        .dbgCCR     (dbg_ccr),
        .dbgSR      (dbg_sr),
        .dbgIipl    (dbg_iipl),
        .dbgRipl    (dbg_ripl),
        .dbgIplStable (dbg_ipl_stable),
        .dbgIplComp (dbg_ipl_comp),
        .dbgIntPend (dbg_int_pend),
        .dbgInl     (dbg_inl),
        .dbgIac     (dbg_iac)
    );
    /* verilator lint_on PINCONNECTEMPTY */

endmodule
