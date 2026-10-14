// -----------------------------------------------------------------------------
// pigskin_protect.sv
//
// Pigskin 621AP (Bally/Midway MCR-68k) protection device, mapped by
// `pigskin_map` at 0x120000-0x120001 (mcr68.cpp:633).  The physical part is
// undumped; MAME's behavioural model is the only available reference, so this
// module is MAME_COMPATIBLE, not hardware-proven.  Per the project evidence
// order, a future PCB/PAL dump is authoritative over this file.
//
// Source of truth: D:\Arcade\AI\mame289\src\mame\bally\mcr68.cpp
//
//   mcr68_state::pigskin_protection_w   (mcr68.cpp:516-530)
//   mcr68_state::pigskin_protection_r   (mcr68.cpp:533-550)
//   pigskin_map entry                   (mcr68.cpp:633)
//   m_protection_data[5] state          (mcr68.cpp:135)
//
// WRITE (mcr68.cpp:516-530).  Guarded by ACCESSING_BITS_0_7 -- an upper-byte-
// only access is ignored entirely, so the shift register is clocked only when
// the LOWER data strobe is asserted.  The 5-entry history then shifts down and
// the new byte lands in [4] (mcr68.cpp:522-526):
//
//     data[0] <= data[1];
//     data[1] <= data[2];
//     data[2] <= data[3];
//     data[3] <= data[4];
//     data[4] <= din[7:0];
//
// so [4] is the MOST RECENT byte and [0] the oldest of the last five.
//
// READ (mcr68.cpp:533-550).  Purely combinational over the current history --
// a read has NO side effect on the shift register in MAME, and none here.
// Four priority-ordered sequence matches, transcribed verbatim:
//
//   1. [4]==0xE3 && [3]==0x94                                  -> 0x0000  :536-537
//   2. [4]==0xC7 && [3]==0x7B && [2]==0x36                     -> 0x0000  :538-539
//   3. [4]==0xC7 && [3]==0x7B                                  -> 0x0007  :540-541
//   4. [4]==0xC7 && [3]==0x1F && [2]==0x03 &&
//      [1]==0x25 && [0]==0x36                                  -> 0x0000  :542-544
//   default (unrecognised sequence, MAME only logerrors)       -> 0x0000  :549
//
// The ORDER of 2 before 3 is load-bearing and is preserved literally: rule 3's
// condition is a strict superset of rule 2's, so C7/7B/36 must return 0x0000
// and any other C7/7B must return 0x0007.  (MAME's comments record the
// firmware's expectations: "must be <= 1", "must be > 5", "must be < 3".)
// Rules 1 and 4 return the same value as the default and are therefore
// functionally redundant in MAME too; they are kept as explicit arms so this
// file stays a line-for-line transcription and a future MAME correction to any
// return value maps onto exactly one arm here.
//
// Because every arm except rule 3 returns 0x0000, the whole device reduces to
// a single expression -- but the priority chain below is written out in full
// deliberately.  Do not "simplify" it.
//
// SYNTHESIS NOTES: no gated clocks, all state in one `always_ff` with
// non-blocking assignment, combinational read fully defaulted (no latch),
// explicit widths throughout.
// -----------------------------------------------------------------------------

`default_nettype none
module pigskin_protect (
    input  wire        clk,
    input  wire        rst,      // synchronous, active high

    // ---- main-CPU bus access ------------------------------------------------
    // `cs`    -- cs_protect from mcr68_addr_decode (0x120000-0x120001).
    // `en`    -- ONE pulse per completed bus access (the integrator's existing
    //            single-cycle bus-access qualifier).  cs & en & we & !lds_n
    //            is the exact analogue of MAME's write handler firing with
    //            ACCESSING_BITS_0_7 true.
    // `lds_n` -- lower data strobe, active low = ACCESSING_BITS_0_7.
    input  wire        en,
    input  wire        cs,
    input  wire        we,       // 1 = write, 0 = read
    input  wire        lds_n,
    // din[15:8] is intentionally unused: MAME's handler is guarded by
    // ACCESSING_BITS_0_7 (mcr68.cpp:519) and stores only `data & 0xff`
    // (mcr68.cpp:526).  The full 16-bit port is kept so the integrator can
    // wire the CPU data bus straight in without a slice.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [15:0] din,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [15:0] dout
);

    // Last five bytes written, [4] = most recent.  mcr68.cpp:135 declares
    // `uint8_t m_protection_data[5] = { }` -- zero-initialised, which this
    // reset value matches.
    logic [7:0] pd0, pd1, pd2, pd3, pd4;

    // MAME's handler runs only when the lower byte lane is accessed.
    wire write_strobe = en & cs & we & ~lds_n;

    always_ff @(posedge clk) begin
        if (rst) begin
            pd0 <= 8'h00;
            pd1 <= 8'h00;
            pd2 <= 8'h00;
            pd3 <= 8'h00;
            pd4 <= 8'h00;
        end else if (write_strobe) begin
            pd0 <= pd1;
            pd1 <= pd2;
            pd2 <= pd3;
            pd3 <= pd4;
            pd4 <= din[7:0];
        end
    end

    // ---- combinational read (mcr68.cpp:533-550) -----------------------------
    always_comb begin
        if (pd4 == 8'hE3 && pd3 == 8'h94)
            dout = 16'h0000;                                    // :536-537
        else if (pd4 == 8'hC7 && pd3 == 8'h7B && pd2 == 8'h36)
            dout = 16'h0000;                                    // :538-539
        else if (pd4 == 8'hC7 && pd3 == 8'h7B)
            dout = 16'h0007;                                    // :540-541
        else if (pd4 == 8'hC7 && pd3 == 8'h1F && pd2 == 8'h03 &&
                 pd1 == 8'h25 && pd0 == 8'h36)
            dout = 16'h0000;                                    // :542-544
        else
            dout = 16'h0000;                                    // :549 default
    end

    // The five history bytes pd0..pd4 are directly visible by hierarchical
    // reference (dut.pd4 etc.) for debugging; no separate concatenated debug
    // net is provided, deliberately -- it would be dead logic in synthesis and
    // an unused-signal lint hit in simulation.

endmodule
`default_nettype wire
