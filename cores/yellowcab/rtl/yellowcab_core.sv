//============================================================================
// Yellow Cab / Kamikaze Cabbie core bus
// Maps: liberate_map + kamikcab_io_map + yellowcb $A000 IN0
//
// Everything lives in BRAM. The full ROM set is ~168 KB (maincpu 64K, audiocpu
// 8K, gfx1 48K, gfx2 32K, user1 16K, PROM 32B) against ~696 KB of M10K on a
// Cyclone V 5CSEBA6, so the SDRAM controller, its word cache, the second clock
// domain, the ioctl CDC and the RDY-stall path into both CPUs are all gone.
// That also removes the reason SIM_FAST_INIT existed: the simulator and the
// synthesised design are now the same RTL.
//============================================================================

import yellowcab_rom_map::*;

module yellowcab_core (
  input             reset,
  input             clk_sys,

  input       [7:0] p1,
  input       [7:0] p2,
  input       [7:0] p3,
  input       [7:0] dsw1,
  input       [7:0] dsw2,
  input             tilt,

  input             pause,

  input             ioctl_download,
  input      [26:0] ioctl_addr,
  input       [7:0] ioctl_dout,
  input             ioctl_wr,

  output      [3:0] red,
  output      [3:0] green,
  output      [3:0] blue,
  output            vs,
  output            vb,
  output            hs,
  output            hb,
  output            ce_pix,
  output     [15:0] audio_l,
  output     [15:0] audio_r
);

// -------- IO regs --------
reg [7:0] io_ram [0:15];
reg       irq_n = 1'b1;
reg       coin_latch = 1'b0;

wire vblank = vb;
// MAME yellowcb IN0: bit2 = VBLANK (IP_ACTIVE_HIGH), rest IPT_UNKNOWN ACTIVE_HIGH
wire [7:0] in0 = {5'b00000, vblank, 2'b00};

// -------- Main CPU --------
wire [15:0] m_ab;
wire [7:0]  m_dout, m_din;
wire        m_rw, bank_en, m_sync;

wire work_cs, mir_cs, color_cs, video_cs, sprite_cs, work2_cs;
wire main_cs, io_w_cs, io_r_cs, user1_cs, in0_cs;

// CPUs are held during download; `pause` freezes them without resetting.
wire cpu_hold = reset | ioctl_download;
wire cpu_run  = ~pause;

io_map u_map(
  .addr(m_ab), .rw(m_rw), .bank_en(bank_en),
  .work_cs(work_cs), .mir_cs(mir_cs),
  .color_cs(color_cs), .video_cs(video_cs), .sprite_cs(sprite_cs),
  .work2_cs(work2_cs), .main_cs(main_cs),
  .io_w_cs(io_w_cs), .io_r_cs(io_r_cs),
  .user1_cs(user1_cs), .in0_cs(in0_cs),
  .bank_vram_hide()
);

mcpu u_mcpu(
  .clk_sys  ( clk_sys ),
  .reset    ( cpu_hold ),
  .irq_n    ( irq_n ),
  .vblank   ( vblank ),
  .ready    ( cpu_run ),
  .io0_data ( in0 ),
  .io1_data ( {7'd0, tilt} ),
  .cpu_ab   ( m_ab ),
  .cpu_din  ( m_din ),
  .cpu_dout ( m_dout ),
  .rw       ( m_rw ),
  .bank_en  ( bank_en ),
  .sync     ( m_sync )
);

// -------- Work RAM --------
// Synchronous BRAM. The address is stable for a whole 24-clock CPU cycle and
// CPU16 latches DI on its clock enable, so the one-cycle read latency is
// invisible.
wire [7:0] work_q, work2_q;

bram_sp #(.DW(8), .AW(12)) u_work (
  .clk(clk_sys), .addr(m_ab[11:0]), .din(m_dout),
  .we(work_cs && !m_rw && cpu_run), .dout(work_q)
);

bram_sp #(.DW(8), .AW(11)) u_work2 (
  .clk(clk_sys), .addr(m_ab[10:0]), .din(m_dout),
  .we(work2_cs && !m_rw && cpu_run), .dout(work2_q)
);

// -------- Program ROM --------
// $1000-$3FFF mirrors maincpu[$9000..]; the bank view maps $4000-$7FFF to user1
wire [15:0] main_cpu_off =
  mir_cs   ? (16'h9000 + (m_ab - 16'h1000)) :
  user1_cs ? (m_ab - 16'h4000) :
             m_ab;

wire        main_rom_cs = (main_cs || mir_cs || user1_cs);
wire [7:0]  main_bram_q;
wire [7:0]  user1_cpu_q;
wire [7:0]  main_rom_q = user1_cs ? user1_cpu_q : main_bram_q;

// init_prosport / init_yellowcb nibble-swap the whole 64K maincpu region
wire [7:0] ioctl_sw   = { ioctl_dout[3:0], ioctl_dout[7:4] };
reg        ioctl_wr_d;
always @(posedge clk_sys) ioctl_wr_d <= ioctl_wr;
wire       ioctl_stb  = ioctl_download && ioctl_wr && !ioctl_wr_d;

wire in_main  = (ioctl_addr < MAIN_SIZE);
wire in_audio = (ioctl_addr >= AUDIO_BASE) && (ioctl_addr < AUDIO_BASE + AUDIO_SIZE);

bram_sdp #(.DW(8), .AW(16)) u_main_rom (
  .clk(clk_sys),
  .wr_addr(ioctl_addr[15:0]), .wr_din(ioctl_sw), .wr_en(ioctl_stb && in_main),
  .rd_addr(main_cpu_off), .rd_dout(main_bram_q)
);

// -------- Audio CPU --------
wire [15:0] a_ab;
wire        a_rw;
wire [7:0]  a_dout, a_din_c;
wire        a_irq_n, a_nmi_n, a_sync;
wire [7:0]  a_rom_q;
wire [12:0] a_rom_off = a_ab[12:0];   // $E000-$FFFF -> 8K

wire [26:0] audio_off = ioctl_addr - AUDIO_BASE[26:0];

bram_sdp #(.DW(8), .AW(13)) u_audio_rom (
  .clk(clk_sys),
  .wr_addr(audio_off[12:0]), .wr_din(ioctl_dout), .wr_en(ioctl_stb && in_audio),
  .rd_addr(a_rom_off), .rd_dout(a_rom_q)
);

acpu u_acpu(
  .clk_sys(clk_sys), .reset(cpu_hold),
  .irq_n(a_irq_n), .nmi_n(a_nmi_n), .ready(cpu_run),
  .cpu_ab(a_ab), .cpu_din(a_din_c), .cpu_dout(a_dout), .rw(a_rw), .sync(a_sync)
);

wire snd_latch_wr = io_w_cs && (m_ab[3:0] == 4'd9) && !m_rw && cpu_run;

sound u_sound(
  .clk_sys(clk_sys), .reset(cpu_hold),
  .latch_wr(snd_latch_wr), .latch_din(m_dout),
  .cpu_ab(a_ab), .cpu_dout(a_dout), .cpu_din(a_din_c), .rw(a_rw),
  .irq_n(a_irq_n), .nmi_n(a_nmi_n),
  .rom_data(a_rom_q),
  .audio_l(audio_l), .audio_r(audio_r)
);

// -------- Video --------
wire [7:0] color_dout, video_dout, sprite_dout;
reg        prom_wr;
reg  [4:0] prom_addr;
reg  [7:0] prom_data;

always @(posedge clk_sys) begin
  prom_wr <= 1'b0;
  if (ioctl_stb && ioctl_addr >= PROM_BASE && ioctl_addr < PROM_BASE + PROM_SIZE) begin
    prom_wr   <= 1'b1;
    prom_addr <= ioctl_addr[4:0];
    prom_data <= ioctl_dout;
  end
end

video u_video(
  .clk_sys(clk_sys), .reset(reset),
  .cpu_ab(m_ab), .cpu_dout(m_dout), .rw(m_rw || !cpu_run),
  .color_cs(color_cs), .video_cs(video_cs), .sprite_cs(sprite_cs),
  .io_ram0(io_ram[0]), .io_ram1(io_ram[1]),
  .io_ram2(io_ram[2]), .io_ram3(io_ram[3]),
  .io_ram4(io_ram[4]), .io_ram5(io_ram[5]),
  .io_ram6(io_ram[6]),
  .ioctl_download(ioctl_download),
  .ioctl_addr(ioctl_addr),
  .ioctl_dout(ioctl_dout),
  .ioctl_wr(ioctl_wr),
  .user1_cpu_addr(main_cpu_off[13:0]),
  .user1_cpu_q(user1_cpu_q),
  .hb(hb), .vb(vb), .hs(hs), .vs(vs), .ce_pix(ce_pix),
  .red(red), .green(green), .blue(blue),
  .prom_wr(prom_wr), .prom_addr(prom_addr), .prom_data(prom_data),
  .color_dout(color_dout), .video_dout(video_dout), .sprite_dout(sprite_dout)
);

// -------- IO write / coin IRQ --------
wire vb_rise;
reg  vb_d;
always @(posedge clk_sys) vb_d <= vb;
assign vb_rise = vb & ~vb_d;

always @(posedge clk_sys) begin
  if (reset) begin
    irq_n <= 1'b1;
    coin_latch <= 1'b0;
    for (int i = 0; i < 16; i++) io_ram[i] <= 8'd0;
  end else begin
    if (io_w_cs && !m_rw && cpu_run) begin
      io_ram[m_ab[3:0]] <= m_dout;
      if (m_ab[3:0] == 4'd8)   // deco16_io_w case 8: IRQ ack
        irq_n <= 1'b1;
    end
    // MAME deco16_interrupt, on the VBLANK rising edge
    if (vb_rise) begin
      if ( ((~p3) & 8'h43) != 8'h00 && !coin_latch ) begin
        irq_n <= 1'b0;
        coin_latch <= 1'b1;
      end else if ( ((~p3) & 8'h43) == 8'h00 )
        coin_latch <= 1'b0;
    end
  end
end

// deco16_io_r
wire [7:0] io_r_data =
  (m_ab[3:0] == 4'd0) ? p1  :
  (m_ab[3:0] == 4'd1) ? p2  :
  (m_ab[3:0] == 4'd2) ? p3  :
  (m_ab[3:0] == 4'd3) ? dsw1:
  (m_ab[3:0] == 4'd4) ? dsw2: 8'hFF;

// Banked IO reads must win over main ROM at $8000-$800F.
assign m_din =
  io_r_cs     ? io_r_data :
  work_cs     ? work_q :
  work2_cs    ? work2_q :
  color_cs    ? color_dout :
  video_cs    ? video_dout :
  sprite_cs   ? sprite_dout :
  in0_cs      ? in0 :
  main_rom_cs ? main_rom_q :
  8'hFF;

wire _unused_sync = m_sync & a_sync;

endmodule
