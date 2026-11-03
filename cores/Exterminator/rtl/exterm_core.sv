// -----------------------------------------------------------------------------
// exterm_core.sv — Exterminator (Premier Technology 1989) board top.
//
// Integrates lane blocks per docs/contract.md:
//   exterm_cpu_sys  (master + slave TMS34010, memory maps, host port, I/O)
//   exterm_video    (GSP timing/display units, BG/FG VRAM, CLUT, mixer)
//   exterm_sound    (Gottlieb P5 sound board)
//   sdram           (single SDRAM stick: EPROM, master DRAM, slave DRAM)
//
// One clock domain clk (20 MHz); clk_ram (80 MHz, phase aligned) only drives
// the SDRAM engine. In simulation (`SIM_SDRAM`) the behavioural model replaces
// the controller and runs on clk.
//
// ioctl stream (MRA index 0): 0x000000-0x1FFFFF maincpu, 0x200000-0x207FFF
// audiocpu (v101d1), 0x208000-0x20FFFF speechcpu (v101y1).
// -----------------------------------------------------------------------------
`default_nettype none
module exterm_core #(
  parameter string SIM_EPROM_HEX = ""
) (
  input  wire        clk,
  input  wire        clk_ram,
  input  wire        rst,        // game reset: held by the framework for the whole ROM download
  input  wire        rst_mem,    // memory-controller reset: power-on/user reset ONLY (never the download hold, lesson 7241)
  input  wire [15:0] in_p1, in_p2,
  input  wire [7:0]  dsw, dial_p1, dial_p2,
  input  wire        ld_en, ld_wr,
  input  wire [24:0] ld_addr,
  input  wire [7:0]  ld_data,
  output wire        ld_busy,
  input  wire        nv_clk_en, nv_we,
  input  wire [11:0] nv_addr,
  input  wire [7:0]  nv_din,
  output wire [7:0]  nv_dout,
  input  wire [1:0]  snd_filter,
  output wire [4:0]  r, g, b,
  output wire        hs, vs, hblank, vblank, ce_pix,
  output wire signed [15:0] audio,
  output wire [12:0] SDRAM_A,
  inout  wire [15:0] SDRAM_DQ,
  output wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS,
  output wire [1:0]  SDRAM_BA,
  output wire        SDRAM_CKE,
  output wire [1:0]  coin_counter,
  // debug / sim
  output wire [31:0] dbg_m_pc, dbg_s_pc,
  output wire        dbg_m_retire, dbg_s_retire, dbg_s_halted
);

  // ---------------------------------------------------------------------------
  // Clock enables (one master clock, 20 MHz)
  // ---------------------------------------------------------------------------
  reg [1:0] div4;  reg [3:0] div10; reg [2:0] div5; reg [6:0] div80;
  reg ce_pix_r, ce_2m, ce_4m, ce_250k;
  always @(posedge clk) begin
    div4  <= div4 + 2'd1;
    div10 <= (div10 == 4'd9)  ? 4'd0 : div10 + 4'd1;
    div5  <= (div5  == 3'd4)  ? 3'd0 : div5  + 3'd1;
    div80 <= (div80 == 7'd79) ? 7'd0 : div80 + 7'd1;
    ce_pix_r <= (div4  == 2'd3);
    ce_2m    <= (div10 == 4'd9);
    ce_4m    <= (div5  == 3'd4);
    ce_250k  <= (div80 == 7'd79);
  end

  // ---------------------------------------------------------------------------
  // SDRAM
  // ---------------------------------------------------------------------------
  wire        sd_req, sd_we, sd_ack, sd_ready;
  wire [23:0] sd_addr;
  wire [15:0] sd_din;
  wire [1:0]  sd_be;
  wire [2:0]  sd_burst;
  wire [63:0] sd_dout;

`ifdef SIM_SDRAM
  sdram_model #(.LAT(1), .ACK_HOLD(2), .IGNORE_DQM(1'b1), .INIT_FILE(SIM_EPROM_HEX)) u_sdram (
    .clk(clk), .rst(rst_mem), .ready(sd_ready),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din),
    .sd_be(sd_be), .sd_burst(sd_burst), .sd_dout(sd_dout), .sd_ack(sd_ack));
  assign SDRAM_A = 13'd0; assign SDRAM_BA = 2'd0;
  assign {SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 6'b111111;
  assign SDRAM_CKE = 1'b0;
  assign SDRAM_DQ  = 16'hzzzz;
`else
  sdram u_sdram (
    .clk(clk_ram), .init(rst_mem), .ready(sd_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din),
    .sd_be(sd_be), .sd_burst(sd_burst), .sd_dout(sd_dout), .sd_ack(sd_ack));
`endif

  // Board reset is held until the SDRAM is initialised (lane 1 requirement).
  reg sd_ready_s1, sd_ready_s2;
  always @(posedge clk) begin sd_ready_s1 <= sd_ready; sd_ready_s2 <= sd_ready_s1; end
  wire board_rst = rst | ~sd_ready_s2;

  // ---------------------------------------------------------------------------
  // ROM download routing
  // ---------------------------------------------------------------------------
  wire ld_main = ld_en & (ld_addr[24:21] == 4'd0);
  wire ld_snd  = ld_en & (ld_addr[24:16] == 9'h020);

  // ---------------------------------------------------------------------------
  // CPU system
  // ---------------------------------------------------------------------------
  wire [15:0] hcount, vcount, m_dpyadr_live, s_dpyadr_live;
  wire        m_dint, s_dint;
  wire [255:0] m_vreg_p, s_vreg_p;
  wire        mv_req, mv_we, mv_srt_rd, mv_srt_wr, mv_ack;
  wire [15:0] mv_addr, mv_wdata, mv_rdata;
  wire [1:0]  mv_be;
  wire        sv_req, sv_we, sv_srt_rd, sv_srt_wr, sv_ack;
  wire [15:0] sv_addr, sv_wdata, sv_rdata;
  wire [1:0]  sv_be;
  wire        pal_we;
  wire [10:0] pal_addr;
  wire [15:0] pal_wdata, pal_rdata;
  wire [1:0]  pal_be;
  wire [7:0]  snd_data;
  wire        snd_wr;

  exterm_cpu_sys #(.PACE_CLKS(4)) u_cpu (
    .clk(clk), .rst(board_rst | (ld_en & ~ld_snd)),
    .hcount(hcount), .vcount(vcount), .m_dint(m_dint), .s_dint(s_dint),
    .m_dpyadr_live(m_dpyadr_live), .s_dpyadr_live(s_dpyadr_live),
    .m_vreg(m_vreg_p), .s_vreg(s_vreg_p),
    .mv_req(mv_req), .mv_we(mv_we), .mv_addr(mv_addr), .mv_wdata(mv_wdata), .mv_be(mv_be),
    .mv_srt_rd(mv_srt_rd), .mv_srt_wr(mv_srt_wr), .mv_rdata(mv_rdata), .mv_ack(mv_ack),
    .sv_req(sv_req), .sv_we(sv_we), .sv_addr(sv_addr), .sv_wdata(sv_wdata), .sv_be(sv_be),
    .sv_srt_rd(sv_srt_rd), .sv_srt_wr(sv_srt_wr), .sv_rdata(sv_rdata), .sv_ack(sv_ack),
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_wdata(pal_wdata), .pal_be(pal_be), .pal_rdata(pal_rdata),
    .nv_ext_clk_en(nv_clk_en), .nv_ext_we(nv_we), .nv_ext_addr(nv_addr), .nv_ext_din(nv_din), .nv_ext_dout(nv_dout),
    .in_p1(in_p1), .in_p2(in_p2), .dsw(dsw), .dial_p1(dial_p1), .dial_p2(dial_p2),
    .snd_data(snd_data), .snd_wr(snd_wr), .coin_counter(coin_counter),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be),
    .sd_burst(sd_burst), .sd_dout(sd_dout), .sd_ack(sd_ack),
    .ld_en(ld_en & ld_main), .ld_wr(ld_wr & ld_main), .ld_addr(ld_addr[23:0]), .ld_data(ld_data),
    .ld_busy(ld_busy),
    .dbg_m_pc(dbg_m_pc), .dbg_s_pc(dbg_s_pc), .dbg_m_retire(dbg_m_retire),
    .dbg_s_retire(dbg_s_retire), .dbg_s_halted(dbg_s_halted));

  // packed -> unpacked register bundles for the video block
  wire [15:0] m_vreg [0:15];
  wire [15:0] s_vreg [0:15];
  genvar gi;
  generate for (gi = 0; gi < 16; gi = gi + 1) begin : g_vreg
    assign m_vreg[gi] = m_vreg_p[16*gi +: 16];
    assign s_vreg[gi] = s_vreg_p[16*gi +: 16];
  end endgenerate

  // ---------------------------------------------------------------------------
  // Video
  // ---------------------------------------------------------------------------
  wire de_unused;
  exterm_video u_video (
    .clk(clk), .rst(rst), .ce_pix(ce_pix_r),
    .m_vreg(m_vreg), .s_vreg(s_vreg),
    .hcount(hcount), .vcount(vcount), .m_dint(m_dint), .s_dint(s_dint),
    .m_dpyadr_live(m_dpyadr_live), .s_dpyadr_live(s_dpyadr_live),
    .mv_req(mv_req), .mv_we(mv_we), .mv_addr(mv_addr), .mv_wdata(mv_wdata), .mv_be(mv_be),
    .mv_srt_rd(mv_srt_rd), .mv_srt_wr(mv_srt_wr), .mv_rdata(mv_rdata), .mv_ack(mv_ack),
    .sv_req(sv_req), .sv_we(sv_we), .sv_addr(sv_addr), .sv_wdata(sv_wdata), .sv_be(sv_be),
    .sv_srt_rd(sv_srt_rd), .sv_srt_wr(sv_srt_wr), .sv_rdata(sv_rdata), .sv_ack(sv_ack),
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_wdata(pal_wdata), .pal_be(pal_be), .pal_rdata(pal_rdata),
    .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
    .de(de_unused), .ce_pix_o(ce_pix));

  // ---------------------------------------------------------------------------
  // Sound
  // ---------------------------------------------------------------------------
  exterm_sound u_sound (
    .clk(clk), .rst(board_rst | ld_en), .ce_2m(ce_2m), .ce_4m(ce_4m), .ce_250k(ce_250k),
    .cmd(snd_data), .cmd_wr(snd_wr),
    .ld_en(ld_snd), .ld_wr(ld_wr & ld_snd), .ld_region(ld_addr[15]), .ld_addr(ld_addr[14:0]),
    .ld_data(ld_data), .filter_mode(snd_filter), .audio(audio), .dbg_led());

endmodule
`default_nettype wire
