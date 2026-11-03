//============================================================================
// Yellow Cab / Kamikaze Cabbie core bus
// Maps: liberate_map + kamikcab_io_map + yellowcb $A000 IN0
//
// The normalized region map reserves maincpu 64K, audiocpu 16K, gfx1 72K,
// gfx2 32K, user1 16K and PROM 32B. Smaller sets are padded by their MRA so all
// Liberation-family variants share these offsets. The universal wrapper keeps
// the shared main program bank in cached SDRAM; latency-sensitive graphics,
// auxiliary ROM, writable RAM and the video pipeline remain in local M10Ks.
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

  // Hi-score port: while hs_active the CPU is paused and this port drives the main bus
  input             hs_active,
  input      [15:0] hs_addr,
  input             hs_wr,
  input       [7:0] hs_wdata,
  output      [7:0] hs_rdata,

  input       [7:0] game_variant,
  input       [7:0] game_flags,

  input             ioctl_download,
  input      [26:0] ioctl_addr,
  input       [7:0] ioctl_dout,
  input             ioctl_wr,

  output     [15:0] ext_main_addr,
  input       [7:0] ext_main_data,
  output            ext_main_req,
  input             ext_main_ready,
  output     [15:0] ext_aux_addr,
  input       [7:0] ext_aux_data,

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

// Hi-score bus inputs are registered locally: keeps the bus-mux select short and close to its loads.
reg        hs_active_q;
reg [15:0] hs_addr_q;
reg        hs_wr_q;
reg  [7:0] hs_wdata_q;
always @(posedge clk_sys) begin
  hs_active_q <= hs_active;
  hs_addr_q   <= hs_addr;
  hs_wr_q     <= hs_wr;
  hs_wdata_q  <= hs_wdata;
end

// -------- IO regs --------
reg [7:0] io_ram [0:15];
reg       irq_n = 1'b1;
reg       coin_latch = 1'b0;
wire      is_prosport = (game_variant == 8'h03);
// Yellow Cab/Kamikaze Cabbie replaces the generic TILT port with an entirely
// unused input in MAME, matching its cabinet wiring. Other family variants
// retain the active-high $02 tilt bit.
wire      pcb_tilt = (game_variant == 8'h00) ? 1'b0 : tilt;

wire vblank = vb;
// MAME yellowcb IN0: bit2 = VBLANK (IP_ACTIVE_HIGH), rest IPT_UNKNOWN ACTIVE_HIGH
wire [7:0] in0 = {5'b00000, vblank, 2'b00};

// -------- Main CPU --------
wire [15:0] cpu_m_ab;
wire [7:0]  cpu_m_dout, m_din;
wire        cpu_m_rw;
wire        bank_en, m_sync;
wire [15:0] m_ab   = hs_active_q ? hs_addr_q   : cpu_m_ab;
wire [7:0]  m_dout = hs_active_q ? hs_wdata_q  : cpu_m_dout;
wire        m_rw   = hs_active_q ? ~hs_wr_q    : cpu_m_rw;
reg [7:0] hs_rdata_r;
always @(posedge clk_sys) hs_rdata_r <= m_din;   // registered: cuts the CPU->bus->hiscore timing path
assign hs_rdata = hs_rdata_r;

wire work_cs, mir_cs, color_cs, video_cs, sprite_cs, work2_cs;
wire main_cs, io_w_cs, io_r_cs, user1_cs, in0_cs;
wire pro_ram_cs, pro_palette_cs, pro_bg_cs, pro_char_cs;

// CPUs are held during download; `pause` freezes them without resetting.
wire cpu_hold = reset | ioctl_download;
wire cpu_run       = ~pause;
wire main_cpu_run  = cpu_run && ext_main_ready;

io_map u_map(
  .addr(m_ab), .rw(m_rw), .bank_en(bank_en && !hs_active_q),   // hi-score reads see RAM, as MAME reads with the I/O view closed
  .yellow_in0_override(game_variant == 8'h00),
  .prosport(is_prosport),
  .work_cs(work_cs), .mir_cs(mir_cs),
  .color_cs(color_cs), .video_cs(video_cs), .sprite_cs(sprite_cs),
  .work2_cs(work2_cs), .main_cs(main_cs),
  .io_w_cs(io_w_cs), .io_r_cs(io_r_cs),
  .user1_cs(user1_cs), .in0_cs(in0_cs),
  .bank_vram_hide(),
  .pro_ram_cs(pro_ram_cs), .pro_palette_cs(pro_palette_cs),
  .pro_bg_cs(pro_bg_cs), .pro_char_cs(pro_char_cs)
);

mcpu u_mcpu(
  .clk_sys  ( clk_sys ),
  .reset    ( cpu_hold ),
  .irq_n    ( irq_n ),
  .nmi_n    ( 1'b1 ),     // MAME liberate/prosport maincpu has no NMI source
  .vblank   ( vblank ),
  .ready    ( main_cpu_run ),
  .opcode_decrypt( game_flags[1] ),
  .bank_bit2( game_flags[2] ),
  .io0_data ( in0 ),
  // MAME's generic Liberation-family TILT port is active-high at bit 1
  // (mask $02). Preserve that PCB input bit; bit 0 is unconnected.
  .io1_data ( {6'd0, pcb_tilt, 1'b0} ),
  .cpu_ab   ( cpu_m_ab ),
  .cpu_din  ( m_din ),
  .cpu_dout ( cpu_m_dout ),
  .rw       ( cpu_m_rw ),
  .bank_en  ( bank_en ),
  .sync     ( m_sync )
);

// -------- Work RAM --------
// Synchronous BRAM. The address is stable for a whole 24-clock CPU cycle and
// CPU16 latches DI on its clock enable, so the one-cycle read latency is
// invisible.
wire [7:0] base_ram_q, work2_q;

// The ordinary $0000-$0fff work RAM and Pro Sports' folded base RAM are
// selected by mutually exclusive game variants and use the same physical
// address. Keep one bank instead of reserving two 4 KiB M10K memories.
bram_sp #(.DW(8), .AW(12)) u_base_ram (
  .clk(clk_sys), .addr(m_ab[11:0]), .din(m_dout),
  .we((work_cs || pro_ram_cs) && !m_rw && (cpu_run || hs_active_q)), .dout(base_ram_q)
);

bram_sp #(.DW(8), .AW(11)) u_work2 (
  .clk(clk_sys), .addr(m_ab[10:0]), .din(m_dout),
  .we(work2_cs && !m_rw && (cpu_run || hs_active_q)), .dout(work2_q)
);

// Pro Sports folds $0000-$03ff through $2000-$23ff and continues with RAM at
// $2400-$2fff. Mapping both windows onto m_ab[11:0] reproduces that mirror.

// -------- Program ROM --------
// $1000-$3FFF mirrors maincpu[$9000..]; the bank view maps $4000-$7FFF to user1
wire [15:0] main_cpu_off =
  is_prosport ? m_ab :
  mir_cs   ? (16'h9000 + (m_ab - 16'h1000)) :
  user1_cs ? (m_ab - 16'h4000) :
             m_ab;

wire        main_rom_cs = (main_cs || mir_cs || user1_cs);
assign ext_main_req = main_rom_cs && m_rw;
wire [7:0]  main_bram_q = ext_main_data;
wire [7:0]  user1_cpu_q;
wire [7:0]  main_rom_q = user1_cs ? user1_cpu_q : main_bram_q;
assign ext_main_addr = main_cpu_off;

wire       ioctl_stb  = ioctl_download && ioctl_wr;

// -------- Audio CPU --------
wire [15:0] a_ab;
wire        a_rw;
wire [7:0]  a_dout, a_din_c;
wire        a_irq_n, a_nmi_n, a_sync;
wire [7:0]  a_rom_q = ext_aux_data;
wire [13:0] a_rom_off = a_ab[13:0];   // $C000-$FFFF -> normalized 16K
assign ext_aux_addr = {2'b00, a_rom_off};

acpu u_acpu(
  .clk_sys(clk_sys), .reset(cpu_hold),
  .irq_n(a_irq_n), .nmi_n(a_nmi_n), .ready(cpu_run),
  .slow_clock(is_prosport),
  .cpu_ab(a_ab), .cpu_din(a_din_c), .cpu_dout(a_dout), .rw(a_rw), .sync(a_sync)
);

wire snd_latch_wr = io_w_cs &&
                    (m_ab[3:0] == (is_prosport ? 4'd2 : 4'd9)) &&
                    !m_rw && cpu_run;

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
wire [7:0] pro_palette_dout, pro_bg_dout, pro_char_dout;
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
  .game_variant(game_variant),
  .cpu_ab(m_ab), .cpu_dout(m_dout), .rw(m_rw || !cpu_run),
  .color_cs(color_cs), .video_cs(video_cs), .sprite_cs(sprite_cs),
  .pro_palette_cs(pro_palette_cs), .pro_bg_cs(pro_bg_cs),
  .pro_char_cs(pro_char_cs),
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
  .color_dout(color_dout), .video_dout(video_dout), .sprite_dout(sprite_dout),
  .pro_palette_dout(pro_palette_dout), .pro_bg_dout(pro_bg_dout),
  .pro_char_dout(pro_char_dout)
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
      if (m_ab[3:0] == (is_prosport ? 4'd4 : 4'd8))
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
  pro_palette_cs ? pro_palette_dout :
  pro_bg_cs   ? pro_bg_dout :
  pro_char_cs ? pro_char_dout :
  (pro_ram_cs || work_cs) ? base_ram_q :
  work2_cs    ? work2_q :
  color_cs    ? color_dout :
  video_cs    ? video_dout :
  sprite_cs   ? sprite_dout :
  in0_cs      ? in0 :
  main_rom_cs ? main_rom_q :
  8'hFF;

wire _unused_sync = m_sync & a_sync & ^game_variant;

endmodule
