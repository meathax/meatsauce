`default_nettype none

// Atari JSA II sound board (S.T.U.N. Runner): 6502, YM2151, OKI MSM6295.
// Behavioural reference: MAME 0.289 atarijsa.cpp / atariscom.cpp.
//
// 6502 map (mirror 0x01f9 on the 2800/2a00 pages):
//   0000-1fff RAM            2000-2001 YM2151
//   2800 r OKI status        2802 r command (clears NMI)
//   2804 r I/O port          2806 r/w timed IRQ acknowledge
//   2a00 w OKI command       2a02 w response (asserts main IRQ)
//   2a04 w I/O latch         2a06 w mix latch
//   3000-3fff banked ROM (4 x 4 KiB from ROM 0x0000)
//   4000-ffff ROM
module stunrun_jsa2 (
  input  logic        clk_i,          // 48 MHz
  input  logic        rst_i,          // board reset (power-on, main reset)

  // 68010 side (same clock).
  input  logic        main_reset_i,   // pulse: 0x604000 read
  input  logic        main_cmd_wr_i,  // pulse: 0x600000 write
  input  logic [7:0]  main_cmd_i,
  input  logic        main_resp_rd_i, // pulse: 0x600000 read
  output logic [7:0]  main_resp_o,
  output logic        main_irq_o,     // /LINKIRQ, 68010 level 4
  output logic        main_cmd_full_o, // command latched, not yet read by the 6502

  input  logic        coin1_i,
  input  logic        coin2_i,
  output logic [1:0]  coin_counter_o,

  // 6502 program ROM download (ioctl index 1): big-endian word pairs.
  input  logic        rom_wr_clk_i,
  input  logic        rom_wr_en_i,
  input  logic [14:0] rom_wr_addr_i,
  input  logic [15:0] rom_wr_data_i,

  // OKI sample ROM (256 KiB), word reads through a DDR client.
  output logic [17:1] oki_rom_addr_o,
  output logic        oki_rom_req_o,  // toggle
  input  logic        oki_rom_ack_i,  // == req when done
  input  logic [15:0] oki_rom_data_i, // {even byte, odd byte}

  output logic signed [15:0] audio_o
);
  // ---------------------------------------------------------------------
  // Clock enables from 48 MHz: 3.579545 MHz YM, /2 CPU, /3 OKI.
  // ---------------------------------------------------------------------
  localparam int unsigned MASTER = 3_579_545;
  localparam int unsigned CLK    = 48_000_000;
  logic [25:0] ph_q;
  logic        cen_ym, cen_cpu, cen_oki;
  logic        half_q;
  logic [1:0]  third_q;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      ph_q    <= '0;
      cen_ym  <= 1'b0;
      cen_cpu <= 1'b0;
      cen_oki <= 1'b0;
      half_q  <= 1'b0;
      third_q <= 2'd0;
    end else begin
      cen_ym  <= 1'b0;
      cen_cpu <= 1'b0;
      cen_oki <= 1'b0;
      if (ph_q + 26'(MASTER) >= 26'(CLK)) begin
        ph_q    <= ph_q + 26'(MASTER) - 26'(CLK);
        cen_ym  <= 1'b1;
        half_q  <= !half_q;
        cen_cpu <= half_q;
        third_q <= (third_q == 2'd2) ? 2'd0 : third_q + 2'd1;
        cen_oki <= (third_q == 2'd2);
      end else begin
        ph_q <= ph_q + 26'(MASTER);
      end
    end
  end

  // Board reset: power-on / MiSTer reset or the 68010's sound reset read.
  // Held for 1024 clocks (~38 6502 cycles): T65 only completes its reset
  // sequence across clock enables, so a short strobe leaves it half reset.
  logic [10:0] brst_q;
  always_ff @(posedge clk_i) begin
    if (rst_i || main_reset_i) brst_q <= 11'd1024;
    else if (brst_q != 0)      brst_q <= brst_q - 11'd1;
  end
  wire brst = brst_q != 0;

  // ---------------------------------------------------------------------
  // 6502
  // ---------------------------------------------------------------------
  logic [23:0] cpu_a_full;
  wire  [15:0] cpu_a = cpu_a_full[15:0];
  logic [7:0]  cpu_do, cpu_di;
  logic        cpu_rnw;
  logic        cpu_irq_n, cpu_nmi_n;

  T65 u_cpu (
    .Mode(2'b00), .Res_n(!brst), .Enable(cen_cpu), .Clk(clk_i),
    .Rdy(1'b1), .Abort_n(1'b1), .IRQ_n(cpu_irq_n), .NMI_n(cpu_nmi_n),
    .SO_n(1'b1), .DI(cpu_di), .R_W_n(cpu_rnw), .Sync(), .EF(), .MF(),
    .XF(), .ML_n(), .VP_n(), .VDA(), .VPA(), .A(cpu_a_full), .DO(cpu_do)
  );

  wire sel_ram  = cpu_a[15:13] == 3'b000;
  wire sel_ym   = cpu_a[15:11] == 5'b00100;          // 2000-27ff
  wire sel_rd   = cpu_a[15:9]  == 7'b0010100;        // 2800-29ff
  wire sel_wr   = cpu_a[15:9]  == 7'b0010101;        // 2a00-2bff
  wire sel_bank = cpu_a[15:12] == 4'h3;
  wire sel_rom  = cpu_a[15:14] != 2'b00;             // 4000-ffff
  wire [1:0] reg_sel = cpu_a[2:1];
  wire cpu_read_cyc  = cen_cpu && cpu_rnw;
  wire cpu_write_cyc = cen_cpu && !cpu_rnw;

  // Sound comm mailbox (atariscom.cpp).
  logic [7:0] cmd_q, resp_q;
  logic       cmd_ready_q, resp_ready_q;
  // I/O latches (cleared by the board reset like the PCB LS-series parts).
  logic [7:0] wrio_q, mix_q;
  logic       timed_int_q;
  logic [13:0] timer_q;
  logic        ym_irq_n;

  assign main_resp_o = resp_q;
  assign main_irq_o  = resp_ready_q;
  assign main_cmd_full_o = cmd_ready_q;
  assign cpu_nmi_n   = !cmd_ready_q;
  assign cpu_irq_n   = !(timed_int_q || !ym_irq_n);
  assign coin_counter_o = {wrio_q[5], wrio_q[4]};

  always_ff @(posedge clk_i) begin
    if (brst) begin
      cmd_q        <= 8'h00;
      resp_q       <= 8'h00;
      cmd_ready_q  <= 1'b0;
      resp_ready_q <= 1'b0;
      wrio_q       <= 8'h00;
      mix_q        <= 8'h00;
      timed_int_q  <= 1'b0;
      timer_q      <= 14'd0;
    end else begin
      // 3.579545 MHz / 4 / 16 / 16 / 14 periodic IRQ.
      if (cen_ym) begin
        if (timer_q == 14'd14335) begin
          timer_q     <= 14'd0;
          timed_int_q <= 1'b1;
        end else begin
          timer_q <= timer_q + 14'd1;
        end
      end
      if (main_cmd_wr_i) begin
        cmd_q       <= main_cmd_i;
        cmd_ready_q <= 1'b1;
      end
      if (main_resp_rd_i) resp_ready_q <= 1'b0;

      if (cpu_read_cyc && sel_rd) begin
        if (reg_sel == 2'd1) cmd_ready_q <= 1'b0;
        if (reg_sel == 2'd3) timed_int_q <= 1'b0;
      end
      if (cpu_write_cyc && sel_rd && reg_sel == 2'd3) timed_int_q <= 1'b0;
      if (cpu_write_cyc && sel_wr) begin
        unique case (reg_sel)
          2'd1: begin resp_q <= cpu_do; resp_ready_q <= 1'b1; end
          2'd2: wrio_q <= cpu_do;
          2'd3: mix_q  <= cpu_do;
          default: ;
        endcase
      end
    end
  end

  // RAM 8 KiB.
  (* ramstyle = "M10K, no_rw_check" *) logic [7:0] ram [0:8191];
  logic [7:0] ram_q;
  always_ff @(posedge clk_i) begin
    if (cpu_write_cyc && sel_ram) ram[cpu_a[12:0]] <= cpu_do;
    ram_q <= ram[cpu_a[12:0]];
  end

  // Program ROM 64 KiB (32K big-endian words).
  logic [15:0] rom_byte_addr;
  logic [15:0] rom_word_q;
  logic        rom_odd_q;
  assign rom_byte_addr = sel_bank ? {2'b00, wrio_q[7:6], cpu_a[11:0]} : cpu_a;
  harddrivin_dual_clock_word_ram #(.ADDR_WIDTH(15)) u_rom (
    .wr_clk_i(rom_wr_clk_i), .wr_en_i(rom_wr_en_i),
    .wr_addr_i(rom_wr_addr_i), .wr_data_i(rom_wr_data_i),
    .rd_clk_i(clk_i), .rd_addr_i(rom_byte_addr[15:1]), .rd_data_o(rom_word_q)
  );
  always_ff @(posedge clk_i) rom_odd_q <= rom_byte_addr[0];
  wire [7:0] rom_q = rom_odd_q ? rom_word_q[7:0] : rom_word_q[15:8];

  // ---------------------------------------------------------------------
  // YM2151
  // ---------------------------------------------------------------------
  logic [7:0] ym_dout;
  logic signed [15:0] ym_l, ym_r;
  logic ym_ct1;
  logic ym_wr_n_q, ym_a0_q;
  logic [7:0] ym_din_q;
  always_ff @(posedge clk_i) begin
    ym_wr_n_q <= !(cpu_write_cyc && sel_ym);
    if (cpu_write_cyc && sel_ym) begin
      ym_a0_q  <= cpu_a[0];
      ym_din_q <= cpu_do;
    end
  end
  // JT51 clears its shift-register state only if reset spans >= 32 enables;
  // the ROM pulses /YAMRES for a few 6502 cycles, so stretch it (~76).
  logic [11:0] ym_rst_q;
  always_ff @(posedge clk_i) begin
    if (brst || !wrio_q[0]) ym_rst_q <= 12'd2047;
    else if (ym_rst_q != 0) ym_rst_q <= ym_rst_q - 12'd1;
  end
  jt51 u_ym (
    .rst(ym_rst_q != 0), .clk(clk_i), .cen(cen_ym), .cen_p1(cen_cpu),
    .cs_n(ym_wr_n_q), .wr_n(ym_wr_n_q), .a0(ym_a0_q), .din(ym_din_q),
    .dout(ym_dout), .ct1(ym_ct1), .ct2(), .irq_n(ym_irq_n), .sample(),
    .left(ym_l), .right(ym_r), .xleft(), .xright()
  );

  // ---------------------------------------------------------------------
  // OKI MSM6295 (1.193 MHz, pin 7 from the I/O latch)
  // ---------------------------------------------------------------------
  logic [7:0] oki_dout;
  logic [17:0] oki_addr;
  logic [7:0]  oki_data;
  logic        oki_ok;
  logic signed [13:0] oki_snd;
  logic oki_wr_n_q;
  logic [7:0] oki_din_q;
  always_ff @(posedge clk_i) begin
    oki_wr_n_q <= !(cpu_write_cyc && sel_wr && reg_sel == 2'd0);
    if (cpu_write_cyc && sel_wr && reg_sel == 2'd0) oki_din_q <= cpu_do;
  end
  jt6295 #(.INTERPOL(0)) u_oki (
    .rst(brst || !wrio_q[2]), .clk(clk_i), .cen(cen_oki), .ss(wrio_q[3]),
    .wrn(oki_wr_n_q), .din(oki_din_q), .dout(oki_dout),
    .rom_addr(oki_addr), .rom_data(oki_data), .rom_ok(oki_ok),
    .sound(oki_snd), .sample()
  );

  // DDR word fetch: one outstanding request, the last word is kept.
  logic [17:1] served_q;
  logic        served_valid_q, pending_q;
  logic [15:0] served_data_q;
  assign oki_ok   = served_valid_q && !pending_q && (served_q == oki_addr[17:1]);
  assign oki_data = oki_addr[0] ? served_data_q[7:0] : served_data_q[15:8];
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      served_valid_q <= 1'b0;
      pending_q      <= 1'b0;
      oki_rom_req_o  <= 1'b0;
      oki_rom_addr_o <= '0;
      served_q       <= '0;
      served_data_q  <= 16'h0000;
    end else if (pending_q) begin
      if (oki_rom_ack_i == oki_rom_req_o) begin
        pending_q      <= 1'b0;
        served_valid_q <= 1'b1;
        served_q       <= oki_rom_addr_o;
        served_data_q  <= oki_rom_data_i;
      end
    end else if (!served_valid_q || served_q != oki_addr[17:1]) begin
      oki_rom_addr_o <= oki_addr[17:1];
      oki_rom_req_o  <= !oki_rom_req_o;
      pending_q      <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------
  // 6502 read data
  // ---------------------------------------------------------------------
  // JSAII port: coins active high, bit 5 response full, bit 6 command
  // pending (active low); MAME's self-test bit reads 0 in both states.
  wire [7:0] rdio = {1'b0, !cmd_ready_q, resp_ready_q, 3'b000, coin2_i, coin1_i};
  logic [15:0] a_q;
  always_ff @(posedge clk_i) a_q <= cpu_a;
  always_comb begin
    if (a_q[15:13] == 3'b000)           cpu_di = ram_q;
    else if (a_q[15:11] == 5'b00100)    cpu_di = ym_dout;
    else if (a_q[15:9] == 7'b0010100) begin
      unique case (a_q[2:1])
        2'd0: cpu_di = oki_dout;
        2'd1: cpu_di = cmd_q;
        2'd2: cpu_di = rdio;
        default: cpu_di = 8'h00;
      endcase
    end else if (a_q[15:12] == 4'h3 || a_q[15:14] != 2'b00)
      cpu_di = rom_q;
    else
      cpu_di = 8'hff;
  end

  // ---------------------------------------------------------------------
  // Mixer (MAME: YM 0.60 x vol/7, OKI 0.75 x {0.5,1} x CT1, speaker 0.5)
  // ---------------------------------------------------------------------
  // |L+R| (<= 65534) x vol (<= 7) x 11 reaches 5.0M, so the product needs
  // 25 bits. A 22-bit product wrapped once |L+R| > 27235 at full volume:
  // loud music turned into full-scale static.
  logic signed [16:0] ym_sum;
  logic signed [24:0] ym_prod;
  logic signed [21:0] ym_term;
  logic signed [17:0] oki_term;
  logic signed [22:0] mix;
  always_ff @(posedge clk_i) begin
    ym_sum   <= ym_l + ym_r;
    ym_prod  <= $signed({{8{ym_sum[16]}}, ym_sum}) * $signed({1'b0, mix_q[3:1]}) * 25'sd11;
    ym_term  <= $signed({{4{ym_prod[24]}}, ym_prod[24:7]});   // >>> 7, |.| < 2^16
    oki_term <= !ym_ct1 ? 18'sd0
              : mix_q[0] ? (($signed({oki_snd, 2'b00}) * 18'sd3) >>> 2)
              : (($signed({oki_snd, 2'b00}) * 18'sd3) >>> 3);
    mix      <= (ym_term + oki_term) >>> 1;
    audio_o  <= (mix > 23'sd32767) ? 16'sd32767 :
                (mix < -23'sd32768) ? -16'sd32768 : mix[15:0];
  end
  logic unused;
  assign unused = ^{cpu_a_full[23:16], sel_rom, mix_q[7:4]};
endmodule

`default_nettype wire
