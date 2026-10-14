// -----------------------------------------------------------------------------
// williams_adpcm.sv
//
// Williams ADPCM sound board (Midway Y-Unit), as used by Total Carnage / Mortal
// Kombat / NBA Jam. Reproduces MAME's williams_adpcm_sound_device
// (src/mame/shared/williamssound.cpp):
//
//   MC6809E @ 8MHz/4 = 2MHz (E clock)    -- cavnex mc6809e, negedge-E clocked
//   8 KiB RAM                             0x0000-0x1fff
//   ROM bank select (0..7)                0x2000 (mirror 0x03ff)
//   YM2151 (jt51) @ 3.579545 MHz          0x2400-0x2401 (mirror 0x03fe)
//   AD7524 DAC (8-bit)                    0x2800 (mirror 0x03ff)
//   OKI MSM6295 (jt6295) @ 8MHz/8 = 1MHz  0x2c00 (mirror 0x03ff)
//   command_r (host latch, clears IRQ)    0x3000 (mirror 0x03ff)
//   OKI bank select (0..7)                0x3400 (mirror 0x03ff)
//   talkback                              0x3c00 (mirror 0x03ff)
//   banked ROM window (0x8000, bank 0..7) 0x4000-0xbfff  (rom[0x10000]+bank*0x8000)
//   fixed upper ROM (0x4000)              0xc000-0xffff  (rom[0x4c000])
//
//   Host sound write (adpcm_sound_w @0x01e00000, 16-bit): reset_write(~data[8])
//   then write(data). The board latches data[7:0] as the command; data[8]=1 runs
//   the CPU / =0 holds it in reset (and clears IRQ + rombank); data[9]=0 asserts
//   the 6809 IRQ (a command has arrived). command_r (read of 0x3000) clears the
//   IRQ; the main-CPU-visible sound_int_state lingers ~10us afterwards so the
//   host self-test can observe it (MAME irq_clear timer).
//
//   YM2151 IRQ -> 6809 FIRQ.  OKI/DAC/YM mix per MAME: YM 0.10, DAC 0.10, OKI 0.15.
//
// Clocking mirrors williams_cvsd.sv: E/Q quadrature ~2MHz from clk_sys; the rest
// of the board on clk_sys with an e_fall access strobe. The sound-CPU ROM is an
// internal BRAM (SND_ROM_HEX) in sim / SDRAM-backed (EXTERNAL_SND_ROM) on hw.
// The OKI sample ROM is an internal BRAM (OKI_ROM_HEX) in sim / SDRAM on hw; when
// neither is provided the OKI reads 0 (silence) but the 6809 still boots.
// -----------------------------------------------------------------------------

`default_nettype none
module williams_adpcm #(
  parameter        CLK_SYS_HZ   = 24_162_000,
  parameter        SND_ROM_HEX  = "",     // sim: $readmemh sound-CPU region (0x50000 bytes)
  parameter        OKI_ROM_HEX  = "",     // sim: $readmemh OKI region (0x100000 bytes)
  parameter        EXTERNAL_SND_ROM = 0,  // hw: route CPU-ROM reads to an SDRAM port
  parameter [24:1] SND_WORD_BASE    = 24'h500000,  // SDRAM word base of the sound-CPU ROM
  parameter        EXTERNAL_OKI_ROM = 0,  // hw: route OKI sample reads to an SDRAM port
  parameter [24:1] OKI_WORD_BASE    = 24'h540000,  // SDRAM word base of the OKI ROM
  parameter        SS_PIN7          = 1'b1 // OKI PIN7 (MAME PIN7_HIGH -> /132 rate)
) (
  input  wire        clk,        // clk_sys
  input  wire        rst,        // system reset (async board reset)

  // host (main TMS34010) sound command latch: [7:0]=data, [8]=~reset, [9]=~irq
  input  wire [9:0]  cmd,
  input  wire        cmd_stb,    // 1-cycle strobe: new command written

  output reg  [7:0]  talkback,
  output wire        snd_int_state,   // -> main CPU IN1 bit 0x4000 (adpcm_irq_state_r)

  // audio (signed 16-bit)
  output wire signed [15:0] audio_l,
  output wire signed [15:0] audio_r,

  // Sound-CPU-ROM SDRAM read port (used only when EXTERNAL_SND_ROM=1). The 6809's
  // E-clock is wait-stated until the requested ROM word is available.
  output reg         snd_rom_req,
  output reg  [24:1] snd_rom_addr,
  input  wire [15:0] snd_rom_dout,
  input  wire        snd_rom_ack,

  // OKI-sample-ROM SDRAM read port (used only when EXTERNAL_OKI_ROM=1). The OKI
  // stalls (rom_ok low) until the requested sample word arrives.
  output reg         oki_rom_req,
  output reg  [24:1] oki_rom_addr,
  input  wire [15:0] oki_rom_dout,
  input  wire        oki_rom_ack,

  // live debug
  output wire        dbg_run,
  output wire        dbg_stall
);
  reg [20:0] dbg_ecnt;
  assign dbg_run = dbg_ecnt[20];

  // ---------------------------------------------------------------------------
  // Board reset: system rst OR the host-controlled reset line (~cmd[8]). Held
  // reset at power-on until the host releases it (first command with bit8=1).
  // ---------------------------------------------------------------------------
  reg cmd_reset;     // 1 = 6809 held in reset (MAME reset_write high)
  initial cmd_reset = 1'b1;
  wire snd_rst = rst | cmd_reset;

  // ---------------------------------------------------------------------------
  // E / Q clock generation: ~2.014 MHz (clk_sys / EDIV), quadrature (Q leads E).
  // ---------------------------------------------------------------------------
  localparam int EDIV = (CLK_SYS_HZ + 1_007_000) / 2_014_000;
  reg [4:0] ephase = 0;
  wire rom_stall;
  always_ff @(posedge clk) if (!rom_stall) ephase <= (ephase==EDIV-1) ? 5'd0 : ephase + 5'd1;
  wire E = (ephase < EDIV/2);
  wire Q = (ephase >= (3*EDIV)/4) || (ephase < EDIV/4);
  reg E_r; always_ff @(posedge clk) E_r <= E;
  wire e_fall = E_r & ~E;

  // ---------------------------------------------------------------------------
  // 6809 core (cavnex mc6809e)
  // ---------------------------------------------------------------------------
  wire [15:0] cpu_addr;
  wire [7:0]  cpu_dout;
  wire        cpu_rnw;
  reg  [7:0]  cpu_din;
  wire        cpu_nreset = ~snd_rst;
  wire        cmd_irq_n;     // command IRQ (active-low to 6809 nIRQ)
  wire        ym_irq_n;      // YM2151 IRQ  (active-low to 6809 nFIRQ)

  mc6809e u_cpu (
    .D(cpu_din), .DOut(cpu_dout), .ADDR(cpu_addr), .RnW(cpu_rnw),
    .E(E), .Q(Q),
    .BS(), .BA(),
    .nIRQ(cmd_irq_n), .nFIRQ(ym_irq_n), .nNMI(1'b1),
    .AVMA(), .BUSY(), .LIC(),
    .nHALT(1'b1), .nRESET(cpu_nreset)
  );

  reg [15:0] addr_r; reg [7:0] dout_r; reg rnw_r;
  always_ff @(posedge clk) begin addr_r <= cpu_addr; dout_r <= cpu_dout; rnw_r <= cpu_rnw; end

  // ---------------------------------------------------------------------------
  // Address decode. Peripherals live at 0x2000-0x3fff (a[15:13]==001), one 0x400
  // block each (a[12:10]): 0 bank, 1 YM, 2 DAC, 3 OKI, 4 command, 5 okibank,
  // 7 talkback. RAM 0x0000-0x1fff (a[15:13]==000). ROM: 0x4000-0xbfff banked,
  // 0xc000-0xffff fixed upper.
  // ---------------------------------------------------------------------------
  function automatic logic sel_ram (input [15:0] a); sel_ram = (a[15:13]==3'b000); endfunction
  function automatic logic sel_per (input [15:0] a); sel_per = (a[15:13]==3'b001); endfunction
  function automatic logic sel_rlo (input [15:0] a); sel_rlo = (a[15:14]==2'b01) || (a[15:13]==3'b100); endfunction // 0x4000-0xbfff
  function automatic logic sel_rhi (input [15:0] a); sel_rhi = (a[15:14]==2'b11); endfunction                       // 0xc000-0xffff
  wire [2:0] per_blk = addr_r[12:10];
  wire [2:0] per_blk_l = cpu_addr[12:10];
  wire wr = e_fall & ~rnw_r;
  wire rd = e_fall &  rnw_r;
  assign dbg_stall = rom_stall;
  always_ff @(posedge clk) if (e_fall) dbg_ecnt <= dbg_ecnt + 21'd1;

  // ---------------------------------------------------------------------------
  // 8 KiB work RAM
  // ---------------------------------------------------------------------------
  (* ramstyle="M10K" *) reg [7:0] ram [0:8191];
  reg [7:0] ram_q;
  always_ff @(posedge clk) begin
    if (wr && sel_ram(addr_r)) ram[addr_r[12:0]] <= dout_r;
    ram_q <= ram[cpu_addr[12:0]];
  end

  // ---------------------------------------------------------------------------
  // "Hidden RAM" -- MAME install_hidden_ram(sound_cpu, 0xFC04, 0xFC2E): 43 bytes
  // of writable RAM overlaying the upper ROM in the 6809 program space (the sound
  // code uses it as protection/scratch RAM). Reads/writes here hit RAM, not ROM.
  // ---------------------------------------------------------------------------
  localparam [15:0] HR_LO = 16'hFC04, HR_HI = 16'hFC2E;
  function automatic logic sel_hram(input [15:0] a); sel_hram = (a >= HR_LO) && (a <= HR_HI); endfunction
  reg [7:0] hidden_ram [0:63];
  reg [7:0] hram_q;
  wire [5:0] hr_widx = 6'(addr_r  - HR_LO);
  wire [5:0] hr_ridx = 6'(cpu_addr - HR_LO);
  always_ff @(posedge clk) begin
    if (wr && sel_hram(addr_r)) hidden_ram[hr_widx] <= dout_r;
    hram_q <= hidden_ram[hr_ridx];
  end

  // ---------------------------------------------------------------------------
  // Bank registers
  //   rombank (0x2000, data&7) selects the 0x8000 CPU-ROM window at 0x4000-0xbfff
  //   okibank (0x3400, data&7) selects the OKI 0x20000 sample window
  // A host reset (cmd_reset) forces rombank=0 (MAME reset_write -> bank_select_w(0)).
  // ---------------------------------------------------------------------------
  reg [2:0] rombank, okibank;
  always_ff @(posedge clk) begin
    if (snd_rst) rombank <= 3'd0;
    else if (wr && sel_per(addr_r) && per_blk==3'd0) rombank <= dout_r[2:0];
  end
  always_ff @(posedge clk) begin
    if (rst) okibank <= 3'd0;
    else if (wr && sel_per(addr_r) && per_blk==3'd5) okibank <= dout_r[2:0];
  end

  // CPU-ROM byte address into the 0x50000 region.
  //   banked window (0x4000-0xbfff): 0x10000 + bank*0x8000 + (a-0x4000)
  //   fixed upper   (0xc000-0xffff): 0x4c000 + (a-0xc000)   (== bank7 upper 0x4000)
  // The banked stride is 0x8000 (rombank<<15) and the window offset must use the
  // FULL 16-bit cpu_addr (the window is 0x8000 wide, spanning bit 15). A prior
  // adaptation from the CVSD board (whose window starts at 0x8000) used <<13 and
  // dropped bit 15 -> every bank!=0 and every 0x8000-0xbfff access read the wrong
  // ROM byte, corrupting the banked sound driver + OKI dispatch (YM played from
  // the correct fixed region, but OKI/samples never triggered).
  wire [18:0] crom_addr = sel_rhi(cpu_addr)
      ? (19'h4c000 + {5'd0, cpu_addr[13:0]})
      : (19'h10000 + {1'd0, rombank, 15'd0} + {3'd0, cpu_addr} - 19'h4000);

  reg [7:0] crom_q;
  generate if (EXTERNAL_SND_ROM == 0) begin : g_introm
    (* ramstyle="M10K" *) reg [7:0] crom [0:327679];   // 0x50000
    initial if (SND_ROM_HEX != "") $readmemh(SND_ROM_HEX, crom);
    always_ff @(posedge clk) crom_q <= crom[crom_addr];
    assign rom_stall = 1'b0;
    always_ff @(posedge clk) begin snd_rom_req <= 1'b0; snd_rom_addr <= '0; end
  end else begin : g_extrom
    // 64-entry direct-mapped word cache to SDRAM (mirrors williams_cvsd EXTROM).
    wire [17:0] want_w    = crom_addr[18:1];
    wire [5:0]  ci        = want_w[5:0];
    wire        rom_access = sel_rlo(cpu_addr) || sel_rhi(cpu_addr);
    reg  [15:0] cdata [0:63];
    reg  [11:0] ctag  [0:63];
    reg  [63:0] cval;
    reg         fetching;
    reg  [5:0]  fill_ci;
    wire        rom_hit = cval[ci] && (ctag[ci] == want_w[17:6]);
    wire [15:0] hitw    = cdata[ci];
    // req is HELD (not a 1-cycle pulse) until its ack. The 6809 CPU-ROM and the
    // OKI sample ROM share ONE arbitrated SDRAM channel; a 1-cycle pulse is LOST
    // if the arbiter is busy with the other requester when it fires -> the cache
    // stalls (fetching stuck) -> rom_stall never clears -> the 6809 HANGS. In-game
    // the OKI runs constantly, so contention is frequent -> hang -> silence. Holding
    // the req guarantees the arbiter eventually serves it.
    always_ff @(posedge clk) begin
      if (rst) begin cval <= '0; fetching <= 1'b0; snd_rom_req <= 1'b0; end
      else if (!fetching && !rom_hit && rom_access) begin
        snd_rom_req  <= 1'b1;
        snd_rom_addr <= SND_WORD_BASE + {6'd0, want_w};
        fill_ci      <= ci;
        fetching     <= 1'b1;
      end else if (fetching && snd_rom_ack) begin
        cdata[fill_ci] <= snd_rom_dout;
        ctag[fill_ci]  <= want_w[17:6];
        cval[fill_ci]  <= 1'b1;
        fetching       <= 1'b0;
        snd_rom_req    <= 1'b0;
      end
      crom_q <= crom_addr[0] ? hitw[15:8] : hitw[7:0];
    end
    assign rom_stall = (sel_rlo(cpu_addr) || sel_rhi(cpu_addr)) && !rom_hit;
  end endgenerate

  // ---------------------------------------------------------------------------
  // Host command latch + 6809 IRQ + main-CPU-visible sound_int_state
  // ---------------------------------------------------------------------------
  reg  [7:0] cmd_latch;
  reg        irq_active;       // 6809 IRQ line
  reg        int_state;        // main-CPU-visible (lingers ~10us after command_r)
  reg [12:0] int_clr_cnt;      // ~10us @ clk_sys down-counter (0 = idle)
  localparam int INT_CLR_CYC = (CLK_SYS_HZ / 100_000);   // 10 us

  wire cmd_r_read = rd && sel_per(addr_r) && per_blk==3'd4;   // read of 0x3000

  always_ff @(posedge clk) begin
    if (rst) begin
      cmd_latch<=8'h00; irq_active<=1'b0; int_state<=1'b0; int_clr_cnt<=0; cmd_reset<=1'b1;
    end else begin
      if (cmd_stb) begin
        cmd_reset <= ~cmd[8];               // reset_write(~data[8])
        cmd_latch <= cmd[7:0];              // sync_command: latch = data & 0xff
        if (~cmd[8]) begin                  // reset asserted -> device_reset()
          irq_active <= 1'b0; int_state <= 1'b0; int_clr_cnt <= 0;
        end else if (~cmd[9]) begin         // !(data & 0x200) -> assert IRQ
          irq_active <= 1'b1; int_state <= 1'b1; int_clr_cnt <= 0;
        end
      end
      if (cmd_r_read) begin
        irq_active  <= 1'b0;                // command_r clears the 6809 IRQ now
        int_clr_cnt <= INT_CLR_CYC[12:0];   // int_state clears ~10us later
      end
      if (int_clr_cnt != 0) begin
        int_clr_cnt <= int_clr_cnt - 13'd1;
        if (int_clr_cnt == 13'd1) int_state <= 1'b0;
      end
    end
  end
  assign cmd_irq_n = ~irq_active;
  assign snd_int_state = int_state;

  // ---------------------------------------------------------------------------
  // AD7524 DAC (8-bit) at 0x2800
  // ---------------------------------------------------------------------------
  reg [7:0] dac_val;
  always_ff @(posedge clk) begin
    if (rst) dac_val <= 8'h80;
    else if (wr && sel_per(addr_r) && per_blk==3'd2) dac_val <= dout_r;
  end

  // ---------------------------------------------------------------------------
  // talkback at 0x3c00
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) talkback <= 8'h00;
    else if (wr && sel_per(addr_r) && per_blk==3'd7) talkback <= dout_r;
  end

  // ---------------------------------------------------------------------------
  // YM2151 (jt51) @ 3.579545 MHz  (0x2400/0x2401)
  // ---------------------------------------------------------------------------
  localparam YM_HZ = 3_579_545;
  reg [31:0] cen_acc; reg cen_ym; reg cen_p1_tgl; wire cen_p1 = cen_ym & cen_p1_tgl;
  always_ff @(posedge clk) begin
    if (cen_acc + YM_HZ >= CLK_SYS_HZ) begin cen_acc <= cen_acc + YM_HZ - CLK_SYS_HZ; cen_ym <= 1'b1; end
    else                               begin cen_acc <= cen_acc + YM_HZ;             cen_ym <= 1'b0; end
    if (cen_ym) cen_p1_tgl <= ~cen_p1_tgl;
  end
  reg ym_req; reg ym_a0_r; reg [7:0] ym_din_r;
  always_ff @(posedge clk) begin
    if (wr && sel_per(addr_r) && per_blk==3'd1) begin ym_req<=1'b1; ym_a0_r<=addr_r[0]; ym_din_r<=dout_r; end
    else if (ym_req && cen_ym) ym_req <= 1'b0;
  end
  wire ym_cs_n = ~(ym_req & cen_ym);
  wire ym_wr_n = ~(ym_req & cen_ym);
  wire [7:0] ym_dout;
  wire signed [15:0] ym_l, ym_r;
  jt51 u_ym (
    .rst(snd_rst), .clk(clk), .cen(cen_ym), .cen_p1(cen_p1),
    .cs_n(ym_cs_n), .wr_n(ym_wr_n), .a0(ym_a0_r), .din(ym_din_r), .dout(ym_dout),
    .ct1(), .ct2(), .irq_n(ym_irq_n),
    .sample(), .left(), .right(), .xleft(ym_l), .xright(ym_r)
  );

  // ---------------------------------------------------------------------------
  // OKI MSM6295 (jt6295) @ 1 MHz  (0x2c00). CPU/ROM interfaces run at full speed
  // (no cen), sound engine at cen_oki.
  // ---------------------------------------------------------------------------
  localparam OKI_HZ = 1_000_000;
  reg [31:0] ocen_acc; reg cen_oki;
  always_ff @(posedge clk) begin
    if (ocen_acc + OKI_HZ >= CLK_SYS_HZ) begin ocen_acc <= ocen_acc + OKI_HZ - CLK_SYS_HZ; cen_oki <= 1'b1; end
    else                                 begin ocen_acc <= ocen_acc + OKI_HZ;             cen_oki <= 1'b0; end
  end
  // one clean write pulse per 6809 OKI write
  reg oki_wr; reg [7:0] oki_din_r;
  always_ff @(posedge clk) begin
    oki_wr <= 1'b0;
    if (wr && sel_per(addr_r) && per_blk==3'd3) begin oki_wr <= 1'b1; oki_din_r <= dout_r; end
  end
  wire        oki_wrn = ~oki_wr;
  wire [7:0]  oki_dout;
  wire [17:0] oki_chip_addr;   // jt6295's 18-bit OKI address (distinct from the SDRAM port)
  wire signed [13:0] oki_snd;

  // OKI sample ROM (region 0x100000). Address = okibank window (0x00000-0x1ffff)
  // or fixed region rom[0x60000] (0x20000-0x3ffff). See MAME williams_adpcm_oki_map
  // + okibank table. Internal BRAM in sim; zero (silence) when no image given.
  reg [7:0] oki_rom_q; wire oki_rom_ok;
  function automatic [19:0] okibank_base(input [2:0] b);
    case (b)
      3'd0: okibank_base = 20'h40000; 3'd1: okibank_base = 20'h40000;
      3'd2: okibank_base = 20'h20000; 3'd3: okibank_base = 20'h00000;
      3'd4: okibank_base = 20'he0000; 3'd5: okibank_base = 20'hc0000;
      3'd6: okibank_base = 20'ha0000; 3'd7: okibank_base = 20'h80000;
      default: okibank_base = 20'h40000;
    endcase
  endfunction
  wire [19:0] oki_byte = oki_chip_addr[17]
      ? (20'h60000 + {3'd0, oki_chip_addr[16:0]})            // 0x20000-0x3ffff fixed
      : (okibank_base(okibank) + {3'd0, oki_chip_addr[16:0]}); // 0x00000-0x1ffff banked
  generate if (EXTERNAL_OKI_ROM) begin : g_okisdram
    // Minimal 1-word cache: the OKI region is 1 MB (0x80000 words). Serve the
    // requested byte from the cached word when its word address matches; else
    // fetch it from SDRAM and hold rom_ok low (jt6295 stalls) until it arrives.
    wire [18:0] want_w = oki_byte[19:1];
    reg  [18:0] cur_w;
    reg  [15:0] cur_d;
    reg         cur_v;
    reg         fetching;
    wire        hit = cur_v && (cur_w == want_w);
    // req HELD until ack (same arbiter lost-fetch fix as the CPU-ROM cache above).
    always_ff @(posedge clk) begin
      if (rst) begin cur_v <= 1'b0; fetching <= 1'b0; oki_rom_req <= 1'b0; end
      else if (!fetching && !hit) begin
        oki_rom_req  <= 1'b1;
        oki_rom_addr <= OKI_WORD_BASE + {5'd0, want_w};
        fetching     <= 1'b1;
      end else if (fetching && oki_rom_ack) begin
        cur_d <= oki_rom_dout; cur_w <= want_w; cur_v <= 1'b1; fetching <= 1'b0;
        oki_rom_req <= 1'b0;
      end
      oki_rom_q <= oki_byte[0] ? cur_d[15:8] : cur_d[7:0];
    end
    assign oki_rom_ok = hit;
  end else if (OKI_ROM_HEX != "") begin : g_okirom
    (* ramstyle="M10K" *) reg [7:0] okirom [0:1048575];   // 0x100000
    initial $readmemh(OKI_ROM_HEX, okirom);
    always_ff @(posedge clk) oki_rom_q <= okirom[oki_byte];
    assign oki_rom_ok = 1'b1;
    always_ff @(posedge clk) begin oki_rom_req <= 1'b0; oki_rom_addr <= '0; end
  end else begin : g_nooki
    always_ff @(posedge clk) oki_rom_q <= 8'h00;
    assign oki_rom_ok = 1'b1;
    always_ff @(posedge clk) begin oki_rom_req <= 1'b0; oki_rom_addr <= '0; end
  end endgenerate

  jt6295 #(.INTERPOL(0)) u_oki (
    .rst(snd_rst), .clk(clk), .cen(cen_oki), .ss(SS_PIN7),
    .wrn(oki_wrn), .din(oki_din_r), .dout(oki_dout),
    .rom_addr(oki_chip_addr), .rom_data(oki_rom_q), .rom_ok(oki_rom_ok),
    .sound(oki_snd), .sample()
  );

  // ---------------------------------------------------------------------------
  // 6809 read data mux (async-read semantics; sources track live ADDR)
  // ---------------------------------------------------------------------------
  always @* begin
    if      (sel_ram(cpu_addr))                          cpu_din = ram_q;
    else if (sel_hram(cpu_addr))                         cpu_din = hram_q;    // hidden RAM overlays upper ROM
    else if (sel_rlo(cpu_addr) || sel_rhi(cpu_addr))     cpu_din = crom_q;
    else if (sel_per(cpu_addr) && per_blk_l==3'd1)       cpu_din = ym_dout;    // YM
    else if (sel_per(cpu_addr) && per_blk_l==3'd3)       cpu_din = oki_dout;   // OKI status
    else if (sel_per(cpu_addr) && per_blk_l==3'd4)       cpu_din = cmd_latch;  // command_r
    else                                                 cpu_din = 8'hff;
  end

  // ---------------------------------------------------------------------------
  // Mixer (MAME routes: YM 0.10, DAC 0.10, OKI 0.15).
  // ---------------------------------------------------------------------------
  wire signed [15:0] dac_s = $signed({1'b0, dac_val, 7'd0}) - 16'sd16384;  // 8-bit unsigned -> signed
  wire signed [15:0] oki_s = {oki_snd, 2'd0};                              // 14-bit -> 16-bit
  // MAME gains: YM 0.10, DAC 0.10, OKI 0.15 -> OKI:YM = 1.5:1. YM=DAC=1/8,
  // OKI=3/16 ((>>3)+(>>4)) gives 3/16 : 2/16 = 1.5:1 (was 5/16 = ~2.5:1, too loud).
  // Mix keeping the MAME 2:2:3 (YM:DAC:OKI) ratio but ~4x louder than before: the
  // old code shifted every source >>3 AND took the [16:1] slice (an extra >>1), so
  // the whole board sat near -30 dBFS (span ~2040) = effectively inaudible. Use the
  // full 16-bit range with saturation instead.
  wire signed [17:0] mixL = (ym_l >>> 2) + (dac_s >>> 2) + (oki_s >>> 2) + (oki_s >>> 3);
  wire signed [17:0] mixR = (ym_r >>> 2) + (dac_s >>> 2) + (oki_s >>> 2) + (oki_s >>> 3);
  assign audio_l = (mixL >  18'sd32767) ?  16'sd32767 :
                   (mixL < -18'sd32768) ? -16'sd32768 : mixL[15:0];
  assign audio_r = (mixR >  18'sd32767) ?  16'sd32767 :
                   (mixR < -18'sd32768) ? -16'sd32768 : mixR[15:0];
endmodule
`default_nettype wire
