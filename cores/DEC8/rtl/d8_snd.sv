// DEC8 sound board (PLAN M3): 6502, YM2203, OPL, sound latch.
//
// Reference: MAME 0.288 dataeast/dec8.cpp (reference/mame/v0288/),
// "dec8:L" = line numbers there; "spec N" = docs/dec8_system_spec.md.
//
//   lastmisn  R65C02 1.5 MHz (12 MHz / 8, dec8:1992), ym3526_s_map
//             (dec8:651-658): RAM 0000-05FF, YM2203 0800-0801, YM3526
//             1000-1001, latch read 3000, ROM 8000-FFFF
//   gondo     R65C02 1.5 MHz (dec8:2109), oscar_s_map (dec8:635-641): YM2203
//             2000-2001, YM3526 4000-4001, latch read 6000
//   srdarwin  DECO 222 1.5 MHz (dec8:2423), dec8_s_map (dec8:625-631): as
//             gondo with a YM3812 at 4000-4001; the DECO 222 swaps opcode
//             bits 5 and 6 on opcode fetches only (deco222.cpp:34)
//   YM2203 at 1.5 MHz on all three (dec8:2031, 2148, 2453); the OPL at
//   3 MHz (dec8:2038, 2155, 2460). Sound IRQ = YM2203 IRQ OR OPL IRQ
//   (input merger, dec8:2028-2039).
//   NMI: lastmisn / srdarwin: the latch's data-pending line, set by the
//   main CPU's write and cleared by the 6502's read of the latch
//   (generic_latch_8, dec8:2025-2026, 2443-2444); the 6502 NMI input is
//   edge triggered. gondo: the write asserts NMI for 4 audio CPU cycles
//   (an LS194 clocked with the 6502, dec8:144-149, 233-238).
//   The chips are mapped write-only in MAME; a 6502 read of them returns
//   the unmapped value 0, as does any other unmapped read. The oracle's
//   sound log (sim/mame/d8_oracle.lua SNDLOG) shows the sound programs
//   never read the chips (m3_findings).
//
// Cores: jt65c02 (jotego, GPL-3.0-or-later; DECO222 parameter set, the
// opcode swap enabled with i_machine == srdarwin), jt03 (YM2203 with its
// SSG), jtopl2 (YM3812; YM3526 behaviour on lastmisn / gondo by clearing
// the wave-select enable bit of register 01 on its way in: with that bit
// clear jtopl2's operator path is jtopl's OPL1 path, jtopl_reg.v,
// jtopl_op.v). See rtl/vendor/*/PROVENANCE.md.
//
// Clocking (96 MHz system clock): jt65c02 cen at 6 MHz (every 16 clocks,
// four per 1.5 MHz bus cycle), YM2203 cen 1.5 MHz (every 64), OPL cen 3 MHz
// (every 32). Pause holds every enable.

module d8_snd #(
    // mix gains in 1/256 (R20, docs/r20_pcb_audio_check.md). Measured on a
    // real SRD board (PCB capture of power-on and both demos, fitted
    // against this core's chip outputs over 100 s): OPL:FM 1.65 (90%
    // interval 1.60-1.77 before MAME-bias correction), SSG 3400-3900 for FM
    // 102. The schematics' equal 10 kOhm summing resistors (Last Mission
    // sheet 27, Gondomania sheet 28) do not give 1:1: the chips' DAC words
    // differ in level. MAME: OPL 2x on lastmisn/srdarwin, 1.25x on gondo.
    // Last Mission and Gondomania use the same chips into the same summing
    // network as the measured board, so the SRD balance is applied to all
    // three (Gondomania inferred, no recording checked yet).
    parameter int FM_GAIN   = 102,     // 0.40 (MAME's FM route)
    parameter int SSG_GAIN  = 3600,    // PCB fit (MAME 2775: 0.20 per channel on jt49's sum)
    parameter int OPL_GAIN  = 170,     // PCB fit, 1.67 x FM (MAME 0.80 = 205)
    parameter int OPL_GAIN_GO = 170,   // as OPL_GAIN (MAME 0.50 = 128)
    // Cobra-Command (DE-0298 sheet 16, docs/COBRACOM_DONORS.md "Sound mix"):
    // FM and OPL both 56 k into the node -> the SRD-measured DAC balance
    // (OPL:FM 1.67) holds; the SSG goes through 1 k x3 into 47 Ohm and then
    // 5.6 k, which puts it 15 dB (current-source YM2203 output model) to
    // 21.5 dB (voltage-source model) higher against FM than on the 470 Ohm /
    // 56 k, FM 10 k boards. The lower bound (x5.6) is used. All three are
    // scaled by 1/4 against the SRD values for 16-bit headroom; d8_board's
    // profile gain restores the level (x4).
    parameter int FM_GAIN_CB  = 26,    // 102 / 4
    parameter int OPL_GAIN_CB = 43,    // 170 / 4
    parameter int SSG_GAIN_CB = 5040   // 3600 * 5.6 / 4
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_pause,
    input  logic [3:0]  i_machine,       // machine profile, see docs/PROFILES.md

    // sound latch from the main CPU (one-clock strobe)
    input  logic        i_latch_wr,
    input  logic [7:0]  i_latch_d,

    // sound ROM load (8000-FFFF, before reset is released)
    input  logic        i_rom_we,
    input  logic [15:0] i_rom_addr,      // fixed 32 KiB, then Captain Silver bank data
    input  logic [7:0]  i_rom_din,

    output logic signed [15:0] o_fm,     // YM2203 FM
    output logic        [9:0]  o_ssg,    // YM2203 SSG, jt49 sum of the three channels
    output logic signed [15:0] o_opl,    // OPL
    output logic signed [15:0] o_mix,    // the gains above, saturated

    output logic [15:0] o_dbg_unmapped,  // 6502 accesses to unmapped addresses
    output logic [15:0] o_dbg_rom_writes
);

  wire cs = i_machine == 4'd7;
  wire lm = i_machine == 4'd0 || i_machine == 4'd3 || cs;
  wire go = i_machine == 4'd1 || i_machine == 4'd4;
  wire gb = i_machine == 4'd5 || i_machine == 4'd6;
  wire sr = i_machine == 4'd2;
  wire cb = i_machine == 4'd9;                 // Cobra-Command
  // Psycho-Nics Oscar (dec8.cpp L2360-2405): DECO 222 at 1.5 MHz with
  // oscar_s_map (as gondo: YM2203 2000, YM3526 4000, latch 6000) and the
  // latch's data-pending NMI (as lastmisn)
  wire os = i_machine == 4'd8;

  // ================================================================ enables
  // The counters run through reset: jt03 and jtopl clear their operator
  // pipelines (jt12_sh_rst / jtopl_sh_rst shift registers) only on clock
  // enables while rst is high, so the chips need their enables during the
  // reset period (held for the ROM download on the board). With frozen
  // enables jt03 left reset with its envelope pipeline unfilled and output
  // a large wandering FM signal until the program happened to rewrite every
  // operator (m3_findings 3).
  // Reset is deterministic whatever its length (on the MiSTer it lasts
  // through the ROM download; M4 found the sound board 8 clocks, then an
  // OPL timer 192 clocks, apart between the board and the M2 harness,
  // m4_findings 6): the dividers and the chip enables run for the first
  // 37,464 clocks of a reset and then stop until the release. 37,464 is the
  // reset length of the M2/M3 harness (m2/tb_sys.cpp), so the sound board
  // leaves reset in exactly the state the M3 results (compared with MAME)
  // were measured from: 585 YM2203 and 1,170 OPL enables, enough to fill the
  // chips' pipelines, and the same free-running prescaler phase (the OPL
  // timer base).
  localparam logic [15:0] RST_RUN = 16'd18732;
  logic [3:0]  c16 = '0;
  logic [5:0]  c64 = '0;
  // rcnt counts clocks from the START of a reset up to RST_RUN and then
  // holds, whether or not the reset is still asserted. snd_rst keeps the CPU
  // and the chips in reset until rcnt has saturated, so a short reset (the
  // 600-clock time-zero harness; a quick warm reset) still gives the jt03 /
  // jtopl pipelines their 585 / 1,170 enables with rst high. With the long
  // MiSTer ROM-download reset nothing changes. (Without this the chips
  // power up with a free-running envelope: Last Mission FM/OPL sounded at
  // once while MAME is silent until the first command.)
  logic [15:0] rcnt = '0;
  logic        rst_q = 1'b0;
  always_ff @(posedge clk) begin
    rst_q <= rst_n;
    if (rst_q && !rst_n) rcnt <= '0;
    else if (rcnt != RST_RUN) rcnt <= rcnt + 16'd1;
  end
  wire snd_rst_n = rst_n && rcnt == RST_RUN;
  wire rst_hold = !rst_n && rcnt == RST_RUN;
  wire run = !i_pause && !rst_hold;
  always_ff @(posedge clk) begin
    if (run) begin
      c16 <= c16 == 4'd7 ? 4'd0 : c16 + 4'd1;
      c64 <= c64 == 6'd31 ? 6'd0 : c64 + 6'd1;
    end
  end
  wire cpu_cen /* verilator public_flat_rd */ = run && c16 == 4'd7;
  wire ym_cen  = run && c64 == 6'd31;
  wire opl_cen = run && c64[3:0] == 4'd15;

  // ================================================================ 6502
  logic [15:0] A /* verilator public_flat_rd */;
  logic [7:0]  dout /* verilator public_flat_rd */, din /* verilator public_flat_rd */;
  logic        rd /* verilator public_flat_rd */, wr /* verilator public_flat_rd */;
  logic        irq, nmi;
  logic        fetch /* verilator public_flat_rd */;  // opcode fetch (sim trace)

  jt65c02 #(.DECO222(1)) u_cpu (
    .rst(!snd_rst_n), .clk(clk), .cen(cpu_cen),
    .irq(irq), .nmi(nmi), .opdec(sr || i_machine == 4'd5 || os),
    .wr(wr), .rd(rd), .fetch(fetch), .addr(A), .din(din), .dout(dout));

  // one event per bus write: the first cen of a write, or a new address
  logic        wr_l;
  logic [15:0] wa_l;
  always_ff @(posedge clk) begin
    if (!snd_rst_n) begin wr_l <= 1'b0; wa_l <= '0; end
    else if (cpu_cen) begin wr_l <= wr; wa_l <= A; end
  end
  wire wev /* verilator public_flat_rd */ = cpu_cen && wr && (!wr_l || wa_l != A);

  // address decode (dec8:625-658)
  wire [15:0] YM  = lm ? 16'h0800 : 16'h2000;
  wire [15:0] OPL = lm ? 16'h1000 : 16'h4000;
  wire [15:0] LAT = lm ? 16'h3000 : 16'h6000;
  wire s_ram  = A < (cs ? 16'h0800 : 16'h0600);
  wire s_rom  = A[15] || (cs && A[15:14] == 2'b01);
  wire s_ym   = {A[15:1], 1'b0} == YM;
  wire s_opl  = {A[15:1], 1'b0} == OPL;
  wire s_lat  = A == LAT;
  wire s_adpcm = cs && A == 16'h1800;
  wire s_bank = cs && A == 16'h2000;
  wire s_reset = cs && A == 16'h3400;
  wire s_unm  = !(s_ram || s_rom || s_ym || s_opl || s_lat || s_adpcm || s_bank || s_reset);

  // ================================================================ memories
  logic [7:0] ram [0:2047] /* verilator public_flat_rd */;
  logic [7:0] rom [0:65535] /* verilator public_flat_rw */;
  logic sound_bank;
  wire [15:0] rom_address = cs && !A[15] ? {1'b1,sound_bank,A[13:0]} : {1'b0,A[14:0]};
  always_ff @(posedge clk) begin
    if (!snd_rst_n) sound_bank <= 1'b0;
    else if (wev && s_bank) sound_bank <= dout[3];
  end
  logic [7:0] ram_q, rom_q;
  always_ff @(posedge clk) begin
    if (wev && s_ram) ram[A[10:0]] <= dout;
    ram_q <= ram[A[10:0]];
  end
  always_ff @(posedge clk) begin
    if (i_rom_we) rom[i_rom_addr] <= i_rom_din;
    rom_q <= rom[rom_address];
  end

  // ================================================================ latch and NMI
  logic [7:0] latch /* verilator public_flat_rd */;
  logic       pending /* verilator public_flat_rd */;
  logic [5:0] nmi_cnt;                   // gondo: 4 bus cycles = 16 cens
  wire  lat_rd = cpu_cen && rd && !wr && s_lat;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      latch <= '0; pending <= 1'b0; nmi_cnt <= '0;
    end else begin
      if (lat_rd) pending <= 1'b0;
      if ((go || gb) && nmi_cnt != 0 && cpu_cen) nmi_cnt <= nmi_cnt - 6'd1;
      if (i_latch_wr) begin
        latch <= i_latch_d;
        if (go || gb) nmi_cnt <= 6'd16;
        else    pending <= 1'b1;
      end
    end
  end
  assign nmi = go || gb ? (nmi_cnt != 0) : pending;

  // ================================================================ YM2203
  logic signed [15:0] ym_fm;
  logic [9:0]  ym_ssg;
  logic        ym_irq_n, opl_irq_n;
  jt03 u_ym (
    .rst(!snd_rst_n), .clk(clk), .cen(ym_cen),
    .din(dout), .addr(A[0]), .cs_n(!(wev && s_ym)), .wr_n(1'b0),
    .dout(), .irq_n(ym_irq_n),
    .IOA_in(8'd0), .IOB_in(8'd0), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
    .psg_A(), .psg_B(), .psg_C(), .fm_snd(ym_fm), .psg_snd(ym_ssg),
    .snd(), .snd_sample(), .debug_view());

  // ================================================================ OPL
  // YM3526 on lastmisn / gondo: register 01 bit 5 (OPL2 wave-select enable)
  // does not exist; clear it so jtopl2 keeps every operator on the sine
  logic [7:0] opl_sel;
  always_ff @(posedge clk) begin
    if (!snd_rst_n) opl_sel <= '0;
    else if (wev && s_opl && !A[0]) opl_sel <= dout;
  end
  // (Cobra-Command, profile 9, has a YM3812: keep the bit)
  wire [7:0] opl_din = (!sr && !gb && !cb && A[0] && opl_sel == 8'h01) ? (dout & 8'hDF) : dout;
  logic signed [15:0] opl_snd;
  jtopl2 u_opl (
    .rst(!snd_rst_n), .clk(clk), .cen(opl_cen),
    .din(opl_din), .addr(A[0]), .cs_n(!(wev && s_opl)), .wr_n(1'b0),
    .dout(), .irq_n(opl_irq_n), .snd(opl_snd), .sample());

  wire adpcm_irq, adpcm_tick;
  wire signed [11:0] adpcm_sample /* verilator public_flat_rd */;
  d8_adpcm u_adpcm (
    .clk, .rst_n(snd_rst_n && cs), .i_pause(i_pause || rst_hold || !cs),
    .i_data_we(wev && s_adpcm), .i_data(dout), .o_irq(adpcm_irq),
    .o_tick(adpcm_tick), .o_nibble(), .o_audio(adpcm_sample));
  assign irq = cs ? adpcm_irq : !ym_irq_n || !opl_irq_n;

  // ================================================================ read data
  always_comb begin
    din = 8'h00;                         // unmapped, and the write-only chips
    if (s_ram) din = ram_q;
    else if (s_rom) din = rom_q;
    else if (s_lat) din = latch;
  end

  // ================================================================ gate counters
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_dbg_unmapped <= '0; o_dbg_rom_writes <= '0;
    end else if (cpu_cen && (rd || wr) && s_unm && (wr ? wev : 1'b1)) begin
      o_dbg_unmapped <= o_dbg_unmapped + 16'd1;
    end else if (wev && s_rom) begin
      o_dbg_rom_writes <= o_dbg_rom_writes + 16'd1;
    end
  end

  // ================================================================ mix
  // every term signed (Dooyong landmine: one unsigned operand makes the
  // whole sum unsigned and >>> logical)
  wire signed [15:0] fm_g = ym_fm;
  assign o_fm  = fm_g;
  assign o_ssg = ym_ssg;
  assign o_opl = opl_snd;
  // The three products are registered (M4 timing: the whole mix in one
  // clock missed 96 MHz by 1.9 ns), so o_mix follows the chips one clock
  // (10 ns) later than in M3.
  logic signed [31:0] p_fm, p_ssg, p_opl, p_adpcm;
  always_ff @(posedge clk) begin
    p_fm  <= 32'(fm_g) * $signed(32'(cb ? FM_GAIN_CB : cs ? FM_GAIN/2 : FM_GAIN));
    p_ssg <= $signed(32'({1'b0, ym_ssg})) * $signed(32'(cb ? SSG_GAIN_CB : cs ? SSG_GAIN/2 : SSG_GAIN));
    p_opl <= 32'(opl_snd) * $signed(32'(cb ? OPL_GAIN_CB : cs ? OPL_GAIN/2 : go ? OPL_GAIN_GO : OPL_GAIN));
    // 12-bit PCM -> signed 16-bit: MAME msm5205 scales signal/4096 (full scale
    // +-0.5) and the route is 0.80, so 0.80*8 = 6.4 per count (1638/256);
    // measured slope of MAME's wav on the same nibbles: 6.2 per count.
    p_adpcm <= cs ? 32'(adpcm_sample) * 32'sd1638 : 32'sd0;
  end
  always_comb begin
    logic signed [31:0] m;
    m = cs ? ((p_fm+p_ssg)+(p_opl+p_adpcm)) >>> 8 : (p_fm + p_ssg + p_opl) >>> 8;
    o_mix = (m > 32'sd32767) ? 16'sh7FFF : (m < -32'sd32768) ? 16'sh8000 : m[15:0];
  end

endmodule
