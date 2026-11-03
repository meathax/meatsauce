// Exterminator sound: Gottlieb "PIN5" sound board (MAME gottlieb_sound_p5_device).
//
//   dcpu (M6502 @2 MHz) : RAM 0000-3FFF (2 KB mirrored), 4000-7FFF read command latch + ack IRQ,
//                         8000-BFFF write: even = DACVOL, odd = DAC; ROM 8000-FFFF (v101d1)
//   ycpu (M6502 @2 MHz) : RAM 0000-1FFF, 2000-3FFF write = filter latch, 4000-5FFF write = YM2151
//                         (A0 = speech_control[7]), 6000 write NMI rate, 6800 read command latch + ack IRQ,
//                         7000 read/write = pulse dcpu NMI, 8000 write PSG latch, A000 write
//                         speech_control, ROM 8000-FFFF (v101y1)
//   2 x AY-8913 @2 MHz, YM2151 @4 MHz (jt51), AD7528 DAC multiplying DAC by DACVOL.
//
// Mono mix as MAME: DAC 0.5, each AY channel 0.5, YM2151 (L+R) x 0.75.
// 6502 core: T65 (Verilog conversion, cycle accurate incl. dummy bus cycles, Enable input).
module exterm_sound #(
  // ycpu timer-NMI early-assert in CPU cycles (compensates T65's NMI detect pipeline vs MAME's m6502)
  parameter int NMI_ADV = 4
) (
  input  logic               clk,          // 20 MHz
  input  logic               rst,
  input  logic               ce_2m,        // clk/10
  input  logic               ce_4m,        // clk/5
  input  logic               ce_250k,      // clk/80
  input  logic [7:0]         cmd,
  input  logic               cmd_wr,
  input  logic               ld_en,
  input  logic               ld_wr,
  input  logic               ld_region,    // 0 = audiocpu v101d1, 1 = speechcpu v101y1
  input  logic [14:0]        ld_addr,
  input  logic [7:0]         ld_data,
  input  logic [1:0]         filter_mode,  // 0 = MAME (no filter), 1 = PCB approximation
  output logic signed [15:0] audio,
  output logic               dbg_led
);

  // ------------------------------------------------------------------------------------
  // Board reset: T65 completes its reset sequence only over Enable pulses -> stretch.
  // ------------------------------------------------------------------------------------
  logic [9:0] brst_q;
  always_ff @(posedge clk) begin
    if (rst)             brst_q <= 10'd1000;
    else if (brst_q != 0) brst_q <= brst_q - 10'd1;
  end
  wire brst = (brst_q != 0);
  logic ym_rst_q;                      // dedicated flop for jt51's reset (used asynchronously inside)
  always_ff @(posedge clk) ym_rst_q <= rst | (brst_q != 10'd0);
  logic res_n_q;                       // dedicated flop for the CPUs' asynchronous Res_n
  always_ff @(posedge clk) res_n_q <= ~(rst | (brst_q > 10'd1));

  // ------------------------------------------------------------------------------------
  // Memories (BRAM). ROMs are loaded through ld_*; in simulation they can be preloaded.
  // ------------------------------------------------------------------------------------
  (* ramstyle = "M10K" *) logic [7:0] rom_d [0:32767];
  (* ramstyle = "M10K" *) logic [7:0] rom_y [0:32767];
  (* ramstyle = "M10K" *) logic [7:0] ram_d [0:2047];
  (* ramstyle = "M10K" *) logic [7:0] ram_y [0:2047];
`ifdef EXTERM_SND_SIM_ROMS
  `ifndef EXTERM_SND_AUDIO_HEX
    `define EXTERM_SND_AUDIO_HEX "roms/audiocpu.hex"
  `endif
  `ifndef EXTERM_SND_SPEECH_HEX
    `define EXTERM_SND_SPEECH_HEX "roms/speechcpu.hex"
  `endif
  initial begin
    $readmemh(`EXTERM_SND_AUDIO_HEX, rom_d);
    $readmemh(`EXTERM_SND_SPEECH_HEX, rom_y);
  end
`endif

  logic [7:0] rom_d_q, rom_y_q, ram_d_q, ram_y_q;
  logic [15:0] d_a, y_a;
  logic [7:0]  d_do, y_do;
  logic        d_rnw, y_rnw;

  always_ff @(posedge clk) begin
    if (ld_en && ld_wr && !ld_region) rom_d[ld_addr] <= ld_data;
    rom_d_q <= rom_d[d_a[14:0]];
  end
  always_ff @(posedge clk) begin
    if (ld_en && ld_wr && ld_region) rom_y[ld_addr] <= ld_data;
    rom_y_q <= rom_y[y_a[14:0]];
  end

  wire d_cyc_wr = ce_2m && !d_rnw;
  wire y_cyc_wr = ce_2m && !y_rnw;
  wire d_cyc_rd = ce_2m &&  d_rnw;
  wire y_cyc_rd = ce_2m &&  y_rnw;

  always_ff @(posedge clk) begin
    if (d_cyc_wr && d_a[15:14] == 2'b00) ram_d[d_a[10:0]] <= d_do;
    ram_d_q <= ram_d[d_a[10:0]];
  end
  always_ff @(posedge clk) begin
    if (y_cyc_wr && y_a[15:13] == 3'b000) ram_y[y_a[10:0]] <= y_do;
    ram_y_q <= ram_y[y_a[10:0]];
  end

  // ------------------------------------------------------------------------------------
  // Command latch (gottlieb_sound_p4_device::write_sync)
  // ------------------------------------------------------------------------------------
  logic [7:0] latch_d, latch_y, last_cmd;
  logic       irq_d, irq_y;
  wire d_ack = d_cyc_rd && (d_a[15:14] == 2'b01);                       // 4000-7FFF read
  wire y_ack = y_cyc_rd && (y_a[15:11] == 5'b01101);                    // 6800-6FFF read

  always_ff @(posedge clk) begin
    if (brst) begin
      latch_d <= 8'h00; latch_y <= 8'h00; last_cmd <= 8'h00; irq_d <= 1'b0; irq_y <= 1'b0;
    end else begin
      if (d_ack) irq_d <= 1'b0;
      if (y_ack) irq_y <= 1'b0;
      if (cmd_wr) begin
        if (cmd != 8'hff) begin
          latch_d <= cmd; latch_y <= cmd;
          if (last_cmd == 8'hff) begin irq_d <= 1'b1; irq_y <= 1'b1; end
        end
        last_cmd <= cmd;
      end
    end
  end

  // ------------------------------------------------------------------------------------
  // Speech-CPU registers
  // ------------------------------------------------------------------------------------
  logic [7:0] ctl, psg_latch, nmi_rate, filt_reg;
  logic       nmi_state;
  logic       nmi_d_pulse;                 // ycpu -> dcpu NMI pulse
  logic [23:0] nmi_cnt;

  wire y_wr_ym   = y_cyc_wr && (y_a[15:13] == 3'b010);                   // 4000-5FFF
  wire y_wr_rate = y_cyc_wr && (y_a[15:11] == 5'b01100);                 // 6000-67FF
  wire y_nmi_sig = ce_2m && (y_a[15:11] == 5'b01110);                    // 7000-77FF rd or wr
  wire y_wr_psg  = y_cyc_wr && (y_a[15:13] == 3'b100);                   // 8000-9FFF
  wire y_wr_ctl  = y_cyc_wr && (y_a[15:13] == 3'b101);                   // A000-BFFF
  wire y_wr_filt = y_cyc_wr && (y_a[15:13] == 3'b001);                   // 2000-3FFF

  logic       ay1_wr, ay2_wr, ay_addr;

  always_ff @(posedge clk) begin
    ay1_wr <= 1'b0; ay2_wr <= 1'b0;
    if (brst) begin
      ctl <= 8'h00; ay_addr <= 1'b0; psg_latch <= 8'h00; nmi_rate <= 8'h00; filt_reg <= 8'hff; nmi_d_pulse <= 1'b0;
    end else begin
      if (ce_2m) nmi_d_pulse <= y_nmi_sig;        // asserted for exactly one CPU enable period
      if (y_wr_rate) nmi_rate <= y_do;
      if (y_wr_psg)  psg_latch <= y_do;
      if (y_wr_filt) filt_reg <= y_do;
      if (y_wr_ctl) begin
        ctl <= y_do;
        // BDIR (bit 2) falling edge latches the PSG bus into the selected AY (bit 3: 1 = AY1)
        if (ctl[2] && !y_do[2]) begin
          ay_addr <= y_do[4];
          if (y_do[3]) ay1_wr <= 1'b1; else ay2_wr <= 1'b1;
        end
      end
    end
  end

  // NMI timer: period = 256*(256-rate) ticks of SOUND2/16 (250 kHz); pulse width one tick.
  // The timer is counted in CPU cycles since the board reset was released (8 x ce_2m = one
  // SOUND2/16 tick = 4 us), exactly like MAME where timer and both CPUs start at t = 0; it does
  // not depend on the phase of ce_250k.  NMI_ADV: MAME's m6502 samples the NMI line at the
  // opcode-prefetch (last) cycle of each instruction, T65 only after a two-enable detect pipeline;
  // asserting the timer NMI NMI_ADV CPU cycles early makes the same instruction get interrupted
  // as in MAME (measured against the MAME PC traces, see docs/lane3_sound.md).
  logic [2:0] nmi_ph;                       // CPU cycles since reset release, mod 8
  always_ff @(posedge clk) begin
    if (brst) nmi_ph <= 3'd0;
    else if (ce_2m) nmi_ph <= nmi_ph + 3'd1;
  end
  localparam int NMI_PHI = 7 - NMI_ADV;
  localparam [2:0] NMI_PH = NMI_PHI[2:0];   // ce_2m phase (0..7) at which the early tick fires
  wire nmi_tick = ce_2m && (nmi_ph == NMI_PH);
  always_ff @(posedge clk) begin
    if (brst) begin
      nmi_cnt <= 24'd65536; nmi_state <= 1'b0;
    end else if (nmi_tick) begin
      nmi_state <= 1'b0;
      if (nmi_cnt <= 24'd1) begin
        nmi_state <= 1'b1;
        nmi_cnt   <= {7'd0, (9'd256 - {1'b0, nmi_rate}), 8'd0};
      end else nmi_cnt <= nmi_cnt - 24'd1;
    end
  end


  // ------------------------------------------------------------------------------------
  // CPUs
  // ------------------------------------------------------------------------------------
  logic [23:0] d_a_full, y_a_full;
  assign d_a = d_a_full[15:0];
  assign y_a = y_a_full[15:0];
  logic [7:0] d_di, y_di;
  wire d_nmi_n = ~nmi_d_pulse;
  wire y_nmi_n = ~(nmi_state & ctl[0]);

  logic d_sync, d_ef, d_mf, d_xf, d_ml, d_vp, d_vda, d_vpa;
  logic y_sync, y_ef, y_mf, y_xf, y_ml, y_vp, y_vda, y_vpa;
  T65 u_dcpu (
    .Mode(2'b00), .Res_n(res_n_q), .Enable(ce_2m), .Clk(clk), .Rdy(1'b1), .Abort_n(1'b1),
    .IRQ_n(~irq_d), .NMI_n(d_nmi_n), .SO_n(1'b1), .DI(d_di), .R_W_n(d_rnw),
    .Sync(d_sync), .EF(d_ef), .MF(d_mf), .XF(d_xf), .ML_n(d_ml), .VP_n(d_vp), .VDA(d_vda), .VPA(d_vpa), .A(d_a_full), .DO(d_do)
  );
  T65 u_ycpu (
    .Mode(2'b00), .Res_n(res_n_q), .Enable(ce_2m), .Clk(clk), .Rdy(1'b1), .Abort_n(1'b1),
    .IRQ_n(~irq_y), .NMI_n(y_nmi_n), .SO_n(1'b1), .DI(y_di), .R_W_n(y_rnw),
    .Sync(y_sync), .EF(y_ef), .MF(y_mf), .XF(y_xf), .ML_n(y_ml), .VP_n(y_vp), .VDA(y_vda), .VPA(y_vpa), .A(y_a_full), .DO(y_do)
  );

  always_comb begin
    if (d_a[15])        d_di = rom_d_q;
    else if (d_a[14])   d_di = latch_d;
    else                d_di = ram_d_q;
  end
  always_comb begin
    if (y_a[15])                          y_di = rom_y_q;
    else if (y_a[15:11] == 5'b01101)      y_di = latch_y;
    else if (y_a[15:13] == 3'b000)        y_di = ram_y_q;
    else                                  y_di = 8'hff;      // unmapped / nopr: unmap_value_high
  end

  // ------------------------------------------------------------------------------------
  // AD7528 DAC x DACVOL: out = vol/256 * (2*d/256 - 1), route gain 0.5, 1.0 = 32768
  //                    -> vol * (d - 128) / 2
  // ------------------------------------------------------------------------------------
  logic [7:0] dacvol, dacval;
  always_ff @(posedge clk) begin
    if (brst) begin dacvol <= 8'h00; dacval <= 8'h00; end
    else if (d_cyc_wr && d_a[15:14] == 2'b10) begin
      if (d_a[0]) dacval <= d_do; else dacvol <= d_do;
    end
  end
  wire signed [8:0]  dac_c   = $signed({1'b0, dacval}) - 9'sd128;
  wire signed [17:0] dac_p   = $signed({1'b0, dacvol}) * dac_c;
  wire signed [16:0] dac_raw = dac_p[17:1];

  // ------------------------------------------------------------------------------------
  // Optional "PCB" filter (filter_mode[0]): MAME leaves the variable Butterworth filter
  // (HC592 + LS74 + MF-4) behind the speech-CPU latch at 0x2000 unemulated.  Approximation:
  // four cascaded one-pole low-passes on the DAC path only, run at 250 kHz, with
  //     fc = 10 kHz / (256 - filt_reg)      (assumed clock-divider law, see docs/lane3_sound.md)
  // and each pole at 2.3 x fc so the cascade is -3 dB at fc.  The ROM never writes 0x2000, so
  // the reset value (0xFF -> 10 kHz) is what the filter sees in practice.
  // ------------------------------------------------------------------------------------
  localparam int FA_K = 37880;                      // 2*pi*2.3*10 kHz / 250 kHz in Q16
  logic [15:0] filt_a;                              // pole coefficient, Q16 = FA_K / (256 - filt_reg)
  logic [7:0]  filt_seen;
  logic [4:0]  div_cnt;
  logic [8:0]  div_rem;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] div_n, div_q;                       // div_q[15] only ever feeds filt_a
  /* verilator lint_on UNUSEDSIGNAL */
  logic [8:0]  div_d;
  logic        div_busy;
  always_ff @(posedge clk) begin : filt_div
    logic [9:0]  r2;
    logic [15:0] q2;
    if (brst) begin
      filt_seen <= 8'hff; filt_a <= FA_K[15:0]; div_busy <= 1'b0; div_cnt <= '0;
      div_rem <= '0; div_n <= '0; div_q <= '0; div_d <= 9'd1;
    end else if (!div_busy) begin
      if (filt_seen != filt_reg) begin
        filt_seen <= filt_reg; div_busy <= 1'b1; div_cnt <= 5'd16;
        div_d <= 9'd256 - {1'b0, filt_reg}; div_rem <= '0; div_n <= FA_K[15:0]; div_q <= '0;
      end
    end else begin                                  // restoring divider, MSB first
      r2 = {div_rem, div_n[15]};
      q2 = {div_q[14:0], 1'b0};
      if (r2 >= {1'b0, div_d}) begin r2 = r2 - {1'b0, div_d}; q2[0] = 1'b1; end
      div_rem <= r2[8:0]; div_q <= q2; div_n <= {div_n[14:0], 1'b0};
      div_cnt <= div_cnt - 5'd1;
      if (div_cnt == 5'd1) begin div_busy <= 1'b0; filt_a <= q2; end
    end
  end

  logic signed [24:0] fst [0:3];                    // pole states, 8 fractional bits
  logic [2:0]         fidx;
  logic signed [24:0] fin;
  always_ff @(posedge clk) begin : filt_poles
    logic signed [25:0] dlt;
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [43:0] prod;                       // only [40:16] used (Q16 product)
    /* verilator lint_on UNUSEDSIGNAL */
    logic signed [24:0] nxt;
    if (brst) begin
      for (int i = 0; i < 4; i++) fst[i] <= 25'sd0;
      fidx <= 3'd4; fin <= 25'sd0;
    end else begin
      if (ce_250k) begin fidx <= 3'd0; fin <= {dac_raw, 8'd0}; end
      else if (!fidx[2]) begin
        dlt  = {fin[24], fin} - {fst[fidx[1:0]][24], fst[fidx[1:0]]};
        prod = dlt * $signed({2'b00, filt_a});
        nxt  = fst[fidx[1:0]] + prod[40:16];
        fst[fidx[1:0]] <= nxt;
        fin  <= nxt;
        fidx <= fidx + 3'd1;
      end
    end
  end
  wire signed [16:0] dac_filt = fst[3][24:8];
  wire signed [16:0] dac_out  = filter_mode[0] ? dac_filt : dac_raw;
  // ------------------------------------------------------------------------------------
  // AY-8913 x2
  // ------------------------------------------------------------------------------------
  logic signed [15:0] ay1_lvl, ay2_lvl;
  exterm_ay8913 u_ay1 (.clk(clk), .rst(brst), .ce(ce_250k), .wr_en(ay1_wr), .wr_addr(ay_addr), .din(psg_latch), .level(ay1_lvl));
  exterm_ay8913 u_ay2 (.clk(clk), .rst(brst), .ce(ce_250k), .wr_en(ay2_wr), .wr_addr(ay_addr), .din(psg_latch), .level(ay2_lvl));

  // ------------------------------------------------------------------------------------
  // YM2151 (jt51) with a small write queue (jt51 ignores writes while busy; MAME has no busy)
  // ------------------------------------------------------------------------------------
  logic        ym_tgl;
  wire         ym_cen    = ce_4m;
  wire         ym_cen_p1 = ce_4m & ym_tgl;
  always_ff @(posedge clk) begin
    if (ce_4m) ym_tgl <= ~ym_tgl;       // free running: jt51 needs cen/cen_p1 pulses DURING its reset
  end

  logic [8:0] ym_fifo [0:63];
  logic [5:0] ym_wp, ym_rp;
  logic [6:0] ym_cnt;
  logic       ym_req, ym_a0;
  logic [7:0] ym_din, ym_dout;
  wire        ym_busy  = ym_dout[7];
  wire        ym_write = ym_req && ym_cen_p1 && !ym_busy;
  wire        ym_push  = y_wr_ym;
  wire        ym_pop   = !ym_req && (ym_cnt != 0);
  always_ff @(posedge clk) begin
    if (brst) begin
      ym_wp <= '0; ym_rp <= '0; ym_cnt <= '0; ym_req <= 1'b0; ym_a0 <= 1'b0; ym_din <= 8'h00;
    end else begin
      if (ym_push) begin ym_fifo[ym_wp] <= {ctl[7], y_do}; ym_wp <= ym_wp + 6'd1; end
      if (ym_pop) begin
        {ym_a0, ym_din} <= ym_fifo[ym_rp]; ym_rp <= ym_rp + 6'd1; ym_req <= 1'b1;
      end else if (ym_write) ym_req <= 1'b0;
      ym_cnt <= ym_cnt + {6'd0, ym_push} - {6'd0, ym_pop};
    end
  end

  logic signed [15:0] ym_l, ym_r, ym_lo, ym_ro;
  logic ym_ct1, ym_ct2, ym_irq_n, ym_sample;
`ifdef EXTERM_SND_NO_YM
  // profiling aid only (simulation speed experiments)
  assign ym_l = 16'sd0; assign ym_r = 16'sd0; assign ym_lo = 16'sd0; assign ym_ro = 16'sd0; assign ym_dout = 8'd0;
  assign ym_ct1 = 1'b0; assign ym_ct2 = 1'b0; assign ym_irq_n = 1'b1; assign ym_sample = 1'b0;
`else
  jt51 u_ym (
    .rst(ym_rst_q), .clk(clk), .cen(ym_cen), .cen_p1(ym_cen_p1),
    .cs_n(~ym_write), .wr_n(~ym_write), .a0(ym_a0), .din(ym_din), .dout(ym_dout),
    .ct1(ym_ct1), .ct2(ym_ct2), .irq_n(ym_irq_n), .sample(ym_sample), .left(ym_lo), .right(ym_ro), .xleft(ym_l), .xright(ym_r)
  );
`endif

  // ------------------------------------------------------------------------------------
  // Mix
  // ------------------------------------------------------------------------------------
  wire signed [17:0] ym_sum = $signed({ym_l[15], ym_l[15], ym_l}) + $signed({ym_r[15], ym_r[15], ym_r});
  wire signed [17:0] ym_mix = (ym_sum >>> 1) + (ym_sum >>> 2);               // x0.75
  wire signed [19:0] mix =  $signed({{3{dac_out[16]}}, dac_out})
                          + {{4{ay1_lvl[15]}}, ay1_lvl} + {{4{ay2_lvl[15]}}, ay2_lvl}
                          + $signed({{2{ym_mix[17]}}, ym_mix});
  always_ff @(posedge clk) begin
    if (mix > 20'sd32767)       audio <= 16'sh7fff;
    else if (mix < -20'sd32768) audio <= 16'sh8000;
    else                        audio <= mix[15:0];
  end

  assign dbg_led = ctl[1];

  wire unused = &{1'b0, filter_mode, ctl[6:3], dac_p[0], filt_reg, ym_dout[6:0], ym_ct1, ym_ct2, ym_irq_n, ym_sample, ym_lo, ym_ro, d_a_full[23:16], y_a_full[23:16],
                  d_sync, d_ef, d_mf, d_xf, d_ml, d_vp, d_vda, d_vpa, y_sync, y_ef, y_mf, y_xf, y_ml, y_vp, y_vda, y_vpa};
endmodule
