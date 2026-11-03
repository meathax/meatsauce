/*============================================================================
  i8041 MCU Top-Level Wrapper

  Instantiates upi41_core (UPI-41 variant of T48 with host-bus interface),
  wired to a dual-port program memory (mcu_pmem) and the main system bus
  (host-side slave interface for 6502 access at $E5xx).

  Port assignments:
    - xtal_i / xtal_en_i / reset_i: clock & reset from main PLL + clock divider
    - Host interface (cs_n, rd_n, wr_n, a0, db_*): 6502 access at $E5xx
    - Tape interface (t0_i, t1_i, p1_*, p2_*, prog_n): to tape_streamer (task 17)
    - Program ROM (rom_we, rom_addr_w, rom_data_w): written by rom_loader (task 25)

  Generics:
    - xtal_div_3_g=1: T48 divides XTAL by 3 then /5 for machine states
    - register_mnemonic_g=1: registered instruction output
    - sample_t1_state_g=4: T1 sampling state
    - is_upi_type_a_g=0: standard UPI-41 (not type-A variant)

  Clock notes:
    - clk_sys: main system clock (typically 48 MHz for MiSTer)
    - ce_hclk: 6 MHz clock enable (from clock_div.v, line ~100)
    - Both xtal_i and clk_i get clk_sys; xtal_en_i and en_clk_i get ce_hclk
    - T48 internally divides by 3 then /5 → ~400 kHz machine state rate
    - Effective i8041 ALE rate ≈ 400 kHz (matches documented 6 MHz XTAL / 15)

  Reset polarity:
    - reset_i to upi41_core is ACTIVE-HIGH (standard T48 convention)
    - External reset_n is inverted at top-level port
============================================================================*/

`timescale 1 ps / 1 ps

module i8041_top (
    input  wire        clk_sys,        // 96 MHz system clock (rom-load / host domain)
    input  wire        ce_hclk,        // 6 MHz clock enable (xtal_en_i again after REALCLK-REVERT-2026-06-04)
    input  wire        clk_8041,       // MCU-CLK-REALCLK-2026-06-04: dedicated ~8 MHz REAL clock; UNUSED after REALCLK-REVERT (kept for easy re-apply)
    input  wire        reset_n,        // active-low external reset

    // Host (main 6502) slave interface
    // Driven by task 17's decode of $E5xx
    input  wire        cs_n,           // Chip Select (active-low)
    input  wire        rd_n,           // Read Enable (active-low)
    input  wire        wr_n,           // Write Enable (active-low)
    input  wire        a0,             // Address bit 0 (selects register)
    input  wire [7:0]  host_din,       // 6502 data bus → MCU
    output wire [7:0]  host_dout,      // MCU data bus → 6502
    output wire [7:0]  host_sts,       // DBBSTS exposure 2026-05-30: real STATUS reg (OBF/IBF/F0/F1/ST4-7)
    output wire        host_dout_oe,   // Output enable for MCU (tristate control)
    output wire        sync_o,         // SYNC output (ALE signal)

    // Tape / cassette / input multiplexer interface (to task 17)
    input  wire        t0_i,           // Timer 0 input
    input  wire        t1_i,           // Timer 1 input
    input  wire [7:0]  p1_i,           // Port 1 input
    output wire [7:0]  p1_o,           // Port 1 output
    output wire        p1_low_imp,     // Port 1 low-impedance drive (open-drain style)
    input  wire [7:0]  p2_i,           // Port 2 input (bit 7 = DACK_N for DMA)
    output wire [7:0]  p2_o,           // Port 2 output
    output wire        p2l_low_imp,    // Port 2 low-byte low-impedance drive
    output wire        p2h_low_imp,    // Port 2 high-byte low-impedance drive
    output wire        prog_n,         // Program mode (inverted; normally low)

    // Program ROM loader interface (task 25)
    // Port A: write-only (rom_loader writes cassmcu1.cpu)
    // Port B: read-only (upi41_core fetches instructions)
    input  wire        rom_we,         // BRAM write enable
    input  wire [9:0]  rom_addr_w,     // BRAM write address (A)
    input  wire [7:0]  rom_data_w,     // BRAM write data (A)

    // DIAG-2026-06-03: expose MCU program counter (pmem fetch addr) for the handshake probe
    output wire [10:0] pmem_addr_o,
    // DIAG-REVERT-2026-06-05: expose rb0 r3/r5/r1 (= dmem[3]/[5]/[1]) so the wrapper can latch the
    // 8041's assembled tape byte (r3) + the failing CRC flags (r5/r1) at PC==$317. Splits (A) sample-
    // phase vs (B) $11E CRC-execution. Delete these 3 ports + the assigns below + the taps in
    // Arcade-DECOCassette.sv to revert.
    output wire [7:0]  dmem_r3_o,
    output wire [7:0]  dmem_r5_o,
    output wire [7:0]  dmem_r1_o
);

    //--------------------------------------------------------------------------
    // Internal signals
    //--------------------------------------------------------------------------

    wire [10:0] pmem_addr;    // Program memory address (11 bits in UPI41)
    wire [7:0]  pmem_data;    // Program memory data (8 bits read)
    assign pmem_addr_o = pmem_addr;   // DIAG-2026-06-03: MCU PC out for probe

    // DMEM-RAM-FIX-2026-06-04: the T48 core has NO internal data RAM — t48_dmem_ctrl only
    // computes addresses and passes data through (data_o <= dmem_data_i). The 64-byte 8041
    // register/scratch/stack RAM is EXTERNAL (canonical t8041_notri instantiates generic_ram_ena).
    // DECO previously tied dmem_data_i=0 => EVERY RAM read returned 0 => `mov r0,a`/`mov a,r0` in the
    // command dispatch ($0EF/$0FA) made A=0 at `jmpp @a` ($0FB), so every command jumped to mem[$00]
    // instead of its handler (no REQ/motor/OUT-DBB ever). These wires + u_dmem below restore the RAM.
    wire [7:0]  dmem_addr;    // Data memory address (core drives 8 bits; I8041A RAM = 128B => use [6:0])
    wire [7:0]  dmem_din;     // Data to RAM   (core dmem_data_o)
    wire [7:0]  dmem_dout;    // Data from RAM (core dmem_data_i)
    wire        dmem_we;      // RAM write enable (core dmem_we_o)

    // MCU-CLK-FIX-2026-06-03: the core's XTAL/3 clock-enable output, fed back
    // into en_clk_i (matches canonical t8041_notri.vhd: en_clk_i => xtal3_s;
    // xtal3_o => xtal3_s). Keeps the machine-state FSM phase-locked to the
    // XTAL sub-phases that place ALE/PSEN/RD/WR.
    wire        mcu_xtal3;

    //--------------------------------------------------------------------------
    // Program Memory (dual-port BRAM)
    // Port A: written by rom_loader
    // Port B: read by upi41_core
    //--------------------------------------------------------------------------

    mcu_pmem u_pmem (
        .clk_a      (clk_sys),      // Port A write: rom_loader (clk_sys)
        .we_a       (rom_we),
        .addr_a     (rom_addr_w),
        .din_a      (rom_data_w),
        // REALCLK-REVERT-2026-06-04: Port B back to clk_sys (synchronous host bus, no CDC).
        // To re-apply the real clock, restore the clk_8041 line and comment the clk_sys line.
        // .clk_b      (clk_8041),     // REALCLK: Port B read on real 8041 clock
        .clk_b      (clk_sys),      // REVERTED: Port B read on clk_sys (same domain as Port A)
        .addr_b     (pmem_addr),
        .dout_b     (pmem_data)
    );

    //--------------------------------------------------------------------------
    // DMEM-RAM-FIX-2026-06-04: 8041 internal Data RAM (64 bytes) — the piece DECO
    // omitted. Mirrors the canonical t8041_notri's generic_ram_ena: synchronous,
    // registered-address read, clocked on the fast clock (clk_sys, same domain as
    // mcu_pmem and the core's clk_i after REALCLK-REVERT). ena='1' (always), so it
    // registers the address every clk_sys edge; the 1-cycle read latency is absorbed
    // by the core reading dmem_data_i on the slower en_clk (xtal3) mstates.
    //--------------------------------------------------------------------------
    // DMEM-RAM-128-2026-06-04: the DECO MCU is an I8041A (decocass.cpp:1025) = 128 bytes of internal
    // RAM, NOT 64. Was 64 (dmem_addr[5:0]) — any RAM access at 64-127 truncated/WRAPPED to 0-63,
    // corrupting the registers/stack and sending the tape data loop down its error branches
    // ($329/$33E) so it never sent a byte ($2C8 dark). Full 128 bytes, addr[6:0].
    reg  [7:0] dmem_mem [0:127];
    reg  [6:0] dmem_a_q;
    always @(posedge clk_sys) begin
        if (dmem_we) dmem_mem[dmem_addr[6:0]] <= dmem_din;
        dmem_a_q <= dmem_addr[6:0];
    end
    assign dmem_dout = dmem_mem[dmem_a_q];

    // DIAG-REVERT-2026-06-05: combinational taps of rb0 r3/r5/r1 for the $317 byte-assembly probe.
    assign dmem_r3_o = dmem_mem[3];   // rb0.r3 = assembled tape byte (read at $317)
    assign dmem_r5_o = dmem_mem[5];   // rb0.r5 = CRC flag tested first  ($318 jnz $33E)
    assign dmem_r1_o = dmem_mem[1];   // rb0.r1 = CRC flag tested second ($31B jnz $329)

    //--------------------------------------------------------------------------
    // UPI41 Core Instantiation
    //
    // Entity: upi41_core
    // File:   rtl/cpu/T48/upi41_core.vhd
    //
    // This is the UPI-41 variant of the T48 core, which includes:
    //   - Host-bus interface (cs_n, rd_n, wr_n, a0, db_i/o/dir)
    //   - Program and data memory interfaces
    //   - Port 1 and Port 2 I/O
    //   - Timer module (T0 overflow, T1 input)
    //   - Flag storage (F0, F1) accessed via host bus
    //   - Input buffer (IBF) / Output buffer (OBF) flags
    //
    // The host-bus is FULLY INSIDE the core via upi41_db_bus submodule (line 352).
    // CS_N/RD_N/WR_N/A0 directly decode register addresses and generate
    // dmem-style read/write strobes for the internal I/O register bank.
    //
    // Generics:
    //   - xtal_div_3_g=1: T48 divides XTAL by 3, then /5 internally for mstate
    //   - register_mnemonic_g=1: instruction mnemonic stored in flip-flops (not used here)
    //   - sample_t1_state_g=4: T1 input sampled in MSTATE4
    //   - is_upi_type_a_g=0: Standard UPI-41 (vs. type-A with extra DMA features)
    //--------------------------------------------------------------------------

    upi41_core u_upi41 (
        // Clock & Reset
        // MCU-CLK-REALCLK-2026-06-04: feed a REAL clock with xtal_en='1' (the canonical T48
        // contract, matching Arcade-JunoFirst's working 8039). clk_sys+ce_hclk broke multi-cycle
        // ADD carry (the 8041 range-rejected valid commands). Now clk_i==xtal_i==clk_8041.
        //
        // REALCLK-REVERT-2026-06-04: REVERTED — 8041 back on clk_sys+ce_hclk, synchronous with the
        // 6502 so upi41_db_bus (which samples the 6502's cs_n/wr_n/a0/db_i) has NO host-bus CDC.
        // IBF-INT-ACK (in upi41_db_bus.vhd), NOT the clock, is what fixed dispatch — the "carry bug"
        // was a red herring — so the real-clock domain was pure liability for the host bus. KEEP the
        // en_clk<-xtal3 fix (MCU-CLK-FIX-2026-06-03) below. To re-apply the real clock, restore the
        // two clk_8041/1'b1 lines and comment the two clk_sys/ce_hclk lines (also clk_i + pmem clk_b).
        // .xtal_i         (clk_8041),     // REALCLK: real ~8 MHz clock
        // .xtal_en_i      (1'b1),         // REALCLK: always enabled
        .xtal_i         (clk_sys),      // REVERTED: was clk_sys
        .xtal_en_i      (ce_hclk),      // REVERTED: was ce_hclk
        // DIAG-REVERT-2026-05-30: T48 res_active_c='0' => reset is ACTIVE-LOW. The ~ here held the
        // core in reset during NORMAL run (reset_n=1 -> ~reset_n=0 = res_active_c => permanent reset),
        // so ibf_q/status_q were frozen at 0 and the MCU never executed. Pass reset_n straight.
        // .reset_i        (~reset_n),     // ORIGINAL (WRONG: comment claimed active-high)
        .reset_i        (reset_n),      // FIXED: active-low, matches T48 res_active_c='0'

        // Host interface (6502 bus at $E5xx)
        // These pins are decoded by upi41_db_bus inside the core
        .cs_n_i         (cs_n),         // Chip Select
        .rd_n_i         (rd_n),         // Read strobe
        .wr_n_i         (wr_n),         // Write strobe
        .a0_i           (a0),           // Address bit 0 (0=command, 1=data)
        .db_i           (host_din),     // Data bus input
        .db_o           (host_dout),    // Data bus output
        .sts_o          (host_sts),     // DBBSTS exposure 2026-05-30
        .db_dir_o       (host_dout_oe), // Output enable (active-high)
        .sync_o         (sync_o),       // Sync/ALE output (strobes addresses)

        // Timer & external inputs
        .t0_i           (t0_i),         // Timer 0 input (tape clock sense)
        .t1_i           (t1_i),         // Timer 1 input

        // Port 1 (input multiplexer for joystick/coin/start)
        .p1_i           (p1_i),
        .p1_o           (p1_o),
        .p1_low_imp_o   (p1_low_imp),

        // Port 2 (control signals for tape motor, LED, etc.)
        .p2_i           (p2_i),
        .p2_o           (p2_o),
        .p2l_low_imp_o  (p2l_low_imp),
        .p2h_low_imp_o  (p2h_low_imp),

        // Program mode flag (active-low, inverted on output)
        .prog_n_o       (prog_n),

        // Core clock & enable (separate from xtal for flexibility)
        // Some designs use clk_i != xtal_i, but we tie them here
        // REALCLK-REVERT-2026-06-04: core clock back to clk_sys (see xtal_i note above).
        // .clk_i          (clk_8041),     // REALCLK: core clock = real 8041 clock
        .clk_i          (clk_sys),      // REVERTED: was clk_sys
        // MCU-CLK-FIX-2026-06-03: en_clk_i was tied to ce_hclk (same net as
        // xtal_en_i) with xtal3_o discarded. That ran the machine-state FSM at
        // ce_hclk while the XTAL-phase / ALE / RD / WR logic ran at ce_hclk/3 —
        // 3x desync, so the MCU executed but garbled instruction sequencing
        // (dispatch at $0ED / jmpp never reached OUT DBB -> CASSETTE ERROR 59).
        // Feed the core's own XTAL/3 output back in, per canonical t8041_notri.
        // TO REVERT: restore the two ORIGINAL lines below and delete the FIXED pair.
        // .en_clk_i       (ce_hclk),      // ORIGINAL (WRONG)
        // .xtal3_o        (),             // ORIGINAL (WRONG: xtal3 discarded)
        .en_clk_i       (mcu_xtal3),    // FIXED: en_clk = core's XTAL/3 enable
        .xtal3_o        (mcu_xtal3),    // FIXED: feedback loop (== canonical)

        // Program memory interface (connects to mcu_pmem)
        .pmem_addr_o    (pmem_addr),    // 11-bit address (i8041 is 2K max; we use 10 bits)
        .pmem_data_i    (pmem_data),    // 8-bit instruction data

        // DMEM-RAM-FIX-2026-06-04: connect the core's data-memory bus to the new 64-byte
        // u_dmem RAM above. The old tie-offs (commented) WERE the bug: the T48 core has no
        // internal RAM, so dmem_data_i=0 blanked every register/scratch/stack read.
        // ORIGINAL (WRONG — no RAM, all reads = 0):
        // .dmem_addr_o    (),
        // .dmem_we_o      (),
        // .dmem_data_i    (8'h00),
        // .dmem_data_o    (),
        .dmem_addr_o    (dmem_addr),    // FIXED: RAM address (8 bits; RAM uses [5:0])
        .dmem_we_o      (dmem_we),      // FIXED: RAM write enable
        .dmem_data_i    (dmem_dout),    // FIXED: RAM read data (was tied 0 = the bug)
        .dmem_data_o    (dmem_din),     // FIXED: RAM write data

        // Generics (via port-map default)
        // .xtal_div_3_g => 1,
        // .register_mnemonic_g => 1,
        // .sample_t1_state_g => 4,
        // .is_upi_type_a_g => 0
    );

endmodule
