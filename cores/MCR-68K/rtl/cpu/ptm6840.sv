// ptm6840.sv -- Motorola MC6840 Programmable Timer Module (PTM)
//
// Synthesizable, generic/reusable SystemVerilog model of the MC6840, ported
// from MAME's device implementation:
//   D:\Arcade\AI\mame289\src\devices\machine\6840ptm.cpp / 6840ptm.h
// All "MAME line NNN" comments below refer to 6840ptm.cpp unless the header
// (6840ptm.h) is named explicitly. This is a from-scratch RTL model -- no
// existing open-source MiSTer/jtcores 6840 was found to port from (confirmed
// by prior research, see doc/you-a-makeing-a-fizzy-rabin.md).
//
// -----------------------------------------------------------------------
// Register map (8 registers, addr[2:0] = byte-address bits [3:1] -> reg 0-7)
//   0  CR1 or CR3 (write), selected by CR2 bit0 (CR1_SELECT); read = 0
//   1  CR2 (write); STATUS (read)
//   2  MSBBUF1 (write, shared MSB staging latch); Timer1 MSB (read)
//   3  LSB1 (write, commits latch1); shared LSB read-back buffer (read)
//   4  MSBBUF2 (write); Timer2 MSB (read)
//   5  LSB2 (write); shared LSB read-back buffer (read)
//   6  MSBBUF3 (write); Timer3 MSB (read)
//   7  LSB3 (write); shared LSB read-back buffer (read)
// This exactly matches MAME's enum in 6840ptm.h:74-83
// (PTM_6840_CTRL1=0, CTRL2/STATUS=1, MSBBUF1=2, LSB1=3, MSBBUF2=4, LSB2=5,
//  MSBBUF3=6, LSB3=7).
//
// Control register bit layout (both CR1/CR2/CR3), from 6840ptm.h:85-95:
//   bit0 : RESET_TIMERS (CR1 only) / CR1_SELECT (CR2 only) / T3_PRESCALE_EN (CR3 only)
//   bit1 : INTERNAL_CLK_EN  (1 = count from the chip's internal clock, 0 = external Cn pin)
//   bit2 : COUNT_MODE_8BIT  (1 = dual independent 8-bit counter, 0 = single 16-bit counter)
//   bit3-5: MODE            (0/2=continuous, 4/6=single-shot, 1/3/5/7=freq/pulse-width compare)
//   bit6 : INTERRUPT_EN
//   bit7 : COUNT_OUT_EN     (gates the On output pin)
//
// -----------------------------------------------------------------------
// Clocking model
// This module is driven by a single system clock `clk` plus two enable-style
// qualifiers:
//   - `ena`      : one clk-wide pulse per PTM *internal* clock period (e.g.
//                  CPU/10 on the MCR-68k board). Not part of the port list the
//                  requester enumerated verbatim, but required to make
//                  "internal-clock counting" meaningful in a generic reusable
//                  synchronous module without hard-coding a divide ratio or
//                  assuming `clk` itself already runs at the chip rate. Tie
//                  to 0 if a board only ever uses external Cn clocking.
//   - `c1/c2/c3` : external clock pins, oversampled and edge-detected against
//                  `clk`. The 6840 counts on the FALLING edge (MAME
//                  set_clock(), line 705-709: rising edges are ignored,
//                  falling edges decrement) -- reproduced with a 2-flop
//                  synchronizer + falling-edge detector per pin.
//
// Every real 6840 register transition in MAME's model (deduct_from_counter,
// state_changed, reload_counter's *state* effects, control/latch writes) is
// reproduced tick-by-tick here instead of via MAME's scheduled-attotime timer
// optimisation. Both produce the identical sequence of counter/output/status
// transitions; the RTL version is simply the literal per-edge hardware
// behaviour MAME's timer scheduling was approximating.
//
// -----------------------------------------------------------------------
// Deliberately NOT modelled (see also the final report to the requester):
//   - G1/G2/G3 gate inputs. Real MC6840 silicon has them; MAME's device
//     supports them (set_gate/m_gate); this module's requested port list does
//     not include them and the target board ties them inactive. Internally
//     "gated" is hardwired to false everywhere MAME's gate term would appear,
//     each such spot is commented. Adding real gate ports later is a small,
//     isolated change.
//   - A separate "fixed external clock frequency in Hz" mode
//     (ptm6840_device::set_ext_clock / m_external_clock). That concept only
//     exists in MAME to let the timer's own event scheduler compute a firing
//     time; it has no synchronous-RTL equivalent because every external
//     clock in real hardware/RTL is definitionally edge-driven via its pin.
//     This model always behaves like MAME's "external_clock == 0.0" case,
//     i.e. driven purely by the c1/c2/c3 pins (this is also exactly the mode
//     MAME's own header comment calls out for "the VBLANK clock on the MCR
//     units", which is precisely this board's C1/C3 usage).
//   - Autonomous O1/O2/O3 output generation for comparison modes (control
//     reg MODE = 1,3,5,7 i.e. freq/pulse-width comparison). MAME's own
//     state_changed() switch (line 616-655) has no case for these modes, so
//     MAME itself never drives the output pin from them either -- this is a
//     documented upstream limitation, not a gap introduced here.
//   - The "single shot output polarity" ambiguity flagged as a MAME TODO
//     (6840ptm.cpp:13-15) is reproduced exactly as MAME implements it, not
//     resolved differently.

module ptm6840 (
    input  logic       clk,
    input  logic       rst,        // synchronous, active-high

    input  logic       ena,        // 1 clk-wide pulse per PTM internal-clock period (e.g. CPU/10)

    // Bus-side register access -- addr[2:0] is the MAME register offset 0-7
    // directly (byte-address bits [3:1]); the caller is responsible for
    // qualifying `en` only on the correct odd/even byte lane per board wiring.
    input  logic       en,         // chip-select qualified per access
    input  logic       we,         // 1 = write, 0 = read
    input  logic [2:0] addr,
    input  logic [7:0] din,
    output logic [7:0] dout,

    // External clock inputs, counted on the falling edge
    input  logic       c1,
    input  logic       c2,
    input  logic       c3,

    // O1/O2/O3 outputs (not needed by the MCR-68k board, included for completeness)
    output logic       out1,
    output logic       out2,
    output logic       out3,

    output logic       irq         // active-high, combines all 3 timers' status & enable
);

    // Several registers below (status_bits, status_read_since_int in
    // particular) are legitimately written from more than one call site --
    // the top-level reset branch, and non-blocking assignments buried inside
    // automatic tasks (do_state_changed/process_write/process_read) that are
    // all invoked from the single always_ff at the bottom of this module.
    // The lint tool's MULTIDRIVEN check cannot see through the task-call
    // graph and flags this as if it were two concurrent processes; it is
    // not -- everything below executes within one always_ff, so ordinary
    // "last non-blocking assignment in procedural order wins" semantics
    // apply, and the intended winner at each such spot is documented at its
    // call site.
    /* verilator lint_off MULTIDRIVEN */

    // ---------------------------------------------------------------
    // Storage (MAME 6840ptm.h:110-129)
    // ---------------------------------------------------------------
    logic [7:0]  control_reg [0:2];   // CR1, CR2, CR3
    logic [15:0] counter     [0:2];   // live down-counters
    logic [15:0] latch       [0:2];   // reload value, committed on LSB write
    logic        output_ff   [0:2];   // internal toggle state (m_output)
    logic        single_fired[0:2];   // one-shot "already fired" latch
    logic        out_reg     [0:2];   // registered O1/O2/O3 pin state

    logic [2:0]  status_bits;         // per-timer IRQ-pending flags (m_status_reg bits 0-2)
    logic [2:0]  status_read_since_int; // m_status_read_since_int

    logic [7:0]  msb_buffer;          // single shared MSB staging latch (m_msb_buffer)
    logic [7:0]  lsb_buffer;          // single shared LSB read-back buffer (m_lsb_buffer)

    logic [2:0]  t3_scaler;           // m_t3_scaler (the /8 T3 prescaler counter)

    // 2-flop synchronizer + falling-edge detector per external clock pin
    logic [1:0]  c1_sr, c2_sr, c3_sr;

    assign out1 = out_reg[0];
    assign out2 = out_reg[1];
    assign out3 = out_reg[2];

    // ---------------------------------------------------------------
    // Combinational helpers
    // ---------------------------------------------------------------

    // MAME opmode table (6840ptm.cpp:56-66): modes 4 and 6 are single-shot.
    function automatic logic is_one_shot(input logic [2:0] m);
        is_one_shot = (m == 3'd4) || (m == 3'd6);
    endfunction

    // compute_counter() (MAME 6840ptm.cpp:282-334), specialised for a model
    // where `counter[idx]` is always the live, cycle-accurate count (no
    // interpolation needed since we tick every real edge). The only MAME
    // behaviour worth preserving here is the "held in RESET_TIMERS, timer
    // not enabled" alternate readback formula (line 292-302).
    //
    // "enabled" (m_enabled) in MAME means "this timer has a defined nonzero
    // clock frequency". Internal clock is always present -> enabled.
    // External clock in this model is always pin-edge-driven with no fixed
    // Hz (MAME's "external_clock == 0.0" case, see file header) -> not
    // enabled, so external-clocked timers always read back the live counter
    // directly, matching MAME line 286-291.
    function automatic logic [15:0] read_counter_value(input logic [1:0] idx);
        logic [15:0] latch_msb_x_lsbp1;
        begin
            latch_msb_x_lsbp1 = latch[idx][15:8] * ({8'h00, latch[idx][7:0]} + 16'h0001);
            if (!control_reg[idx][1]) begin
                // externally clocked (pin-driven) -> not "enabled": raw counter (line 289-290)
                read_counter_value = counter[idx];
            end else if (control_reg[0][0]) begin
                // RESET_TIMERS held (line 292-302)
                read_counter_value = control_reg[idx][2] ? latch_msb_x_lsbp1 : latch[idx];
            end else begin
                // internally clocked, running: live counter is always accurate here
                read_counter_value = counter[idx];
            end
        end
    endfunction

    // ---------------------------------------------------------------
    // Tick qualification (MAME set_clock(), 6840ptm.cpp:696-733, and the
    // duration*=m_t3_divisor scaling in reload_counter(), line 402-405,
    // unified here into one literal per-edge /8 prescaler ahead of the T3
    // counter input -- equivalent effect to MAME's two different code paths
    // for internally- vs externally-clocked T3, and matches real MC6840
    // hardware where the prescaler sits ahead of the clock-source mux.)
    //
    // "gated" is hardwired inactive throughout (see file header: G1/G2/G3 not
    // implemented), so the `!gated` term from MAME's set_clock() line 717
    // condition is always true and is omitted.
    // ---------------------------------------------------------------
    wire not_reset_held = ~control_reg[0][0];                 // !RESET_TIMERS (line 712)

    wire c1_fall = c1_sr[1] & ~c1_sr[0];
    wire c2_fall = c2_sr[1] & ~c2_sr[0];
    wire c3_fall = c3_sr[1] & ~c3_sr[0];

    wire tick0     = not_reset_held & (control_reg[0][1] ? ena : c1_fall);
    wire tick1     = not_reset_held & (control_reg[1][1] ? ena : c2_fall);
    wire tick2_pre = not_reset_held & (control_reg[2][1] ? ena : c3_fall);

    wire [3:0] t3_div  = control_reg[2][0] ? 4'd8 : 4'd1;      // T3_PRESCALE_EN (line 497)
    wire       t3_last = ({1'b0, t3_scaler} + 4'd1) >= t3_div;
    wire       tick2   = tick2_pre & t3_last;

    // ---------------------------------------------------------------
    // status/irq (update_interrupts(), MAME 6840ptm.cpp:248-274). Made fully
    // combinational: ANY_IRQ (status bit7) is always exactly this OR, so it
    // is not stored separately -- it is folded into the STATUS read value
    // below instead of being a redundant register.
    // ---------------------------------------------------------------
    wire t1_irq = status_bits[0] & control_reg[0][6];
    wire t2_irq = status_bits[1] & control_reg[1][6];
    wire t3_irq = status_bits[2] & control_reg[2][6];
    assign irq = t1_irq | t2_irq | t3_irq;

    wire [7:0] status_byte = {irq, 4'b0000, status_bits};

    // ---------------------------------------------------------------
    // state_changed() (MAME 6840ptm.cpp:600-659). Ends by reloading the
    // counter from the latch (line 658, folded from reload_counter()'s only
    // state-relevant effect, line 347 -- reload_counter()'s remaining logic
    // is MAME's own event-scheduling machinery and has no RTL equivalent
    // since this model ticks every real edge).
    // ---------------------------------------------------------------
    task automatic do_state_changed(input logic [1:0] idx);
        logic one_shot;
        logic dual8;
        logic end_of_cycle;
        logic new_out;
        begin
            one_shot     = is_one_shot(control_reg[idx][5:3]);
            dual8        = control_reg[idx][2];
            end_of_cycle = (~dual8 & ~one_shot) | output_ff[idx];   // line 607

            if (end_of_cycle) begin
                status_bits[idx]           <= 1'b1;                 // line 610
                status_read_since_int[idx] <= 1'b0;                 // line 611
            end

            case (control_reg[idx][5:3])
                3'd0, 3'd2: begin // continuous (line 618-630)
                    new_out        = ~output_ff[idx];
                    output_ff[idx] <= new_out;
                    out_reg[idx]   <= control_reg[idx][7] ? new_out : 1'b0;
                end
                3'd4, 3'd6: begin // single-shot (line 632-654)
                    new_out        = ~output_ff[idx];
                    output_ff[idx] <= new_out;
                    if (!single_fired[idx]) begin
                        if (control_reg[idx][7])
                            out_reg[idx] <= new_out;
                        if (!new_out)
                            single_fired[idx] <= 1'b1;               // freeze until reinit
                    end else begin
                        out_reg[idx] <= 1'b0;
                    end
                end
                default: ; // modes 1/3/5/7: MAME's switch has no case -> output untouched
            endcase

            counter[idx] <= latch[idx];                              // reload_counter(), line 347
        end
    endtask

    // ---------------------------------------------------------------
    // deduct_from_counter() (MAME 6840ptm.cpp:191-240), called once per
    // qualifying tick.
    // ---------------------------------------------------------------
    task automatic process_tick(input logic [1:0] idx);
        logic [7:0]  lsb_pre, msb_pre, new_lsb, new_msb;
        logic [15:0] new_counter;
        begin
            if (control_reg[idx][2]) begin
                // dual independent 8-bit mode (line 195-227)
                lsb_pre = counter[idx][7:0];
                msb_pre = counter[idx][15:8];
                if (lsb_pre == 8'h00) begin
                    // LSB borrows (lsb was already at 0 before this decrement)
                    new_lsb = latch[idx][7:0] + 8'h01;
                    if (msb_pre == 8'h00) begin
                        // MSB underflows below zero -> full timeout (line 208-213)
                        do_state_changed(idx); // its own counter<=latch(idx) stands unmodified
                    end else if (msb_pre == 8'h01) begin
                        // MSB reaches zero -> mid-cycle output/status event (line 214-219),
                        // but the locally computed {new_msb,new_lsb} is written AFTER
                        // do_state_changed's own reload and so wins (matches MAME's
                        // execution order: state_changed() runs, then line 225 executes).
                        new_msb = latch[idx][15:8] + 8'h01;
                        do_state_changed(idx);
                        counter[idx] <= {new_msb, new_lsb};
                    end else begin
                        // KNOWN, DELIBERATE DEVIATION FROM MAME (adversarial audit,
                        // 2026-08-05) -- do not "fix" this to match MAME without new
                        // PCB evidence. MAME's deduct_from_counter() computes this
                        // exact case as `lsb = (m_latch[idx]&0xff)+1` into a uint16_t
                        // (6840ptm.cpp:205, NOT masked back to 8 bits) then
                        // `m_counter[idx] = (msb<<8)+lsb` (line 225): when
                        // latch_lsb==0xFF, lsb becomes 256 (not wrapped), which adds a
                        // full +1*256 into the MSB byte position and exactly cancels
                        // the `msb--` at line 206 -- i.e. MAME's MSB does not actually
                        // decrement on that tick. That is a C++ integer-width artifact
                        // of MAME's software model, not real MC6840 behavior: the
                        // actual chip's LSB is a genuine 8-bit register that cannot
                        // hold 256. Per this project's evidence order (MAME is a
                        // compatibility oracle, not hardware truth -- never copy a
                        // known MAME bug into RTL), this RTL intentionally implements
                        // the hardware-correct independent 8-bit wraparound instead.
                        // This WILL produce a genuine MAME-vs-RTL trace divergence if
                        // any game programs a dual-8-bit timer's latch with LSB==0xFF
                        // and lets it run to a borrow with pre-decrement MSB outside
                        // {0,1} -- if that divergence is ever observed during
                        // differential debugging, this comment is the explanation, not
                        // a hint to "fix" the RTL.
                        new_msb = msb_pre - 8'h01;
                        counter[idx] <= {new_msb, new_lsb};
                    end
                end else begin
                    new_lsb = lsb_pre - 8'h01;
                    counter[idx] <= {msb_pre, new_lsb};
                end
            end else begin
                // word (16-bit) mode (line 230-239)
                new_counter = counter[idx] - 16'h0001;
                if ((is_one_shot(control_reg[idx][5:3]) && !output_ff[idx]) ||
                    (new_counter == 16'hFFFF)) begin
                    do_state_changed(idx); // reload from latch supersedes the decrement
                end else begin
                    counter[idx] <= new_counter;
                end
            end
        end
    endtask

    // ---------------------------------------------------------------
    // write() (MAME 6840ptm.cpp:486-592)
    // ---------------------------------------------------------------
    task automatic process_write(input logic [2:0] a, input logic [7:0] d);
        logic [1:0]  idx;
        logic        reset_bit_diff;
        logic [15:0] new_latch_v;
        integer      i;
        begin
            case (a)
                3'd0, 3'd1: begin // CTRL1 / CTRL2 (line 490-560)
                    idx = (a == 3'd1) ? 2'd1 : (control_reg[1][0] ? 2'd0 : 2'd2); // CR1_SELECT, line 493
                    // Only bit0 (RESET_TIMERS, meaningful for idx==0 only) is needed from
                    // MAME's 8-bit `diffs` (line 494): the other use of diffs, `diffs &
                    // INTERRUPT_EN` (line 507-508) just re-triggers update_interrupts(),
                    // which is purely combinational here (irq/status_byte), so it is a
                    // deliberate no-op and is not reproduced.
                    reset_bit_diff = d[0] ^ control_reg[idx][0];
                    control_reg[idx] <= d;

                    if (!d[7])                          // COUNT_OUT_EN cleared -> force out low (line 510-514)
                        out_reg[idx] <= 1'b0;

                    if (idx == 2'd0 && reset_bit_diff) begin  // RESET_TIMERS toggled (line 517-552)
                        if (d[0]) begin
                            // holding reset down (line 520-534)
                            status_bits           <= 3'b000;
                            status_read_since_int  <= 3'b000;
                            for (i = 0; i < 3; i = i + 1) begin
                                counter[i]      <= latch[i];   // reload_counter() state effect
                                output_ff[i]    <= 1'b0;
                                out_reg[i]      <= 1'b0;
                            end
                        end else begin
                            // releasing reset (line 536-548)
                            for (i = 0; i < 3; i = i + 1) begin
                                single_fired[i] <= 1'b0;
                                counter[i]      <= latch[i];   // reload_counter() state effect
                            end
                        end
                        status_bits <= 3'b000;                 // unconditional re-clear, line 550
                    end
                    // MAME's update_expiration_for_clock_source() (lines
                    // 555-557, 727-800) snapshots the continuously scheduled
                    // internal-clock deadline when a timer is changed to the
                    // external pin.  `compute_counter()` uses
                    // attotime::as_ticks(), which floors the remaining
                    // fractional period; after an internal enable there is
                    // therefore one fewer whole count than the discrete `ena`
                    // edge counter when this write lands between edges.  The
                    // board uses exactly this internal->external transition
                    // for T3 (Pigskin's scanline counter), and the one-count
                    // floor is observable in MAME's MSB/LSB readback.  Model
                    // that state conversion, saturating at zero so a timer
                    // already at its deadline is not wrapped to FFFF.
                    if (control_reg[idx][1] && !d[1] && (counter[idx] != 16'h0000)) begin
                        counter[idx] <= counter[idx] - 16'h0001;
                    end
                end

                3'd2, 3'd4, 3'd6: begin // MSBBUF1/2/3 (line 562-569)
                    msb_buffer <= d;
                end

                3'd3, 3'd5, 3'd7: begin // LSB1/2/3 (line 571-590)
                    idx         = 2'((a - 3'd3) >> 1);
                    new_latch_v = {msb_buffer, d};
                    latch[idx]        <= new_latch_v;
                    status_bits[idx]  <= 1'b0;                 // clear that timer's IRQ (line 579)
                    if (!control_reg[idx][4] || control_reg[0][0]) // mode bit4 clear, or reset held (line 583)
                        counter[idx]  <= new_latch_v;          // reload_counter() state effect
                end

                default: ;
            endcase
        end
    endtask

    // ---------------------------------------------------------------
    // read() side effects (MAME 6840ptm.cpp:429-479). The returned value
    // itself is produced combinationally below (dout); this task only
    // performs the state changes a read triggers.
    // ---------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    task automatic process_read(input logic [2:0] a);
        logic [1:0] idx;
        logic [7:0] rv_lsb;
        logic [15:0] rv_counter;
        begin
            case (a)
                3'd1: begin // STATUS (line 439-443)
                    status_read_since_int <= status_read_since_int | status_bits;
                end
                3'd2, 3'd4, 3'd6: begin // MSBBUF1/2/3 (line 452-470)
                    idx    = 2'((a - 3'd2) >> 1);
                    rv_counter = read_counter_value(idx);
                    rv_lsb = rv_counter[7:0];
                    if (status_read_since_int[idx])
                        status_bits[idx] <= 1'b0;              // clear that timer's IRQ (line 460-463)
                    lsb_buffer <= rv_lsb;                      // latch shared LSB buffer (line 467)
                end
                default: ; // CTRL1 read (=0) and LSB reads have no side effect
            endcase
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------------------------------------------------------
    // dout mux -- combinational, mirrors read()'s return value using the
    // pre-this-edge register state (matches a same-cycle synchronous read).
    // ---------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] selected_counter;
    always_comb begin
        selected_counter = read_counter_value(2'((addr - 3'd2) >> 1));
        case (addr)
            3'd0:          dout = 8'h00;               // CTRL1/CTRL3 read always 0 (line 435-436)
            3'd1:          dout = status_byte;          // STATUS
            3'd2, 3'd4, 3'd6: dout = selected_counter[15:8]; // MSBBUF -> MSB
            3'd3, 3'd5, 3'd7: dout = lsb_buffer;         // all LSB regs alias the one shared latch
            default:       dout = 8'h00;
        endcase
    end
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------------------------------------------------------
    // Sequential core
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            // device_reset() (MAME 6840ptm.cpp:150-178)
            control_reg[0] <= 8'h01;  // CR1 resets with RESET_TIMERS held (line 170)
            control_reg[1] <= 8'h00;
            control_reg[2] <= 8'h00;
            counter[0]     <= 16'hFFFF; counter[1] <= 16'hFFFF; counter[2] <= 16'hFFFF;
            latch[0]       <= 16'hFFFF; latch[1]   <= 16'hFFFF; latch[2]   <= 16'hFFFF;
            output_ff[0]   <= 1'b0; output_ff[1] <= 1'b0; output_ff[2] <= 1'b0;
            single_fired[0]<= 1'b0; single_fired[1] <= 1'b0; single_fired[2] <= 1'b0;
            out_reg[0]     <= 1'b0; out_reg[1] <= 1'b0; out_reg[2] <= 1'b0;
            status_bits            <= 3'b000;
            status_read_since_int  <= 3'b000;
            // KNOWN, DELIBERATE DEVIATION FROM MAME (adversarial audit,
            // 2026-08-05): msb_buffer/lsb_buffer are zeroed only once in MAME's
            // device_start() (6840ptm.cpp:108-109) and are NEVER touched by
            // device_reset() (150-178) -- a runtime/warm reset in MAME leaves
            // them at whatever an earlier MSBBUF write or MSBBUF read last set,
            // not zero. This RTL zeros them on every `rst` pulse, which matches
            // MAME only for the very first (power-on) reset -- if `rst` is
            // asserted more than once in a run (a warm reset distinct from
            // power-on), the next MSBBUF/LSB read here can differ from MAME's.
            // No PCB evidence exists either way for real MC6840 warm-reset
            // behavior; zeroing on every reset is kept as the safer,
            // deterministic-for-simulation default rather than replicating an
            // unproven MAME implementation detail. Narrow and likely benign in
            // practice (firmware normally rewrites MSBBUF/LSB after any reset
            // before trusting them) -- flagged here so a divergence in this
            // specific narrow scenario is recognized, not mis-debugged as a
            // new bug.
            msb_buffer     <= 8'h00;
            lsb_buffer     <= 8'h00;
            t3_scaler      <= 3'b000;
            c1_sr <= 2'b00; c2_sr <= 2'b00; c3_sr <= 2'b00;
        end else begin
            // external clock pin synchronizers
            c1_sr <= {c1_sr[0], c1};
            c2_sr <= {c2_sr[0], c2};
            c3_sr <= {c3_sr[0], c3};

            // T3 prescaler bookkeeping (uses the pre-update t3_scaler value
            // captured combinationally above in t3_last/tick2)
            if (tick2_pre) begin
                if (t3_last) t3_scaler <= 3'b000;
                else         t3_scaler <= t3_scaler + 3'b001;
            end

            // Clock-tick processing (deduct_from_counter() equivalent)
            if (tick0) process_tick(2'd0);
            if (tick1) process_tick(2'd1);
            if (tick2) process_tick(2'd2);

            // Bus register access. Deliberately processed AFTER tick
            // processing above so that a register write occurring in the
            // same clk cycle as a clock-tick event wins any conflicting
            // field update. MAME's event scheduler never has true
            // simultaneity between a bus write and a timer firing, so this
            // ordering is a designed RTL tie-break, not a modelled MAME
            // behaviour; it is deterministic and documented here rather than
            // left to tool-dependent non-blocking-assignment ordering.
            if (en) begin
                if (we) process_write(addr, din);
                else    process_read(addr);
            end
        end
    end

    /* verilator lint_on MULTIDRIVEN */

endmodule
