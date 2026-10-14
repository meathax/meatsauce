//////////////////////////////////////////////////////////////////////////////
// mc6809e.sv -- MC6809E CPU for the MCR-68k core's 6809-based sound boards.
//
// Used by:
//   * Williams S11/S11C background sound -- MC6809E
//   * Williams S11 background (Arch Rivals /
//     Pigskin 621AP)                           -- MC68B09E @ 8 MHz / 4
//
// This is a thin, synthesizable wrapper around `mc6809i` (rtl/cpu/mc6809i.sv),
// Greg Miller's cycle-accurate MC6809/MC6809E core, BSD 3-clause. See that
// file's header and doc/rtl_mc6809e.md for provenance and the exact list of
// local modifications.
//
// ---------------------------------------------------------------------------
// CLOCKING CONTRACT -- READ THIS BEFORE INSTANTIATING
// ---------------------------------------------------------------------------
// A real MC6809E is driven by two externally supplied quadrature clocks, E and
// Q, with Q leading E by 90 degrees. Within one E period the ordering of the
// two falling edges the CPU actually uses is: Q falls first, E falls a quarter
// period later. The core samples its control inputs (/IRQ, /FIRQ, /NMI, /HALT)
// on the falling edge of Q and advances its state machine / bus on the falling
// edge of E.
//
// MiSTer/Quartus rules forbid fabric-generated clocks, so this wrapper takes a
// single system clock plus one clock enable and reconstructs the two phases:
//
//     ce   asserted on clk cycle N     -> internal cen_Q  (falling Q)
//                     clk cycle N+1    -> internal cen_E  (falling E)
//
// CONSEQUENCES FOR THE INTEGRATOR:
//
//   * `ce` pulses MUST be at least 2 clk cycles apart. One `ce` pulse == one
//     complete E cycle == one 6809 bus cycle. (Both target boards divide a
//     multi-MHz system clock down to a ~1-2 MHz E, so this is never tight.)
//     A `CE_SPACING` assertion below flags a violation in simulation; it is
//     wrapped in `ifndef SYNTHESIS` and costs nothing in hardware.
//
//   * `addr`, `rw_n`, `dout`, `ba` and `bs` update on the clk edge that
//     follows the `ce` pulse, and then hold until one clk after the NEXT `ce`
//     pulse. So at every `ce` edge they are already stable and describe the
//     bus cycle that `ce` edge belongs to. A peripheral written as
//         always_ff @(posedge clk) if (ce && !rw_n) mem[addr] <= dout;
//     is correct.
//
//   * `din` is sampled by the core on the clk cycle immediately AFTER a `ce`
//     pulse (the internal cen_E tick), against the address that was presented
//     for that bus cycle. Driving `din` combinationally from `addr` (the usual
//     ROM/RAM read mux) is correct. A registered-output memory launched at
//     `ce` is NOT -- its data would arrive one clk too late. Launch such a
//     read from the address instead, or hold it valid through the next `ce`.
//
// ---------------------------------------------------------------------------
// PORT CONTRACT
// ---------------------------------------------------------------------------
// Exactly the agreed interface -- no added, renamed or reordered ports.
// Signals not on the contract are handled internally:
//   /DMABREQ  tied inactive (1). Neither target board uses DMA.
//   AVMA, BUSY, LIC  left unconnected. Neither target board uses them.
// The core's 112-bit RegData debug bus stays internal to `mc6809i`; the
// focused testbench reaches it hierarchically rather than widening this port
// list.
//
// RESET: `rst_n` is the core's /RESET. It is used asynchronously inside
// mc6809i (async assert, and release re-synchronized by that core's own
// `rnRESET` register, which costs one extra E cycle exactly as upstream did).
// Hold it low for at least one `ce` cycle.
//////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ns
`default_nettype none

// rst_n is deliberately BOTH an asynchronous reset (to mc6809i's state
// registers and to the cen_e phase register here) AND an ordinary data input
// inside mc6809i (its `rnRESET <= nRESET` re-synchronizer, which reproduces
// the original core's one-extra-E-cycle reset-release delay). That dual use is
// intentional and matches the part; Verilator's SYNCASYNCNET heuristic cannot
// tell the difference.
/* verilator lint_off SYNCASYNCNET */

module mc6809e (
    input  logic        clk,        // system clock
    input  logic        ce,         // clock enable: one E-clock cycle per pulse
    input  logic        rst_n,
    output logic [15:0] addr,
    input  logic [7:0]  din,
    output logic [7:0]  dout,
    output logic        rw_n,       // 1=read, 0=write
    input  logic        irq_n,
    input  logic        firq_n,
    input  logic        nmi_n,
    input  logic        halt_n,
    output logic        ba,
    output logic        bs
);

    // ---- two-phase reconstruction ------------------------------------------
    // cen_q coincides with `ce`; cen_e is one clk later. Ordering matches a
    // real E/Q pair (Q falls, then E falls).
    logic cen_q;
    logic cen_e;

    assign cen_q = ce;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cen_e <= 1'b0;
        else        cen_e <= ce;
    end

    // ---- core --------------------------------------------------------------
    logic [7:0]   core_dout;
    logic [15:0]  core_addr;
    logic         core_rnw;
    logic         core_ba;
    logic         core_bs;
    /* verilator lint_off UNUSED */
    logic         core_avma;
    logic         core_busy;
    logic         core_lic;
    logic [111:0] core_regdata;
    /* verilator lint_on UNUSED */

    mc6809i #(
        .ILLEGAL_INSTRUCTIONS ("GHOST")     // mimic the real part's incomplete decode
    ) u_core (
        .D        (din),
        .DOut     (core_dout),
        .ADDR     (core_addr),
        .RnW      (core_rnw),
        .clk      (clk),
        .cen_E    (cen_e),
        .cen_Q    (cen_q),
        .BS       (core_bs),
        .BA       (core_ba),
        .nIRQ     (irq_n),
        .nFIRQ    (firq_n),
        .nNMI     (nmi_n),
        .AVMA     (core_avma),
        .BUSY     (core_busy),
        .LIC      (core_lic),
        .nHALT    (halt_n),
        .nRESET   (rst_n),
        .nDMABREQ (1'b1),
        .RegData  (core_regdata)
    );

    assign addr = core_addr;
    assign dout = core_dout;
    assign rw_n = core_rnw;
    assign ba   = core_ba;
    assign bs   = core_bs;

`ifndef SYNTHESIS
    // Simulation-only guard for the >=2 clk `ce` spacing requirement. No
    // synthesizable state is created or consumed by this block.
    logic ce_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ce_d <= 1'b0;
        else        ce_d <= ce;
    end
    always_ff @(posedge clk) begin
        if (rst_n && ce && ce_d) begin
            $display("%t mc6809e: CE_SPACING violation -- ce asserted on two consecutive clk cycles", $time);
            $stop;
        end
    end
`endif

endmodule

/* verilator lint_on SYNCASYNCNET */
`default_nettype wire
