// =============================================================================
// williams_bg.sv -- Williams D-11581 / D-11581-20xx "Audio Board"
// (PCB trace part number 5766-12130-00 REV A), i.e. the System 11 / System 11C
// BACKGROUND MUSIC AND SPEECH board.
//
// MAME 0.289 reference: src/mame/shared/s11c_bg.cpp / .h
//   `s11_bg_device`  (S11,  D-11581)              -> Arch Rivals   (archrivl)
//   `s11c_bg_device` (S11C, D-11581-20xx/400xx)   -> Pigskin       (pigskin)
// selected here by the `s11c` input, which carries mcr68_game_profile.svh's
// `williams_s11c` profile bit. The two devices differ in ONE thing only: the
// output-mixer input resistor values (see williams_bg_mixer.sv).
//
// =============================================================================
// Hardware (evidence: s11c_bg.cpp, read in full; the file's own header carries
// the board's schematic part numbers, jumper table, connector pinout and the
// CVSD filter schematic)
// =============================================================================
//   CPU     MC68B09E @ XTAL(8'000'000) / 4 = 2 MHz E  (s11c_bg.cpp:366)
//   OPM     YM2151   @ XTAL(3'579'545)                (s11c_bg.cpp:386)
//   DAC     MC1408, 8-bit, fed from PIA40 port A      (s11c_bg.cpp:370,373)
//   CVSD    HC55516 + two op-amp filter stages        (s11c_bg.cpp:391-405)
//   PIA     one PIA6821 ("pia40")                     (s11c_bg.cpp:372-378)
//   RAM     2 KiB (6116 or 6164 at U5, jumper W8/W9)
//   ROM     U4/U19/U20, banked into 8000-FFFF
//
//   PIA40 wiring (s11_bg_base + s11_bg_ym, s11c_bg.cpp:364-388):
//     port A out -> MC1408 DAC (8 bit)
//     port B out -> pia40_pb_w  (host readback; unused by MCR-68k, see below)
//     port B in  <- host data bus, J4 pins 3-10 (data_w)
//     CA1 in     <- YM2151 /IRQ, via MAME's `.invert()`  ("IRQ is not true
//                   state") -- so CA1 carries the PIN level, i.e. our
//                   ym2151_wrap `irq_n` connects DIRECTLY, with no further
//                   inversion in this module. Getting this backwards is the
//                   single easiest error here; see the derivation below.
//     CA2 out    -> YM2151 /RESET  (board jumper W1)
//     CB1 in     <- host /STB,  J4 pin 13 (ctrl_w)
//     CB2        <- host /STBR, J4 pin 12 (extra_w) -- see the CB2 note below
//     IRQA       -> 6809 **FIRQ**       (M6809_FIRQ_LINE)
//     IRQB       -> 6809 **NMI**        (INPUT_LINE_NMI)
//   Note that NOTHING drives the 6809's ordinary /IRQ on this board -- it is
//   tied inactive. This is the opposite split from the legacy alternate board
//   board, where the ORed PIA IRQ drives /IRQ and FIRQ/NMI are unused.
//
//   CA1 inversion derivation (do not "simplify" this):
//     MAME calls an irq_handler with state=1 meaning "interrupt ASSERTED",
//     which on the real pin means /IRQ LOW. `.invert()` therefore makes
//     pia->ca1_w() receive 0 when the OPM is asserting IRQ -- i.e. CA1 carries
//     the physical /IRQ pin level. ym2151_wrap.sv exports exactly that pin as
//     `irq_n`. Hence `.ca1(ym_irq_n)` and NOT `.ca1(~ym_irq_n)`.
//
// =============================================================================
// Memory map (s11c_bg_map, s11c_bg.cpp:283-292)
// =============================================================================
//   0000-07FF mirror 1800  RAM 2 KiB          -> 0000-1FFF decodes to RAM
//   2000-2001 mirror 1FFE  YM2151 (r/w)       -> 2000-3FFF, A0 = a0/RS
//   4000-4003 mirror 1FFC  PIA6821 (r/w)      -> 4000-5FFF, {A1,A0} = {RS1,RS0}
//   6000-6000 mirror 07FF  CVSD clock set (w) -> 6000-67FF
//   6800-6800 mirror 07FF  CVSD digit + clock clear (w) -> 6800-6FFF
//   7800-7800 mirror 07FF  ROM bank register (w) -> 7800-7FFF
//   8000-FFFF              banked ROM window
//   (7000-77FF is a genuine unmapped hole.)
//
// DECODE-BUG AVOIDANCE -- the class of mistake fixed twice in sounds_good.sv
// (a `~addr[3]` chip-select qualifier for a real hole inside a mirrored window,
// and a `~uds_n` byte-lane qualifier). Both were re-checked against THIS map
// and both are correctly absent, deliberately:
//   * holes: RAM/YM/PIA each use `base + mirror` masks that together cover every
//     address bit below A13 (RAM 0x07FF|0x1800, YM 0x0001|0x1FFE,
//     PIA 0x0003|0x1FFC), so 0000-1FFF, 2000-3FFF and 4000-5FFF each decode
//     solidly with no hole. A `~addr[N]` qualifier on any of them would be a
//     bug. The 6000-7FFF quadrant is the one that DOES have a hole (7000-77FF),
//     and it is decoded to four 2 KiB slots on {A12,A11} accordingly.
//   * byte lanes: this is an 8-bit 6809 bus, no umask and no UDS/LDS.
//   * PIA register selects: s11c_bg_map uses the PLAIN `pia6821_device::read`
//     / `write`, **not** `read_alt`/`write_alt`. So RS0<-A0 and RS1<-A1, the
//     ORDINARY order -- the RS0/RS1 SWAP that both the Sounds Good and the
//     legacy alternate-board behavior does NOT apply here. rtl/snd/pia6821.sv's
//     `addr` port is {RS1, RS0}, so it is driven with {A1, A0}.
//     Consequence, stated because it is the opposite of the sibling boards:
//     PORTA/DDRA @4000, CRA @4001, PORTB/DDRB @4002, CRB @4003.
//   * `map.unmap_value_high()` is NOT called, so unmapped reads are MAME's
//     default 0x00, not 0xFF (again the opposite of the legacy map).
//
// =============================================================================
// ROM banking (bgbank_w, s11c_bg.cpp:535-548; device_start :499-506)
// =============================================================================
//   configure_entries(0, 16, &rom[0], 0x8000)  -- 16 banks of 32 KiB over the
//   0x90000-byte "bg:cpu" region, entry 0 selected at reset.
//   bank = bitswap<8>(data,7,6,5,4,1,0,3,2) & 0xf
//        = { data[1], data[0], data[3], data[2] }
//   MAME's own table explains what those four bits are on the PCB:
//        3 2 1 0
//        r q 0 0 -  U4, A15 <- q, A16 <- r
//        r q 0 1 - U19, A15 <- q, A16 <- r
//        r q 1 0 - U20, A15 <- q, A16 <- r
//        x x 1 1 - open bus
//   so the bitswap is just re-packing {chip-select, A16, A15} into the flat
//   entry index that the ROM_RELOAD-padded region is laid out for:
//        region offset = data[1:0]*0x20000 + data[3]*0x10000 + data[2]*0x8000
//   Bit 3 (A16) only exists on the A-13971-50003 / D-11581-20xx boards with
//   27512s fitted; on the older board it is unconnected, and the ROM_RELOAD
//   mirrors in the archrivl set make it read the same 32 KiB either way, so no
//   per-title gating is needed here -- the ROM image encodes the difference.
//   Bank index 0b11xx addresses region 0x60000-0x7FFFF, which is unpopulated
//   (verified all-zero in both staged bgcpu.bin files) = the "open bus" row.
//
// =============================================================================
// CVSD (see rtl/snd/williams_bg/hc55516.sv for the decoder itself)
// =============================================================================
// Clock and data are driven ENTIRELY IN SOFTWARE by the 6809 through two
// write-only addresses (s11c_bg.cpp:520-533). The 0x6800 handler runs
// clock_w(0) BEFORE digit_w(data&1); that ordering is preserved here.
//
// The two filter stages are modelled EXACTLY as MAME does, including the
// design error MAME documents and deliberately reproduces: the 1800 uF
// capacitor to ground that stage 1 should have is COMPLETELY MISSING on the
// real D-11297 board and every D-11581 derived from it, which turns what
// should be a 4th-order (2 cascaded 2nd-order MFB) filter into a 1st-order
// -with-gain stage cascaded into a 2nd-order stage -- a 3rd-order filter with
// an odd response. MAME's comment is explicit: "We emulate this weird circuit
// as it existed." So does this module. Coefficients are derived in
// doc/rtl_williams_bg.md from the schematic component values in s11c_bg.cpp's
// header, through MAME's own opamp_mfb_lowpass_calc()/recalc() formulas.
//
// =============================================================================
// Host interface (archrivl_control_w, mcr68.cpp:486-506) -- both games
// =============================================================================
//     m_bg->resetq_w(BIT(m_control_word, 10));   // J4 p18 /RESET
//     m_bg->data_w  (m_control_word & 0xff);     // J4 p3-10  -> PIA port B in
//     m_bg->ctrl_w  (BIT(m_control_word, 8));    // J4 p13 /STB  -> PIA CB1
//     m_bg->extra_w (BIT(m_control_word, 9));    // J4 p12 /STBR -> PIA CB2
// All four are LEVELS passed through with no inversion at the call site, and
// this module likewise applies no inversion -- unlike the Sounds Good path,
// whose strobe bit IS inverted onto CA1 by the board
// module. Do not add an inversion here by analogy with those boards.
//
// `resetq` is EDGE-sensitive in MAME (resetq_w, s11c_bg.cpp:352-360): only a
// transition from not-CLEAR to CLEAR (a 1 -> 0 edge on control bit 10) runs
// common_reset(). common_reset() sets the bank back to 0 and pulses the CPU's
// reset line; it does NOT reset the PIA, the YM2151 or the CVSD. That exact
// scope is reproduced (see `board_rst` below) -- deliberately, because MAME is
// the differential oracle for this board and the real PCB's /RESET fan-out
// beyond the CPU is not established from any schematic available here. Recorded
// as an open item in doc/rtl_williams_bg.md rather than guessed at.
//
// CB2 NOTE (a real, documented gap): on the PCB CB2 is bidirectional -- J4 pin
// 12 is "strobe out", asserted low by the board to tell the mainboard to read
// its bus, and MAME wires both a cb2_handler (board -> host) and extra_w
// (host -> board). rtl/snd/pia6821.sv, which this project shares with the other
// sound boards and which this task does not own, exposes a CB2 INPUT and a CA2
// output but no CB2 output. That costs nothing for the two titles in scope:
// mcr68.cpp binds neither `cb2_cb()` nor `pb_cb()`, so nothing on MCR-68k ever
// observes the board's CB2 or port-B outputs. Logged in
// doc/integration_requests/williams_bg.md so it is not rediscovered as a bug.
//
// =============================================================================
// CPU interface contract (rtl/cpu/mc6809e.sv) -- read its header before editing
// =============================================================================
//   * one `ce` pulse == one 6809 bus cycle (one E period), >= 2 clk apart;
//   * addr/rw_n/dout are stable across the whole bus cycle and valid AT the
//     `ce` edge, so `if (ce && !rw_n)` is the correct write strobe;
//   * `din` is sampled one clk AFTER `ce`, so a registered memory read must be
//     launched FROM THE ADDRESS, never from `ce`. Both memory variants do that.
//   * `irq_n` is tied inactive here; FIRQ and NMI carry the PIA.
//
// HARD CONSTRAINTS OBSERVED: no gated clocks anywhere (clock enables only), all
// state non-blocking and clocked on `clk`, no inferred latches, explicit
// widths, flat block-RAM-inferrable memories.
// =============================================================================

`default_nettype none

module williams_bg #(
    parameter int    CLK_HZ    = 40_000_000, // frequency of `clk` (this module's
                                              // bus domain), NOT the 6809 rate
    parameter int    CPU_HZ    =  2_000_000, // MC68B09E E-clock: 8 MHz XTAL / 4
    parameter int    YM_HZ     =  3_579_545, // YM2151 phi (XTAL(3'579'545))
    parameter int    SAMPLE_HZ =     48_000, // audio filter/mix update rate
    parameter string BG_ROM_FILE = "",       // sim-only flat bgcpu.bin path
    parameter bit    SDRAM_ROM = 1'b0        // 0 = williams_bg_mem_sim (host file)
                                              // 1 = williams_bg_mem_hw + fabric
) (
    input  logic        clk,
    input  logic        rst,          // system/power-on reset, active high

    // ---------------- board variant (static profile bit) ------------------------
    input  logic        s11c,         // mcr68_game_profile.svh `williams_s11c`:
                                       // 0 = S11 / D-11581     (Arch Rivals)
                                       // 1 = S11C / D-11581-20xx (Pigskin)

    // ---------------- host side, J4 (archrivl_control_w) ------------------------
    input  logic [7:0]  host_data,    // control_word[7:0]  -> PIA port B inputs
    input  logic        host_ctrl,    // control_word[8]    -> PIA CB1  (/STB)
    input  logic        host_extra,   // control_word[9]    -> PIA CB2  (/STBR)
    input  logic        host_resetq,  // control_word[10]   -> J4 p18 /RESET,
                                       // EDGE sensitive (1 -> 0 resets the board)

    // ---------------- external program-ROM fabric (SDRAM_ROM == 1 only) ---------
    output logic        bgrom_req,
    output logic [18:0] bgrom_addr,   // {bank[3:0], cpu_addr[14:0]}
    input  logic [7:0]  bgrom_data,
    input  logic        bgrom_ack,

    // ---------------- audio -----------------------------------------------------
    output logic signed [15:0] audio_out,

    // ---------------- debug-only, purely additive -------------------------------
    output logic [15:0] dbg_cpu_addr,
    output logic [7:0]  dbg_cpu_dout,
    output logic [7:0]  dbg_cpu_din,
    output logic        dbg_cpu_rw_n,
    output logic        dbg_cpu_ce,
    output logic        dbg_firq_n,
    output logic        dbg_nmi_n,
    output logic        dbg_rom_cs,
    output logic        dbg_ram_cs,
    output logic        dbg_ym_cs,
    output logic        dbg_pia_cs,
    output logic        dbg_ym_wr,        // 1-clk pulse: host write into the OPM
    output logic        dbg_ym_a0,
    output logic [7:0]  dbg_ym_data,
    output logic        dbg_ym_irq_n,
    output logic        dbg_ym_rst_n,
    output logic [3:0]  dbg_bank,
    output logic [7:0]  dbg_dac8,
    output logic        dbg_cvsd_set,
    output logic        dbg_cvsd_clr,
    output logic        dbg_cvsd_digit,
    output logic signed [15:0] dbg_cvsd_sample,
    output logic signed [17:0] dbg_cvsd_filt,   // after BOTH filter stages
    output logic        dbg_sample_tick
);

    // -------------------------------------------------------------------------
    // Board /RESET (J4 pin 18). MAME's resetq_w is EDGE sensitive: a 1 -> 0
    // transition runs common_reset(), which resets the bank register and pulses
    // the CPU's reset line. The pulse is stretched here to cover several bus
    // cycles, since mc6809e.sv requires rst_n held low for at least one `ce`.
    // -------------------------------------------------------------------------
    logic       resetq_q;
    logic [6:0] board_rst_cnt;
    logic       board_rst;     // CPU + bank only, per common_reset()

    always_ff @(posedge clk) begin
        if (rst) begin
            resetq_q      <= 1'b1;
            board_rst_cnt <= 7'd0;
        end else begin
            resetq_q <= host_resetq;
            if (resetq_q && !host_resetq) board_rst_cnt <= 7'd64;
            else if (board_rst_cnt != 7'd0) board_rst_cnt <= board_rst_cnt - 7'd1;
        end
    end

    assign board_rst = rst | (board_rst_cnt != 7'd0);

    // -------------------------------------------------------------------------
    // Bus-cycle clock enable: fixed-point phase accumulator (NCO) whose long-run
    // average rate is exactly CPU_HZ pulses/sec relative to `clk` -- one pulse
    // per 6809 bus cycle. Same idiom as the shared 6809 bus adapter.
    // No clock is gated anywhere in this module.
    // -------------------------------------------------------------------------
    localparam int ACC_W = 32;
    localparam longint unsigned CE_STEP64 =
        (longint'(CPU_HZ) * (longint'(1) << ACC_W)) / longint'(CLK_HZ);
    localparam logic [ACC_W-1:0] CE_STEP = CE_STEP64[ACC_W-1:0];

    logic [ACC_W-1:0] ce_acc;
    logic             ce_tick;
    logic             ce_pend;
    logic             ce_holdoff;
    logic             cpu_ce;
    logic             rom_stall;

    always_ff @(posedge clk) begin
        if (board_rst) begin
            ce_acc  <= '0;
            ce_tick <= 1'b0;
            ce_pend <= 1'b0;
            ce_holdoff <= 1'b0;
        end else begin
            {ce_tick, ce_acc} <= {1'b0, ce_acc} + {1'b0, CE_STEP};
            if (cpu_ce)                   ce_pend <= 1'b0;
            else if (ce_tick & rom_stall) ce_pend <= 1'b1;

            // A replayed tick already represents the stalled E period.  If
            // the NCO carry arrives in the following clk, coalesce it rather
            // than presenting adjacent enables to the MC6809E wrapper.
            ce_holdoff <= cpu_ce & ce_pend & ~ce_tick;
        end
    end

    assign cpu_ce = (ce_tick | ce_pend) & ~rom_stall & ~ce_holdoff;

    // -------------------------------------------------------------------------
    // CPU. /IRQ is tied inactive -- s11c_bg.cpp wires only M6809_FIRQ_LINE and
    // INPUT_LINE_NMI. /HALT is unused (no DMA on this board).
    // -------------------------------------------------------------------------
    logic [15:0] cpu_addr;
    logic [7:0]  cpu_din, cpu_dout;
    logic        cpu_rw_n;
    logic        cpu_firq_n, cpu_nmi_n;

    /* verilator lint_off PINCONNECTEMPTY */
    mc6809e u_cpu (
        .clk    (clk),
        .ce     (cpu_ce),
        .rst_n  (~board_rst),

        .addr   (cpu_addr),
        .din    (cpu_din),
        .dout   (cpu_dout),
        .rw_n   (cpu_rw_n),

        .irq_n  (1'b1),          // not wired on this board
        .firq_n (cpu_firq_n),    // <- PIA40 IRQA
        .nmi_n  (cpu_nmi_n),     // <- PIA40 IRQB
        .halt_n (1'b1),

        .ba     (),
        .bs     ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // -------------------------------------------------------------------------
    // Address decode (s11c_bg_map). See the header's decode-bug note.
    // -------------------------------------------------------------------------
    logic rom_cs, ram_cs, ym_cs, pia_cs, io6_cs;
    logic cvsd_set_cs, cvsd_clr_cs, bank_cs;

    assign rom_cs = cpu_addr[15];
    assign ram_cs = ~cpu_addr[15] & ~cpu_addr[14] & ~cpu_addr[13];  // 0000-1FFF
    assign ym_cs  = ~cpu_addr[15] & ~cpu_addr[14] &  cpu_addr[13];  // 2000-3FFF
    assign pia_cs = ~cpu_addr[15] &  cpu_addr[14] & ~cpu_addr[13];  // 4000-5FFF
    assign io6_cs = ~cpu_addr[15] &  cpu_addr[14] &  cpu_addr[13];  // 6000-7FFF

    // 6000-7FFF splits into four 2 KiB slots on {A12, A11}:
    //   00 = 6000-67FF CVSD clock set   01 = 6800-6FFF CVSD digit + clock clear
    //   10 = 7000-77FF UNMAPPED         11 = 7800-7FFF bank register
    assign cvsd_set_cs = io6_cs & ~cpu_addr[12] & ~cpu_addr[11];
    assign cvsd_clr_cs = io6_cs & ~cpu_addr[12] &  cpu_addr[11];
    assign bank_cs     = io6_cs &  cpu_addr[12] &  cpu_addr[11];

    // Write strobe for the three write-only registers: exactly one clk wide,
    // aligned to the bus cycle (addr/dout are valid at `ce`).
    logic cpu_wr;
    assign cpu_wr = ~cpu_rw_n & cpu_ce;

    // -------------------------------------------------------------------------
    // ROM bank register (bgbank_w). Reset to entry 0 by common_reset().
    // bank = {data[1], data[0], data[3], data[2]}   (see header derivation)
    // -------------------------------------------------------------------------
    logic [3:0] bank;

    always_ff @(posedge clk) begin
        if (board_rst)               bank <= 4'd0;
        else if (bank_cs && cpu_wr)  bank <= {cpu_dout[1], cpu_dout[0],
                                              cpu_dout[3], cpu_dout[2]};
    end

    // -------------------------------------------------------------------------
    // Memory path.
    // -------------------------------------------------------------------------
    logic [7:0]  mem_dout;
    logic        mem_we;
    logic [18:0] rom_addr;

    assign mem_we   = ~cpu_rw_n & cpu_ce & ram_cs;
    assign rom_addr = {bank, cpu_addr[14:0]};

    generate
        if (!SDRAM_ROM) begin : g_sim_mem
            williams_bg_mem_sim #(
                .BG_ROM_FILE (BG_ROM_FILE)
            ) u_mem (
                .clk      (clk),
                .rom_addr (rom_addr),
                .cpu_addr (cpu_addr),
                .cpu_din  (cpu_dout),
                .cpu_dout (mem_dout),
                .cpu_we   (mem_we),
                .rom_cs   (rom_cs),
                .ram_cs   (ram_cs)
            );
        end else begin : g_hw_mem
            williams_bg_mem_hw u_mem (
                .clk      (clk),
                .rom_addr (rom_addr),
                .cpu_addr (cpu_addr),
                .cpu_din  (cpu_dout),
                .cpu_dout (mem_dout),
                .cpu_we   (mem_we),
                .rom_cs   (rom_cs),
                .ram_cs   (ram_cs)
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // External ROM fabric handshake (SDRAM_ROM == 1), same shape as
    // shared 6809 bus adapter. The 6809 has no wait-state pin in this interface,
    // so a not-yet-fetched ROM byte stalls the bus by withholding cpu_ce --
    // functionally what a real 6809E system does by stretching E via MRDY.
    // -------------------------------------------------------------------------
    logic [7:0]  rom_data_r;
    logic [18:0] rom_addr_q;
    logic        rom_have;
    logic        rom_busy;

    wire rom_hit = rom_have & (rom_addr_q == rom_addr);

    assign rom_stall  = SDRAM_ROM & rom_cs & ~rom_hit;
    assign bgrom_addr = rom_addr;

    always_ff @(posedge clk) begin
        if (board_rst) begin
            bgrom_req  <= 1'b0;
            rom_have   <= 1'b0;
            rom_busy   <= 1'b0;
            rom_addr_q <= '0;
            rom_data_r <= '0;
        end else if (SDRAM_ROM) begin
            if (!rom_busy) begin
                if (rom_cs && !rom_hit) begin
                    rom_addr_q <= rom_addr;
                    rom_have   <= 1'b0;
                    rom_busy   <= 1'b1;
                    bgrom_req  <= 1'b1;
                end
            end else if (bgrom_ack) begin
                rom_data_r <= bgrom_data;
                bgrom_req  <= 1'b0;
                rom_busy   <= 1'b0;
                rom_have   <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // YM2151 (rtl/snd/ym2151/ym2151_wrap.sv -> IKAOPM, BSD-2-Clause).
    //
    // `ce` is an NCO-generated 3.579545 MHz enable. The wrapper turns a host bus
    // cycle into one bounded donor write request, so it is handed a
    // ONE-CLK-WIDE strobe aligned to the bus cycle rather than a level held for
    // the whole 6809 E period. The wrapper asserts if another host write arrives
    // before the request has retired through the OPM enable domain.
    //
    // /RESET comes from PIA40 CA2 (board jumper W1, s11c_bg.cpp:384).
    // ym2151_device::reset_w is documented "active LOW" and MAME blocks register
    // writes while the line is 0, resetting the chip when it returns to 1 -- so
    // driving the wrapper's active-low rst_n from CA2 directly is the same
    // behaviour, and is what the physical /RESET pin does.
    // -------------------------------------------------------------------------
    localparam longint unsigned YM_STEP64 =
        (longint'(YM_HZ) * (longint'(1) << ACC_W)) / longint'(CLK_HZ);
    localparam logic [ACC_W-1:0] YM_STEP = YM_STEP64[ACC_W-1:0];

    logic [ACC_W-1:0] ym_acc;
    logic             ym_ce;

    always_ff @(posedge clk) begin
        if (rst) begin
            ym_acc <= '0;
            ym_ce  <= 1'b0;
        end else begin
            {ym_ce, ym_acc} <= {1'b0, ym_acc} + {1'b0, YM_STEP};
        end
    end

    logic       ym_wr;
    logic [7:0] ym_dout;
    logic       ym_irq_n;
    logic       ym_rst_n;
    logic signed [15:0] ym_l, ym_r;
    logic       pia_ca2_out;

    assign ym_wr    = ym_cs & cpu_wr;
    assign ym_rst_n = pia_ca2_out & ~rst;

    /* verilator lint_off PINCONNECTEMPTY */
    ym2151_wrap #(
        .FULL_RES (0)                 // chip-accurate YM3012-style output
    ) u_ym2151 (
        .clk          (clk),
        .ce           (ym_ce),
        .rst_n        (ym_rst_n),
        .cs_n         (~ym_wr),
        .wr_n         (~ym_wr),
        .a0           (cpu_addr[0]),
        .din          (cpu_dout),
        .dout         (ym_dout),
        .irq_n        (ym_irq_n),
        .sample_l     (ym_l),
        .sample_r     (ym_r),
        .sample_valid ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // -------------------------------------------------------------------------
    // PIA6821 (rtl/snd/pia6821.sv, reused unmodified).
    // ORDINARY register-select order here -- {RS1, RS0} = {A1, A0}. See header.
    // `en` is a single cpu_ce-wide strobe: one PIA access per 6809 bus cycle,
    // exactly the "one E-cycle at a time" convention that file documents.
    // -------------------------------------------------------------------------
    logic [7:0] pia_dout;
    logic [7:0] pia_pa_out;
    logic       pia_irqa, pia_irqb;

    /* verilator lint_off PINCONNECTEMPTY */
    pia6821 u_pia40 (
        .clk    (clk),
        .rst    (rst),                  // see the header note on common_reset()'s
                                         // scope: board /RESET does NOT reset the
                                         // PIA in MAME's model
        .en     (pia_cs & cpu_ce),
        .we     (~cpu_rw_n),
        .addr   ({cpu_addr[1], cpu_addr[0]}),  // {RS1, RS0} -- NOT swapped

        .din    (cpu_dout),
        .dout   (pia_dout),

        .pa_in  (8'h00),                // port A is DAC-out only on this board
        .pb_in  (host_data),            // J4 p3-10, data_w(control_word & 0xff)
        .ca1    (ym_irq_n),             // YM2151 /IRQ pin level -- see header
        .cb1    (host_ctrl),            // J4 p13 /STB,  ctrl_w
        .cb2    (host_extra),           // J4 p12 /STBR, extra_w

        .pa_out (pia_pa_out),
        .pb_out (),                     // pb_cb() is never bound on MCR-68k
        .ca2_out(pia_ca2_out),          // -> YM2151 /RESET
        .irqa   (pia_irqa),
        .irqb   (pia_irqb)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // IRQA -> FIRQ, IRQB -> NMI (s11c_bg.cpp:377-378). Both active low at the pin.
    assign cpu_firq_n = ~pia_irqa;
    assign cpu_nmi_n  = ~pia_irqb;

    // -------------------------------------------------------------------------
    // CPU read-data mux. Unmapped reads return 0x00 (s11c_bg_map does not call
    // unmap_value_high()). In SDRAM_ROM mode the ROM byte comes from the fabric
    // latch instead of the memory module.
    // -------------------------------------------------------------------------
    always_comb begin
        if      (rom_cs) cpu_din = SDRAM_ROM ? rom_data_r : mem_dout;
        else if (ram_cs) cpu_din = mem_dout;
        else if (ym_cs)  cpu_din = ym_dout;
        else if (pia_cs) cpu_din = pia_dout;
        else             cpu_din = 8'h00;
    end

    // -------------------------------------------------------------------------
    // HC55516 CVSD. Strobes are one clk wide and aligned to the bus cycle; the
    // decoder itself enforces MAME's "only act on an actual level change" rule.
    // -------------------------------------------------------------------------
    logic cvsd_set, cvsd_clr;
    logic signed [15:0] cvsd_sample;

    assign cvsd_set = cvsd_set_cs & cpu_wr;
    assign cvsd_clr = cvsd_clr_cs & cpu_wr;

    /* verilator lint_off PINCONNECTEMPTY */
    hc55516 u_cvsd (
        .clk     (clk),
        .rst     (rst),
        .clk_set (cvsd_set),
        .clk_clr (cvsd_clr),
        .digit   (cpu_dout[0]),     // digit_w(data & 1)
        .fzq_n   (1'b1),            // /FZ inactive: no fzq callback on this board
        .sample  (cvsd_sample),
        .agc     ()                 // agc_r() is never read on this board
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // -------------------------------------------------------------------------
    // Audio sample-rate tick (NCO, same idiom as mcr68_snd_dac.sv's). The three
    // audio engines are chained: filter stage 1 -> stage 2 -> mixer, 6+6+5 = 17
    // clk cycles, against ~833 clk cycles per sample at 40 MHz / 48 kHz.
    // -------------------------------------------------------------------------
    localparam longint unsigned SMP_STEP64 =
        (longint'(SAMPLE_HZ) * (longint'(1) << ACC_W)) / longint'(CLK_HZ);
    localparam logic [ACC_W-1:0] SMP_STEP = SMP_STEP64[ACC_W-1:0];

    logic [ACC_W-1:0] smp_acc;
    logic             smp_tick;

    always_ff @(posedge clk) begin
        if (rst) begin
            smp_acc  <= '0;
            smp_tick <= 1'b0;
        end else begin
            {smp_tick, smp_acc} <= {1'b0, smp_acc} + {1'b0, SMP_STEP};
        end
    end

    // -------------------------------------------------------------------------
    // CVSD filter chain. MAME divides the HC55516 output by 4 going in and
    // multiplies by 4 coming out (s11c_bg.cpp:404 vs the *4.0 mixer routes)
    // purely for float headroom; the same pair is reproduced -- the >>> 2 here,
    // the *4-folded weight in williams_bg_mixer.sv -- so the fixed-point
    // headroom analysis in doc/rtl_williams_bg.md matches MAME's numbers
    // directly.
    //
    // Coefficients (signed Q2.14), derived in doc/rtl_williams_bg.md from
    // s11c_bg.cpp's schematic values through MAME's own
    // opamp_mfb_lowpass_calc() + recalc(), evaluated at SAMPLE_HZ = 48 kHz:
    //
    //   stage 1  opamp_mfb_lowpass(43k, 36k, 180k, 0pF, 180pF)
    //            -> LOWPASS1P, fc = 2411.2 Hz, gain = -4.18605
    //               (the C1 = 0 case: the MISSING capacitor)
    //            b0 = -1.133035 -> -18564   a1 = -0.729331 -> -11949
    //   stage 2  opamp_mfb_lowpass(27k, 15k, 27k, 4700pF, 1200pF)
    //            -> LOWPASS,   fc = 3330.0 Hz, Q = 0.698733, gain = -1.0
    //            b0 = -0.035904 ->   -588   b1 = -0.071809 -> -1176
    //            b2 = -0.035904 ->   -588   a1 = -1.392172 -> -22809
    //                                       a2 =  0.535838 ->   8779
    // -------------------------------------------------------------------------
    logic signed [17:0] cvsd_ext, cvsd_in18, cvsd_s1, cvsd_s2;
    logic               s1_done, s2_done, mix_done;

    // MAME's 1/4 pre-scale. NOTE the two-step form: a SystemVerilog
    // concatenation is ALWAYS UNSIGNED regardless of its operands, so
    // `{{2{s[15]}}, s} >>> 2` would perform a LOGICAL shift and turn every
    // negative CVSD sample into a large positive one. That exact bug was here
    // and was caught by sim/sim_williams_bg.cpp's golden-model comparison (its
    // signature was an output that only ever clipped HIGH, never low). Widening
    // through a SIGNED intermediate keeps `>>>` arithmetic.
    assign cvsd_ext  = 18'(cvsd_sample);
    assign cvsd_in18 = cvsd_ext >>> 2;

    williams_bg_biquad #(
        .W_IN (18), .W_OUT (18), .W_STATE (20), .COEF_Q (14),
        .B0 (-16'sd18564), .B1 (16'sd0), .B2 (16'sd0),
        .A1 (-16'sd11949), .A2 (16'sd0)
    ) u_cvsd_filter (
        .clk (clk), .rst (rst), .tick (smp_tick),
        .din (cvsd_in18), .dout (cvsd_s1), .done (s1_done)
    );

    williams_bg_biquad #(
        .W_IN (18), .W_OUT (18), .W_STATE (20), .COEF_Q (14),
        .B0 (-16'sd588), .B1 (-16'sd1176), .B2 (-16'sd588),
        .A1 (-16'sd22809), .A2 (16'sd8779)
    ) u_cvsd_filter2 (
        .clk (clk), .rst (rst), .tick (s1_done),
        .din (cvsd_s1), .dout (cvsd_s2), .done (s2_done)
    );

    // -------------------------------------------------------------------------
    // MC1408 DAC. `dac_byte_interface::data_w` with MAME's dac_mapper_unsigned:
    // an UNSIGNED 8-bit code whose mid-scale is silence. Centred here by
    // subtracting 128 and left-justified by 8 bits into the project's 16-bit
    // signed audio convention (range -32768 .. +32512), then sign-extended to
    // the mixer's 18-bit operand width.
    // -------------------------------------------------------------------------
    logic signed [9:0]  dac_centred;
    logic signed [17:0] dac_s;

    assign dac_centred = $signed({2'b00, pia_pa_out}) - 10'sd128;
    assign dac_s       = {dac_centred, 8'b0};

    williams_bg_mixer u_mixer (
        .clk    (clk),
        .rst    (rst),
        .s11c   (s11c),
        .tick   (s2_done),
        .dac_s  (dac_s),
        .ym_l   (ym_l),
        .ym_r   (ym_r),
        .cvsd_f (cvsd_s2),
        .audio  (audio_out),
        .done   (mix_done)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_mix_done = mix_done;
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Debug-only passthroughs (no synthesizable decision depends on these).
    // -------------------------------------------------------------------------
    assign dbg_cpu_addr    = cpu_addr;
    assign dbg_cpu_dout    = cpu_dout;
    assign dbg_cpu_din     = cpu_din;
    assign dbg_cpu_rw_n    = cpu_rw_n;
    assign dbg_cpu_ce      = cpu_ce;
    assign dbg_firq_n      = cpu_firq_n;
    assign dbg_nmi_n       = cpu_nmi_n;
    assign dbg_rom_cs      = rom_cs;
    assign dbg_ram_cs      = ram_cs;
    assign dbg_ym_cs       = ym_cs;
    assign dbg_pia_cs      = pia_cs;
    assign dbg_ym_wr       = ym_wr;
    assign dbg_ym_a0       = cpu_addr[0];
    assign dbg_ym_data     = cpu_dout;
    assign dbg_ym_irq_n    = ym_irq_n;
    assign dbg_ym_rst_n    = ym_rst_n;
    assign dbg_bank        = bank;
    assign dbg_dac8        = pia_pa_out;
    assign dbg_cvsd_set    = cvsd_set;
    assign dbg_cvsd_clr    = cvsd_clr;
    assign dbg_cvsd_digit  = cpu_dout[0];
    assign dbg_cvsd_sample = cvsd_sample;
    assign dbg_cvsd_filt   = cvsd_s2;
    assign dbg_sample_tick = smp_tick;

endmodule

`default_nettype wire
