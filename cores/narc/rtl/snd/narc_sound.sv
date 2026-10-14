// -----------------------------------------------------------------------------
// Williams NARC dual-6809 sound board.
//
// Hardware behavior follows MAME's williams_narc_sound_device:
//   master 6809E: YM2151, DAC1, host command/talkback, slave command
//   slave  6809E: DAC2, HC55516 CVSD, master-to-slave command
// Both CPUs run at 8 MHz / 4 = 2 MHz and have 8 KiB RAM plus the Williams
// 16-entry banked ROM wiring. In hardware both byte-wide ROM regions share one
// SDRAM read port through independent 64-word caches and a deterministic arbiter.
// -----------------------------------------------------------------------------

`default_nettype none

// The sound board has an independent 8 MHz crystal; each MC6809E receives
// E/Q at exactly one quarter of that rate.  clk_sys is 24.162 MHz, so an
// integer divide-by-12 is 0.675% fast and audibly shifts all CPU-timed DAC and
// CVSD playback.  Advance the four E/Q quadrature states with a fractional
// 8 MHz accumulator instead.  Holding `advance` stretches the current phase
// during an external-ROM wait without losing fractional phase.
module narc_sound_eq_clock #(
  parameter int CLK_SYS_HZ = 24_162_000
) (
  input  wire clk,
  input  wire reset,
  input  wire advance,
  output wire cpu_e,
  output wire cpu_q,
  output wire cycle_boundary
);
  localparam logic [31:0] EQ_TICK_HZ_U = 32'd8_000_000;
  localparam logic [31:0] CLK_SYS_HZ_U = CLK_SYS_HZ;
  logic [31:0] tick_acc = '0;
  logic [1:0] eq_phase = '0;
  logic reset_d = 1'b0;
  wire eq_tick = advance && (tick_acc + EQ_TICK_HZ_U >= CLK_SYS_HZ_U);

  always_ff @(posedge clk) begin
    // Although the physical oscillator is free-running, initialize the FPGA
    // quadrature generator once at reset entry. Continue advancing while reset
    // is held because the MC6809E samples nRESET on an E edge; a static E level
    // could leave the CPU's reset sampler untouched.
    if (reset && !reset_d) begin
      tick_acc <= '0;
      eq_phase <= '0;
    end else if (advance) begin
      if (eq_tick) begin
        tick_acc <= tick_acc + EQ_TICK_HZ_U - CLK_SYS_HZ_U;
        eq_phase <= eq_phase + 2'd1;
      end else begin
        tick_acc <= tick_acc + EQ_TICK_HZ_U;
      end
    end
    reset_d <= reset;
  end

  // phase 0/1/2/3: E/Q = 11,10,00,01 (90-degree quadrature).
  assign cpu_e = ~eq_phase[1];
  assign cpu_q = ~(eq_phase[1] ^ eq_phase[0]);
  assign cycle_boundary = eq_tick && (eq_phase == 2'd3);
endmodule

// Final NARC analogue-path model. The original game source documents the four
// channels as CVSD, DAC A, DAC B and music (NARCSND.ASM), while MAME's Williams
// NARC board routes them at 0.60, 0.25, 0.25 and 0.10 respectively. Use close
// shift/add ratios and saturate like an audio output stage; truncating high bits
// here would turn positive overload into a loud negative discontinuity.
module narc_sound_mixer (
  input  wire signed [15:0] ym_l,
  input  wire signed [15:0] ym_r,
  input  wire        [7:0]  dac1,
  input  wire        [7:0]  dac2,
  input  wire signed [15:0] cvsd,
  output wire signed [15:0] audio_l,
  output wire signed [15:0] audio_r
);
  // AD7224 data is offset binary. Flipping its sign bit maps 00/80/ff to
  // -32768/0/+32512, matching the full-scale 8-bit R-2R DAC convention.
  wire signed [15:0] dac1_s = $signed({~dac1[7], dac1[6:0], 8'h00});
  wire signed [15:0] dac2_s = $signed({~dac2[7], dac2[6:0], 8'h00});

  wire signed [17:0] ym_l_w = {{2{ym_l[15]}}, ym_l};
  wire signed [17:0] ym_r_w = {{2{ym_r[15]}}, ym_r};
  wire signed [17:0] dac1_w = {{2{dac1_s[15]}}, dac1_s};
  wire signed [17:0] dac2_w = {{2{dac2_s[15]}}, dac2_s};
  wire signed [17:0] cvsd_w = {{2{cvsd[15]}}, cvsd};

  // 13/128 = 10.15625%, 77/128 = 60.15625%; error is 0.15625 percentage
  // point versus the reference routes and avoids consuming multiplier DSPs.
  wire signed [17:0] ym_l_scaled = (ym_l_w >>> 3) - (ym_l_w >>> 5)
                                   + (ym_l_w >>> 7);
  wire signed [17:0] ym_r_scaled = (ym_r_w >>> 3) - (ym_r_w >>> 5)
                                   + (ym_r_w >>> 7);
  wire signed [17:0] cvsd_scaled = (cvsd_w >>> 1) + (cvsd_w >>> 3)
                                  - (cvsd_w >>> 5) + (cvsd_w >>> 7);
  wire signed [17:0] mix_l = ym_l_scaled + (dac1_w >>> 2)
                            + (dac2_w >>> 2) + cvsd_scaled;
  wire signed [17:0] mix_r = ym_r_scaled + (dac1_w >>> 2)
                            + (dac2_w >>> 2) + cvsd_scaled;
  function automatic logic signed [15:0] sat16(
    input logic signed [17:0] value
  );
    if (value > 18'sd32767) sat16 = 16'sh7fff;
    else if (value < -18'sd32768) sat16 = 16'sh8000;
    else sat16 = value[15:0];
  endfunction

  assign audio_l = sat16(mix_l);
  assign audio_r = sat16(mix_r);
endmodule

module narc_sound #(
  parameter int CLK_SYS_HZ = 48_000_000,
  parameter MASTER_ROM_HEX = "",
  parameter SLAVE_ROM_HEX = "",
  parameter bit EXTERNAL_SND_ROM = 1'b0,
  parameter logic [24:1] SND_WORD_BASE = 24'hC00000,
  // SDRAM words are normally stored little-endian by the MiSTer loader:
  // byte address +0 is word[7:0]. Keep the board-level lane choice explicit
  // so a module populated with the opposite byte lane can be corrected at the
  // integration boundary without rewriting the CPU address decoder.
  parameter bit SND_ROM_SWAP_BYTES = 1'b0,
  // JT51 exposes YM2151 busy as an active-high status bit on D7. Keep the
  // polarity selectable at the integration boundary for alternate YM cores.
  parameter bit YM_STATUS_BUSY_ACTIVE_HIGH = 1'b1
) (
  input  wire clk,
  input  wire rst,
  // [7:0] command byte, [8] /NMI, [9] /IRQ, [10] /RESET (all active low).
  input  wire [10:0] cmd,
  input  wire cmd_stb,
  input  wire snd_rst,

  output logic [7:0] talkback,
  output logic [1:0] audio_sync,
  output wire signed [15:0] audio_l,
  output wire signed [15:0] audio_r,

  output logic snd_rom_req,
  output logic [24:1] snd_rom_addr,
  input  wire [15:0] snd_rom_dout,
  input  wire snd_rom_ack,

  // ---- fixed upper-window ($C000-$FFFF) M10K mirror fill port --------------
  // Only used with EXTERNAL_SND_ROM: the top level replays the sound-region
  // ioctl download bytes that land in each CPU's un-banked upper 16 KiB code
  // window so vectors and handler code are served with zero wait states. The
  // 64-entry SDRAM cache then only ever holds banked sample/music data, which
  // removes the code-vs-vector index thrash that froze the shared E clock
  // during CVSD speech (the "slow, deep player voices" defect).
  input  wire        uwin_wr,
  input  wire        uwin_sel,           // 0 = master image, 1 = slave image
  input  wire [12:0] uwin_addr,
  input  wire [7:0]  uwin_data,

  output wire dbg_master_run,
  output wire dbg_slave_run,
  output wire dbg_stall,

  // ---- sound-board diagnostic taps (observability only, no behaviour) ------
  // For the on-screen overlay (rtl/diag/narc_diag_overlay.sv). Added to chase a
  // hardware fault a simulation replay has not been able to trigger: a big
  // in-game explosion starts a loud tone that then plays over everything until
  // reset. These are pure outputs; if nothing connects them synthesis removes
  // the whole block, so a production build is unaffected.
  //
  // Rates are counted over a free-running 2^19-clock window (~437k clocks per
  // frame at clk_sys, so roughly one frame) and latched at window close, giving
  // a stable on-screen value instead of an unreadable flicker.
  output wire [31:0] dbg_snd_rate,    // {cvsd writes, dac2 writes} this window
  output wire [31:0] dbg_snd_state,   // {dac2 value, slave_bank, cmd, flags}
  output wire [31:0] dbg_snd_addr,    // {slave addr, master addr}
  output wire [7:0]  dbg_snd_act,     // activity bits for the LED lanes
  output wire [3:0]  dbg_ym_flags     // sticky: YM write, YM audio, mix audio, IRQ
);
  // Host-driven board reset. SOUND bit 10 is the active-low RESET line
  // (`SYS/SYS.INC:41`); `SYS/GSPSND.ASM:SNDRES` asserts it with a 0xFB00 write,
  // spins ~6000 loop iterations, then releases it with 0xFFFF. It is therefore a
  // LEVEL held across many CPU cycles, not a pulse, and must latch here. A hard
  // reset clears it so the board can never power up stuck in software reset.
  logic soft_rst = 1'b0;
  logic sound_ram_scrub_done = 1'b0;
  logic sound_watchdog_trip = 1'b0;
  logic [23:0] sound_watchdog_count = '0;
  logic [23:0] sound_rom_watchdog_count = '0;
  always_ff @(posedge clk) begin
    if (rst || snd_rst) soft_rst <= 1'b0;
    else if (cmd_stb)   soft_rst <= ~cmd[10];
  end
  // Every board-level reset consumer below uses this, so a host reset behaves
  // exactly like a power-on reset for the two 6809s, their banks, the ROM
  // caches, the command latches, the YM2151, both DACs and the CVSD decoder.
  wire hard_board_rst = rst || snd_rst;
  // A wedged 6809 or lost sound-ROM acknowledge is recoverable without
  // requiring the main CPU to leave the game. The normal watchdog is
  // deliberately conservative (a full 24-bit clk_sys-window) and only trips
  // when no E-cycle is visible. ROM stalls use a separate counter: a genuine
  // SDRAM miss is allowed to complete, but a lost acknowledge must not freeze
  // both 6809 clocks forever because the E/Q generator is wait-stated there.
  wire board_rst = rst || snd_rst || soft_rst || sound_watchdog_trip;
  // The RAM scrub is part of sound-board reset. A short external reset must
  // not release the CPUs before the scrub has finished; once the last address
  // is cleared this domain follows the normal hard/soft reset signal.
  wire sound_board_rst = board_rst || !sound_ram_scrub_done;

  // 6809 E/Q oscillator. Freezing both CPUs during either cache miss preserves
  // their shared-board clock relationship and simplifies the one-port ROM path.
  wire rom_stall;
  // E/Q are external clocks on the physical MC6809E boards. Reset entry seeds
  // a known phase, then the clock continues so the 6809 reset sampler sees E
  // edges; after reset release it resumes the exact fractional 8 MHz sequence,
  // while only an SDRAM ROM miss may wait-state the CPUs.
  wire cpu_e, cpu_q, eq_cycle_boundary;
  narc_sound_eq_clock #(.CLK_SYS_HZ(CLK_SYS_HZ)) u_eq_clock (
    .clk(clk), .reset(sound_board_rst),
    // A reset-held 6809 must still receive E/Q boundaries even if its first
    // vector access has already raised the external-ROM stall. Once the
    // release pipeline is complete, a genuine ROM miss may stretch the bus.
    .advance(sound_board_rst || !rom_stall ||
             (sound_startup_wait != 12'hfff) || !cpu_reset_release[1]),
    .cpu_e(cpu_e), .cpu_q(cpu_q), .cycle_boundary(eq_cycle_boundary)
  );
  logic cpu_e_d;
  always_ff @(posedge clk) begin
    if (sound_board_rst)
      cpu_e_d <= 1'b0;
    else
      cpu_e_d <= cpu_e;
  end
  wire e_fall = cpu_e_d && !cpu_e;

  always_ff @(posedge clk) begin
    if (hard_board_rst || soft_rst || sound_watchdog_trip ||
        !sound_ram_scrub_done) begin
      sound_watchdog_count <= '0;
      sound_rom_watchdog_count <= '0;
      sound_watchdog_trip <= 1'b0;
    end else begin
      if (e_fall || rom_stall) begin
        sound_watchdog_count <= '0;
      end else if (sound_watchdog_count != 24'hffffff) begin
        sound_watchdog_count <= sound_watchdog_count + 24'd1;
        if (sound_watchdog_count == 24'hfffffe)
          sound_watchdog_trip <= 1'b1;
      end

      if (!rom_stall) begin
        sound_rom_watchdog_count <= '0;
      end else if (sound_rom_watchdog_count != 24'hffffff) begin
        sound_rom_watchdog_count <= sound_rom_watchdog_count + 24'd1;
        if (sound_rom_watchdog_count == 24'hfffffe)
          sound_watchdog_trip <= 1'b1;
      end
    end
  end

  wire [15:0] ma, sa;
  wire [7:0] mdo, sdo;
  wire mrnw, srnw;
  logic [7:0] mdi, sdi;
  logic master_irq, master_nmi, slave_firq;
  wire ym_irq_n;
  logic ym_firq_n_meta, ym_firq_n_q;
  logic ym_recover;
  always_ff @(posedge clk) begin
    if (sound_board_rst || ym_recover) begin
      ym_firq_n_meta <= 1'b1;
      ym_firq_n_q <= 1'b1;
    end else begin
      // Keep the JT51 timer output from becoming a narrow asynchronous FIRQ
      // pulse at the 6809 input. The second stage also gives the CPU a stable
      // level for its edge-sampled FIRQ entry sequence.
      ym_firq_n_meta <= ym_irq_n;
      ym_firq_n_q <= ym_firq_n_meta;
    end
  end
  wire master_ym_firq_n = ym_recover ? 1'b1 : ym_firq_n_q;
  // Reset may originate outside clk_sys. Assert it on the next clk_sys edge,
  // keep the board quiet through a short post-reset settling window, and only
  // release the 6809s after two successive E-cycle boundaries. The settling
  // window lets the external sound-ROM port and its cache arbiter start from a
  // quiescent state before the first opcode fetch; the two E boundaries give
  // the core's negedge-E reset sampler a deterministic, generously timed
  // release instead of an unconstrained asynchronous edge.
  logic [11:0] sound_startup_wait = '0;
  logic [1:0] cpu_reset_release = '0;
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      sound_startup_wait <= '0;
      cpu_reset_release <= '0;
    end else begin
      if (sound_startup_wait != 12'hfff)
        sound_startup_wait <= sound_startup_wait + 12'd1;
      if (eq_cycle_boundary && (sound_startup_wait == 12'hfff))
        cpu_reset_release <= {cpu_reset_release[0], 1'b1};
    end
  end
  // The 6809 core samples nRESET on `negedge E` (ext_snd/mc6809/mc6809i.v:586).
  // Driving that sampler from a raw combinational cone is a chip-crossing
  // timing path: !sound_board_rst reaches all the way back to the HPS
  // sysmem|init_reset_n register through pure logic, so TimeQuest analysed
  // init_reset_n -> rnRESET as a single combinational hop into the E domain.
  // It only ever met timing by placement luck, and broke the moment the work
  // RAMs moved into M10K and pulled the sound board across the die. Register
  // the release locally in clk_sys -- the domain E is itself derived from --
  // so the launch point sits next to the CPUs instead of beside the HPS.
  // Only the GLOBAL reset term is re-registered here, not the whole
  // expression: the release edge is set by cpu_reset_release[1] (the last
  // term to go true, and already eq_cycle_boundary-aligned), while
  // sound_board_rst deasserts far earlier when the scrub completes. Delaying
  // just this term therefore leaves the release phase bit-identical -- which
  // sim/snd/tb_narc_sound_reset_phase.sv checks, and which registering the
  // combined signal demonstrably broke.
  logic sound_board_rst_cpu_q = 1'b1;
  always_ff @(posedge clk) sound_board_rst_cpu_q <= sound_board_rst;
  wire cpu_nreset = !sound_board_rst_cpu_q &&
                    (sound_startup_wait == 12'hfff) &&
                    cpu_reset_release[1] && sound_ram_scrub_done;

  mc6809e u_master (
    .D(mdi), .DOut(mdo), .ADDR(ma), .RnW(mrnw), .E(cpu_e), .Q(cpu_q),
    .BS(), .BA(), .nIRQ(~master_irq), .nFIRQ(master_ym_firq_n), .nNMI(~master_nmi),
    .AVMA(), .BUSY(), .LIC(), .nHALT(1'b1), .nRESET(cpu_nreset)
  );
  mc6809e u_slave (
    .D(sdi), .DOut(sdo), .ADDR(sa), .RnW(srnw), .E(cpu_e), .Q(cpu_q),
    .BS(), .BA(), .nIRQ(1'b1), .nFIRQ(~slave_firq), .nNMI(1'b1),
    .AVMA(), .BUSY(), .LIC(), .nHALT(1'b1), .nRESET(cpu_nreset)
  );

  logic [15:0] ma_r, sa_r;
  logic [7:0] mdo_r, sdo_r;
  logic mrnw_r, srnw_r;
  always_ff @(posedge clk) begin
    ma_r <= ma; mdo_r <= mdo; mrnw_r <= mrnw;
    sa_r <= sa; sdo_r <= sdo; srnw_r <= srnw;
  end
  wire mwr = e_fall && !mrnw_r;
  wire swr = e_fall && !srnw_r;

  // Address group 0x2000..0x3fff is decoded in mirrored 0x400-byte blocks.
  wire [5:0] mgrp = ma_r[15:10];
  wire [5:0] sgrp = sa_r[15:10];

  // The command latches are acknowledge-cleared, write-set interrupt
  // latches.  A new request and the previous request's acknowledge may land
  // on the same shared E edge; the request must win or the byte is stranded in
  // the latch with no interrupt to make the CPU read it.
  wire master_irq_ack = e_fall && mrnw_r && mgrp == 6'h0d;
  wire slave_firq_ack  = e_fall && srnw_r && sgrp == 6'h0d;
  wire slave_cmd_write = mwr && mgrp == 6'h0b;

  wire mram_sel = (ma[15:13] == 3'b000);
  wire sram_sel = (sa[15:13] == 3'b000);
  // NARC's master board overlays 43 bytes of writable hidden RAM on the
  // otherwise fixed-ROM window.  The sound program copies protection code here.
  wire mhidden_sel = (ma >= 16'hcdff) && (ma <= 16'hce29);
  wire mhidden_sel_r = (ma_r >= 16'hcdff) && (ma_r <= 16'hce29);
  // The overlay is 0xcdff..0xce29, so its 43-byte index is the low-byte
  // value plus one, with 0xcdff wrapping to index zero. Keep the index at
  // the RAM's actual width instead of relying on a truncated 16-bit offset.
  wire [5:0] mhidden_index = (ma[7:0] == 8'hff)
                           ? 6'd0 : ma[5:0] + 6'd1;
  wire [5:0] mhidden_index_r = (ma_r[7:0] == 8'hff)
                             ? 6'd0 : ma_r[5:0] + 6'd1;
  wire mrom_sel = (ma[15:14] != 2'b00) && !mhidden_sel;
  wire srom_sel = (sa[15:14] != 2'b00);

  // Two independent 8 KiB work RAMs.  A full-chip fit showed that putting both
  // in MLABs consumed 5120 memory ALMs and pushed final placement to 94%.
  // Putting both in M10Ks reduced ALMs sharply but made Fast Fit unable to
  // place the two new eight-block clusters around the 416-block framebuffer.
  // Split the pair: master in native blocks, slave in MLAB. The master is two
  // address-equivalent 4 KiB banks rather than one rigid eight-block cascade;
  // this gives Fast Fit two smaller four-M10K clusters to place around the
  // 416-block framebuffer without changing capacity or read latency.
  (* ramstyle="M10K, no_rw_check" *) logic [7:0] master_ram_lo [0:4095];
  (* ramstyle="M10K, no_rw_check" *) logic [7:0] master_ram_hi [0:4095];
  // Slave work RAM, split into two address-equivalent 4 KiB M10K banks for the
  // same reason the master pair is split (see above): an 8 KiB MLAB costs
  // 2,560 memory ALMs / 256 Memory LABs -- 44% of every Memory LAB on the
  // device -- because an MLAB row is 32x20 and 12 of those 20 bits are thrown
  // away at byte width. Two 4-block M10K clusters also give Fast Fit an easier
  // placement than one rigid 8-block cascade around the 416-block framebuffer.
  (* ramstyle="M10K, no_rw_check" *) logic [7:0] slave_ram_lo [0:4095];
  (* ramstyle="M10K, no_rw_check" *) logic [7:0] slave_ram_hi [0:4095];
  // This 43-byte protection overlay is smaller than a useful MLAB mode. Keep
  // it in logic so Quartus does not pad the inferred RAM to 64 words and emit
  // a depth-mismatched initialization file.
  (* ramstyle="logic" *) logic [7:0] master_hidden_ram [0:42];
  logic [7:0] master_ram_lo_q, master_ram_hi_q;
  logic [7:0] master_ram_q, slave_ram_q, master_hidden_q;
  logic [7:0] slave_ram_lo_q, slave_ram_hi_q;
  logic       slave_ram_bank_q, slave_ram_bypass_q, slave_ram_rst_q;
  logic [7:0] slave_ram_bypass_dq;
  logic master_ram_bank_q;
  // Write-first turnaround and reset-time zeroing are applied to the master
  // RAM's REGISTERED OUTPUT rather than inside the array access itself -- see
  // the block-RAM inference note above the two bank blocks below.
  logic       master_ram_bypass_q;
  logic [7:0] master_ram_bypass_dq;
  logic       master_ram_rst_q;
  logic [12:0] sound_ram_scrub_addr = '0;
  logic sound_board_restart_d = 1'b0;
  // MAME's install_hidden_ram() value-initializes this overlay. Keep FPGA and
  // simulation power-up behavior deterministic without adding a reset write
  // port that would prevent MLAB inference.
  initial begin : init_master_hidden_ram
    for (int hidden_i = 0; hidden_i < 43; hidden_i++)
      master_hidden_ram[hidden_i] = 8'h00;
  end
  // --- Master work RAM: two address-equivalent 4 KiB M10K banks -------------
  // Each bank lives in its OWN always_ff below containing nothing but one
  // write port and one UNCONDITIONAL registered read -- the exact template
  // Quartus needs to infer M10K. The previous form performed the array read
  // underneath a write-enable/address-compare condition (the write-first
  // turnaround) and reset the read register inside the same branch that wrote
  // the array; Quartus classified that as "asynchronous read logic", silently
  // ignored the ramstyle="M10K" attribute, and implemented all 65,536 bits as
  // registers plus two 4096:1 read muxes -- over half of this entire design's
  // register count. The turnaround and reset behaviour are preserved exactly,
  // just moved onto the registered output (master_ram_q, below).
  wire [11:0] mram_waddr    = sound_board_rst ? sound_ram_scrub_addr[11:0]
                                              : ma_r[11:0];
  wire  [7:0] mram_wdata    = sound_board_rst ? 8'h00 : mdo_r;
  wire        mram_scrub_we = sound_board_rst &&
                              (sound_ram_scrub_addr[12:0] < 13'd4096);
  wire        mram_cpu_we   = !sound_board_rst && mwr &&
                              (ma_r[15:13] == 3'b000);
  wire        mram_we_lo    = mram_scrub_we || (mram_cpu_we && !ma_r[12]);
  wire        mram_we_hi    = mram_scrub_we || (mram_cpu_we &&  ma_r[12]);

  always_ff @(posedge clk) begin
    if (mram_we_lo) master_ram_lo[mram_waddr] <= mram_wdata;
    master_ram_lo_q <= master_ram_lo[ma[11:0]];
  end
  always_ff @(posedge clk) begin
    if (mram_we_hi) master_ram_hi[mram_waddr] <= mram_wdata;
    master_ram_hi_q <= master_ram_hi[ma[11:0]];
  end

  // Slave work RAM banks -- identical template to the master pair above.
  wire [11:0] sram_waddr    = sound_board_rst ? sound_ram_scrub_addr[11:0]
                                              : sa_r[11:0];
  wire  [7:0] sram_wdata    = sound_board_rst ? 8'h00 : sdo_r;
  wire        sram_cpu_we   = !sound_board_rst && swr &&
                              (sa_r[15:13] == 3'b000);
  wire        sram_we_lo    = (sound_board_rst && !sound_ram_scrub_addr[12]) ||
                              (sram_cpu_we && !sa_r[12]);
  wire        sram_we_hi    = (sound_board_rst &&  sound_ram_scrub_addr[12]) ||
                              (sram_cpu_we &&  sa_r[12]);

  always_ff @(posedge clk) begin
    if (sram_we_lo) slave_ram_lo[sram_waddr] <= sram_wdata;
    slave_ram_lo_q <= slave_ram_lo[sa[11:0]];
  end
  always_ff @(posedge clk) begin
    if (sram_we_hi) slave_ram_hi[sram_waddr] <= sram_wdata;
    slave_ram_hi_q <= slave_ram_hi[sa[11:0]];
  end

  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      // Deterministically clear the sound work RAM while the CPUs are held in
      // reset. This removes stale protection/music state across a soft reset
      // and matches the clean RAM image expected by the boot diagnostics.
      // (Both work RAMs are scrubbed by the bank blocks above.)
      // A new board reset must invalidate the previous completion state until
      // the entire scrub pass reaches its terminal address. Without this,
      // releasing a short software reset while the old done bit was still set
      // could let the CPUs run after only a partial RAM clear.
      if (board_rst)
        sound_ram_scrub_done <= 1'b0;
      else
        sound_ram_scrub_done <= (sound_ram_scrub_addr == 13'd8191);
      // A reset that arrives while an earlier scrub is in progress must start
      // a fresh full pass, but a level-held reset must still let the scrubber
      // advance on subsequent clocks.
      if (board_rst && !sound_board_restart_d)
        sound_ram_scrub_addr <= '0;
      else if (sound_ram_scrub_addr < 13'd8191)
        sound_ram_scrub_addr <= sound_ram_scrub_addr + 13'd1;
      if (sound_ram_scrub_addr < 13'd43)
        master_hidden_ram[sound_ram_scrub_addr[5:0]] <= 8'h00;
      master_ram_bypass_q <= 1'b0;
      master_ram_rst_q    <= 1'b1;
      master_ram_bank_q <= 1'b0;
      slave_ram_bypass_q <= 1'b0;
      slave_ram_rst_q    <= 1'b1;
      slave_ram_bank_q   <= 1'b0;
      master_hidden_q <= 8'h00;
      sound_board_restart_d <= board_rst;
    end else begin
      sound_ram_scrub_addr <= '0;
      sound_board_restart_d <= board_rst;
      // (Work-RAM bank writes are driven by mram_we_*/sram_we_* above.)
      if (mwr && mhidden_sel_r)
        master_hidden_ram[mhidden_index_r] <= mdo_r;
      // Use write-first behavior for a same-address turnaround. The physical
      // SRAMs return the byte just written; leaving this to the inferred
      // MLAB/M10K read-during-write mode makes the 6809's protection and audio
      // work-RAM behavior device-family dependent.
      master_ram_bypass_q  <= mwr && mram_sel && (ma_r == ma);
      master_ram_bypass_dq <= mdo_r;
      master_ram_rst_q     <= 1'b0;
      master_ram_bank_q <= ma[12];
      slave_ram_bypass_q  <= swr && sram_sel && (sa_r == sa);
      slave_ram_bypass_dq <= sdo_r;
      slave_ram_rst_q     <= 1'b0;
      slave_ram_bank_q    <= sa[12];
      if (mhidden_sel) begin
        if (mwr && mhidden_sel_r && (ma_r == ma))
          master_hidden_q <= mdo_r;
        else
          master_hidden_q <= master_hidden_ram[mhidden_index];
      end
    end
    sound_board_restart_d <= board_rst;
  end
  // Reset zeroing and the write-first turnaround, applied to the registered
  // bank outputs so the array accesses themselves stay M10K-inferrable.
  always_comb master_ram_q = master_ram_rst_q    ? 8'h00
                           : master_ram_bypass_q ? master_ram_bypass_dq
                           : master_ram_bank_q   ? master_ram_hi_q
                                                 : master_ram_lo_q;
  always_comb slave_ram_q  = slave_ram_rst_q     ? 8'h00
                           : slave_ram_bypass_q  ? slave_ram_bypass_dq
                           : slave_ram_bank_q    ? slave_ram_hi_q
                                                 : slave_ram_lo_q;

`ifdef NARC_SRAM_EQUIV_CHECK
  // Simulation-only equivalence check: a shadow copy of the ORIGINAL single
  // flat slave_ram implementation, driven by the identical live signals, so
  // the real 6809 access stream proves the lo/hi M10K split is behaviourally
  // identical. Never compiled into hardware.
  logic [7:0] sram_ref [0:8191];
  logic [7:0] sram_ref_q;
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      sram_ref[sound_ram_scrub_addr] <= 8'h00;
      sram_ref_q <= 8'h00;
    end else begin
      if (swr && sa_r[15:13] == 3'b000) sram_ref[sa_r[12:0]] <= sdo_r;
      if (swr && sram_sel && (sa_r == sa)) sram_ref_q <= sdo_r;
      else                                 sram_ref_q <= sram_ref[sa[12:0]];
    end
  end
  int sram_cmp_count = 0;
  always @(negedge clk) begin
    if (slave_ram_q !== sram_ref_q) begin
      $display("SRAM_MISMATCH t=%0t got=%02h exp=%02h sa=%04h sa_r=%04h rst=%b",
               $time, slave_ram_q, sram_ref_q, sa, sa_r, sound_board_rst);
      $fatal(1, "slave_ram split diverged from reference");
    end else sram_cmp_count++;
  end
  final $display("SRAM_EQUIV_OK compares=%0d", sram_cmp_count);
`endif

  logic [3:0] master_bank, slave_bank;
  wire master_bank_write = mwr && mgrp == 6'h0e;
  wire slave_bank_write  = swr && sgrp == 6'h0e;
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      master_bank <= '0;
      slave_bank <= '0;
    end else begin
      if (master_bank_write) master_bank <= mdo_r[3:0];
      if (slave_bank_write)  slave_bank <= sdo_r[3:0];
    end
  end

  // Canonical MRA/SDRAM sound image layout:
  //   master image: C00000 + 0x000000 words
  //   slave image : C00000 + 0x048000 words
  // Both images are 0x90000 bytes; the CPU-visible upper window begins at
  // byte 0x8c000 in either image after the Williams bank decoder expansion.
  localparam logic [19:0] SOUND_BANKED_BASE = 20'h10000;
  localparam logic [19:0] SOUND_UPPER_BASE  = 20'h8c000;
  localparam logic [24:1] SOUND_SLAVE_WORD_OFFSET = 24'h048000;

  function automatic [19:0] rom_byte_addr(
    input logic [15:0] cpu_addr,
    input logic [3:0] bank
  );
    logic [19:0] bank_offset;
    begin
      bank_offset = {4'd0, bank[0], 15'd0}
                  + {3'd0, bank[3], 16'd0}
                  + {1'd0, bank[2:1], 17'd0};
      if (cpu_addr[15:14] == 2'b11)
        // MAME masterupper/slaveupper base: 0x10000+0x4000+0x8000+
        // 0x10000+3*0x20000 = 0x8c000.
        rom_byte_addr = SOUND_UPPER_BASE + {6'd0, cpu_addr[13:0]};
      else
        rom_byte_addr = SOUND_BANKED_BASE + bank_offset
                      + ({4'd0, cpu_addr} - 20'h04000);
    end
  endfunction

  wire [19:0] master_rom_byte = rom_byte_addr(ma, master_bank);
  wire [19:0] slave_rom_byte = rom_byte_addr(sa, slave_bank);
  logic [7:0] master_rom_q, slave_rom_q;
  logic master_rom_stall, slave_rom_stall;

  generate if (!EXTERNAL_SND_ROM) begin : g_int_rom
    (* ramstyle="M10K" *) logic [7:0] master_rom [0:589823];
    (* ramstyle="M10K" *) logic [7:0] slave_rom [0:589823];
    initial if (MASTER_ROM_HEX != "") $readmemh(MASTER_ROM_HEX, master_rom);
    initial if (SLAVE_ROM_HEX != "") $readmemh(SLAVE_ROM_HEX, slave_rom);
    always_ff @(posedge clk) begin
      master_rom_q <= master_rom[master_rom_byte];
      slave_rom_q <= slave_rom[slave_rom_byte];
      snd_rom_req <= 1'b0;
      snd_rom_addr <= '0;
    end
    always_comb begin
      master_rom_stall = 1'b0;
      slave_rom_stall = 1'b0;
    end
  end else begin : g_ext_rom
    wire [18:0] mwant = master_rom_byte[19:1];
    wire [18:0] swant = slave_rom_byte[19:1];
    wire [5:0] mci = mwant[5:0];
    wire [5:0] sci = swant[5:0];
    // Tiny direct-mapped caches — keep them out of M10K (framebuffer budget).
    (* ramstyle = "MLAB, no_rw_check" *) logic [15:0] mcdata [0:63];
    (* ramstyle = "MLAB, no_rw_check" *) logic [15:0] scdata [0:63];
    (* ramstyle = "MLAB, no_rw_check" *) logic [12:0] mctag  [0:63];
    (* ramstyle = "MLAB, no_rw_check" *) logic [12:0] sctag  [0:63];
    logic [63:0] mcvalid, scvalid;
    wire mchit = mcvalid[mci] && mctag[mci] == mwant[18:6];
    wire schit = scvalid[sci] && sctag[sci] == swant[18:6];
    wire [15:0] mword = mcdata[mci];
    wire [15:0] sword = scdata[sci];
    logic fetching, fetch_slave;
    logic [5:0] fill_ci;
    logic [12:0] fill_tag;

    // Fixed upper-window mirrors. $C000-$FFFF is un-banked ROM for both CPUs
    // (rom_byte_addr maps it to a constant base), and it holds the vectors AND
    // every interrupt handler. During CVSD speech the vector fetch and handler
    // code alias to one 64-entry cache index, so each per-sample interrupt
    // missed twice and froze the shared E clock — audibly slowing all speech.
    // Serving the whole window from M10K removes those misses entirely; only
    // banked data ($4000-$BFFF) still goes through the cache. One write port
    // plus one unconditional registered read per array (the M10K-inference
    // template this project requires — see CLAUDE.md "uninferred due to").
    // Mirror the LOWER half of the fixed code window, $C000-$DFFF. Measured
    // with tb_snd_lat (600 ms boot, LAT=2): mirroring only the vector page or
    // only $E000-$FFFF leaves MASTER conflict misses at ~147k and E at 0.964x
    // -- the hot code (reset path C060+, IRQ/NMI handlers C345/C34C, the
    // slave's CVSD handler C5F1-C8F2) is all in the lower half. Mirroring
    // $C000-$DFFF alone gives MASTER conflict=0 and E=0.994x, identical to a
    // full 16 KiB mirror at half the block-RAM cost. Vector fetches from
    // $FFFx still go through the cache, which is harmless once the handler
    // they point at no longer shares it. MUST be M10K: byte-wide MLAB at this
    // depth costs ~256 memory LABs per array and LABs are the binding
    // resource (98%).
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] mvec [0:8191];
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] svec [0:8191];
    logic [7:0] mvec_q, svec_q;
    always_ff @(posedge clk) begin
      if (uwin_wr && !uwin_sel) mvec[uwin_addr] <= uwin_data;
      mvec_q <= mvec[ma[12:0]];
    end
    always_ff @(posedge clk) begin
      if (uwin_wr && uwin_sel) svec[uwin_addr] <= uwin_data;
      svec_q <= svec[sa[12:0]];
    end
    // ma/sa are stable for the whole ~12-clk E cycle, so the one-clk
    // registered-read latency settles long before the CPU samples at e_fall
    // (the internal-ROM build uses the identical timing).
    wire m_upper = (ma[15:13] == 3'b110);
    wire s_upper = (sa[15:13] == 3'b110);

`ifdef VERILATOR
    // Simulation preload so existing external-ROM testbenches (which model
    // only the SDRAM side) keep booting without driving the fill port. The
    // upper window starts at byte 0x8C000 of either CPU image.
    initial begin
      logic [7:0] uwin_tmp [0:589823];
      if (MASTER_ROM_HEX != "") begin
        $readmemh(MASTER_ROM_HEX, uwin_tmp);
        for (int i = 0; i < 8192; i++) mvec[i] = uwin_tmp[20'h8c000 + i];
      end
      if (SLAVE_ROM_HEX != "") begin
        $readmemh(SLAVE_ROM_HEX, uwin_tmp);
        for (int i = 0; i < 8192; i++) svec[i] = uwin_tmp[20'h8c000 + i];
      end
    end
`endif

    always_comb begin
      master_rom_q = m_upper ? mvec_q
                             : master_rom_byte[0] ? mword[15:8] : mword[7:0];
      slave_rom_q = s_upper ? svec_q
                            : slave_rom_byte[0] ? sword[15:8] : sword[7:0];
      master_rom_stall = mrom_sel && !m_upper && !mchit;
      slave_rom_stall = srom_sel && !s_upper && !schit;
    end

    always_ff @(posedge clk) begin
      if (sound_board_rst) begin
        mcvalid <= '0;
        scvalid <= '0;
        fetching <= 1'b0;
        snd_rom_req <= 1'b0;
        snd_rom_addr <= '0;
      end else if (fetching) begin
        // Hold both request and address until the SDRAM client acknowledges.
        // A one-clock pulse can be missed at the clk_sys/clk_ram boundary,
        // leaving the 6809s parked on their first early-game ROM fetch.
        snd_rom_req <= 1'b1;
        if (snd_rom_ack) begin
          if (fetch_slave) begin
            scdata[fill_ci] <= SND_ROM_SWAP_BYTES
                             ? {snd_rom_dout[7:0], snd_rom_dout[15:8]}
                             : snd_rom_dout;
            sctag[fill_ci] <= fill_tag;
            scvalid[fill_ci] <= 1'b1;
          end else begin
            mcdata[fill_ci] <= SND_ROM_SWAP_BYTES
                             ? {snd_rom_dout[7:0], snd_rom_dout[15:8]}
                             : snd_rom_dout;
            mctag[fill_ci] <= fill_tag;
            mcvalid[fill_ci] <= 1'b1;
          end
          snd_rom_req <= 1'b0;
          fetching <= 1'b0;
        end
      end else if (!snd_rom_ack) begin
        // A bank write changes the CPU-visible ROM address space. The full
        // address is already part of each tag, but invalidating both sides at
        // the decoder boundary also prevents an old line from being reused
        // during the bank-register write/read turnaround.
        if (master_bank_write) mcvalid <= '0;
        if (slave_bank_write)  scvalid <= '0;
        if (master_rom_stall) begin
          snd_rom_req <= 1'b1;
          snd_rom_addr <= SND_WORD_BASE + {5'd0, mwant};
          fetch_slave <= 1'b0;
          fill_ci <= mci;
          fill_tag <= mwant[18:6];
          fetching <= 1'b1;
        end else if (slave_rom_stall) begin
          snd_rom_req <= 1'b1;
          // Each CPU image is 0x90000 bytes = 0x48000 SDRAM words.
          snd_rom_addr <= SND_WORD_BASE + SOUND_SLAVE_WORD_OFFSET + {5'd0, swant};
          fetch_slave <= 1'b1;
          fill_ci <= sci;
          fill_tag <= swant[18:6];
          fetching <= 1'b1;
        end else begin
          snd_rom_req <= 1'b0;
        end
      end
    end
  end endgenerate
  assign rom_stall = master_rom_stall || slave_rom_stall;
  assign dbg_stall = rom_stall;

  // Host and inter-CPU command latches with MAME's interrupt semantics.
  logic [7:0] master_latch, slave_latch;
  // Host writes can arrive back-to-back while the master 6809 is still inside
  // the previous command handler. Keep the command stream lossless at the
  // board boundary: one active IRQ command is held until its acknowledge,
  // while later commands wait in this bounded ordered FIFO. The idle fast path
  // still dispatches the first command in the same cycle as before.
  // Keep a full frame's worth of pending commands before the unavoidable
  // newest-command policy has to discard anything.
  localparam int HOST_FIFO_DEPTH = 64;
  logic [10:0] host_fifo [0:HOST_FIFO_DEPTH-1];
  logic [5:0] host_fifo_wr = '0, host_fifo_rd = '0;
  logic [6:0] host_fifo_count = '0;
  logic       host_active = 1'b0;
  logic       host_fifo_overflow = 1'b0;
  // The physical command latch holds /NMI active until the host writes the
  // all-ones release command.  MC6809 NMI is edge-sensitive, but keeping the
  // line asserted until release guarantees that the edge is visible even when
  // a command arrives between the core's interrupt-sampling phases. Queued
  // writes still retire in order and each write applies its own MAME-compatible
  // set/clear level, so a later release cannot be lost behind a queued command.
  logic       soft_reset_pending = 1'b0;
  logic       nmi_rearm_pending = 1'b0;
  // Guarantee that even a back-to-back assert/release pair presents NMI low
  // through at least one complete sound-board quadrature boundary.
  logic       nmi_hold_pending = 1'b0;
  logic       nmi_release_pending = 1'b0;
  // The 6809 cannot latch an NMI edge while held in cpu_nreset. sound_board_rst
  // (which gates host_dispatch) clears well before cpu_nreset actually releases
  // (the RAM/ROM scrub tail adds tens of ms beyond it), so a suppress command
  // arriving in that gap must not pulse-and-drop the edge the CPU never saw.
  logic       nmi_assert_deferred = 1'b0;
  // The 6809 also masks NMI internally from reset until its first LDS
  // executes (a documented erratum): an edge coincident with cpu_nreset's
  // release is coincident with the reset-vector fetch itself and is still
  // lost. Give the CPU a fixed settle window (far beyond this ROM's ~15-cycle
  // reset-to-LDS distance) before letting the deferred edge through.
  localparam logic [11:0] NMI_SETTLE_CYCLES = 12'd2047;
  logic [11:0] nmi_settle_count = '0;
  wire         nmi_cpu_settled = (nmi_settle_count == NMI_SETTLE_CYCLES);
  // FFxx is the explicit host-side NMI release used after every sound/music
  // command. It is a delimiter, not another sound request: dispatch it ahead
  // of stale queued commands so an abort cannot be delayed behind a burst.
  // FDxx (music) is deliberately excluded because bit 9 is low there.
  wire host_release_urgent = cmd_stb && !sound_board_rst &&
                             (cmd[10:8] == 3'b111);
  wire host_direct = host_release_urgent ||
                     (cmd_stb && !sound_board_rst && cmd[10] &&
                      !host_active && (host_fifo_count == 0) &&
                      (!master_nmi || cmd[8]));
  wire host_dispatch = host_direct ||
                       (!sound_board_rst && !host_active &&
                        (host_fifo_count != 0));
  wire [10:0] host_dispatch_cmd = host_direct ? cmd : host_fifo[host_fifo_rd];
  wire host_fifo_push = cmd_stb && !hard_board_rst && cmd[10] &&
                        (!sound_ram_scrub_done || soft_rst || soft_reset_pending || master_nmi ||
                         host_active || (host_fifo_count != 0)) &&
                        !host_direct;
  wire host_fifo_pop = host_dispatch && !host_direct;
  // If the bounded queue ever fills, retain the newest command. In practice
  // this protects the latest FF release/abort from being discarded behind a
  // burst of older sound requests; normal operation remains an ordered FIFO.
  wire host_fifo_push_ok = host_fifo_push;
  wire host_fifo_drop_oldest = host_fifo_push_ok &&
                               (host_fifo_count == HOST_FIFO_DEPTH) &&
                               !host_fifo_pop;
  wire master_irq_set = host_dispatch && !host_dispatch_cmd[9];

  // The master-to-slave PIA command line has the same overwrite hazard as the
  // host latch. Preserve ordered FIRQ commands until the slave acknowledges
  // each byte instead of allowing a rapid abort/new-sample pair to replace the
  // byte currently being serviced.
  // Preserve a longer inter-CPU command train before applying newest-command
  // drop while the slave is inside a CVSD/DAC handler.
  localparam int SLAVE_FIFO_DEPTH = 32;
  logic [7:0] slave_fifo [0:SLAVE_FIFO_DEPTH-1];
  logic [4:0] slave_fifo_wr, slave_fifo_rd;
  logic [5:0] slave_fifo_count;
  logic       slave_active;
  logic       slave_fifo_overflow;
  wire slave_direct = slave_cmd_write && !sound_board_rst &&
                       !slave_active && (slave_fifo_count == 0);
  wire slave_dispatch = slave_direct ||
                        (!sound_board_rst && !slave_active && (slave_fifo_count != 0));
  wire [7:0] slave_dispatch_data = slave_direct ? mdo_r : slave_fifo[slave_fifo_rd];
  wire slave_fifo_push = slave_cmd_write && !sound_board_rst &&
                         (slave_active || (slave_fifo_count != 0));
  wire slave_fifo_pop = slave_dispatch && !slave_direct;
  wire slave_fifo_push_ok = slave_fifo_push;
  wire slave_fifo_drop_oldest = slave_fifo_push_ok &&
                                (slave_fifo_count == SLAVE_FIFO_DEPTH) &&
                                !slave_fifo_pop;
  wire slave_firq_set = slave_dispatch;

  always_ff @(posedge clk) begin
    if (hard_board_rst || sound_watchdog_trip) begin
      master_latch <= '0;
      slave_latch <= '0;
      master_irq <= 1'b0;
      master_nmi <= 1'b0;
      slave_firq <= 1'b0;
      host_fifo_wr <= '0;
      host_fifo_rd <= '0;
      host_fifo_count <= '0;
      host_active <= 1'b0;
      host_fifo_overflow <= 1'b0;
      soft_reset_pending <= 1'b0;
      nmi_rearm_pending <= 1'b0;
      nmi_hold_pending <= 1'b0;
      nmi_release_pending <= 1'b0;
      nmi_assert_deferred <= 1'b0;
      nmi_settle_count <= '0;
      slave_fifo_wr <= '0;
      slave_fifo_rd <= '0;
      slave_fifo_count <= '0;
      slave_active <= 1'b0;
      slave_fifo_overflow <= 1'b0;
    end else if (cmd_stb && !cmd[10]) begin
      // A host reset is immediate and discards stale queued commands. The
      // following reset-release write starts a fresh ordered command stream.
      master_latch <= '0;
      master_irq <= 1'b0;
      master_nmi <= 1'b0;
      slave_latch <= '0;
      slave_firq <= 1'b0;
      host_fifo_wr <= '0;
      host_fifo_rd <= '0;
      host_fifo_count <= '0;
      host_active <= 1'b0;
      host_fifo_overflow <= 1'b0;
      soft_reset_pending <= 1'b1;
      nmi_rearm_pending <= 1'b0;
      nmi_hold_pending <= 1'b0;
      nmi_release_pending <= 1'b0;
      nmi_assert_deferred <= 1'b0;
      nmi_settle_count <= '0;
      slave_fifo_wr <= '0;
      slave_fifo_rd <= '0;
      slave_fifo_count <= '0;
      slave_active <= 1'b0;
      slave_fifo_overflow <= 1'b0;
    end else if (soft_rst || soft_reset_pending) begin
      // The main CPU can issue the reset-release and first gameplay commands
      // while the sound CPUs are still held in software reset. Preserve those
      // writes in the host FIFO instead of dropping the entire early sequence.
      master_latch <= '0;
      master_irq <= 1'b0;
      master_nmi <= 1'b0;
      nmi_rearm_pending <= 1'b0;
      nmi_hold_pending <= 1'b0;
      nmi_release_pending <= 1'b0;
      nmi_assert_deferred <= 1'b0;
      nmi_settle_count <= '0;
      slave_latch <= '0;
      slave_firq <= 1'b0;
      host_active <= 1'b0;
      slave_active <= 1'b0;
      // The host FIFO intentionally survives until the reset-release write,
      // but the inter-CPU queue belongs to the reset 6809 pair. Retaining it
      // would replay a pre-reset CVSD/DAC command as soon as the slave runs.
      slave_fifo_wr <= '0;
      slave_fifo_rd <= '0;
      slave_fifo_count <= '0;
      slave_fifo_overflow <= 1'b0;
      if (host_fifo_push_ok) begin
        host_fifo[host_fifo_wr] <= cmd;
        host_fifo_wr <= host_fifo_wr + 6'd1;
        if (host_fifo_count < HOST_FIFO_DEPTH)
          host_fifo_count <= host_fifo_count + 7'd1;
        else
          host_fifo_rd <= host_fifo_rd + 6'd1;
        if (host_fifo_count == HOST_FIFO_DEPTH)
          host_fifo_overflow <= 1'b1;
      end else if (host_fifo_push) begin
        host_fifo_overflow <= 1'b1;
      end
      if (!soft_rst && sound_ram_scrub_done)
        soft_reset_pending <= 1'b0;
    end else if (!sound_ram_scrub_done) begin
      // Cold-start initialization when the external reset pulse was too short
      // to initialize the command-queue registers itself. The RAM scrub keeps
      // the board in this state until all work RAM has been cleared.
      master_latch <= '0;
      slave_latch <= '0;
      master_irq <= 1'b0;
      master_nmi <= 1'b0;
      nmi_rearm_pending <= 1'b0;
      nmi_hold_pending <= 1'b0;
      nmi_release_pending <= 1'b0;
      nmi_assert_deferred <= 1'b0;
      nmi_settle_count <= '0;
      slave_firq <= 1'b0;
      host_active <= 1'b0;
      // A reset shorter than one clk_sys edge can skip the hard-reset branch.
      // The RAM scrub is still guaranteed to run, so use this cold-start path
      // to reinitialize every host-queue control bit before any queued command
      // is allowed to dispatch. Leaving stale pointers/count here can replay
      // an old byte or treat an empty FIFO as full on the first boot sound.
      if (sound_ram_scrub_addr == 13'd0) begin
        host_fifo_wr <= '0;
        host_fifo_rd <= '0;
        host_fifo_count <= '0;
        host_fifo_overflow <= 1'b0;
        soft_reset_pending <= 1'b0;
        if (host_fifo_push_ok) begin
          // This is the first valid entry after cold initialization. Do not
          // use the stale pre-reset pointer/count on the RHS of the normal
          // FIFO update; explicitly seed slot zero and a one-entry queue.
          host_fifo[0] <= cmd;
          host_fifo_wr <= 6'd1;
          host_fifo_count <= 7'd1;
        end
      end else if (host_fifo_push_ok) begin
        host_fifo[host_fifo_wr] <= cmd;
        host_fifo_wr <= host_fifo_wr + 6'd1;
        if (host_fifo_count < HOST_FIFO_DEPTH)
          host_fifo_count <= host_fifo_count + 7'd1;
        else
          host_fifo_rd <= host_fifo_rd + 6'd1;
        if (host_fifo_count == HOST_FIFO_DEPTH)
          host_fifo_overflow <= 1'b1;
      end else if (host_fifo_push) begin
        host_fifo_overflow <= 1'b1;
      end
      slave_fifo_wr <= '0;
      slave_fifo_rd <= '0;
      slave_fifo_count <= '0;
      slave_active <= 1'b0;
      slave_fifo_overflow <= 1'b0;
    end else begin
      // SET DOMINANT -- a new request must survive an acknowledge on the same
      // shared E edge; otherwise its byte is stranded in the latch.
      //
      // Both interrupt latches are set by a WRITE and cleared by the target
      // CPU's READ of its command port. Both events are gated on the SAME
      // `e_fall` (mwr = e_fall && !mrnw_r, :198), and both 6809s share one E
      // clock, so they run a bus cycle on every E edge. A master write to the
      // slave port landing on the same edge as the slave's acknowledge read is
      // therefore ROUTINE, not a rare race.
      //
      // With the clear written last it won, and the new request was swallowed:
      // the *_latch still took the new command, so the data was sitting there,
      // but the target CPU was never interrupted and so never looked at it. It
      // simply carried on with whatever it was already doing.
      //
      // MEASURED ON HARDWARE 2026-07-29: in the sound-board digitizer test, the
      // "U30 - CVSD WAVEFORM" selection kept playing at full volume through
      // every subsequent selection and only stopped on leaving the menu (which
      // asserts board_rst). That is this defect -- the abort/next-sound command
      // reached slave_latch but its FIRQ was lost, so the slave never left its
      // playback loop. master_irq carries the identical defect, which drops
      // HOST sound commands during normal play.
      //
      // Set-dominant is also the safe direction: a lost request wedges the
      // board until reset, while a redundant interrupt merely makes the target
      // re-read a latch it has already serviced.
      if (host_release_urgent) begin
        // FFxx is the latch's explicit command delimiter. The physical
        // command register is single-entry/overwrite based, so requests that
        // were queued behind an asserted sound are stale once this release
        // arrives. Drop them together with the NMI release instead of replaying
        // an old tone on the following dispatch.
        host_fifo_wr <= '0;
        host_fifo_rd <= '0;
        host_fifo_count <= '0;
      end else begin
        if (host_fifo_push_ok) begin
          host_fifo[host_fifo_wr] <= cmd;
          host_fifo_wr <= host_fifo_wr + 6'd1;
        end
        if (host_fifo_push && (host_fifo_count == HOST_FIFO_DEPTH)) begin
          // On overflow retain the newest command and advance the read side.
          // The sticky flag is diagnostic-only and does not alter timing.
          host_fifo_overflow <= 1'b1;
        end
        if (host_fifo_pop || host_fifo_drop_oldest)
          host_fifo_rd <= host_fifo_rd + 6'd1;
        case ({host_fifo_push_ok, host_fifo_pop})
          2'b10: if (host_fifo_count < HOST_FIFO_DEPTH)
                    host_fifo_count <= host_fifo_count + 7'd1;
          2'b01: host_fifo_count <= host_fifo_count - 7'd1;
          default: host_fifo_count <= host_fifo_count;
        endcase
      end

      if (host_dispatch) begin
        master_latch <= host_dispatch_cmd[7:0];
        host_active <= ~host_dispatch_cmd[9];
        // NMI is edge-sensitive on the 6809, while the physical latch holds
        // the line active until the host's explicit release write. Normally
        // the game sends FE/FD followed by FF. If a malformed or accelerated
        // producer repeats an assert before its release, insert a complete
        // E/Q-low re-arm interval so the second command still has a visible
        // edge instead of being silently coalesced with the old assertion.
        if (host_dispatch_cmd[8]) begin
          if (nmi_hold_pending) begin
            // Defer the release until the asserted line has been sampled by
            // the 6809's falling-Q/falling-E interrupt pipeline.
            nmi_release_pending <= 1'b1;
          end else begin
            master_nmi <= 1'b0;
            nmi_release_pending <= 1'b0;
          end
          nmi_rearm_pending <= 1'b0;
        end else if (master_nmi) begin
          master_nmi <= 1'b0;
          nmi_rearm_pending <= 1'b1;
          nmi_hold_pending <= 1'b0;
          nmi_release_pending <= 1'b0;
        end else if (cpu_nreset) begin
          master_nmi <= 1'b1;
          nmi_rearm_pending <= 1'b0;
          nmi_hold_pending <= 1'b1;
          nmi_release_pending <= 1'b0;
        end else begin
          // The 6809 cannot latch this edge while held in cpu_nreset (which
          // lags sound_board_rst's release by the RAM/ROM scrub tail). Defer
          // the assert instead of pulsing and auto-releasing an edge the CPU
          // was never running to see.
          nmi_assert_deferred <= 1'b1;
        end
      end else if (host_active && master_irq_ack) begin
        host_active <= 1'b0;
      end else if (nmi_assert_deferred && nmi_cpu_settled) begin
        master_nmi <= 1'b1;
        nmi_hold_pending <= 1'b1;
        nmi_assert_deferred <= 1'b0;
      end else if (nmi_rearm_pending && eq_cycle_boundary) begin
        // Hold the line low through a full quadrature cycle before reasserting
        // it; a one-clk_sys pulse would be shorter than the 6809 interrupt
        // sampling aperture.
        master_nmi <= 1'b1;
        nmi_rearm_pending <= 1'b0;
      end
      if (nmi_release_pending && eq_cycle_boundary) begin
        master_nmi <= 1'b0;
        nmi_release_pending <= 1'b0;
        nmi_hold_pending <= 1'b0;
      end else if (nmi_hold_pending && eq_cycle_boundary) begin
        nmi_hold_pending <= 1'b0;
      end
      if (!cpu_nreset) begin
        nmi_settle_count <= '0;
      end else if (nmi_settle_count != NMI_SETTLE_CYCLES) begin
        nmi_settle_count <= nmi_settle_count + 12'd1;
      end
      if (slave_fifo_push_ok) begin
        slave_fifo[slave_fifo_wr] <= mdo_r;
        slave_fifo_wr <= slave_fifo_wr + 5'd1;
      end
      if (slave_fifo_push && (slave_fifo_count == SLAVE_FIFO_DEPTH)) begin
        slave_fifo_overflow <= 1'b1;
      end
      if (slave_fifo_pop || slave_fifo_drop_oldest)
        slave_fifo_rd <= slave_fifo_rd + 5'd1;
      case ({slave_fifo_push_ok, slave_fifo_pop})
        2'b10: if (slave_fifo_count < SLAVE_FIFO_DEPTH)
                  slave_fifo_count <= slave_fifo_count + 6'd1;
        2'b01: slave_fifo_count <= slave_fifo_count - 6'd1;
        default: slave_fifo_count <= slave_fifo_count;
      endcase
      if (slave_dispatch)
        slave_active <= 1'b1;
      else if (slave_active && slave_firq_ack)
        slave_active <= 1'b0;
      // Set-dominant priority is intentional: if ACK and SET coincide, keep
      // the interrupt asserted so the target CPU consumes the new latch byte.
      // This is the hardware race that otherwise drops normal gameplay
      // commands while widely-spaced diagnostic commands appear healthy.
      if (master_irq_set)       master_irq <= 1'b1;
      else if (master_irq_ack)  master_irq <= 1'b0;
      if (slave_firq_set)       slave_firq <= 1'b1;
      else if (slave_firq_ack)  slave_firq <= 1'b0;

      if (slave_dispatch)
        slave_latch <= slave_dispatch_data;
    end
  end

  // Talkback and the two 74LS123-style audio sync pulses (~81 ms).
  localparam int SYNC_CYCLES = (CLK_SYS_HZ / 1000) * 81;
  logic [31:0] master_sync_count, slave_sync_count;
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      talkback <= '0;
      audio_sync <= '0;
      master_sync_count <= '0;
      slave_sync_count <= '0;
    end else begin
      if (mwr && mgrp == 6'h0a) talkback <= mdo_r;
      if (mwr && mgrp == 6'h0f) begin
        audio_sync[0] <= 1'b1;
        master_sync_count <= SYNC_CYCLES;
      end else if (master_sync_count != 0) begin
        master_sync_count <= master_sync_count - 32'd1;
        if (master_sync_count == 1) audio_sync[0] <= 1'b0;
      end
      if (swr && sgrp == 6'h0f) begin
        audio_sync[1] <= 1'b1;
        slave_sync_count <= SYNC_CYCLES;
      end else if (slave_sync_count != 0) begin
        slave_sync_count <= slave_sync_count - 32'd1;
        if (slave_sync_count == 1) audio_sync[1] <= 1'b0;
      end
    end
  end

  // YM2151 @ 3.579545 MHz, driven only by the master CPU.
  localparam int YM_HZ = 3_579_545;
  localparam logic [31:0] YM_HZ_U = YM_HZ;
  localparam logic [31:0] CLK_SYS_HZ_U = CLK_SYS_HZ;
  logic [31:0] cen_acc;
  logic cen, cen_p1_tgl;
  wire cen_p1 = cen && cen_p1_tgl;
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      cen_acc <= '0; cen <= 1'b0; cen_p1_tgl <= 1'b0;
    end else begin
      if (cen_acc + YM_HZ_U >= CLK_SYS_HZ_U) begin
        cen_acc <= cen_acc + YM_HZ_U - CLK_SYS_HZ_U; cen <= 1'b1;
      end else begin
        cen_acc <= cen_acc + YM_HZ_U; cen <= 1'b0;
      end
      if (cen) cen_p1_tgl <= ~cen_p1_tgl;
    end
  end

  logic ym_req, ym_a0;
  logic [7:0] ym_din;
  wire [7:0] ym_dout;
  wire signed [15:0] ym_l, ym_r;
  // JT51 accepts writes on its half-rate P1 phase while the 6809 can issue a
  // register write on every E cycle. A voice setup is a burst of many writes;
  // A shallow queue only covers a short fraction of that burst and can silently
  // lose TL/KC/KEYON registers, producing missing or malformed music.
  // A YM voice/key-on setup is a dense register burst. Preserve the complete
  // burst even when the chip's 32-cycle busy interval overlaps later writes.
  localparam int YM_FIFO_DEPTH = 128;
  logic [8:0] ym_fifo [0:YM_FIFO_DEPTH-1];
  logic [6:0] ym_fifo_wr, ym_fifo_rd;
  logic [7:0] ym_fifo_count;
  logic       ym_active;
  logic       ym_fifo_overflow;
  wire ym_bus_write = mwr && mgrp == 6'h08;
  wire ym_direct = ym_bus_write && !ym_active && (ym_fifo_count == 0);
  wire ym_dispatch = ym_direct ||
                     (!ym_active && (ym_fifo_count != 0));
  wire [8:0] ym_dispatch_data = ym_direct ? {ma_r[0], mdo_r} : ym_fifo[ym_fifo_rd];
  wire ym_fifo_push = ym_bus_write && (ym_active || (ym_fifo_count != 0));
  wire ym_fifo_pop = ym_dispatch && !ym_direct;
  wire ym_fifo_push_ok = ym_fifo_push;
  wire ym_fifo_drop_oldest = ym_fifo_push_ok &&
                             (ym_fifo_count == YM_FIFO_DEPTH) &&
                             !ym_fifo_pop;
  // The JT51 register file accepts a bus write only on its half-rate phase.
  // Keep the request asserted until that exact phase and queue later writes.
  // JT51 exposes its internal busy state on D7 of the readback bus. A write
  // presented while busy is not retired by the chip; hold the request instead
  // of consuming it so a dense channel/key-on setup cannot lose a register.
  wire ym_busy = YM_STATUS_BUSY_ACTIVE_HIGH ? ym_dout[7] : ~ym_dout[7];
  // Do not retire the pending bus write on the same cycle that the local YM
  // recovery reset is asserted. The JT51 is held in reset then, so accepting
  // the handshake would discard the write instead of replaying it afterward.
  wire ym_write = ym_req && cen_p1 && !ym_busy && !ym_recover;
  logic [19:0] ym_busy_count;
  logic [19:0] ym_req_count;
  // A normal YM2151 busy interval is short. If the device remains busy for a
  // full conservative window, reset only the YM and leave the queued write in
  // place; this recovers a wedged audio peripheral without disturbing either
  // 6809 or the CVSD/DAC state.
  always_ff @(posedge clk) begin
    if (sound_board_rst || ym_recover) begin
      ym_busy_count <= '0;
      ym_req_count <= '0;
      ym_recover <= 1'b0;
    end else begin
      // Recover both a stuck busy flag and a request that never reaches the
      // chip's accepted half-rate phase. Either condition otherwise leaves a
      // queued register write pending indefinitely.
      if (ym_req) begin
        if (ym_req_count != 20'hfffff) begin
          ym_req_count <= ym_req_count + 20'd1;
          if (ym_req_count == 20'hffffe)
            ym_recover <= 1'b1;
        end
      end else begin
        ym_req_count <= '0;
      end
      if (ym_active && ym_busy) begin
        if (ym_busy_count != 20'hfffff) begin
          ym_busy_count <= ym_busy_count + 20'd1;
          if (ym_busy_count == 20'hffffe)
            ym_recover <= 1'b1;
        end
      end else begin
        ym_busy_count <= '0;
      end
    end
  end
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      ym_req <= 1'b0;
      ym_a0 <= 1'b0;
      ym_din <= 8'h00;
      ym_fifo_wr <= '0;
      ym_fifo_rd <= '0;
      ym_fifo_count <= '0;
      ym_active <= 1'b0;
      ym_fifo_overflow <= 1'b0;
    end else begin
      if (ym_fifo_push_ok) begin
        ym_fifo[ym_fifo_wr] <= {ma_r[0], mdo_r};
        ym_fifo_wr <= ym_fifo_wr + 7'd1;
      end
      if (ym_fifo_push && (ym_fifo_count == YM_FIFO_DEPTH)) begin
        ym_fifo_overflow <= 1'b1;
      end
      if (ym_fifo_pop || ym_fifo_drop_oldest)
        ym_fifo_rd <= ym_fifo_rd + 7'd1;
      case ({ym_fifo_push_ok, ym_fifo_pop})
        2'b10: if (ym_fifo_count < YM_FIFO_DEPTH)
                  ym_fifo_count <= ym_fifo_count + 8'd1;
        2'b01: ym_fifo_count <= ym_fifo_count - 8'd1;
        default: ym_fifo_count <= ym_fifo_count;
      endcase

      if (ym_dispatch) begin
        ym_req <= 1'b1;
        ym_a0 <= ym_dispatch_data[8];
        ym_din <= ym_dispatch_data[7:0];
        ym_active <= 1'b1;
      end else if (ym_active && ym_write) begin
        ym_req <= 1'b0;
        ym_active <= 1'b0;
      end
    end
  end
  jt51 u_ym (
    .rst(sound_board_rst || ym_recover), .clk(clk), .cen(cen), .cen_p1(cen_p1),
    .cs_n(~ym_write), .wr_n(~ym_write),
    .a0(ym_a0), .din(ym_din), .dout(ym_dout),
    .ct1(), .ct2(), .irq_n(ym_irq_n),
    .sample(), .left(), .right(), .xleft(ym_l), .xright(ym_r)
  );

  // Two AD7224-compatible unsigned DAC latches and the slave CVSD path. Each
  // receives a short ordered queue so a burst of sample writes cannot replace
  // the previous value before the audio device has consumed it.
  logic [7:0] dac1, dac2;
  // Preserve DAC sample steps during dense 6809 writes instead of replacing
  // them after a short queue fills.
  localparam int DAC_FIFO_DEPTH = 32;
  logic [7:0] dac1_fifo [0:DAC_FIFO_DEPTH-1];
  logic [7:0] dac2_fifo [0:DAC_FIFO_DEPTH-1];
  logic [4:0] dac1_fifo_wr, dac1_fifo_rd, dac2_fifo_wr, dac2_fifo_rd;
  logic [5:0] dac1_fifo_count, dac2_fifo_count;
  logic       dac1_fifo_overflow, dac2_fifo_overflow;
  wire dac1_write = mwr && mgrp == 6'h0c;
  wire dac2_write = swr && sgrp == 6'h0c;
  // The AD7224 latches are written by the 6809 bus, not by clk_sys.  Drain
  // one queued sample per sound-board E edge so a burst is preserved at the
  // same cadence as the physical bus instead of collapsing into a clk_sys-
  // rate update.
  wire dac1_pop = e_fall && (dac1_fifo_count != 0);
  wire dac2_pop = e_fall && (dac2_fifo_count != 0);
  wire dac1_direct = dac1_write && (dac1_fifo_count == 0);
  wire dac2_direct = dac2_write && (dac2_fifo_count == 0);
  wire dac1_push_ok = dac1_write && !dac1_direct;
  wire dac2_push_ok = dac2_write && !dac2_direct;
  wire dac1_drop_oldest = dac1_push_ok &&
                          (dac1_fifo_count == DAC_FIFO_DEPTH) && !dac1_pop;
  wire dac2_drop_oldest = dac2_push_ok &&
                          (dac2_fifo_count == DAC_FIFO_DEPTH) && !dac2_pop;
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      dac1 <= 8'h80; dac2 <= 8'h80;
      dac1_fifo_wr <= '0; dac1_fifo_rd <= '0; dac1_fifo_count <= '0;
      dac2_fifo_wr <= '0; dac2_fifo_rd <= '0; dac2_fifo_count <= '0;
      dac1_fifo_overflow <= 1'b0; dac2_fifo_overflow <= 1'b0;
    end else begin
      if (dac1_push_ok) begin
        dac1_fifo[dac1_fifo_wr] <= mdo_r;
        dac1_fifo_wr <= dac1_fifo_wr + 5'd1;
      end
      if (dac1_write && !dac1_direct && (dac1_fifo_count == DAC_FIFO_DEPTH))
        dac1_fifo_overflow <= 1'b1;
      if (dac2_push_ok) begin
        dac2_fifo[dac2_fifo_wr] <= sdo_r;
        dac2_fifo_wr <= dac2_fifo_wr + 5'd1;
      end
      if (dac2_write && !dac2_direct && (dac2_fifo_count == DAC_FIFO_DEPTH))
        dac2_fifo_overflow <= 1'b1;
      // An empty queue is the normal case. Retire that write directly on the
      // completing E edge so the FPGA does not add a whole sound-CPU cycle of
      // latency compared with the AD7224 bus latch.
      if (dac1_direct)
        dac1 <= mdo_r;
      else if (dac1_pop) begin
        dac1 <= dac1_fifo[dac1_fifo_rd];
        dac1_fifo_rd <= dac1_fifo_rd + 5'd1;
      end
      if (dac1_drop_oldest)
        dac1_fifo_rd <= dac1_fifo_rd + 5'd1;
      if (dac2_direct)
        dac2 <= sdo_r;
      else if (dac2_pop) begin
        dac2 <= dac2_fifo[dac2_fifo_rd];
        dac2_fifo_rd <= dac2_fifo_rd + 5'd1;
      end
      if (dac2_drop_oldest)
        dac2_fifo_rd <= dac2_fifo_rd + 5'd1;
      case ({dac1_push_ok, dac1_pop})
        2'b10: if (dac1_fifo_count < DAC_FIFO_DEPTH)
                  dac1_fifo_count <= dac1_fifo_count + 6'd1;
        2'b01: dac1_fifo_count <= dac1_fifo_count - 6'd1;
        default: dac1_fifo_count <= dac1_fifo_count;
      endcase
      case ({dac2_push_ok, dac2_pop})
        2'b10: if (dac2_fifo_count < DAC_FIFO_DEPTH)
                  dac2_fifo_count <= dac2_fifo_count + 6'd1;
        2'b01: dac2_fifo_count <= dac2_fifo_count - 6'd1;
        default: dac2_fifo_count <= dac2_fifo_count;
      endcase
    end
  end
  // CVSD writes are two strobes per bit and can arrive in long bursts while
  // the slave is wait-stated. Keep the transition order through a full burst.
  localparam int CVSD_FIFO_DEPTH = 64;
  (* ramstyle = "MLAB" *) logic [1:0] cvsd_fifo [0:CVSD_FIFO_DEPTH-1];
  logic [5:0] cvsd_fifo_wr, cvsd_fifo_rd;
  logic [6:0] cvsd_fifo_count;
  logic       cvsd_fifo_overflow;
  wire cvsd_write = swr && ((sgrp == 6'h08) || (sgrp == 6'h09));
  wire cvsd_direct = cvsd_write && (cvsd_fifo_count == 0);
  // HC55516 clock transitions are the slave CPU's two memory-mapped writes;
  // consume queued transitions at the shared 6809 E cadence.
  wire cvsd_pop = e_fall && (cvsd_fifo_count != 0);
  wire cvsd_push_ok = cvsd_write && !cvsd_direct;
  wire cvsd_drop_oldest = cvsd_push_ok &&
                          (cvsd_fifo_count == CVSD_FIFO_DEPTH) && !cvsd_pop;
  wire cvsd_direct_set = cvsd_direct && (sgrp == 6'h08);
  wire cvsd_direct_clear = cvsd_direct && (sgrp == 6'h09);
  wire cvsd_set = cvsd_direct_set ||
                  (cvsd_pop && cvsd_fifo[cvsd_fifo_rd][1]);
  wire cvsd_clear = cvsd_direct_clear ||
                    (cvsd_pop && !cvsd_fifo[cvsd_fifo_rd][1]);
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      cvsd_fifo_wr <= '0; cvsd_fifo_rd <= '0; cvsd_fifo_count <= '0;
      cvsd_fifo_overflow <= 1'b0;
    end else begin
      if (cvsd_push_ok) begin
        cvsd_fifo[cvsd_fifo_wr] <= {sgrp == 6'h08, sdo_r[0]};
        cvsd_fifo_wr <= cvsd_fifo_wr + 6'd1;
      end
      if (cvsd_write && !cvsd_direct && (cvsd_fifo_count == CVSD_FIFO_DEPTH))
        cvsd_fifo_overflow <= 1'b1;
      if (cvsd_pop || cvsd_drop_oldest)
        cvsd_fifo_rd <= cvsd_fifo_rd + 6'd1;
      case ({cvsd_push_ok, cvsd_pop})
        2'b10: if (cvsd_fifo_count < CVSD_FIFO_DEPTH)
                  cvsd_fifo_count <= cvsd_fifo_count + 7'd1;
        2'b01: cvsd_fifo_count <= cvsd_fifo_count - 7'd1;
        default: cvsd_fifo_count <= cvsd_fifo_count;
      endcase
    end
  end
  wire signed [15:0] cvsd_sample;
  hc55516 u_cvsd (
    .clk(clk), .rst(sound_board_rst),
    .cvsd_wr(cvsd_set || cvsd_clear), .clk_set(cvsd_set),
    .digit(cvsd_direct ? sdo_r[0] : cvsd_fifo[cvsd_fifo_rd][0]),
    .sample(cvsd_sample)
  );

  // Live read muxes. Sources have several clk_sys cycles to settle per E cycle.
  always_comb begin
    if (mram_sel) mdi = master_ram_q;
    else if (mhidden_sel) mdi = master_hidden_q;
    else if (mrom_sel) mdi = master_rom_q;
    else if (ma[15:10] == 6'h08) mdi = ym_dout;
    else if (ma[15:10] == 6'h0d) mdi = master_latch;
    else mdi = 8'hff;
  end
  always_comb begin
    if (sram_sel) sdi = slave_ram_q;
    else if (srom_sel) sdi = slave_rom_q;
    else if (sa[15:10] == 6'h0d) sdi = slave_latch;
    else sdi = 8'hff;
  end

  logic [20:0] master_ecount, slave_ecount;
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin master_ecount <= '0; slave_ecount <= '0; end
    else if (e_fall) begin
      master_ecount <= master_ecount + 21'd1;
      slave_ecount <= slave_ecount + 21'd1;
    end
  end
  assign dbg_master_run = master_ecount[20];
  assign dbg_slave_run = slave_ecount[20];

  // ---- sound-board diagnostic taps ----------------------------------------
  // See the port declarations. Window = 2^19 clk_sys ~= one frame.
  logic [18:0] dbg_win;
  logic [15:0] dbg_cvsd_cnt, dbg_dac2_cnt;
  logic [15:0] dbg_cvsd_lat, dbg_dac2_lat;
  logic [10:0] dbg_last_cmd;
  // Sticky activity: set when the event fires, cleared at window close, so the
  // overlay's ACTIVITY lanes distinguish "toggling" from "stuck asserted" --
  // which is the whole question here.
  logic dbg_a_cvsd, dbg_a_dac2, dbg_a_sfirq, dbg_a_mirq, dbg_a_nmi, dbg_a_cmd;
  logic dbg_ym_written, dbg_ym_nonzero, dbg_mix_nonzero, dbg_irq_seen;
  always_ff @(posedge clk) begin
    if (sound_board_rst) begin
      dbg_win <= '0; dbg_cvsd_cnt <= '0; dbg_dac2_cnt <= '0;
      dbg_cvsd_lat <= '0; dbg_dac2_lat <= '0; dbg_last_cmd <= '0;
      dbg_a_cvsd <= 1'b0; dbg_a_dac2 <= 1'b0; dbg_a_sfirq <= 1'b0;
      dbg_a_mirq <= 1'b0; dbg_a_nmi <= 1'b0; dbg_a_cmd <= 1'b0;
      dbg_ym_written <= 1'b0; dbg_ym_nonzero <= 1'b0;
      dbg_mix_nonzero <= 1'b0; dbg_irq_seen <= 1'b0;
    end else begin
      dbg_win <= dbg_win + 19'd1;
      if (cvsd_set || cvsd_clear) begin
        if (!(&dbg_cvsd_cnt)) dbg_cvsd_cnt <= dbg_cvsd_cnt + 16'd1;
        dbg_a_cvsd <= 1'b1;
      end
      if (swr && sgrp == 6'h0c) begin
        if (!(&dbg_dac2_cnt)) dbg_dac2_cnt <= dbg_dac2_cnt + 16'd1;
        dbg_a_dac2 <= 1'b1;
      end
      if (slave_firq)  dbg_a_sfirq <= 1'b1;
      if (master_irq)  dbg_a_mirq  <= 1'b1;
      if (master_nmi)  dbg_a_nmi   <= 1'b1;
      if (cmd_stb) begin dbg_last_cmd <= cmd; dbg_a_cmd <= 1'b1; end
      if (mwr && mgrp == 6'h08) dbg_ym_written <= 1'b1;
      if (ym_l != 16'sd0 || ym_r != 16'sd0) dbg_ym_nonzero <= 1'b1;
      if (audio_l != 16'sd0 || audio_r != 16'sd0) dbg_mix_nonzero <= 1'b1;
      if (master_irq) dbg_irq_seen <= 1'b1;
      if (dbg_win == '1) begin
        dbg_cvsd_lat <= dbg_cvsd_cnt; dbg_dac2_lat <= dbg_dac2_cnt;
        dbg_cvsd_cnt <= '0;           dbg_dac2_cnt <= '0;
        dbg_a_cvsd <= 1'b0; dbg_a_dac2 <= 1'b0; dbg_a_sfirq <= 1'b0;
        dbg_a_mirq <= 1'b0; dbg_a_nmi <= 1'b0; dbg_a_cmd <= 1'b0;
      end
    end
  end
  assign dbg_snd_rate  = {dbg_cvsd_lat, dbg_dac2_lat};
  assign dbg_snd_state = {dac2, 4'd0, slave_bank, 5'd0, dbg_last_cmd};
  assign dbg_snd_addr  = {sa, ma};
  assign dbg_snd_act   = {soft_rst, dbg_a_cmd, dbg_a_nmi, dbg_a_mirq,
                          dbg_a_sfirq, dbg_a_dac2, dbg_a_cvsd, rom_stall};
  // Keep overflow diagnostics visible to synthesis as well as simulation.
  // They remain sticky internal taps for the Verilator tests, while the
  // existing four-bit overlay bus reports any FIFO fault in the corresponding
  // activity category.
  assign dbg_ym_flags  = {dbg_ym_written | ym_fifo_overflow,
                          dbg_ym_nonzero | dac1_fifo_overflow | dac2_fifo_overflow,
                          dbg_mix_nonzero | cvsd_fifo_overflow,
                          dbg_irq_seen | host_fifo_overflow | slave_fifo_overflow};

  wire signed [15:0] mixed_audio_l, mixed_audio_r;
  // A host reset holds the board in reset while RAM and device state are
  // reinitialized. Do not expose the previous device output during that
  // interval; otherwise a latched DAC/CVSD value can sound through the reset
  // and make a reset appear not to have stopped a runaway tone. Keep the output
  // muted through the same settling window used for CPU release so the first
  // post-reset device state cannot produce a click or stale burst.
  wire audio_startup_mute = sound_board_rst || (sound_startup_wait != 12'hfff);
  assign audio_l = audio_startup_mute ? 16'sd0 : mixed_audio_l;
  assign audio_r = audio_startup_mute ? 16'sd0 : mixed_audio_r;

  narc_sound_mixer u_mixer (
    .ym_l(ym_l), .ym_r(ym_r), .dac1(dac1), .dac2(dac2),
    .cvsd(cvsd_sample), .audio_l(mixed_audio_l), .audio_r(mixed_audio_r)
  );
endmodule
`default_nettype wire
