// -----------------------------------------------------------------------------
// williams_cvsd.sv
//
// Williams CVSD sound board (Midway Y-Unit), as used by Smash T.V. Reproduces
// MAME's williams_cvsd_sound_device (src/mame/shared/williamssound.cpp):
//
//   MC6809E @ 8MHz/4 = 2MHz (E clock)   -- cavnex mc6809e, negedge-E clocked
//   2 KiB RAM                            0x0000-0x07ff (mirror 0x1800)
//   YM2151 (jt51) @ 3.579545 MHz         0x2000-0x2001 (mirror 0x1ffe)
//   MC6821 PIA                           0x4000-0x4003 (mirror 0x1ffc)
//   HC55516 CVSD (bit-banged)            0x6000 clk0+digit / 0x6800 clk1
//   ROM bank select (0..15)              0x7800
//   banked ROM window                    0x8000-0xffff
//
//   PIA: port A -> MC1408 DAC, port B -> talkback, CA2 -> YM /reset,
//        CA1 <- YM IRQ (inv) -> FIRQ, CB1 <- host cmd strobe -> NMI.
//   Host sound write (10 bits): [7:0]=command -> port B, [8]=CB1, [9]=CB2.
//
// Clocking: E and Q are generated as quadrature ~2MHz clocks from clk_sys; the
// 6809 runs on them, everything else on clk_sys with an e_fall access strobe.
// The sound ROM region (0x90000, U4/U19/U20 laid out per MAME device_start) is
// an internal BRAM preloaded in simulation via SND_ROM_HEX; on hardware it is
// SDRAM-backed (EXTERNAL_SND_ROM, port not yet wired).
//
// Verified by sim/snd/tb_snd_boot.sv (reset-vector fetch + boot + command NMI).
// -----------------------------------------------------------------------------

`default_nettype none
module williams_cvsd #(
  parameter        CLK_SYS_HZ   = 48_324_000,
  parameter        SND_ROM_HEX  = "",     // sim: $readmemh region image (0x90000 bytes)
                                          // (untyped, not `string` -- Quartus 17.1)
  parameter        EXTERNAL_SND_ROM = 0,  // hw: route ROM reads to an SDRAM port
  parameter [24:1] SND_WORD_BASE    = 24'h500000  // SDRAM word base of the sound ROM
) (
  input  wire        clk,        // clk_sys
  input  wire        rst,

  // host (main TMS34010) sound command latch
  input  wire [9:0]  cmd,        // [7:0]=data, [8]=cb1, [9]=cb2
  input  wire        cmd_stb,    // 1-cycle strobe: new command written
  input  wire        snd_rst,    // sound-board reset line (host CONTROL bit)

  output reg  [7:0]  talkback,

  // audio (signed 16-bit)
  output wire signed [15:0] audio_l,
  output wire signed [15:0] audio_r,

  // Sound-ROM SDRAM read port (used only when EXTERNAL_SND_ROM=1). The 6809's
  // E-clock is wait-stated until the requested ROM word is available.
  output reg         snd_rom_req,
  output reg  [24:1] snd_rom_addr,   // word address (SND_WORD_BASE + rom_addr>>1)
  input  wire [15:0] snd_rom_dout,
  input  wire        snd_rom_ack,

  // live debug (for the on-screen sound diagnostic overlay)
  output wire        dbg_run,        // toggles ~0.5 Hz while the 6809 executes
  output wire        dbg_stall       // ROM wait-state active right now
);
  reg [20:0] dbg_ecnt;
  assign dbg_run = dbg_ecnt[20];
  // ---------------------------------------------------------------------------
  // E / Q clock generation: ~2.014 MHz (clk_sys / 24), quadrature (Q leads E).
  // E high for cnt 0..11, Q high for cnt 18..23,0..5 -> negedge Q @6, negedge E
  // @12. Edges align to clk_sys so the rest of the board samples with e_fall.
  // ---------------------------------------------------------------------------
  // E-clock divider derived from the actual clk_sys (rounded): the 6809E runs
  // at ~2.014 MHz. 48.324 MHz -> 24; 24.162 MHz (the halved hardware clk_sys)
  // -> 12. Previously hardcoded 24, which halved the whole sound board when
  // clk_sys was halved for timing closure.
  localparam int EDIV = (CLK_SYS_HZ + 1_007_000) / 2_014_000;
  reg [4:0] ephase = 0;
  // rom_stall (external-ROM wait-state) freezes E/Q so the 6809 waits for SDRAM.
  always_ff @(posedge clk) if (!rom_stall) ephase <= (ephase==EDIV-1) ? 5'd0 : ephase + 5'd1;
  // E high for the first half-period; Q leads E by a quarter period. (Was
  // hardcoded for EDIV=24: E<12, Q>=18||<6 -- generalized to any EDIV.)
  wire E = (ephase < EDIV/2);
  wire Q = (ephase >= (3*EDIV)/4) || (ephase < EDIV/4);
  reg E_r; always_ff @(posedge clk) E_r <= E;
  wire e_fall = E_r & ~E;         // 6809 latched a bus cycle (clk_sys pulse @cnt12)

  // ---------------------------------------------------------------------------
  // 6809 core (cavnex mc6809e)
  // ---------------------------------------------------------------------------
  wire [15:0] cpu_addr;
  wire [7:0]  cpu_dout;
  wire        cpu_rnw;
  reg  [7:0]  cpu_din;
  wire        pia_irqa, pia_irqb;     // -> FIRQ, NMI (active high; core wants active-low)
  wire        cpu_nreset = ~snd_rst;

  mc6809e u_cpu (
    .D(cpu_din), .DOut(cpu_dout), .ADDR(cpu_addr), .RnW(cpu_rnw),
    .E(E), .Q(Q),
    .BS(), .BA(),
    .nIRQ(1'b1), .nFIRQ(~pia_irqa), .nNMI(~pia_irqb),
    .AVMA(), .BUSY(), .LIC(),
    .nHALT(1'b1), .nRESET(cpu_nreset)
  );

  // Registered bus (values from the completing cycle, sampled the clk before e_fall)
  reg [15:0] addr_r; reg [7:0] dout_r; reg rnw_r;
  always_ff @(posedge clk) begin addr_r <= cpu_addr; dout_r <= cpu_dout; rnw_r <= cpu_rnw; end

  // ---------------------------------------------------------------------------
  // Address decode (live ADDR for reads, addr_r for the e_fall write strobe)
  // ---------------------------------------------------------------------------
  function automatic logic sel_ram (input [15:0] a); sel_ram = (a[15:13]==3'b000); endfunction
  function automatic logic sel_ym  (input [15:0] a); sel_ym  = (a[15:13]==3'b001); endfunction
  function automatic logic sel_pia (input [15:0] a); sel_pia = (a[15:13]==3'b010); endfunction
  function automatic logic sel_ctl (input [15:0] a); sel_ctl = (a[15:13]==3'b011); endfunction
  function automatic logic sel_rom (input [15:0] a); sel_rom = a[15]; endfunction
  // within 0x6000-0x7fff: addr[12:11] = 00:cvsd0 01:cvsd1 10:-- 11:bank
  wire wr = e_fall & ~rnw_r;
  assign dbg_stall = rom_stall;
  always_ff @(posedge clk) if (e_fall) dbg_ecnt <= dbg_ecnt + 21'd1;

  // ---------------------------------------------------------------------------
  // 2 KiB work RAM
  // ---------------------------------------------------------------------------
  (* ramstyle="M10K" *) reg [7:0] ram [0:2047];
  reg [7:0] ram_q;
  always_ff @(posedge clk) begin
    if (wr && sel_ram(addr_r)) ram[addr_r[10:0]] <= dout_r;
    ram_q <= ram[cpu_addr[10:0]];
  end

  // ---------------------------------------------------------------------------
  // Bank register + ROM region (internal BRAM for sim)
  //   base = 0x10000 + 0x8000*bank[3:2] + 0x20000*bank[1:0]
  //   rom_addr = base + addr[14:0]
  // ---------------------------------------------------------------------------
  reg [3:0] bank;
  always_ff @(posedge clk) begin
    if (snd_rst) bank <= 4'd0;
    else if (wr && sel_ctl(addr_r) && addr_r[12:11]==2'b11) bank <= dout_r[3:0];
  end
  wire [19:0] rom_addr = 20'h10000
                       + {5'd0,  cpu_addr[14:0]}
                       + {3'd0,  bank[3:2], 15'd0}
                       + {1'd0,  bank[1:0], 17'd0};

  reg [7:0] rom_q;
  logic     rom_stall;      // when high, the E clock is frozen (6809 wait-state)
  generate if (EXTERNAL_SND_ROM == 0) begin : g_introm
    (* ramstyle="M10K" *) reg [7:0] snd_rom [0:589823];   // 0x90000
    initial if (SND_ROM_HEX != "") $readmemh(SND_ROM_HEX, snd_rom);
    always_ff @(posedge clk) rom_q <= snd_rom[rom_addr];
    assign rom_stall = 1'b0;
    always_ff @(posedge clk) begin snd_rom_req <= 1'b0; snd_rom_addr <= '0; end
  end else begin : g_extrom
    // Route ROM reads to SDRAM through a 64-entry direct-mapped word cache
    // (128 bytes). The 6809 fetches are highly sequential/loopy, so this cuts
    // the SDRAM wait-states (the snd channel is lowest priority and stalls
    // under blit contention) to rare cold misses. On a miss the 6809's E clock
    // freezes (rom_stall) until the word arrives. word = rom_addr>>1;
    // index = word[5:0]; tag = word[18:6] (region 0x90000 bytes = 19-bit word).
    wire [18:0] want_w    = rom_addr[19:1];
    wire [5:0]  ci        = want_w[5:0];
    wire        rom_access = cpu_addr[15];       // sel_rom
    reg  [15:0] cdata [0:63];
    reg  [12:0] ctag  [0:63];
    reg  [63:0] cval;
    reg         fetching;
    reg  [5:0]  fill_ci;
    wire        rom_hit = cval[ci] && (ctag[ci] == want_w[18:6]);
    wire [15:0] hitw    = cdata[ci];
    always_ff @(posedge clk) begin
      snd_rom_req <= 1'b0;
      if (snd_rst) begin cval <= '0; fetching <= 1'b0; end
      else if (!fetching && !rom_hit && rom_access && !snd_rom_ack) begin
        snd_rom_req  <= 1'b1;
        snd_rom_addr <= SND_WORD_BASE + {5'd0, want_w};
        fill_ci      <= ci;
        fetching     <= 1'b1;
      end else if (fetching && snd_rom_ack) begin
        cdata[fill_ci] <= snd_rom_dout;
        ctag[fill_ci]  <= want_w[18:6];
        cval[fill_ci]  <= 1'b1;
        fetching       <= 1'b0;
      end
      rom_q <= rom_addr[0] ? hitw[15:8] : hitw[7:0];
    end
    assign rom_stall = rom_access && !rom_hit;   // freeze E until the word is cached
  end endgenerate

  // ---------------------------------------------------------------------------
  // PIA6821
  // ---------------------------------------------------------------------------
  // CB1 = the command STROBE. From the game source (SOUNDS.ASM/SNDSND) a sound
  // is sent as two writes: (code | 0xFD00) then (code | 0xFF00) -- the only
  // difference is bit 9, which lands on the board as CB1 (our brd_cmd[8]=data9).
  // write2 leaves CB1=1, so CB1 IDLES HIGH between commands and the trigger is
  // write1's FALLING edge (1->0). Resetting CB1 to 0 (idle low) meant the first
  // command produced no falling edge -> no NMI -> the 6809 never got commands.
  // Idle HIGH so every command's write1 makes the falling strobe edge.
  reg  [7:0] cmd_data; reg cmd_cb1, cmd_cb2;
  always_ff @(posedge clk) begin
    if (snd_rst) begin cmd_data<=0; cmd_cb1<=1'b1; cmd_cb2<=0; end
    else if (cmd_stb) begin cmd_data<=cmd[7:0]; cmd_cb1<=cmd[8]; cmd_cb2<=cmd[9]; end
  end

  wire [7:0] pia_dout, pia_pa, pia_pb;
  wire       pia_ca2;
  wire       ym_irq_n;
  pia6821 u_pia (
    .clk(clk), .rst(snd_rst),
    .en(e_fall & sel_pia(addr_r)), .we(~rnw_r), .addr(addr_r[1:0]),
    .din(dout_r), .dout(pia_dout),
    .pa_in(8'h00), .pb_in(cmd_data), .ca1(~ym_irq_n), .cb1(cmd_cb1), .cb2(cmd_cb2),
    .pa_out(pia_pa), .pb_out(pia_pb), .ca2_out(pia_ca2),
    .irqa(pia_irqa), .irqb(pia_irqb)
  );
  always_ff @(posedge clk) talkback <= pia_pb;

  // ---------------------------------------------------------------------------
  // HC55516 CVSD (bit-banged by the 6809 at 0x6000/0x6800)
  // ---------------------------------------------------------------------------
  wire cvsd_wr0 = wr & sel_ctl(addr_r) & (addr_r[12:11]==2'b00);  // 0x6000 clk->0, digit
  wire cvsd_wr1 = wr & sel_ctl(addr_r) & (addr_r[12:11]==2'b01);  // 0x6800 clk->1
  wire signed [15:0] cvsd_sample;
  hc55516 u_cvsd (
    .clk(clk), .rst(snd_rst),
    .cvsd_wr(cvsd_wr0 | cvsd_wr1), .clk_set(cvsd_wr1), .digit(dout_r[0]),
    .sample(cvsd_sample)
  );

  // ---------------------------------------------------------------------------
  // YM2151 (jt51) @ 3.579545 MHz, accurate fractional clock enable
  // ---------------------------------------------------------------------------
  localparam YM_HZ = 3_579_545;
  reg [31:0] cen_acc; reg cen; reg cen_p1_tgl; wire cen_p1 = cen & cen_p1_tgl;
  always_ff @(posedge clk) begin
    if (cen_acc + YM_HZ >= CLK_SYS_HZ) begin cen_acc <= cen_acc + YM_HZ - CLK_SYS_HZ; cen <= 1'b1; end
    else                               begin cen_acc <= cen_acc + YM_HZ;             cen <= 1'b0; end
    if (cen) cen_p1_tgl <= ~cen_p1_tgl;
  end

  // one clean YM write per 6809 write, synchronized to cen
  reg ym_req; reg ym_a0_r; reg [7:0] ym_din_r;
  always_ff @(posedge clk) begin
    if (wr && sel_ym(addr_r)) begin ym_req <= 1'b1; ym_a0_r <= addr_r[0]; ym_din_r <= dout_r; end
    else if (ym_req && cen)   ym_req <= 1'b0;
  end
  wire ym_cs_n = ~(ym_req & cen);
  wire ym_wr_n = ~(ym_req & cen);

  wire [7:0] ym_dout;
  wire signed [15:0] ym_l, ym_r;
  jt51 u_ym (
    .rst(snd_rst), .clk(clk), .cen(cen), .cen_p1(cen_p1),
    .cs_n(ym_cs_n), .wr_n(ym_wr_n), .a0(ym_a0_r), .din(ym_din_r), .dout(ym_dout),
    .ct1(), .ct2(), .irq_n(ym_irq_n),
    .sample(), .left(), .right(), .xleft(ym_l), .xright(ym_r)
  );

  // ---------------------------------------------------------------------------
  // 6809 read data mux (async-read semantics; sources track live ADDR)
  // ---------------------------------------------------------------------------
  always @* begin
    if      (sel_ram(cpu_addr)) cpu_din = ram_q;
    else if (sel_rom(cpu_addr)) cpu_din = rom_q;
    else if (sel_pia(cpu_addr)) cpu_din = pia_dout;
    else if (sel_ym (cpu_addr)) cpu_din = ym_dout;
    else                        cpu_din = 8'hff;
  end

  // ---------------------------------------------------------------------------
  // Mixer: MAME routes -- YM 0.10, DAC(MC1408) 0.25, CVSD 0.60.
  // DAC is 8-bit unsigned from PIA port A; center and scale to signed 16-bit.
  // ---------------------------------------------------------------------------
  wire signed [15:0] dac_s = $signed({1'b0, pia_pa, 7'd0}) - 16'sd16384;   // 0..255 -> +/-
  // weighted sum (approx MAME gains, /4 headroom)
  wire signed [17:0] mixL = (ym_l  >>> 3) + (dac_s >>> 2) + (cvsd_sample >>> 1) + (cvsd_sample >>> 3);
  wire signed [17:0] mixR = (ym_r  >>> 3) + (dac_s >>> 2) + (cvsd_sample >>> 1) + (cvsd_sample >>> 3);
  assign audio_l = mixL[16:1];
  assign audio_r = mixR[16:1];
endmodule
`default_nettype wire
