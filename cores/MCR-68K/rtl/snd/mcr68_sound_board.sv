// =============================================================================
// mcr68_sound_board.sv -- top-level "Sounds Good" sound board, wiring
// rtl/snd/sounds_good.sv + the simulation or production RAM path +
// rtl/snd/mcr68_snd_dac.sv into ONE module with a clean external interface.
//
// The module is wired into rtl/mcr68_main_board.sv's cs_soundio path
// (0x0C0000-0x0CFFFF, xenophobe_control_w). The host-file RAM path is kept
// only for standalone simulation; SDRAM_ROM selects the production RAM path.
//
// External interface (per this task's explicit spec):
//   clk, rst, sndsel[3:0], sint, stat[1:0] out, audio_out (signed) out.
// ctrl_reset_n is added as an EXTRA input with a default value (`= 1'b1`,
// "sound CPU runs") so every existing/expected call site that only wires
// the required five signals still works unmodified, while a future
// integration that wants to drive the real schematic board-reset bit
// (control-word bit 5, see sounds_good.sv's own header note) can do so
// without another interface change. dbg_pc is similarly additive.
//
// =============================================================================
// Port-interface reconciliation performed by this integration pass
// =============================================================================
// Read all three sibling files directly (not just their completion-report
// summaries) before wiring, per this task's instruction. Findings:
//
// 1. sounds_good.sv <-> the selected sound-memory path: the memory bus ports
//    (mem_addr/mem_dout/mem_din/mem_uds_n/mem_lds_n/mem_we_n/rom_cs/ram_cs
//    on one side, cpu_addr/cpu_din/cpu_dout/cpu_uds_n/cpu_lds_n/cpu_we_n/
//    rom_cs/ram_cs on the other) already cross-wire 1:1 in both width and
//    polarity -- both sides agree cpu_addr indices are CPU address PIN
//    numbers (A18..A1, i.e. mem_addr[k]/cpu_addr[k] == CPU pin A(k+1)),
//    both use we_n with the same 0=write/1=read convention, and both
//    already narrowed to the same ROM (17-bit word index) / RAM (11-bit
//    word index) ranges. No mismatch found here -- confirmed by working
//    through the actual bit arithmetic, not just trusting the matching
//    port names.
//
// 2. sounds_good.sv's PIA address decode (cs_pia): found and fixed a real
//    bug while re-deriving the decode from midway_sound.cpp:596 directly --
//    see the dated comment inside sounds_good.sv itself (this integration
//    pass added `& ~cpu_addr[3]`, the PIA's base 8-byte window excludes
//    byte-address bit 3, which the original decode omitted, over-selecting
//    the PIA across the whole 0x060000-0x06FFFF range instead of only the
//    ...x0-...x7 sub-windows within it). Latent/harmless for the firmware's
//    actual access pattern, but a genuine decode-accuracy bug, fixed at the
//    smallest possible scope (one AND term).
//
// 3. sounds_good.sv <-> mcr68_snd_dac.sv: dac10[9:0] itself matches in
//    width and meaning on both sides (unsigned AD7533 code, {PA[7:0],
//    PB[7:6]}) -- NOT a mismatch. The real mismatch is CLOCK DOMAIN:
//    mcr68_snd_dac.sv's own header claims dac10 "is expected to be
//    produced by rtl/snd/sounds_good.sv in that same [8 MHz CPU] clock
//    domain (a PIA output register clocked by the sound CPU clock)" and
//    therefore defaults CLK_HZ=8_000_000. That assumption does not hold:
//    sounds_good.sv instantiates its PIA with `.clk(clk)` -- sounds_good's
//    OWN `clk` port, documented in ITS OWN header as "this module's own
//    bus/PIA clock domain. Not the 8 MHz CPU rate itself", defaulting to
//    CLK_HZ=40_000_000 (the donor's `clock_40`). The PIA's output latches
//    (ola/olb, hence dac10) are therefore registered at the full 40 MHz
//    `clk` rate, not divided down to 8 MHz anywhere. Instantiating
//    mcr68_snd_dac with its own default CLK_HZ=8_000_000 while actually
//    clocking it from sounds_good's 40 MHz `clk` domain (the only sensible
//    choice, since dac10 lives there and cross-domain sampling of a
//    slowly-changing DAC code would just add needless latency/risk for no
//    benefit) would make its internal SAMPLE_HZ phase-accumulator wrap 5x
//    too fast, silently pulling the realised low-pass corner to ~5x the
//    intended ~5.1 kHz -- i.e. a real, and non-obvious, filter-accuracy
//    bug if left unreconciled. Fixed below by explicitly overriding
//    mcr68_snd_dac's CLK_HZ parameter to match the CLK_HZ this module
//    actually feeds it (this module's own CLK_HZ parameter, kept in sync
//    with the value passed to the sounds_good instance) -- a parameter
//    override at the integration point, not a change to either sibling
//    file (mcr68_snd_dac.sv's own directed testbench,
//    sim/tb_mcr68_snd_dac.sv, legitimately uses its 8 MHz default for an
//    isolated filter-math smoke test unrelated to this integration).
// =============================================================================

`default_nettype none

module mcr68_sound_board #(
    parameter string SNDCPU_ROM_FILE = "",       // path to sndcpu.bin for
                                                   // standalone bring-up; the
                                                   // production path uses SDRAM.
                                                   // A +SNDCPU_ROM=<path> plusarg
                                                   // overrides this in the
                                                   // host-file memory variant.
    parameter int    CLK_HZ    = 40_000_000,      // sounds_good's own bus/PIA clock
                                                   // domain -- see sounds_good.sv's
                                                   // header. Also the clock this
                                                   // module feeds mcr68_snd_dac (see
                                                   // reconciliation note 3 above).
    parameter int    CPU_HZ    = 8_000_000,       // nominal Sounds Good 68000 rate
    parameter int    SAMPLE_HZ = 48_000,
    parameter bit    SDRAM_ROM = 1'b0
                                                   // update rate; matches
                                                   // sys/audio_out.sv's fixed
                                                   // AUDIO_RATE (see mcr68_snd_dac.sv)
) (
    input  logic        clk,
    input  logic        rst,             // system reset, active high

    // Schematic-real, MAME-dormant board reset (control-word bit 5) --
    // see sounds_good.sv's own header "Reset" note. Defaulted to 1
    // ("CPU runs") so the required 5-signal interface below still works
    // with no change at any call site that doesn't care about this bit.
    input  logic         ctrl_reset_n,

    output logic         sndrom_req,
    output logic [16:0]  sndrom_addr,
    input  logic [15:0]  sndrom_data,
    input  logic         sndrom_ack,

    // ---------------- required external interface (per this task's spec) ----------
    input  logic [3:0]  sndsel,          // command nibble in: control-word bits 0-3
    input  logic        sint,            // strobe in, ACTIVE HIGH (see sounds_good.sv
                                          // "sint/CA1 polarity" header note)
    output logic [1:0]  stat,            // status out, PB5:PB4 (Xenophobe never reads
                                          // this; passed through for completeness)

    output logic signed [15:0] audio_out,

    // Debug-only: passthrough of the CPU's PC, for simulation trace
    // visibility. Purely additive.
    output logic [31:0] dbg_pc,

    // ---------------- debug-only bus/IRQ/DAC visibility, purely additive -----------
    // Straight taps of sounds_good.sv's own equivalently-named debug ports,
    // plus mcr68_snd_dac's sample_o, so a standalone harness needs only
    // this module's ports to build a mister-bus-jsonl-v1-shaped trace and
    // confirm PIA/DAC activity -- no need to reach inside a sub-instance.
    output logic [23:1] dbg_cpu_addr,
    output logic [15:0] dbg_cpu_dout,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_as_n,
    output logic        dbg_uds_n,
    output logic        dbg_lds_n,
    output logic        dbg_rw_n,
    output logic        dbg_dtack_n,
    output logic [2:0]  dbg_fc,
    output logic        dbg_irq4,
    output logic [9:0]  dbg_dac10,
    output logic        dbg_ca2,
    output logic         dbg_rom_cs,
    output logic         dbg_ram_cs,
    output logic         dbg_sample_tick
);

    // -------------------------------------------------------------------------
    // sounds_good <-> selected sound-memory bus (internal only -- see
    // reconciliation note 1 above: already a 1:1 cross-wire, no adaptation
    // needed beyond direct connection).
    // -------------------------------------------------------------------------
    logic [17:0] mem_addr;
    logic [15:0] mem_dout;   // sounds_good -> memory (write data)
    logic [15:0] mem_din;    // selected memory -> sounds_good (read data)
    logic [15:0] mem_din_sim;
    logic        mem_uds_n, mem_lds_n, mem_we_n;
    logic        rom_cs, ram_cs;
    logic        rom_ready;
    logic        ram_ready;   // driven by the selected memory model; 1 for the
                              // combinational sim model, registered-read ack
                              // for mcr68_snd_mem_hw (audit finding SND-02)
    logic [15:0] rom_data_r;
    logic [16:0] rom_addr_q;
    logic        rom_busy;
    logic        rom_valid;

    // -------------------------------------------------------------------------
    // sounds_good -> mcr68_snd_dac raw DAC code (internal only).
    // -------------------------------------------------------------------------
    logic [9:0]  dac10;

    sounds_good #(
        .CLK_HZ(CLK_HZ),
        .CPU_HZ(CPU_HZ)
    ) u_sounds_good (
        .clk          (clk),
        .rst          (rst),
        .ctrl_reset_n (ctrl_reset_n),

        .sndsel       (sndsel),
        .sint         (sint),
        .stat         (stat),

        .mem_addr     (mem_addr),
        .mem_dout     (mem_dout),
        .mem_din      (mem_din),
        .rom_ready    (rom_ready),
        .ram_ready    (ram_ready),
        .mem_uds_n    (mem_uds_n),
        .mem_lds_n    (mem_lds_n),
        .mem_we_n     (mem_we_n),
        .rom_cs       (rom_cs),
        .ram_cs       (ram_cs),

        .dac10        (dac10),
        .dbg_pc       (dbg_pc),

        .dbg_cpu_addr (dbg_cpu_addr),
        .dbg_cpu_dout (dbg_cpu_dout),
        .dbg_cpu_din  (dbg_cpu_din),
        .dbg_as_n     (dbg_as_n),
        .dbg_uds_n    (dbg_uds_n),
        .dbg_lds_n    (dbg_lds_n),
        .dbg_rw_n     (dbg_rw_n),
        .dbg_dtack_n  (dbg_dtack_n),
        .dbg_fc       (dbg_fc),
        .dbg_irq4     (dbg_irq4),
        .dbg_dac10    (dbg_dac10),
        .dbg_ca2      (dbg_ca2)
    );

    assign dbg_rom_cs = rom_cs;
    assign dbg_ram_cs = ram_cs;

    generate
        if (!SDRAM_ROM) begin : g_sim_mem
            mcr68_snd_mem_sim #(
                .SNDCPU_ROM_FILE (SNDCPU_ROM_FILE)
            ) u_mem (
                .clk       (clk),
                .cpu_addr  (mem_addr),
                .cpu_din   (mem_dout),
                .cpu_dout  (mem_din_sim),
                .cpu_uds_n (mem_uds_n),
                .cpu_lds_n (mem_lds_n),
                .cpu_we_n  (mem_we_n),
                .rom_cs    (rom_cs),
                .ram_cs    (ram_cs),
                .ram_ready (ram_ready)
            );
        end else begin : g_hw_mem
            mcr68_snd_mem_hw u_mem (
                .clk       (clk),
                .cpu_addr  (mem_addr),
                .cpu_din   (mem_dout),
                .cpu_dout  (mem_din_sim),
                .cpu_uds_n (mem_uds_n),
                .cpu_lds_n (mem_lds_n),
                .cpu_we_n  (mem_we_n),
                .rom_cs    (rom_cs),
                .ram_cs    (ram_cs),
                .ram_ready (ram_ready)
            );
        end
    endgenerate

    // The fabric request address is held independently of the live 68000 bus.
    // The CPU may advance A1..A17 while AS remains asserted after DTACK; a
    // live address here would otherwise let a late ack be attributed to the
    // wrong word.
    assign sndrom_addr = rom_addr_q;

    // A ROM response is valid for one exact CPU word, not for the whole AS
    // phase. This is intentionally combinational so sounds_good can remove
    // DTACK immediately after the registered response is accepted.
    assign rom_ready = !SDRAM_ROM ||
                       (rom_valid && (rom_addr_q == mem_addr[16:0]));

    always_ff @(posedge clk) begin
        if (rst || !SDRAM_ROM) begin
            sndrom_req <= 1'b0;
            rom_addr_q <= '0;
            rom_busy   <= 1'b0;
            rom_valid  <= 1'b0;
            rom_data_r <= 16'h0000;
        end else if (!rom_cs) begin
            sndrom_req <= 1'b0;
            rom_busy   <= 1'b0;
            rom_valid  <= 1'b0;
        end else begin
            // A new word on an AS-held bus phase invalidates the previous
            // response and starts a new single-outstanding fabric request.
            if (rom_valid && (rom_addr_q != mem_addr[16:0])) begin
                rom_valid <= 1'b0;
                rom_busy  <= 1'b0;
            end

            if (!rom_busy &&
                !(rom_valid && (rom_addr_q == mem_addr[16:0]))) begin
                rom_addr_q <= mem_addr[16:0];
                rom_valid  <= 1'b0;
                rom_busy   <= 1'b1;
                sndrom_req <= 1'b1;
            end else if (rom_busy && sndrom_ack) begin
                if (rom_addr_q == mem_addr[16:0]) begin
                    rom_data_r <= sndrom_data;
                    sndrom_req <= 1'b0;
                    rom_busy   <= 1'b0;
                    rom_valid  <= 1'b1;
                end else begin
                    // Do not consume a response for an address the CPU has
                    // already abandoned. Drop req for one clock so the
                    // replacement word gets a fresh fabric rising edge.
                    rom_addr_q <= mem_addr[16:0];
                    rom_valid  <= 1'b0;
                    rom_busy   <= 1'b0;
                    sndrom_req <= 1'b0;
                end
            end
        end
    end

    always_comb begin
        if (SDRAM_ROM && rom_cs) mem_din = rom_data_r;
        else                     mem_din = mem_din_sim;
    end

    mcr68_snd_dac #(
        .CLK_HZ   (CLK_HZ),      // *** reconciliation note 3: must match sounds_good's
                                  // actual clk domain, NOT mcr68_snd_dac.sv's own
                                  // 8 MHz default -- see header note above.
        .SAMPLE_HZ(SAMPLE_HZ)
    ) u_dac (
        .clk      (clk),
        .rst      (rst),
        .dac10    (dac10),
        .audio_o  (audio_out),
        .sample_o (dbg_sample_tick)
    );

endmodule

`default_nettype wire
