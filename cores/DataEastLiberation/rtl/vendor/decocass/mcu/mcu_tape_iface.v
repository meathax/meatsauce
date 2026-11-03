/*============================================================================
  MCU ↔ Tape ↔ Main CPU Interface

  Glue logic connecting:
  - i8041 MCU (P1, P2, T0, T1 ports) to tape_streamer (task 16)
  - Main 6502 CPU ($E5xx address space) to i8041 host-bus interface
  - Dongle lower-nibble (task 18) to CPU read response

  Pin mappings per decocass_m.cpp (lines 1734-1835):

  P1 (tape data/status in; motor/direction/speed out):
    P1.0 ← tape_data       (MAME: ~data bit if set, see decocass_m.cpp line 1778)
    P1.1 ← tape_clock      (MAME: ~clk bit if set, line 1779)
    P1.2 ← tape_bot        (MAME: ~BOT# if set, line 1780)
    P1.3 ← tape_eot        (MAME: ~EOT# if set, line 1781)
    P1.4 → tape_motor_on   (MAME: ~motor if set, line 1782; inverted in schematic)
    P1.5 → tape_direction  (MAME: ~forward if set, line 1783; inverted)
    P1.6/7 → speed[1:0]    (MAME: speed control, lines 1784-1785)

  P2 (input mux select out; status in):
    P2[3:0] → input mux select (to inputs.v task 23)
    P2[7:4] ← status bits (from tape_streamer or MCU; returned as upper nibble of $E5xx read)

  T0/T1 (timer inputs):
    T0 ← tape direction sensor (TODO: verify mapping in MAME)
    T1 ← tape status bit (TODO: verify mapping in MAME)

  $E5xx Host Bus Protocol:
    CPU write $E5xx:  cs_n/wr_n strobed, A0 = cpu_addr[0], host_din = cpu_dout
    CPU read $E5xx:   cs_n/rd_n strobed, A0 = cpu_addr[0], host_dout captured, combined with dongle_din_low4

  Clock domains:
    - clk_sys: 96 MHz (all Verilog)
    - ce_hclk: 6 MHz MCU clock enable (1 per T48 machine state)
    - ce_hclk1: 3 MHz main 6502 clock enable
    - ce_tape: 4.8 kHz tape data rate
    One ce_hclk1 pulse spans exactly 2 ce_hclk pulses; stretch cpu strobes accordingly.

============================================================================*/

`timescale 1 ps / 1 ps

module mcu_tape_iface (
    input  wire        clk_sys,
    input  wire        ce_hclk,        // 6 MHz MCU clock enable
    input  wire        ce_hclk1,       // 3 MHz CPU clock enable
    input  wire        ce_tape,        // 4.8 kHz tape clock enable
    input  wire        reset,

    // MCU ports (to/from i8041_top)
    output wire [7:0]  mcu_p1_in,
    input  wire [7:0]  mcu_p1_out,
    output wire [7:0]  mcu_p2_in,
    input  wire [7:0]  mcu_p2_out,
    output wire        mcu_t0,
    output wire        mcu_t1,

    // MCU host-bus interface (stretched strobes to i8041_top)
    output wire        mcu_cs_n,
    output wire        mcu_rd_n,
    output wire        mcu_wr_n,
    output wire        mcu_a0,
    output wire [7:0]  mcu_dout,

    // Tape signals (to/from tape_streamer)
    output wire        tape_motor_on,
    output wire        tape_direction,
    output wire [1:0]  tape_speed_select,
    input  wire        tape_data,
    input  wire        tape_clock,
    input  wire        tape_bot,
    input  wire        tape_eot,

    // Main CPU side ($E5xx)
    input  wire        cpu_e5_re,      // Read strobe (new signal from decocass.v task 28)
    input  wire        cpu_e5_we,      // Write strobe (existing cpu_we_e5xx)
    input  wire [7:0]  cpu_addr_lo,    // Low byte of address ($E5xx)
    input  wire [7:0]  cpu_dout,       // CPU data out
    output wire [7:0]  cpu_din,        // Upper nibble = MCU status, lower = dongle

    // MCU host bus output — DBBOUT register (8-bit).
    // The dongle data path returns the i8041's host output register
    // (`upi41_master_r(0)`), NOT P2 outputs.
    input  wire [7:0]  mcu_host_dout,
    input  wire        mcu_host_dout_oe,

    // Dongle interface (downstream to task 18)
    output wire [7:0]  dongle_addr_lo,
    output wire        dongle_re,
    output wire        dongle_we,
    output wire [7:0]  dongle_dout,
    input  wire [3:0]  dongle_din_low4
);

    //------------------------------------------------------------------------
    // P1 Wiring (decocass_m.cpp lines 1734-1789)
    //
    // 2026-05-17 — REWRITE. Previous version wired tape_data/tape_clock/
    // tape_bot/tape_eot into mcu_p1_in[0..3]. That was WRONG: per MAME's
    // i8041_p1_r (decocass_m.cpp:1768-1789), P1 reads return `m_i8041_p1`
    // unchanged — i.e. whatever the MCU LAST WROTE. P1 is purely OUTPUT from
    // the MCU (tape transport control, REQ output to main CPU). Tape signals
    // do NOT come in via P1.
    //
    // P1 output bit assignments per the LOG strings at line 1742-1749:
    //   bit 0 = DATA-WRT (MCU writes data bit to tape)
    //   bit 1 = DATA-CLK (MCU writes clock to tape)
    //   bit 2 = FAST     (1 = normal speed, 0 = fast)
    //   bit 3 = (unknown, BIT3)
    //   bit 4 = REW      (1 = rewind active, 0 = forward)
    //   bit 5 = FWD      (1 = forward active, 0 = stopped)
    //   bit 6 = WREN     (write enable)
    //   bit 7 = REQ      (REQ signal to main CPU, polled via $E502 bit 0)
    //
    // For OUR tape_streamer, we need to derive motor/direction/speed from
    // P1.4/5/2 according to the MAME-decoded LOG semantics:
    //   FAST = ~P1.2 (bit 2 = 0 means fast)
    //   REW  = ~P1.4 (bit 4 = 0 means rewind active)
    //   FWD  = ~P1.5 (bit 5 = 0 means forward active)
    //   Motor on if FWD OR REW. Direction = FWD.
    //
    // Inputs to MCU's P1: all 1s (idle pull-ups; open-drain semantics).
    //------------------------------------------------------------------------
    assign mcu_p1_in = 8'hFF;   // No external drives on P1 (per MAME)

    // Decode P1 outputs into tape control. NOTE: MCU writes inverted-active
    // signals (a 0 = "asserted") per LOG comments above.
    wire fast_active = ~mcu_p1_out[2];
    // TAPE-DIR-2026-06-04: a MAME-LITERAL swap (rew=~P1.5, fwd=P1.5&~P1.4, from i8041_p1_w where
    // bit5=0 => NEGATIVE speed) was TRIED and REVERTED — it REGRESSED on FPGA: with the ORIGINAL
    // decode the tape reads blocks (counter 999->998, then ERROR #1); with the swap it reads
    // NOTHING (deck looks dead, ERROR #52, counter never gets a value). Why the original is right:
    // the 8041 syncs on the block HEADER (0xAA), which is at the START of a block, so it must see
    // header-then-data = FORWARD streaming (clockpos increasing). Original `fwd=~P1.5` makes
    // read_block's P1.5=0 => forward => correct order. MAME's bit5=0=>negative is a DIFFERENT
    // physical convention (reads while rewinding) that does NOT map onto this streamer's clockpos
    // layout. So ERROR #1's cause is NOT direction — it's downstream (speed/bit-timing on a block
    // that IS being read forward; the count stays at the 999 default => the header data is garbage).
    // DIRECTION: tested MAME-literal (rew=~P1.5/fwd=P1.5&~P1.4) WITH the probe 2026-06-04 →
    // MEASURABLY WORSE: tape ran to the clockpos-0 wall, read_block never dispatched ($2E8 dark),
    // nothing delivered (ROW2/3 = $00), BOT-now lit. It breaks positioning (rewind/seek spools the
    // wrong way) AND reading. The ORIGINAL forward decode drives the tape INTO the data region
    // (RCLK@read lit, $05 delivered), so forward is empirically correct for THIS streamer's layout,
    // even though it diverges from MAME's bit5-sign. (Why MAME's negative-speed read works in MAME
    // but not ported = unresolved; not the bug to chase — the $05 garbage on a FORWARD read is.)
    // MAME-literal kept for reference (do NOT re-enable — proven worse):
    // wire rew_active  = ~mcu_p1_out[5];
    // wire fwd_active  =  mcu_p1_out[5] & ~mcu_p1_out[4];
    wire rew_active  = ~mcu_p1_out[4];   // ORIGINAL (restored): forward read reaches the data
    wire fwd_active  = ~mcu_p1_out[5];   // ORIGINAL (restored): P1.5=0 => forward

    assign tape_motor_on     = fwd_active | rew_active;   // ~P1.5 | ~P1.4
    assign tape_direction    = fwd_active;       // 1 = forward, 0 = rewind
    // FIX 2026-05-30: speed_select now encodes MAGNITUDE only (direction is tape_direction above);
    // 00=stop, 01=normal(1x), 10=fast(7x) — matches MAME |speed| 0/1/7. Was 11=rewind (direction
    // baked in), which left fast-rewind indistinguishable from normal and the streamer ignored it.
    assign tape_speed_select = (!(fwd_active | rew_active)) ? 2'b00 :  // stopped
                               fast_active                   ? 2'b10 :  // fast (7x)
                                                               2'b01;   // normal (1x)

    //------------------------------------------------------------------------
    // P2 Wiring (decocass_m.cpp lines 1791-1835)
    //
    // 2026-05-17 — REWRITE. Previous version had mcu_p2_in[7:4] hardcoded
    // to 0, dropping the tape status bits the MCU firmware needs. Per
    // MAME's i8041_p2_r (line 1816):
    //   data = (m_i8041_p2 & ~0xe0) | m_cassette->get_status_bits();
    // So P2[7:5] are OR'd with the cassette status bits, while P2[4:0]
    // come from the MCU's own latched writes.
    //
    // From decocass_tape.cpp:288-338 (get_status_bits):
    //   bit 0x20 = BOT/EOT (set in LEADER, BOT, EOT, TRAILER regions)
    //   bit 0x40 = RCLK    (read clock — active in data region)
    //   bit 0x80 = RDATA   (read data bit)
    //
    // For our tape_streamer outputs:
    //   tape_bot (from streamer) is true in LEADER/BOT/EOT/TRAILER regions
    //   tape_eot similar
    //   tape_clock and tape_data are the serial stream
    //------------------------------------------------------------------------
    wire status_bot_eot = tape_bot | tape_eot;    // bit 5 — tape end indicator
    wire status_rclk    = tape_clock;             // bit 6 — read clock
    wire status_rdata   = tape_data;              // bit 7 — read data

    assign mcu_p2_in[7] = status_rdata;
    assign mcu_p2_in[6] = status_rclk;
    assign mcu_p2_in[5] = status_bot_eot;
    assign mcu_p2_in[4] = 1'b1;                   // IN4 (unknown source — idle pull-up)
    assign mcu_p2_in[3:0] = 4'b1111;              // P2[3:0] are MCU outputs; idle pull-up

    //------------------------------------------------------------------------
    // T0/T1 Wiring — MAME does NOT register callbacks for T0/T1 on the MCU
    // (decocass.cpp:1026-1029 only wires P1/P2). The i8041 emulator defaults
    // T0/T1 to floating-high. Match that with hardcoded 1s.
    //------------------------------------------------------------------------
    assign mcu_t0 = 1'b1;
    assign mcu_t1 = 1'b1;

    //------------------------------------------------------------------------
    // $E5xx Host Bus Protocol
    //
    // The MCU runs at ce_hclk (6 MHz), driven on clk_sys.
    // The CPU runs at ce_hclk1 (3 MHz), also on clk_sys.
    // One ce_hclk1 pulse spans exactly 2 ce_hclk pulses.
    //
    // When the CPU issues a read or write strobe (cpu_e5_re or cpu_e5_we),
    // that strobe is 1 clock (clk_sys) wide and asserted during ce_hclk1.
    // We must stretch it to 2 ce_hclk pulses (16 clk_sys clocks) so the
    // MCU sees it and latches the bus.
    //
    // Strategy:
    //   - Detect rising edge of cpu_e5_re/cpu_e5_we (on clk_sys)
    //   - Latch the strobe and A0/data
    //   - Assert cs_n=0/rd_n=0 or cs_n=0/wr_n=0 for 2 ce_hclk pulses
    //   - On rd_n, capture host_dout when host_dout_oe asserts
    //   - Return {mcu_status_high4, dongle_din_low4} as cpu_din
    //------------------------------------------------------------------------

    // Pipeline: detect ce_hclk1 edge to know when CPU strobe is fresh
    reg        ce_hclk1_r, ce_hclk1_rr;
    always @(posedge clk_sys) begin
        ce_hclk1_r  <= ce_hclk1;
        ce_hclk1_rr <= ce_hclk1_r;
    end
    wire       ce_hclk1_rising = ce_hclk1_r && !ce_hclk1_rr;

    // ===== DIAG-REVERT-2026-05-30: original host-strobe gen was PHASE-BROKEN =====
    // cpu_e5_we is 1 clk_sys wide *during* ce_hclk1, but ce_hclk1_rising (above) is delayed
    // one clk_sys, so `cpu_e5_we_lat <= cpu_e5_we` sampled the pulse a cycle late and latched
    // 0. mcu_wr_n therefore NEVER asserted -> i8041 IBF never set -> CASSETTE ERROR 59.
    // (Confirmed on FPGA: diag cell7 = mcu_wr_seen_ever was BLACK.)
    // TO REVERT: delete the FIXED block below and un-/* */ the original.
    /* ---- ORIGINAL (broken), preserved verbatim ----
    // Latch CPU strobes on rising edge of ce_hclk1
    reg        cpu_e5_re_lat, cpu_e5_we_lat;
    reg [7:0]  cpu_addr_lo_lat, cpu_dout_lat;
    always @(posedge clk_sys) begin
        if (ce_hclk1_rising) begin
            cpu_e5_re_lat  <= cpu_e5_re;
            cpu_e5_we_lat  <= cpu_e5_we;
            cpu_addr_lo_lat <= cpu_addr_lo;
            cpu_dout_lat   <= cpu_dout;
        end
    end
    reg  [1:0] hclk_strobe_cnt;
    wire       hclk_strobe_active = (hclk_strobe_cnt != 0);
    reg        ce_hclk_r, ce_hclk_rr;
    always @(posedge clk_sys) begin
        ce_hclk_r  <= ce_hclk;
        ce_hclk_rr <= ce_hclk_r;
    end
    wire       ce_hclk_rising = ce_hclk_r && !ce_hclk_rr;
    always @(posedge clk_sys or posedge reset) begin
        if (reset) begin
            hclk_strobe_cnt <= 0;
        end else if ((cpu_e5_re_lat || cpu_e5_we_lat) && !hclk_strobe_active) begin
            if (ce_hclk_rising)
                hclk_strobe_cnt <= 2;
        end else if (ce_hclk_rising && hclk_strobe_active) begin
            hclk_strobe_cnt <= hclk_strobe_cnt - 1;
        end
    end
    assign     mcu_cs_n  = ~hclk_strobe_active;
    assign     mcu_rd_n  = ~(hclk_strobe_active && cpu_e5_re_lat);
    assign     mcu_wr_n  = ~(hclk_strobe_active && cpu_e5_we_lat);
    assign     mcu_a0    = cpu_addr_lo_lat[0];
    assign     mcu_dout  = cpu_dout_lat;
    ---- end original ---- */

    // ===== FIXED 2026-05-30: phase-independent capture + held op-type =====
    // Latch the access the instant cpu_e5_we/re pulses (addr+data valid then), hold it in a
    // sticky 'pending' flag until a 2-ce_hclk strobe can launch, and hold the op-type for the
    // whole window so mcu_wr_n/mcu_rd_n stay asserted long enough for the i8041 db_bus to
    // register the write (and set IBF). Write takes priority if a read is also pending.
    reg        pend_we, pend_re;
    reg        strobe_is_we, strobe_is_re;
    reg [7:0]  cpu_addr_lo_lat, cpu_dout_lat;
    reg  [1:0] hclk_strobe_cnt;
    wire       hclk_strobe_active = (hclk_strobe_cnt != 2'd0);

    reg        ce_hclk_r;
    always @(posedge clk_sys) begin
        ce_hclk_r  <= ce_hclk;
    end
    // Clock enables are events, including consecutive enabled clocks during
    // turbo loading. Edge detection loses ticks when ce_hclk remains high.
    wire       ce_hclk_tick = ce_hclk_r;

    // MAME-PARITY 2026-05-30: route the host strobe to the i8041 ONLY for $E5x0/$E5x1
    // (offset bit1 == 0). MAME `decocass_e5xx_w` sends a 6502 write to `upi41_master_w`
    // only when (offset & E5XX_MASK[0x02]) == 0; $E5x2/$E5x3 are STATUS/dongle space and
    // must NOT reach the MCU. Likewise `decocass_e5xx_r` composes the STATUS byte at
    // $E5x2/$E5x3 in software, and only the $E5x0/$E5x1 path returns the MCU DBBOUT.
    // Before this gate, every BIOS status poll at $E5x2 strobed the MCU (clearing OBF /
    // polluting a0_q in upi41_db_bus), and any write to $E5x2/$E5x3 was delivered to the
    // MCU as a bogus command byte -> firmware reject at $0ED (cmd must be $25..$34) ->
    // motor never commanded -> CASSETTE ERROR 59. (dongle_re/we below stay UNGATED — the
    // dongle module does its own offset decode; cpu_din status mux is unchanged.)
    wire e5_we_mcu = cpu_e5_we & ~cpu_addr_lo[1];
    wire e5_re_mcu = cpu_e5_re & ~cpu_addr_lo[1];

    always @(posedge clk_sys or posedge reset) begin
        if (reset) begin
            pend_we <= 1'b0; pend_re <= 1'b0;
            strobe_is_we <= 1'b0; strobe_is_re <= 1'b0;
            hclk_strobe_cnt <= 2'd0;
            cpu_addr_lo_lat <= 8'd0; cpu_dout_lat <= 8'd0;
        end else begin
            // Capture addr/data on the live CPU access strobe (valid this cycle).
            // MAME-PARITY 2026-05-30: gated e5_we_mcu/e5_re_mcu (was cpu_e5_we/cpu_e5_re) so
            // only $E5x0/$E5x1 reach the MCU; $E5x2/$E5x3 no longer strobe it.
            if (e5_we_mcu) begin cpu_addr_lo_lat <= cpu_addr_lo; cpu_dout_lat <= cpu_dout; end
            else if (e5_re_mcu) cpu_addr_lo_lat <= cpu_addr_lo;

            if (!hclk_strobe_active && ce_hclk_tick &&
                (pend_we || e5_we_mcu || pend_re || e5_re_mcu)) begin
                hclk_strobe_cnt <= 2'd2;
                if (pend_we || e5_we_mcu) begin       // write priority
                    strobe_is_we <= 1'b1; strobe_is_re <= 1'b0;
                    pend_we <= 1'b0;                  // a co-pending read stays queued
                end else begin
                    strobe_is_we <= 1'b0; strobe_is_re <= 1'b1;
                    pend_re <= 1'b0;
                end
            end else begin
                if (e5_we_mcu) pend_we <= 1'b1;
                if (e5_re_mcu) pend_re <= 1'b1;
                if (hclk_strobe_active && ce_hclk_tick)
                    hclk_strobe_cnt <= hclk_strobe_cnt - 2'd1;
            end
        end
    end

    // Drive MCU host bus during strobe window (exposed via output ports)
    assign     mcu_cs_n  = ~hclk_strobe_active;
    assign     mcu_rd_n  = ~(hclk_strobe_active && strobe_is_re);
    assign     mcu_wr_n  = ~(hclk_strobe_active && strobe_is_we);
    // A0-LIVE-READ-FIX-2026-06-05: a0 was the LATCHED cpu_addr_lo_lat[0]. The BIOS read loop does
    // `bit $e501` (a0=1) immediately before `lda $e500` (a0=0); the continuously-tracked latch could
    // still present $E501's a0=1 during the $E500 read window -> db_o returned DBBSTS ($05) instead of
    // DBBOUT ($20) AND the $E500 read didn't clear OBF. MEASURED: 8041 OUT-DBBs $20 (r3=$20, OUTDBB lit)
    // but the 6502 stored $05 (DBBSTS = OBF+F0, position-independent). The 6502 holds its address stable
    // for the whole access, so for READS bind a0 to the LIVE cpu_addr_lo[0]; WRITES keep the latched
    // value (captured at access time for the delayed-strobe case). Original below.
    // assign     mcu_a0    = cpu_addr_lo_lat[0];                                           // ORIGINAL (stale latch)
    // assign     mcu_a0    = (hclk_strobe_active && strobe_is_re) ? cpu_addr_lo[0] : cpu_addr_lo_lat[0]; // v1: only live DURING strobe — 6502 samples AFTER strobe ends -> fell back to stale latch=1 -> still $05
    // A0-LIVE-READ-FIX v2 2026-06-05: reads use the LIVE 6502 address UNCONDITIONALLY (the 6502 holds
    // $E500 for the whole access, so a0=0 whenever the bus is sampled -> db_o = dbbout_q = $20, and the
    // $E500 read clears OBF). Only WRITES use the latched value (write data captured at access time).
    assign     mcu_a0    = strobe_is_we ? cpu_addr_lo_lat[0] : cpu_addr_lo[0];
    assign     mcu_dout  = cpu_dout_lat;

    // Capture MCU host_dout on read completion
    // When a read strobe completes, host_dout_oe should assert and hold data.
    // We'll capture it after the strobe window and return it for 1 CPU cycle.
    // TODO: receive host_dout and host_dout_oe from i8041_top; capture and hold.

    reg [7:0] mcu_dout_read;  // Latched read data from MCU
    // TODO: capture mcu read data after read strobe completes

    //------------------------------------------------------------------------
    // Dongle Lower-Nibble Integration
    //------------------------------------------------------------------------
    // The main CPU's $E5xx read combines:
    //   Upper nibble: MCU P2[7:4] status bits
    //   Lower nibble: Dongle-specific encryption (from task 18)
    //
    // We proxy the read/write strobes and address to the dongle module
    // and return the combined result.

    assign dongle_addr_lo = cpu_addr_lo;
    // DONGLE-E5XXMASK-GATE-2026-06-27: MAME routes ONLY $E5x0/$E5x1 (offset & E5XX_MASK[0x02])==0 to the dongle
    // (decocass_e5xx_r:1200/1227, decocass_e5xx_w); $E5x2/$E5x3 are STATUS and NEVER reach m_dongle_r/_w. Our
    // dongle modules decode A0 but NOT bit1, so the BIOS load loop's constant $E502 status polls (bios.log
    // F512/F526/F205) were hitting the dongle as if they were $E500 and CLOBBERING its sequence-stateful latch
    // every poll: type3 d0_latch (dongle_type3.v:119) and type1 latch1 (dongle_type1.v:180), plus spurious
    // type3 counter ++ on $E503. Result = corrupted decoded bytes -> CRC fail -> CASSETTE ERROR #1 on BOTH
    // dongled games (nodong has no state -> immune). Gate the strobes to $E5x0/1 to match MAME's E5XX_MASK.
    // DIAG-REVERT-2026-06-27: original ungated strobes below, uncomment + delete the gated pair to restore.
    // assign dongle_re      = cpu_e5_re;
    // assign dongle_we      = cpu_e5_we;
    assign dongle_re      = cpu_e5_re & ~cpu_addr_lo[1];   // $E5x0/1 only (E5XX_MASK)
    assign dongle_we      = cpu_e5_we & ~cpu_addr_lo[1];   // $E5x0/1 only (E5XX_MASK)
    assign dongle_dout    = cpu_dout;

    // Return result to main CPU — MAME splits behavior on (offset & E5XX_MASK)
    // where E5XX_MASK = 0x02 (decocass_m.cpp:212):
    //
    //   (offset & 2) == 2  → STATUS byte composed from MCU/cassette state
    //                        (decocass_m.cpp:1199-1213)
    //   (offset & 2) == 0  → dongle data path (decocass_m.cpp:1227-1233)
    //
    // Until 2026-05-17 this module returned `{mcu_p2_out[7:4], dongle_din_low4}`
    // for EVERY $E5xx read regardless of offset, so BIOS polls of $E502 STATUS
    // (cassette-present, REQ/, EOT/, ERR/) received garbage and BIOS stalled
    // immediately after the palette-clear phase. Symptom: solid-black screen
    // with palette-swatch overlay showing every entry black (BIOS only ever
    // wrote 0xFF clearing pattern, never reached "write real colors").
    //
    // Status byte mapping (MAME decocass_m.cpp:1204-1212):
    //   D7 = !cassette_present   (active-low; 0 = present)
    //   D6 = 1                   (floating input)
    //   D5 = 1                   (floating input)
    //   D4 = bot_eot             (BOT/EOT direct from drive — bit 5 of
    //                             m_cassette->get_status_bits()))
    //   D3 = m_i8041_p2[2]       (P22 = ERR/)
    //   D2 = m_i8041_p2[1]       (P21 = EOT/)
    //   D1 = m_i8041_p2[0]       (P20 = FNO/)
    //   D0 = m_i8041_p1[7]       (P17 = REQ/)
    //
    // Cassette is always "present" in this system (BRAM-loaded image), so
    // wire cassette_present_n = 0. bot_eot from tape signals.

    wire        cassette_present_n = 1'b0;    // 0 = present (active-low)
    wire        bot_eot            = tape_bot | tape_eot;

    wire [7:0]  e5xx_status_byte = {
        cassette_present_n,     // D7
        1'b1,                   // D6 floating
        1'b1,                   // D5 floating
        bot_eot,                // D4
        mcu_p2_out[2],          // D3 ERR/
        mcu_p2_out[1],          // D2 EOT/
        mcu_p2_out[0],          // D1 FNO/
        mcu_p1_out[7]           // D0 REQ/
    };

    wire        e5xx_is_status = (cpu_addr_lo[1] == 1'b1);   // E5XX_MASK = 0x02

    // Latch MCU host data when MCU is presenting it. Per
    // upi41_db_bus.vhd:256-257:
    //     db_o <= dbbout_q when a0_i = '0' else status_q;
    // mcu_host_dout already carries DBBOUT (for $E5x0 reads) or DBBSTS
    // (for $E5x1 reads) based on mcu_a0 = cpu_addr_lo_lat[0]. We just
    // latch whichever register the i8041 presented during the bus stretch.
    // DBBOUT-LIVE-FIX-2026-06-04: $E500 (tape DATA) was returning a STALE LATCHED byte. The latch
    // captured mcu_host_dout on EVERY $E5xx read strobe (mcu_host_dout_oe), so the read driver's
    // `bit $e501` (DBBSTS) just before `lda $e500` left DBBSTS latched ($05 = OBF+F0), and $E500
    // handed back that STATUS byte instead of the tape DATA → constant $05 every byte, independent
    // of tape content (explains why a bit-shift changed nothing). MAME `decocass_e5xx_r` returns
    // DBBOUT LIVE (m_dongle_r, no latch). mcu_host_dout already carries the correct register live
    // (dbbout_q for a0=0 = $E5x0, status_q for a0=1 = $E5x1), so return it directly.
    // ORIGINAL (stale-latch bug):
    // reg [7:0] latched_host_dout;
    // always @(posedge clk_sys or posedge reset) begin
    //     if (reset)                 latched_host_dout <= 8'h00;
    //     else if (mcu_host_dout_oe) latched_host_dout <= mcu_host_dout;
    // end
    // assign cpu_din = e5xx_is_status ? e5xx_status_byte : latched_host_dout;
    assign cpu_din = e5xx_is_status ? e5xx_status_byte : mcu_host_dout;   // FIXED: live DBBOUT

    //------------------------------------------------------------------------
    // Summary of TODO items
    //------------------------------------------------------------------------
    // TODO(verify-with-mame): P2[7:4] status bit sources (tape BOT/EOT, etc.)
    // TODO(verify-with-mame): T0/T1 timer input mapping in decocass_m.cpp
    // TODO(new-signal-decocass.v): Add cpu_re_e5xx strobe (currently only cpu_we_e5xx exists)
    // TODO(new-signal-decocass.v): Expose mcu_cs_n, mcu_rd_n, mcu_wr_n, mcu_a0 to i8041_top
    // TODO(new-signal-i8041_top): Expose host_dout and host_dout_oe from upi41_core

endmodule
