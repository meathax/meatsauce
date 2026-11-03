// DECO-222 wrapper around T65 6502 core
// Implements opcode fetch data-bus encryption: D5 and D6 are swapped
// on M1/sync cycles only. Data fetches and write cycles pass through unmodified.
//
// Reference: MAME src/devices/cpu/m6502/deco222.cpp
//   bswap = ((byte & 0x9F) | ((byte & 0x40) >> 1) | ((byte & 0x20) << 1))
//   i.e. swap bits D5 and D6  (corrected 2026-05-30 — was wrongly D1<->D6)

module deco222 (
    input  wire        clk_sys,
    input  wire        ce,            // = ce_hclk4 (750 kHz)
    input  wire        reset,

    input  wire        nmi_n,
    input  wire        irq_n,
    input  wire        rdy,

    output wire [15:0] addr,
    input  wire [7:0]  di,
    output wire [7:0]  do,
    output wire        rw_n,          // 1 = read, 0 = write
    output wire        sync           // T65 SYNC: 1 on opcode fetch
);

    wire [7:0] di_eff;
    // T65 exposes a 24-bit address bus even in 6502 mode. Keep the complete
    // VHDL connection and explicitly retain the 6502 low word at this
    // wrapper's public 16-bit address interface.
    wire [23:0] addr_full;
    assign addr = addr_full[15:0];

    // AUDIT-2026-05-30 ROOT-CAUSE FIX: DECO-222 swaps D5<->D6 on opcode fetch, NOT D1<->D6.
    // The old D1<->D6 swap was WRONG (predecessor mis-transcribed MAME): it turned the BIOS
    // reset entry $F053 (raw 38 B8 C2 FF 9A) into SEC/CLV/illegal garbage, and $F615 raw $DD
    // into illegal $9F (CPU jammed there = the black-screen hang). Correct D5<->D6 yields
    // $F053 -> CLI/CLD/LDX #$FF/TXS (textbook reset) and $DD -> $BD (LDA abs,X). Verified vs the
    // ROM bytes. MAME formula: (b & 0x9F) | ((b&0x40)>>1) | ((b&0x20)<<1).
    // OLD (D1<->D6, wrong): assign di_eff = sync ? { di[7], di[1], di[5:2], di[6], di[0] } : di;
    assign di_eff = sync
        ? { di[7], di[5], di[6], di[4:0] }   // swap D5<->D6 on opcode fetch
        : di;

    // Instantiate T65 6502 core
    T65 cpu (
        .Mode      (2'b00),               // 6502 mode
        .Res_n     (~reset),              // active-low reset
        .Enable    (ce),                  // clock enable
        .Clk       (clk_sys),             // system clock
        .Rdy       (rdy),                 // ready (not used, always 1)
        .Abort_n   (1'b1),                // 65C816 abort, unused
        .IRQ_n     (irq_n),               // active-low interrupt request
        .NMI_n     (nmi_n),               // active-low non-maskable interrupt
        .SO_n      (1'b1),                // 6502 set-overflow, unused
        .R_W_n     (rw_n),                // read(1) / write(0) output
        .Sync      (sync),                // opcode fetch strobe
        .EF        (),                    // 65C02/816 stuff, unused
        .MF        (),
        .XF        (),
        .ML_n      (),
        .VP_n      (),
        .VDA       (),
        .VPA       (),
        .A         (addr_full),           // T65 address bus [23:0]
        .DI        (di_eff),              // data in (munged for opcode fetch)
        .DO        (do),                  // data out
        .Regs      (),                    // debug register read-out, unused
        .DEBUG     (),                    // debug port, unused
        .NMI_ack   ()                     // debug NMI ack, unused
    );

endmodule
