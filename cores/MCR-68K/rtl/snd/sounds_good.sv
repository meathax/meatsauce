// =============================================================================
// sounds_good.sv -- Bally/Midway MCR-68k "Sounds Good" sound board
// (A080-91863-B000, midway_sound.cpp's midway_sounds_good_device), ported from
// the only known open-source implementation of this board,
// third_party/Arcade-MCR3Mono_MiSTer/rtl/sounds_good.vhd, to synthesizable
// SystemVerilog (this project is Verilator-verified; VHDL cannot be compiled
// by Verilator -- see C:\Users\meath\.claude\plans\you-a-makeing-a-fizzy-rabin.md,
// "Sound" section and its research-findings preamble).
//
// FILE-OWNERSHIP NOTE: this module is intentionally self-contained. It does
// NOT instantiate, modify, or depend on the exact current state of
// rtl/mcr68_main_board.sv, rtl/cpu/fx68k.sv, rtl/cpu/mcr68_m68k.sv, or
// sim/sim_mcr68_headless.cpp (all mid-edit by a separate, unrelated
// investigation at the time this file was written). It DOES instantiate
// rtl/cpu/mcr68_m68k.sv -- that file's port list is a stable, already-
// documented interface explicitly designed to be reused for exactly this
// second-CPU-instance case (see that file's own header). Final cross-board
// wiring into mcr68_main_board.sv (sndsel/sint/stat <-> the main board's
// 0x0C0000 sound-I/O port, audio routing) is explicitly OUT OF SCOPE here and
// lands in a later integration step.
//
// Sibling modules already built under rtl/snd/ define this module's external
// contract on both sides of the bus:
//   - rtl/snd/mcr68_snd_mem_sim.sv (ROM+RAM storage, sim-only): declares
//     itself "the (separate, not-yet-written) Sounds Good address decoder"
//     as its caller, taking a pre-decoded {cpu_addr[17:0], cpu_din, cpu_dout,
//     cpu_uds_n, cpu_lds_n, cpu_we_n, rom_cs, ram_cs} bus. THIS module is
//     that address decoder -- its mem_* / rom_cs / ram_cs ports below are
//     named and polarised to cross-wire 1:1 with mcr68_snd_mem_sim's ports of
//     the same purpose (mem_addr->cpu_addr, mem_dout->cpu_din,
//     mem_din<-cpu_dout, mem_we_n->cpu_we_n, etc).
//   - rtl/snd/mcr68_snd_dac.sv (AD7533 DAC output filter): takes this
//     module's raw dac10[9:0] and applies the LM359 MFB low-pass
//     approximation. THIS module deliberately does NOT filter or register
//     dac10 beyond the PIA's own output latches -- see "DAC bit assembly"
//     below.
//
//   The Xenophobe Sounds Good schematic also routes PIA CA2 into the
//   remote-volume/MC3340 analogue control network.  The digital CA2 level is
//   exported as dbg_ca2 for trace/review; the analogue gain law is not guessed
//   here until the component response and firmware activity are measured.
//
// =============================================================================
// Hardware map (evidence: D:\Arcade\AI\mame289\src\mame\bally\midway_sound.cpp,
// midway_sounds_good_device -- read directly for this port, not paraphrased)
// =============================================================================
//   68000 @ 8 MHz = DERIVED_CLOCK(1,2) of a 16 MHz board oscillator
//     (midway_sound.cpp:607, device_add_mconfig: "M68000(config, m_cpu,
//     DERIVED_CLOCK(1, 2));"). No 6840 on this board, only the PIA
//     (per the plan's "Sound" section).
//
//   soundsgood_map (midway_sound.cpp:591-598), global_mask 0x7ffff:
//     000000-03FFFF  ROM                                    (line 595)
//     060000-060007  PIA, mirror 00FFF0, D8-D15 (umask16(0xff00)),
//                    read_alt/write_alt because RS0<-A2, RS1<-A1
//                    (swapped from the usual RS0<-A1/RS1<-A2 -- verbatim
//                    from the in-source comment at line 596: "RS0 connects
//                    to A2, RS1 connects to A1, hence the 'alt' functions
//                    are used.")                             (line 596)
//     070000-070FFF  RAM, mirror 00F000                      (line 597)
//
//   AD7533 10-bit DAC "value" is not a separate chip in this model, just a
//   direct wire concatenation of the PIA's own output latches:
//     porta_w (midway_sound.cpp:530-534):
//       m_dacval = (data << 2) | (m_dacval & 3);   // PA[7:0] -> dacval[9:2]
//     portb_w (midway_sound.cpp:541-550):
//       m_dacval = (m_dacval & ~3) | (data >> 6);  // PB[7:6] -> dacval[1:0]
//   i.e. dacval[9:2]=PA[7:0], dacval[1:0]=PB[7:6] -- exactly what the donor
//   sounds_good.vhd does at line 218: "audio_out <= pia_pa_out(7 downto
//   0)&pia_pb_out(7 downto 6);". MAME's m_dacval is only a register because
//   MAME's device callbacks fire per-port; on real hardware (and in this
//   port) the PIA's own OLA/OLB latches already hold both halves
//   persistently, so a live combinational read of {pa_out, pb_out[7:6]}
//   reproduces the identical function with no extra register -- see "DAC bit
//   assembly" below for why this module deliberately does NOT add one.
//
//   portb_w (midway_sound.cpp:541-550) also derives the (Xenophobe-unused)
//   status readback:
//     uint8_t z_mask = m_pia->port_b_z_mask();
//     if (~z_mask & 0x10) m_status = (m_status & ~1) | ((data >> 4) & 1);
//     if (~z_mask & 0x20) m_status = (m_status & ~2) | ((data >> 4) & 2);
//   The z_mask gating is a MAME-internal optimisation of ITS OWN m_status
//   latch (used to serve the *main board's* read() of this device, which
//   Xenophobe never performs -- see the plan's "Sound" section: "PB4-PB5 = 2-
//   bit status out (Xenophobe never reads this)"). It is not a property of
//   the physical PB4/PB5 pins themselves, which the donor VHDL models simply
//   as `stat <= pia_pb_out(5 downto 4)` (sounds_good.vhd:223) with no latch
//   or gating at all. This module follows the donor here: `stat` is a direct,
//   un-gated combinational tap of the PIA's own PB5:PB4 output-latch bits.
//   This is a deliberate simplification (not a guess) -- flagged explicitly
//   in the completion report, not hidden.
//
//   irq_w (midway_sound.cpp:557-561, wired at 613-614):
//     int combined_state = m_pia->irq_a_state() | m_pia->irq_b_state();
//     m_cpu->set_input_line(4, combined_state ? ASSERT_LINE : CLEAR_LINE);
//   PIA IRQA|IRQB -> sound 68000 IPL4, autovectored. The donor VHDL
//   (sounds_good.vhd:100/204) wires this same combined flag onto fx68k's
//   IPL2n pin specifically, with IPL1n/IPL0n tied to '1': that is the
//   correct active-low encoding for interrupt LEVEL 4 (binary 100 -> IPL2n=0,
//   IPL1n=1, IPL0n=1), not a different, lower interrupt level -- reproduced
//   below via mcr68_m68k's generic ipl_n[2:0] port.
//
//   Command handshake, main-board side (xenophobe_control_w, per the plan's
//   "Sound" section, itself citing mcr68.cpp:383-388 -- not independently
//   re-opened by this task, which was scoped to midway_sound.cpp + the VHDL
//   donor + the plan; treated here as an already-established plan finding):
//     sounds_good.write(((ctrl & 0x000f) << 1) | ((ctrl & 0x0010) >> 4));
//   i.e. control-word bits 0-3 -> command nibble, bit 4 -> strobe.
//   synced_write (midway_sound.cpp:656-663) then does, on the resulting
//   8-bit `param`:
//     m_pia->portb_w((param >> 1) & 0x0f);   // restores the bits[3:0] nibble
//     m_pia->ca1_w(~param & 0x01);           // strobe bit0, INVERTED onto CA1
//   See "sint/CA1 polarity" below for how this module reproduces both lines.
//
//   reset_write (midway_sound.cpp:519-523) is commented out of the current
//   mcr68.cpp driver's wiring but is real schematic wiring per the plan's
//   "Sound" section: "bit 5 would be board reset (present in hardware,
//   commented out in MAME 0.289's model -- implement it, since the schematic
//   wiring is real)": `reset_write(~control & 0x0020)`. See "Reset" below.
//
// =============================================================================
// sint / CA1 polarity -- resolved, not guessed
// =============================================================================
// midway_sound.cpp:659: `m_pia->ca1_w(~param & 0x01);` -- the PIA's CA1 PIN
// STATE is the bitwise NOT of the raw strobe bit (param bit0, which is
// control-word bit 4, UN-inverted, per xenophobe_control_w above). The donor
// sounds_good.vhd reproduces exactly this at line 220: `pia_ca1_in <= not
// sint;` -- i.e. the donor's own `sint` PORT carries the un-inverted strobe
// (matching control-word bit 4 directly), and the VHDL INTERNALLY inverts it
// before driving the PIA. This module's `sint` input follows the same
// convention for direct consistency with the only working reference
// implementation: ACTIVE HIGH, un-inverted, mirroring control-word bit 4
// as-is; this module inverts internally (`pia_ca1 = ~sint`) before driving
// pia6821's `ca1` input port. A caller wiring the real main-board control
// word therefore passes control-word bit 4 straight through with NO
// inversion of its own -- this module owns the inversion, exactly once,
// matching MAME's `~param & 0x01` and the donor's `not sint`.
//
// =============================================================================
// Reset -- control-word bit 5 (schematic-real, MAME-dormant)
// =============================================================================
// reset_write(int state) asserts the sound CPU's reset line when state != 0.
// The plan's documented schematic derivation is `state = (~control) & 0x0020`
// (midway_sound.cpp:519-523's call convention, applied to a hypothetical
// control-word bit 5 the current mcr68.cpp driver never actually calls).
// Algebra: state is nonzero (reset ASSERTED) exactly when control-word bit 5
// == 0; state == 0 (reset RELEASED, CPU runs) exactly when bit 5 == 1.
// This module's `ctrl_reset_n` input is defined to equal control-word bit 5
// DIRECTLY (no inversion required from the caller): 1 = CPU runs, 0 = CPU
// held in reset -- an active-low reset name that is a literal, zero-logic
// passthrough of that one control bit, avoiding a second inversion site.
// =============================================================================

`default_nettype none

module sounds_good #(
    parameter int CLK_HZ = 40_000_000, // frequency of `clk` (this module's own bus/PIA
                                        // clock domain). Not the 8 MHz CPU rate itself --
                                        // see "CPU clock enable" below. 40 MHz default
                                        // mirrors the donor's `clock_40` (40/5 = 8 MHz,
                                        // sounds_good.vhd:167).
    parameter int CPU_HZ = 8_000_000   // nominal Sounds Good 68000 rate: 16 MHz / 2
                                        // (midway_sound.cpp:607).
) (
    input  logic        clk,
    input  logic        rst,           // system/global reset, active high

    // Schematic-documented, MAME-dormant board reset (control-word bit 5).
    // Drive directly with the main board's control-word bit 5 -- see the
    // "Reset" header note above for the exact polarity derivation.
    input  logic        ctrl_reset_n,  // 1 = sound CPU runs, 0 = held in reset

    // ---------------- command handshake (xenophobe_control_w on the main board) ----
    input  logic [3:0]  sndsel,        // command nibble in: control-word bits 0-3
                                        // (mcr68.cpp:383-388 via the plan;
                                        // midway_sound.cpp:658)
    input  logic        sint,          // strobe in, ACTIVE HIGH, un-inverted mirror of
                                        // control-word bit 4 -- see the "sint/CA1
                                        // polarity" header note; this module owns the
                                        // inversion onto the PIA's CA1 pin internally.
    output logic [1:0]  stat,          // status out, PB5:PB4 direct read-back
                                        // (midway_sound.cpp:541-550; Xenophobe never
                                        // reads this -- see header note on z_mask).

    // ---------------- pre-decoded external memory bus ------------------------------
    // Cross-wires 1:1 with rtl/snd/mcr68_snd_mem_sim.sv's cpu_* ports (or any future
    // synthesizable ROM/RAM replacement presenting the same shape): this module is
    // that sibling's own documented caller, "the Sounds Good address decoder".
    output logic [17:0] mem_addr,      // word address (68000 has no A0; byte address =
                                        // {mem_addr,1'b0}). Global mask 0x7ffff already
                                        // applied by construction: only addr[18:1] of the
                                        // CPU's bus is ever examined below.
    output logic [15:0] mem_dout,      // write data to memory (full 16-bit CPU write bus;
                                        // byte-lane gating is mem_uds_n/mem_lds_n, exactly
                                        // as mcr68_snd_mem_sim.sv expects)
    input  logic [15:0] mem_din,       // read data from memory
    input  logic        rom_ready,     // external ROM data latched; ignored for RAM/PIA
    input  logic        ram_ready,     // sound RAM read data valid for the live address.
                                        // 1'b1 from the combinational sim memory model;
                                        // the synthesizable model registers its read so
                                        // the array is inferrable as M10K and must hold
                                        // DTACK for that clock (audit finding SND-02).
    output logic        mem_uds_n,     // D15-D8 byte lane valid, active low
    output logic        mem_lds_n,     // D7-D0  byte lane valid, active low
    output logic        mem_we_n,      // 0 = write cycle, 1 = read cycle (direct
                                        // passthrough of the 68000 R/W pin -- see
                                        // "Memory bus" below)
    output logic        rom_cs,        // 000000-03FFFF
    output logic        ram_cs,        // 070000-070FFF, mirror 00F000

    // ---------------- raw DAC code (filter stage owned by mcr68_snd_dac.sv) --------
    output logic [9:0]  dac10,         // unsigned AD7533 code: {PA[7:0], PB[7:6]}
                                        // (midway_sound.cpp:530-546)

    // Debug-only: passthrough of the CPU's PC, for simulation trace visibility.
    // Purely additive, mirrors mcr68_m68k.sv's own dbg_pc contract.
    output logic [31:0] dbg_pc,

    // ---------------- debug-only bus/IRQ visibility, purely additive ---------------
    // Added during the mcr68_sound_board integration pass so a standalone
    // sound-board Verilator harness can emit a mister-bus-jsonl-v1-shaped
    // trace (mirroring tb_mcr68_headless.sv's dbg_cpu_*/dbg_dtack_n/dbg_fc
    // convention on the main board) without needing a second read of this
    // module's internals from outside. None of these feed back into any
    // synthesizable decision inside this module -- appended at the end of
    // the port list so existing named-connection instantiations are
    // unaffected.
    output logic [23:1] dbg_cpu_addr,
    output logic [15:0] dbg_cpu_dout,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_as_n,
    output logic        dbg_uds_n,
    output logic        dbg_lds_n,
    output logic        dbg_rw_n,
    output logic        dbg_dtack_n,
    output logic [2:0]  dbg_fc,
    output logic        dbg_irq4,   // pia_irqa | pia_irqb, pre-active-low-fold:
                                     // the sound CPU's IPL4 source (see "IRQ" below)
    output logic [9:0]  dbg_dac10,  // same value as dac10, exposed here too so a
                                     // harness need only read debug ports
    output logic        dbg_ca2     // physical PIA CA2 level; observation only
);

    // -------------------------------------------------------------------------
    // Reset combination
    // -------------------------------------------------------------------------
    logic rst_i;
    assign rst_i = rst | ~ctrl_reset_n;

    // -------------------------------------------------------------------------
    // CPU clock enable: self-contained fixed-point phase accumulator (a DDS/NCO),
    // generating a `cpu_ce` pulse train whose long-run average rate is exactly
    // 2*CPU_HZ relative to `clk`, as mcr68_m68k.sv's contract requires ("cpu_ce
    // must pulse at 2x the nominal 68000 clock rate; internally divided into the
    // alternating enPhi1/enPhi2 pair"). This is a generic, parameterised
    // reimplementation of the same *effect* as the donor's fixed divide-by-5
    // counter (clock_40 at 40 MHz, cpu_ce1 at count==2, cpu_ce2 at count==4,
    // sounds_good.vhd:167-186) -- both average to CLK_HZ/2.5 = 2*CPU_HZ pulses/
    // sec when CLK_HZ=40e6, CPU_HZ=8e6, but the NCO form also works correctly
    // for any other CLK_HZ/CPU_HZ ratio a future integration might choose,
    // without needing an exact integer divisor. Deliberately self-contained: it
    // does not depend on (and was not derived from) whatever clock-enable
    // generator the locked main board file may use internally.
    // -------------------------------------------------------------------------
    localparam int ACC_W = 32;
    localparam longint unsigned CE_STEP64 =
        (longint'(CPU_HZ) * 2 * (longint'(1) << ACC_W)) / longint'(CLK_HZ);
    localparam logic [ACC_W-1:0] CE_STEP = CE_STEP64[ACC_W-1:0];

    logic [ACC_W-1:0] ce_acc;
    logic             cpu_ce;

    always_ff @(posedge clk) begin
        if (rst_i) begin
            ce_acc <= '0;
            cpu_ce <= 1'b0;
        end else begin
            {cpu_ce, ce_acc} <= {1'b0, ce_acc} + {1'b0, CE_STEP};
        end
    end

    // -------------------------------------------------------------------------
    // CPU instance -- same generic wrapper as the main board (rtl/cpu/mcr68_m68k.sv),
    // instantiated a second time per that file's own documented intent.
    // -------------------------------------------------------------------------
    logic [23:1] cpu_addr;
    logic [15:0] cpu_din, cpu_dout;
    logic        cpu_as_n, cpu_uds_n, cpu_lds_n, cpu_rw_n, cpu_dtack_n;
    logic [2:0]  cpu_fc;
    logic [2:0]  cpu_ipl_n;

    // Sounds Good exposes only the sound CPU PC; the remaining generic CPU
    // debug taps are optional observation ports, not board functionality.
    /* verilator lint_off PINCONNECTEMPTY */
    /* verilator lint_off PINMISSING */
    mcr68_m68k u_cpu (
        .clk     (clk),
        .rst     (rst_i),
        .cpu_ce  (cpu_ce),

        .addr    (cpu_addr),
        .din     (cpu_din),
        .dout    (cpu_dout),
        .as_n    (cpu_as_n),
        .uds_n   (cpu_uds_n),
        .lds_n   (cpu_lds_n),
        .rw_n    (cpu_rw_n),
        .dtack_n (cpu_dtack_n),

        .fc      (cpu_fc),
        .ipl_n   (cpu_ipl_n),
        .vpa_n   (),

        .dbg_pc  (dbg_pc),
        .dbg_d7  (),
        .dbg_ccr (),
        .dbg_sr  ()
    );
    /* verilator lint_on PINMISSING */
    /* verilator lint_on PINCONNECTEMPTY */

    // -------------------------------------------------------------------------
    // Address decode (soundsgood_map, midway_sound.cpp:591-598). global_mask
    // 0x7ffff is applied structurally: only cpu_addr[18:1] is ever examined
    // below, so any address bits above bit 18 alias exactly as MAME's
    // global_mask(0x7ffff) would fold them -- this is the same approach the
    // donor VHDL uses (it likewise never routes cpu_addr bits above 18).
    // -------------------------------------------------------------------------
    logic cpu_sel;
    assign cpu_sel = ~cpu_as_n & (~cpu_uds_n | ~cpu_lds_n);

    // *** Integration-pass correctness fix (2026-08-05, mcr68_sound_board
    // integration task) ***: re-checking midway_sound.cpp:596 directly --
    // `map(0x060000, 0x060007).mirror(0x00fff0)...` -- shows the PIA's base
    // decode window is only 8 bytes (byte address bits 2:0), and the mirror
    // mask 0x00FFF0 covers bits 15:4 only. Byte address bit 3 is therefore
    // neither part of the base range nor part of the mirror: it MUST be 0
    // for the PIA to be selected (0x060008-0x06000F, and every ...x8-...xF
    // window at any mirrored bits[15:4] value, is genuinely unmapped on
    // real hardware/MAME, not a second PIA mirror). The original decode
    // below (`cpu_addr[18:16]==3'b110` alone) treated the entire
    // 0x060000-0x06FFFF range as PIA, over-decoding by 1 address bit.
    // cpu_addr[3] is literal CPU pin A3 (this module's cpu_addr indices ARE
    // the 68000's own address-pin numbers, per mcr68_m68k.sv's `addr`
    // port), so the fix is a direct `~cpu_addr[3]` qualifier -- no
    // reindexing needed. Firmware never legitimately addresses the hole, so
    // this was latent (harmless for the command handshake this board
    // actually uses) but is a real, evidenced decode bug, fixed here per
    // CLAUDE.md's "apply the smallest correct synthesizable fix".
    // *** Adversarial-audit correctness fix (2026-08-06, Phase 4 verify
    // pass) ***: midway_sound.cpp:596 also carries `.umask16(0xff00)` on
    // the PIA entry -- MAME/real hardware only routes an access to the PIA
    // when the UPPER byte lane (D15-D8, UDS) is touched; an LDS-only
    // (odd-address, low-byte-only) access within the PIA's decoded window
    // is genuinely unmapped, not routed to the PIA at all. cpu_sel (line
    // 310) is deliberately either-lane for rom_cs/ram_cs, which are full
    // 16-bit-wide regions with no umask -- but cs_pia needs its own
    // narrower qualifier. Read side was already harmless by coincidence
    // (cpu_din already forces the low byte to 8'hFF regardless, matching
    // MAME's unmap_value_high() for that lane); write side was a real gap:
    // an LDS-only byte write into this window would have mutated PIA state
    // where real hardware/MAME leaves it untouched. Fixed with an explicit
    // ~cpu_uds_n qualifier on cs_pia only.
    logic cs_pia;
    assign rom_cs = cpu_sel & ~cpu_addr[18];                 // 000000-03FFFF (line 595)
    assign ram_cs = cpu_sel &  (cpu_addr[18:16] == 3'b111);  // 070000-070FFF mirror 00F000 (line 597)
    assign cs_pia = ~cpu_as_n & ~cpu_uds_n &                 // umask16(0xff00): UDS lane only
                    (cpu_addr[18:16] == 3'b110) & ~cpu_addr[3];
                                                              // 060000-060007 mirror 00FFF0,
                                                              // byte A3 must be 0 (line 596)

    // The donor (sounds_good.vhd:200) and this board's own comment ("no ROMD
    // signal for inserting wait states") ack ROM/RAM/PIA with no wait states.
    // Both *_ready terms are therefore MODEL artifacts, not board behaviour:
    // rom_ready covers the multi-cycle SDRAM ROM fabric, and ram_ready (added
    // 2026-09-12 for audit finding SND-02) covers the one clock the
    // synthesizable RAM model needs because its read had to be registered to
    // be inferrable as M10K. Both collapse to a constant 1 in the
    // zero-latency simulation configuration, where this expression is exactly
    // the donor's.
    assign cpu_dtack_n = ~((rom_cs & rom_ready) | (ram_cs & ram_ready) | cs_pia);

    // -------------------------------------------------------------------------
    // Memory bus -- cross-wires with rtl/snd/mcr68_snd_mem_sim.sv (see header).
    // mem_we_n is a direct passthrough of the CPU's own R/W pin: mcr68_m68k's
    // rw_n (FX68K's eRWn) is already high=read/low=write, the exact convention
    // mcr68_snd_mem_sim.sv's cpu_we_n documents ("0 = write cycle, 1 = read
    // cycle") -- no inversion needed or performed.
    // -------------------------------------------------------------------------
    assign mem_addr  = cpu_addr[18:1];
    assign mem_dout  = cpu_dout;
    assign mem_uds_n = cpu_uds_n;
    assign mem_lds_n = cpu_lds_n;
    assign mem_we_n  = cpu_rw_n;

    // -------------------------------------------------------------------------
    // PIA instance (rtl/snd/pia6821.sv, adapted from the local generic MC6821
    // and audited against the MCR3Mono donor). Address permutation RS0<-A2,
    // RS1<-A1 (swapped from the usual
    // RS0<-A1/RS1<-A2 -- midway_sound.cpp:596's own comment, confirmed against
    // the donor sounds_good.vhd:135 `addr => cpu_addr(1)&cpu_addr(2)`).
    // pia6821.sv's addr port is documented as {RS1,RS0}, so RS1(addr[1])<-A1,
    // RS0(addr[0])<-A2:
    // -------------------------------------------------------------------------
    logic [7:0] pia_din, pia_dout;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] pia_pa_out, pia_pb_out;
    /* verilator lint_on UNUSEDSIGNAL */
    logic       pia_irqa, pia_irqb;
    logic       pia_ca2_out;

    assign pia_din = cpu_dout[15:8];   // PIA lives on D8-D15 (umask16(0xff00), line 596)

    pia6821 u_pia (
        .clk    (clk),
        .rst    (rst_i),

        // `en` is held combinationally for the whole selected bus phase (several
        // `clk` cycles under the CE divider above), not pulsed once per E-cycle
        // as pia6821.sv's own header envisions for its original 6809/E-clock
        // caller. CORRECTED 2026-09-12: an earlier revision of this comment
        // claimed the held level was safe because every effect of the clocked
        // `en` branch is idempotent. That was FALSE for the PORTA read-clear of
        // cra[7] -- a CA1 strobe edge landing inside the read window was set by
        // the edge process and then wiped by the next clk's repeated
        // read-clear, losing the IRQ4 and the sound command (audit 2026-09-11
        // finding SND-01). pia6821.sv now gates the access branch on the rising
        // edge of `en`, which restores its documented one-access-per-assertion
        // contract; the held level here is correct input for that.
        // cpu_addr/cpu_rw_n are stable from S2 and cpu_dout is driven before
        // UDS (which cs_pia requires) asserts at S4, so the first clk of the
        // window already carries valid address/data.
        .en     (cs_pia),
        .we     (~cpu_rw_n),
        .addr   ({cpu_addr[1], cpu_addr[2]}),  // {RS1,RS0} = {A1,A2}

        .din    (pia_din),
        .dout   (pia_dout),

        .pa_in  (8'h00),               // Port A has no external input source on this
                                        // board (AD7533 data-out only)
        .pb_in  ({4'h0, sndsel}),      // PB3:0 = command nibble in. Upper nibble forced
                                        // to 0, matching MAME's own
                                        // `m_pia->portb_w((param >> 1) & 0x0f)`
                                        // (midway_sound.cpp:658) -- an 8-bit write whose
                                        // upper 4 bits are implicitly 0. (The donor VHDL
                                        // instead hard-ties this upper nibble to "1100"
                                        // at sounds_good.vhd:219; harmless either way
                                        // since PB7:4 are firmware-configured as PIA
                                        // OUTPUTS in normal operation, so pb_in[7:4] is a
                                        // don't-care for the read-back mux -- but this
                                        // module follows MAME (evidence tier 3) over the
                                        // donor FPGA core (tier 4) per project policy.)
        .ca1    (~sint),               // see "sint/CA1 polarity" header note
        .cb1    (1'b0),                // spare/unconnected on this board (no cb1_w
                                        // callback registered in midway_sound.cpp)
        .cb2    (1'b0),                // unconnected (no cb2 callback registered either)

        .pa_out (pia_pa_out),
        .pb_out (pia_pb_out),
        .ca2_out(pia_ca2_out),         // schematic-routed remote-volume control;
                                        // analogue load is outside this digital block
        .irqa   (pia_irqa),
        .irqb   (pia_irqb)
    );

    // -------------------------------------------------------------------------
    // IRQ: PIA IRQA|IRQB -> sound CPU IPL4, autovectored (midway_sound.cpp:
    // 557-561, wired at 613-614). ipl_n[2:0] map straight onto FX68K's
    // IPL2n:IPL1n:IPL0n pins (see rtl/cpu/mcr68_m68k.sv); {IPL2n,IPL1n,IPL0n}
    // = {0,1,1} is the active-low encoding for interrupt level 4, matching the
    // donor's identical wiring of the combined flag onto IPL2n alone with
    // IPL1n/IPL0n tied high (sounds_good.vhd:98-100/204). Autovectoring itself
    // (VPAn on FC==111) is generated internally by mcr68_m68k -- nothing further
    // to do here.
    // -------------------------------------------------------------------------
    assign cpu_ipl_n = {~(pia_irqa | pia_irqb), 1'b1, 1'b1};

    // -------------------------------------------------------------------------
    // CPU read-data mux
    // -------------------------------------------------------------------------
    always_comb begin
        if (rom_cs || ram_cs) cpu_din = mem_din;
        else if (cs_pia)      cpu_din = {pia_dout, 8'hFF};   // low byte floats high,
                                                              // matching the donor
                                                              // (sounds_good.vhd:215,
                                                              // `pia_data_out & x"FF"`)
        else                  cpu_din = 16'hFFFF;
    end

    // -------------------------------------------------------------------------
    // Status readback: direct PB5:PB4 tap, no z_mask-gated latch -- see the
    // header note above for why (that gating belongs to MAME's own read()
    // model of the main-board-facing status port, not to this board's
    // physical PB4/PB5 pins, and Xenophobe never reads it regardless).
    // -------------------------------------------------------------------------
    assign stat = pia_pb_out[5:4];

    // -------------------------------------------------------------------------
    // DAC bit assembly (midway_sound.cpp:530-546): dac10[9:2]=PA[7:0],
    // dac10[1:0]=PB[7:6]. Combinational, NOT a separate register and NOT owned
    // by the PIA itself -- pia_pa_out/pia_pb_out are the PIA's own persistent
    // output-latch registers (ola/olb in pia6821.sv), so a live concatenation
    // of their current values already reproduces MAME's incremental
    // m_dacval bookkeeping exactly (each MAME callback only ever updates its
    // own half, preserving the other -- exactly what two independently-
    // latched PIA registers do for free). The AD7533 output-filter stage
    // (three cascaded LM359 MFB low-pass stages) is a separate sibling module,
    // rtl/snd/mcr68_snd_dac.sv, not instantiated here.
    // -------------------------------------------------------------------------
    assign dac10 = {pia_pa_out, pia_pb_out[7:6]};

    // -------------------------------------------------------------------------
    // Debug-only bus/IRQ passthrough -- see port-list header note above.
    // -------------------------------------------------------------------------
    assign dbg_cpu_addr = cpu_addr;
    assign dbg_cpu_dout = cpu_dout;
    assign dbg_cpu_din  = cpu_din;
    assign dbg_as_n     = cpu_as_n;
    assign dbg_uds_n    = cpu_uds_n;
    assign dbg_lds_n    = cpu_lds_n;
    assign dbg_rw_n     = cpu_rw_n;
    assign dbg_dtack_n  = cpu_dtack_n;
    assign dbg_fc       = cpu_fc;
    assign dbg_irq4     = pia_irqa | pia_irqb;
    assign dbg_dac10    = dac10;
    assign dbg_ca2      = pia_ca2_out;

endmodule

`default_nettype wire
