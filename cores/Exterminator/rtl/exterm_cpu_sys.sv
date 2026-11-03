// -----------------------------------------------------------------------------
// exterm_cpu_sys.sv -- Exterminator CPU / bus / memory subsystem (lane 1)
//
// Two TMS34010 cores (master + slave, donor rtl/cpu, RESET_VECTOR_FETCH=1,
// PACE_CLKS=4 @ clk_sys 20 MHz = 5 MHz GSP cycle), the MAME exterm.cpp memory
// maps, the host port (master -> slave HSTADRL/H, HSTDATA, HSTCTL), I/O ports,
// NVRAM, and the shared SDRAM arbiter. Port contract: docs/contract.md section 1
// (deviations listed in docs/lane1_cpu.md: packed m_vreg/s_vreg, SRT handshake).
// -----------------------------------------------------------------------------
`default_nettype none
module exterm_cpu_sys #(
  parameter int PACE_CLKS = 4,     // fixed pacing floor (only used when MAME_CYC=0)
  parameter bit MAME_CYC  = 1'b1,  // per-instruction MAME cycle budget (tms34010_cyc)
  // Area trims, verified against 29 x 1.7 s MAME gameplay+attract trace windows (bot: coin, start, joystick,
  // fire, dial): LINE/MPYS/MOD/DIVU were absent from those sampled windows; MPYU and DIVS are master operations.
  // Master DRAV is required by gameplay at FFF54990 and is kept independently of LINE;
  // the slave DOES use PIXBLT L,XY / B,XY heavily (kept). CONTROL.W sampled 0 on both. 1 = full-featured GSP.
  parameter bit M_HAS_LINE = 1'b0,
  parameter bit M_HAS_DRAV = 1'b1,
  parameter bit S_HAS_GFX  = 1'b0,
  parameter bit PACE_FAST  = 1'b1,
  // SLAVE_VDI: slave DI generated on the master's MAME-cycle timeline (see below); SLAVE_SOFS: slave start offset in cycles.
  parameter bit SLAVE_VDI = 1'b0,
  parameter bit HLT_ACK = 1'b1,         // host HLT write waits until the slave has frozen (see tms34010_core HALT_WAIT_IE)
  parameter bit MASTER_RESYNC = 1'b0,
  parameter [31:0] SLAVE_SOFS = 32'd0
) (
  input  wire        clk,
  input  wire        rst,

  // ---- video timing feedback ----
  input  wire [15:0] hcount,
  input  wire [15:0] vcount,
  input  wire        m_dint,
  input  wire        s_dint,
  input  wire [15:0] m_dpyadr_live,     // unused: DPYADR is computed in the core (vreg[12])
  input  wire [15:0] s_dpyadr_live,
  // GSP video registers, 16 x 16 bit packed (element i at [16*i +: 16])
  //   0 HESYNC 1 HEBLNK 2 HSBLNK 3 HTOTAL 4 VESYNC 5 VEBLNK 6 VSBLNK 7 VTOTAL
  //   8 DPYCTL 9 DPYSTRT 10 DPYINT 11 DPYTAP 12 DPYADR 13 CONTROL 14,15 0
  output wire [255:0] m_vreg,
  output wire [255:0] s_vreg,

  // ---- BG (master) VRAM port ----
  output wire        mv_req,
  output wire        mv_we,
  output wire [15:0] mv_addr,
  output wire [15:0] mv_wdata,
  output wire [1:0]  mv_be,
  output wire        mv_srt_rd,
  output wire        mv_srt_wr,
  input  wire [15:0] mv_rdata,
  input  wire        mv_ack,
  // ---- FG (slave) VRAM port ----
  output wire        sv_req,
  output wire        sv_we,
  output wire [15:0] sv_addr,
  output wire [15:0] sv_wdata,
  output wire [1:0]  sv_be,
  output wire        sv_srt_rd,
  output wire        sv_srt_wr,
  input  wire [15:0] sv_rdata,
  input  wire        sv_ack,
  // ---- CLUT ----
  output wire        pal_we,
  output wire [10:0] pal_addr,
  output wire [15:0] pal_wdata,
  output wire [1:0]  pal_be,
  input  wire [15:0] pal_rdata,
  // ---- NVRAM ----
  input  wire        nv_ext_clk_en,
  input  wire        nv_ext_we,
  input  wire [11:0] nv_ext_addr,
  input  wire [7:0]  nv_ext_din,
  output wire [7:0]  nv_ext_dout,
  // ---- inputs ----
  input  wire [15:0] in_p1,
  input  wire [15:0] in_p2,
  input  wire [7:0]  dsw,
  input  wire [7:0]  dial_p1,
  input  wire [7:0]  dial_p2,
  // ---- outputs ----
  output reg  [7:0]  snd_data,
  output reg         snd_wr,
  output wire [1:0]  coin_counter,
  // ---- SDRAM (generic word port) ----
  output wire        sd_req,
  output wire        sd_we,
  output wire [23:0] sd_addr,
  output wire [15:0] sd_din,
  output wire [1:0]  sd_be,
  output wire [2:0]  sd_burst,
  input  wire [63:0] sd_dout,
  input  wire        sd_ack,
  // ---- ROM download ----
  input  wire        ld_en,
  input  wire        ld_wr,
  input  wire [23:0] ld_addr,
  input  wire [7:0]  ld_data,
  output wire        ld_busy,
  // ---- debug ----
  output wire [31:0] dbg_m_pc,
  output wire [31:0] dbg_s_pc,
  output wire        dbg_m_retire,
  output wire        dbg_s_retire,
  output wire        dbg_s_halted,
  output wire [31:0] dbg_m_cyc,       // MAME cycles consumed by the master / slave (budget model)
  output wire [31:0] dbg_s_cyc
);

  // ===========================================================================
  // Slave reset: global reset, or a pulse from output-port bit 13 (rising edge)
  // ===========================================================================
  reg [4:0] srst_cnt;
  wire      srst_pulse = (srst_cnt != 5'd0);
  wire      slave_rst  = rst | srst_pulse;

  // ===========================================================================
  // MASTER GSP
  // ===========================================================================
  wire        mc_req, mc_we, mc_pix, mc_ers;
  wire [2:0]  mc_eng;
  wire [1:0]  mc_esub;
  wire [31:0] mc_addr, mc_wdata;
  wire [5:0]  mc_size;
  wire        mc_ack;
  wire [31:0] mc_rdata;
  wire [511:0] m_io;
  wire [31:0] m_retire_pc;
  wire        m_retire;

  // ---- master cycle count resynchronised to the DI grid ------------------------------------------
  // MAME's master sees its display interrupt k at virtual cycle k*83952. The FPGA master runs behind its model timeline by
  // the stalls MAME does not charge, so at each video DI the model cycle count is set to the grid value; everything derived
  // from it (slave virtual DI, below) then sees the MAME timeline however slow the memory system is.
  reg  [15:0] vc_prev;
  reg  [31:0] grid_q;                  // (frame index + 1) * 83952
  reg         m_cyc_set;
  reg  [31:0] m_cyc_val;
  always @(posedge clk) begin
    m_cyc_set <= 1'b0;
    vc_prev   <= vcount;
    if (rst) begin grid_q <= 32'd83952; m_cyc_val <= 32'd0; end
    else begin
      if (vcount == 16'd0 && vc_prev != 16'd0) grid_q <= grid_q + 32'd83952;
      if (MASTER_RESYNC && m_dint) begin m_cyc_set <= 1'b1; m_cyc_val <= grid_q; end
    end
  end

  // ---- slave display interrupt on the master's MAME-cycle timeline ----------------------------------
  // In MAME both GSPs share one virtual timeline: the slave DI is a scan-timer event at k*83952 master cycles whatever the
  // master's real speed. The FPGA master lags its model timeline by the memory-system stalls MAME does not charge (VRAM
  // shift-register transfers, SDRAM waits), so a video-timed slave DI would land earlier relative to the master's host-port
  // writes (slave command words) than in MAME. SLAVE_VDI re-times the slave DI onto the master/slave cycle counters (arming
  // rule: DI only if the slave's VTOTAL is non-zero at the preceding line-0 callback and DPYCTL.ENV is set). The video-timed
  // pulse s_dint is then unused.
  reg  [31:0] mf_next;                 // next multiple of 83952 master cycles above the master cycle count
  reg         sv_run, sv_arm_done, sv_armed;
  reg  [31:0] sv_base, sv_next;
  reg         s_dint_c;
  wire [31:0] sv_t = sv_base + dbg_s_cyc;
  always @(posedge clk) begin
    s_dint_c <= 1'b0;
    if (rst) begin
      mf_next <= 32'd83952; sv_run <= 1'b0; sv_arm_done <= 1'b0; sv_armed <= 1'b0; sv_base <= 32'd0; sv_next <= 32'd0;
    end else begin
      if (dbg_m_cyc >= mf_next) mf_next <= mf_next + 32'd83952;
      if (!SLAVE_VDI) s_dint_c <= s_dint;
      else begin
        if (dbg_s_halted) sv_run <= 1'b0;
        else if (!sv_run) begin
          sv_run <= 1'b1; sv_arm_done <= 1'b0; sv_base <= dbg_m_cyc - SLAVE_SOFS; sv_next <= mf_next;
        end else if (!sv_arm_done && (sv_t >= sv_next - 32'd81408)) begin
          sv_arm_done <= 1'b1; sv_armed <= (s_vreg[16*7 +: 16] != 16'h0) && (sv_next - 32'd81408 >= sv_base);
        end else if (sv_t >= sv_next) begin
          s_dint_c <= s_vreg[16*8+15] && sv_armed; sv_arm_done <= 1'b0; sv_next <= sv_next + 32'd83952;
        end
      end
    end
  end


  tms34010_core #(.RESET_VECTOR_FETCH(1'b1), .PACE_CLKS(PACE_CLKS), .HALT_ON_RESET(1'b0), .MAME_CYC(MAME_CYC),
      .PACE_FAST(PACE_FAST), .HAS_WINDOW(1'b0), .HAS_PBLT(1'b1), .HAS_LINE(M_HAS_LINE), .HAS_DRAV(M_HAS_DRAV), .HAS_MPY(1'b1), .HAS_DIV(1'b1)) u_mcpu (
    .clk(clk), .rst(rst),
    .ext_dint_set(m_dint), .ext_int1_line(1'b0), .ext_int2_line(1'b0), .ext_halt(1'b0),
    .hcount_i(hcount), .vcount_i(vcount),
    .dpyint_o(), .dpyctl_o(), .dpystart_o(), .dpytap_o(), .dpyadr_o(),
    .mem_req(mc_req), .mem_we(mc_we), .mem_addr(mc_addr), .mem_size(mc_size),
    .mem_wdata(mc_wdata), .mem_rdata(mc_rdata), .mem_ack(mc_ack),
    .state_o(), .pc_o(), .instr_pc_o(), .instr_word_o(), .illegal_opcode_o(),
    .hp_we(1'b0), .hp_idx(5'd0), .hp_wdata(16'h0), .hp_ext(1'b0), .hp_adr_inc(1'b0),
    .hp_ridx(5'd0), .hp_rdata(), .hp_adr_o(), .hp_ctl_o(),
    .icache_flush(1'b0), .ioreg_flat_o(m_io), .mem_pix_o(mc_pix),
    .mem_eng_o(mc_eng), .mem_esub_o(mc_esub), .mem_ers_o(mc_ers),
    .retire_o(m_retire), .retire_pc_o(m_retire_pc), .cyc_set_i(m_cyc_set), .cyc_val_i(m_cyc_val), .halted_o(), .cyc_tot_o(dbg_m_cyc)
  );

  // one-entry request stage (the CPU computes addresses combinationally; see
  // NARC smashtv_core.sv): hold the transaction until the target acknowledges.
  reg         mb_busy, mb_we, mb_pix, mb_ers;
  reg  [2:0]  mb_eng;
  reg  [1:0]  mb_esub;
  reg  [31:0] mb_addr, mb_wdata;
  reg  [5:0]  mb_size;
  wire        mm_ack;
  wire [31:0] mm_rdata;
  always @(posedge clk) begin
    if (rst) begin
      mb_busy <= 1'b0; mb_we <= 1'b0; mb_pix <= 1'b0; mb_addr <= 32'h0; mb_wdata <= 32'h0; mb_size <= 6'h0;
      mb_eng <= 3'd0; mb_esub <= 2'd0; mb_ers <= 1'b0;
    end else if (!mb_busy) begin
      if (mc_req) begin
        mb_busy <= 1'b1; mb_we <= mc_we; mb_pix <= mc_pix; mb_addr <= mc_addr;
        mb_eng <= mc_eng; mb_esub <= mc_esub; mb_ers <= mc_ers;
        mb_wdata <= mc_wdata; mb_size <= mc_size;
      end
    end else if (mm_ack) begin
      mb_busy <= 1'b0;
    end
  end
  assign mc_ack = mb_busy && mm_ack;
  reg [31:0] mc_rhold;
  always @(posedge clk) begin
    if (rst) mc_rhold <= 32'h0;
    else if (mc_ack) mc_rhold <= mm_rdata;
  end
  assign mc_rdata = mc_ack ? mm_rdata : mc_rhold;

  // ---- master memory fabric ----
  wire        m_sd_req, m_sd_we, m_sd_ack;
  wire [23:0] m_sd_addr;
  wire [15:0] m_sd_din;
  wire [1:0]  m_sd_be;
  wire [2:0]  m_sd_burst;
  wire [63:0] arb_dout;

  wire        per_req, per_we, per_ack;
  wire [3:0]  per_sel;
  wire [15:0] per_wdata;
  wire [15:0] per_rdata;

  wire        nv_we;
  wire [10:0] nv_addr;
  wire [15:0] nv_wdata;
  wire [1:0]  nv_be;
  reg  [15:0] nv_rdata;

  exterm_master_mem #(.IS_SLAVE(1'b0)) u_mmem (
    .clk(clk), .rst(rst),
    .req(mb_busy), .we(mb_we), .addr(mb_addr), .size(mb_size), .wdata(mb_wdata),
    .pix(mb_pix), .srt_on(m_io[16*8 + 11]), .eng(mb_eng), .esub(mb_esub), .ers(mb_ers), .srt_clr(m_retire),
    .rdata(mm_rdata), .ack(mm_ack),
    .sd_req(m_sd_req), .sd_we(m_sd_we), .sd_addr(m_sd_addr), .sd_din(m_sd_din),
    .sd_be(m_sd_be), .sd_burst(m_sd_burst), .sd_dout(arb_dout), .sd_ack(m_sd_ack),
    .rom_inval(ld_en),
    .v_req(mv_req), .v_we(mv_we), .v_addr(mv_addr), .v_wdata(mv_wdata), .v_be(mv_be),
    .v_srt_rd(mv_srt_rd), .v_srt_wr(mv_srt_wr), .v_rdata(mv_rdata), .v_ack(mv_ack),
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_wdata(pal_wdata), .pal_be(pal_be), .pal_rdata(pal_rdata),
    .nv_we(nv_we), .nv_addr(nv_addr), .nv_wdata(nv_wdata), .nv_be(nv_be), .nv_rdata(nv_rdata),
    .per_req(per_req), .per_we(per_we), .per_sel(per_sel), .per_wdata(per_wdata),
    .per_rdata(per_rdata), .per_ack(per_ack)
  );

  // ===========================================================================
  // SLAVE GSP
  // ===========================================================================
  wire        sc_req, sc_we, sc_pix, sc_ers;
  wire [2:0]  sc_eng;
  wire [1:0]  sc_esub;
  wire [31:0] sc_addr, sc_wdata;
  wire [5:0]  sc_size;
  wire        sc_ack;
  wire [31:0] sc_rdata;
  wire [511:0] s_io;
  wire [31:0] s_retire_pc;
  wire        s_retire;

  // host-port plumbing (driven by the peripheral FSM below)
  reg         hp_we_r, hp_ext_r, hp_inc_r, icache_flush_r;
  reg  [4:0]  hp_idx_r;
  reg  [15:0] hp_wdata_r;
  wire [31:0] hp_adr;
  wire [15:0] hp_ctl;
  wire [15:0] hp_rdata;

  tms34010_core #(.RESET_VECTOR_FETCH(1'b1), .PACE_CLKS(PACE_CLKS), .HALT_ON_RESET(1'b1), .HALT_WAIT_IE(HLT_ACK), .MAME_CYC(MAME_CYC),
      .PACE_FAST(PACE_FAST), .HAS_WINDOW(1'b0), .HAS_PBLT(1'b1), .HAS_LINE(S_HAS_GFX), .HAS_DRAV(S_HAS_GFX), .HAS_MPY(S_HAS_GFX), .HAS_DIV(S_HAS_GFX)) u_scpu (
    .clk(clk), .rst(slave_rst),
    .ext_dint_set(s_dint_c), .ext_int1_line(1'b0), .ext_int2_line(1'b0), .ext_halt(1'b0),
    .hcount_i(hcount), .vcount_i(vcount),
    .dpyint_o(), .dpyctl_o(), .dpystart_o(), .dpytap_o(), .dpyadr_o(),
    .mem_req(sc_req), .mem_we(sc_we), .mem_addr(sc_addr), .mem_size(sc_size),
    .mem_wdata(sc_wdata), .mem_rdata(sc_rdata), .mem_ack(sc_ack),
    .state_o(), .pc_o(), .instr_pc_o(), .instr_word_o(), .illegal_opcode_o(),
    .hp_we(hp_we_r), .hp_idx(hp_idx_r), .hp_wdata(hp_wdata_r), .hp_ext(hp_ext_r),
    .hp_adr_inc(hp_inc_r), .hp_ridx(hp_adr[8:4]), .hp_rdata(hp_rdata),
    .hp_adr_o(hp_adr), .hp_ctl_o(hp_ctl),
    .icache_flush(icache_flush_r), .ioreg_flat_o(s_io), .mem_pix_o(sc_pix),
    .mem_eng_o(sc_eng), .mem_esub_o(sc_esub), .mem_ers_o(sc_ers),
    .retire_o(s_retire), .retire_pc_o(s_retire_pc), .cyc_set_i(1'b0), .cyc_val_i(32'd0), .halted_o(s_frozen), .cyc_tot_o(dbg_s_cyc)
  );

  // slave request stage with two sources: slave core and master's host port
  reg         h_mem_req, h_mem_we;
  reg  [31:0] h_mem_addr;
  reg  [15:0] h_mem_wdata;

  reg         sb_busy, sb_host, sb_we, sb_pix, sb_ers;
  reg  [2:0]  sb_eng;
  reg  [1:0]  sb_esub;
  reg  [31:0] sb_addr, sb_wdata;
  reg  [5:0]  sb_size;
  wire        sm_ack;
  wire [31:0] sm_rdata;
  always @(posedge clk) begin
    if (rst) begin
      sb_busy <= 1'b0; sb_host <= 1'b0; sb_we <= 1'b0; sb_pix <= 1'b0; sb_eng <= 3'd0; sb_esub <= 2'd0; sb_ers <= 1'b0;
      sb_addr <= 32'h0; sb_wdata <= 32'h0; sb_size <= 6'h0;
    end else if (!sb_busy) begin
      if (h_mem_req) begin
        sb_busy <= 1'b1; sb_host <= 1'b1; sb_we <= h_mem_we; sb_pix <= 1'b0; sb_eng <= 3'd0; sb_esub <= 2'd0; sb_ers <= 1'b0;
        sb_addr <= h_mem_addr; sb_wdata <= {16'h0, h_mem_wdata}; sb_size <= 6'd16;
      end else if (sc_req) begin
        sb_busy <= 1'b1; sb_host <= 1'b0; sb_we <= sc_we; sb_pix <= sc_pix; sb_eng <= sc_eng; sb_esub <= sc_esub; sb_ers <= sc_ers;
        sb_addr <= sc_addr; sb_wdata <= sc_wdata; sb_size <= sc_size;
      end
    end else if (sm_ack) begin
      sb_busy <= 1'b0;
    end
  end
  assign sc_ack = sb_busy && !sb_host && sm_ack;
  wire   h_mem_ack = sb_busy && sb_host && sm_ack;
  reg [31:0] sc_rhold;
  always @(posedge clk) begin
    if (rst) sc_rhold <= 32'h0;
    else if (sc_ack) sc_rhold <= sm_rdata;
  end
  assign sc_rdata = sc_ack ? sm_rdata : sc_rhold;

  wire        s_sd_req, s_sd_we, s_sd_ack;
  wire [23:0] s_sd_addr;
  wire [15:0] s_sd_din;
  wire [1:0]  s_sd_be;
  wire [2:0]  s_sd_burst;

  exterm_slave_mem u_smem (
    .clk(clk), .rst(rst),
    .req(sb_busy), .we(sb_we), .addr(sb_addr), .size(sb_size), .wdata(sb_wdata),
    .pix(sb_pix), .srt_on(s_io[16*8 + 11]), .eng(sb_eng), .esub(sb_esub), .ers(sb_ers), .srt_clr(s_retire), .rdata(sm_rdata), .ack(sm_ack),
    .sd_req(s_sd_req), .sd_we(s_sd_we), .sd_addr(s_sd_addr), .sd_din(s_sd_din),
    .sd_be(s_sd_be), .sd_burst(s_sd_burst), .sd_dout(arb_dout), .sd_ack(s_sd_ack),
    .v_req(sv_req), .v_we(sv_we), .v_addr(sv_addr), .v_wdata(sv_wdata), .v_be(sv_be),
    .v_srt_rd(sv_srt_rd), .v_srt_wr(sv_srt_wr), .v_rdata(sv_rdata), .v_ack(sv_ack)
  );

  // ===========================================================================
  // SDRAM arbiter
  // ===========================================================================
  // The loader path must work while the CPUs are held in reset (download), so the
  // arbiter is only reset when no download is active.
  exterm_sdram_arb u_arb (
    .clk(clk), .rst(rst && !ld_en),
    .m_req(m_sd_req), .m_we(m_sd_we), .m_addr(m_sd_addr), .m_din(m_sd_din), .m_be(m_sd_be),
    .m_burst(m_sd_burst), .m_ack(m_sd_ack),
    .s_req(s_sd_req), .s_we(s_sd_we), .s_addr(s_sd_addr), .s_din(s_sd_din), .s_be(s_sd_be),
    .s_burst(s_sd_burst), .s_ack(s_sd_ack),
    .rd_dout(arb_dout),
    .ld_en(ld_en), .ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data), .ld_busy(ld_busy),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be),
    .sd_burst(sd_burst), .sd_dout(sd_dout), .sd_ack(sd_ack)
  );

  // ===========================================================================
  // NVRAM 2K x 16: two byte-wide M10K arrays, CPU port (16 bit) + framework port
  // ===========================================================================
  wire [15:0] nv_q_a;
  exterm_nv_ram u_nvram (
    .clk(clk),
    .addr_a(nv_addr), .din_a(nv_wdata), .we_a(nv_we), .be_a(nv_be), .q_a(nv_q_a),
    .addr_b(nv_ext_addr), .din_b(nv_ext_din), .we_b(nv_ext_we && nv_ext_clk_en), .q_b(nv_ext_dout)
  );
  always @* nv_rdata = nv_q_a;

  // ===========================================================================
  // Peripherals (master map): host port, trackballs, DSW, output port, sound, wdog
  // ===========================================================================
  localparam [3:0] PS_HADRL = 4'd0, PS_HADRH = 4'd1, PS_HDATA = 4'd2, PS_HCTL = 4'd3,
                   PS_TB0 = 4'd4, PS_TB1 = 4'd5, PS_DSW = 4'd6, PS_OUT = 4'd7,
                   PS_SND = 4'd8, PS_WDG = 4'd9;
  localparam [2:0] P_IDLE = 3'd0, P_HCTL2 = 3'd1, P_HMEM = 3'd2, P_WL = 3'd3, P_HWAIT = 3'd4;
  reg [23:0] hwait_cnt;
  reg        hlt_was;
  wire       s_frozen;
  reg [2:0]  pst;
  reg        per_ack_r;            // slow-path ack (registered pulse)
  reg [15:0] per_rdata_r;          // slow-path read data

  // trackball state (MAME exterm_state: m_aimpos, m_trackball_old, m_last)
  reg [7:0]  tb_old0, tb_old1;
  reg [5:0]  aim0, aim1;
  reg [15:0] out_last;
  reg [1:0]  coin_q;
  assign coin_counter = coin_q;

  // trackball_port_r<Which>() combinational helpers
  wire [7:0] tb_diff0 = tb_old0 - dial_p1;
  wire [7:0] tb_diff1 = tb_old1 - dial_p2;
  wire [5:0] tb_inc0  = {tb_diff0[7] | tb_diff0[5], tb_diff0[4:0]};
  wire [5:0] tb_inc1  = {tb_diff1[7] | tb_diff1[5], tb_diff1[4:0]};
  wire [5:0] aim0_n   = aim0 + tb_inc0;
  wire [5:0] aim1_n   = aim1 + tb_inc1;

  wire [31:0] hp_a_masked = {hp_adr[31:4], 4'b0000};
  wire        hp_a_io     = (hp_a_masked[31:30] == 2'b11) && (hp_a_masked[29:9] == 21'd0);

  // Posted host data write (master -> slave memory): the master is acknowledged as soon as the
  // word is latched; the write to slave memory completes in the background. Any later host
  // operation that must observe it (HSTDATA read, HSTCTL, I/O-register writes) waits for !hw_pend.
  reg         hw_issued;
  reg  [31:0] hq_a [0:1];
  reg  [15:0] hq_d [0:1];
  reg         hq_h, hq_t;                // 2-entry posted-write FIFO (head / tail)
  reg  [1:0]  hw_n;
  wire        hw_pend = (hw_n != 2'd0);
  wire        hw_full = (hw_n == 2'd2);
  wire        hw_pop  = hw_issued && h_mem_ack;
  wire        hw_push = fast_ok && (per_sel == PS_HDATA);
  wire        hp_busy = hp_we_r | hp_inc_r;

  // 0-wait peripherals: ack in the same cycle the request is visible
  wire sel_hdata = (per_sel == PS_HDATA);
  wire fast_hdata = sel_hdata && per_we && !hp_a_io && !hw_full && !hp_busy;
  wire fast_sel   = (per_sel == PS_HADRL) || (per_sel == PS_HADRH) || (per_sel == PS_TB0) ||
                    (per_sel == PS_TB1)   || (per_sel == PS_DSW)   || (per_sel == PS_OUT) ||
                    (per_sel == PS_SND)   || (per_sel == PS_WDG)   || (per_sel == 4'd15) ||
                    (per_sel > PS_WDG && per_sel != PS_HDATA && per_sel != PS_HCTL);
  wire fast_ok    = per_req && (pst == P_IDLE) && !per_ack_r &&
                    ((fast_sel && !(per_we && (per_sel == PS_HADRL || per_sel == PS_HADRH) && hp_busy)) || fast_hdata);
  assign per_ack  = per_ack_r | fast_ok;

  reg [15:0] per_rd_fast;
  always @* begin
    case (per_sel)
      PS_HADRL: per_rd_fast = hp_adr[15:0];
      PS_HADRH: per_rd_fast = hp_adr[31:16];
      PS_TB0:   per_rd_fast = (in_p1 & 16'hc0ff) | {2'b00, aim0_n, 8'h00};
      PS_TB1:   per_rd_fast = (in_p2 & 16'hc0ff) | {2'b00, aim1_n, 8'h00};
      PS_DSW:   per_rd_fast = {8'hff, dsw};
      PS_HDATA, PS_HCTL: per_rd_fast = per_rdata_r;
      default:  per_rd_fast = 16'h0000;
    endcase
  end
  assign per_rdata = per_rd_fast;

  always @(posedge clk) begin
    per_ack_r      <= 1'b0;
    hp_we_r        <= 1'b0;
    hp_inc_r       <= 1'b0;
    icache_flush_r <= 1'b0;
    snd_wr         <= 1'b0;
    if (srst_cnt != 5'd0) srst_cnt <= srst_cnt - 5'd1;
    if (rst) begin
      pst <= P_IDLE; per_rdata_r <= 16'h0; hp_idx_r <= 5'd0; hp_wdata_r <= 16'h0; hp_ext_r <= 1'b0;
      h_mem_req <= 1'b0; h_mem_we <= 1'b0; h_mem_addr <= 32'h0; h_mem_wdata <= 16'h0;
      tb_old0 <= 8'h0; tb_old1 <= 8'h0; aim0 <= 6'h0; aim1 <= 6'h0; out_last <= 16'h0;
      coin_q <= 2'b00; snd_data <= 8'h0; srst_cnt <= 5'd0;
      hw_n <= 2'd0; hw_issued <= 1'b0; hq_h <= 1'b0; hq_t <= 1'b0;
    end else begin
      // ---- 0-wait operations (side effects at the ack edge) ----
      if (fast_ok) begin
        case (per_sel)
          PS_HADRL: if (per_we) begin hp_we_r <= 1'b1; hp_idx_r <= 5'h0D; hp_wdata_r <= per_wdata; hp_ext_r <= 1'b0; end
          PS_HADRH: if (per_we) begin hp_we_r <= 1'b1; hp_idx_r <= 5'h0E; hp_wdata_r <= per_wdata; hp_ext_r <= 1'b0; end
          PS_HDATA: begin   // posted write (fast_hdata)
            hq_a[hq_t] <= hp_a_masked; hq_d[hq_t] <= per_wdata; hq_t <= ~hq_t;
            if (hp_ctl[11]) hp_inc_r <= 1'b1;
          end
          PS_TB0: begin tb_old0 <= dial_p1; aim0 <= aim0_n; end
          PS_TB1: begin tb_old1 <= dial_p2; aim1 <= aim1_n; end
          PS_OUT: if (per_we) begin
            if (per_wdata[0] && !out_last[0]) aim0 <= 6'h0;
            if (per_wdata[1] && !out_last[1]) aim1 <= 6'h0;
            if (per_wdata[13] && !out_last[13]) srst_cnt <= 5'd20;   // >= 16 clk: the register files clear in a 16-clk sweep
            coin_q <= {per_wdata[14], per_wdata[15]};
            out_last <= per_wdata;
          end
          PS_SND: if (per_we) begin snd_data <= per_wdata[7:0]; snd_wr <= 1'b1; end
          default: ;
        endcase
      end

      // ---- background issue of the posted host write into the slave memory ----
      if (hw_pend && !hw_issued && pst == P_IDLE && !h_mem_req) begin
        h_mem_req <= 1'b1; h_mem_we <= 1'b1; h_mem_addr <= hq_a[hq_h]; h_mem_wdata <= hq_d[hq_h];
        hw_issued <= 1'b1;
      end
      if (hw_issued && h_mem_ack) begin
        h_mem_req <= 1'b0; hw_issued <= 1'b0; hq_h <= ~hq_h; icache_flush_r <= 1'b1;
      end
      hw_n <= hw_n + {1'b0, hw_push} - {1'b0, hw_pop};

      // ---- slow operations ----
      case (pst)
        P_IDLE: if (per_req && !fast_ok && !per_ack_r && !hw_pend && !hp_busy) begin
          case (per_sel)
            PS_HCTL: begin
              if (per_we) begin
                // io_register_w(HSTCTLH, data & 0xff00), then (HSTCTLL, data & 0x00ff)
                hp_we_r <= 1'b1; hp_idx_r <= 5'h10; hp_wdata_r <= {per_wdata[15:8], 8'h00}; hp_ext_r <= 1'b1;
                hlt_was <= dbg_s_halted;
                pst <= P_HCTL2;
              end else begin
                per_rdata_r <= hp_ctl; per_ack_r <= 1'b1; pst <= P_WL;
              end
            end
            PS_HDATA: begin
              if (hp_a_io) begin
                if (per_we) begin
                  hp_we_r <= 1'b1; hp_idx_r <= hp_a_masked[8:4]; hp_wdata_r <= per_wdata; hp_ext_r <= 1'b0;
                end else per_rdata_r <= hp_rdata;
                if (per_we ? hp_ctl[11] : hp_ctl[12]) hp_inc_r <= 1'b1;
                per_ack_r <= 1'b1; pst <= P_WL;
              end else begin   // HSTDATA read from slave memory
                h_mem_req <= 1'b1; h_mem_we <= 1'b0; h_mem_addr <= hp_a_masked; h_mem_wdata <= per_wdata;
                pst <= P_HMEM;
              end
            end
            default: ;
          endcase
        end
        P_HCTL2: begin
          hp_we_r <= 1'b1; hp_idx_r <= 5'h0F; hp_wdata_r <= {8'h00, per_wdata[7:0]}; hp_ext_r <= 1'b1;
          // a HLT request waits until the slave has actually frozen (it may be inside an interrupt handler), so the master's
          // following slave-memory uploads cannot overwrite code the slave is still executing
          if (HLT_ACK && per_wdata[15] && !hlt_was) begin hwait_cnt <= 24'd0; pst <= P_HWAIT; end
          else begin per_ack_r <= 1'b1; pst <= P_WL; end
        end
        P_HWAIT: begin
          hwait_cnt <= hwait_cnt + 24'd1;
          if (s_frozen || hwait_cnt[23]) begin per_ack_r <= 1'b1; pst <= P_WL; end
        end
        P_HMEM: if (h_mem_ack) begin
          h_mem_req <= 1'b0;
          per_rdata_r <= sm_rdata[15:0];
          if (hp_ctl[12]) hp_inc_r <= 1'b1;
          per_ack_r <= 1'b1; pst <= P_WL;
        end
        P_WL: if (!per_req && !per_ack_r) pst <= P_IDLE;
        default: pst <= P_IDLE;
      endcase
    end
  end

  // ===========================================================================
  // Exports
  // ===========================================================================
  function automatic [255:0] vreg_pack(input [511:0] io);
    reg [255:0] v;
    integer k;
    begin
      v = 256'h0;
      for (k = 0; k <= 10; k = k + 1) v[16*k +: 16] = io[16*k +: 16];
      v[16*11 +: 16] = io[16*5'h1B +: 16];   // DPYTAP
      v[16*12 +: 16] = io[16*5'h1E +: 16];   // DPYADR
      v[16*13 +: 16] = io[16*5'h0B +: 16];   // CONTROL
      vreg_pack = v;
    end
  endfunction
  assign m_vreg = vreg_pack(m_io);
  assign s_vreg = vreg_pack(s_io);

  assign dbg_m_pc     = m_retire_pc;
  assign dbg_s_pc     = s_retire_pc;
  assign dbg_m_retire = m_retire;
  assign dbg_s_retire = s_retire;
  assign dbg_s_halted = s_io[16*5'h10 + 15];

endmodule

// -----------------------------------------------------------------------------
// exterm_nv_ram -- 2K x 16 NVRAM, true dual port, single clock: port A 16 bit with byte
// enables (CPU), port B 8 bit (framework byte port: even byte = low byte). One M10K pair
// (altsyncram mixed width, same style as the proven lane-2 VRAM); Verilator branch is behavioural.
// Reads: 1-clock latency, unregistered q.
// -----------------------------------------------------------------------------
module exterm_nv_ram (
  input  wire        clk,
  input  wire [10:0] addr_a,
  input  wire [15:0] din_a,
  input  wire        we_a,
  input  wire [1:0]  be_a,
  output wire [15:0] q_a,
  input  wire [11:0] addr_b,
  input  wire [7:0]  din_b,
  input  wire        we_b,
  output wire [7:0]  q_b
);
`ifdef VERILATOR
  reg [7:0] lo [0:2047];
  reg [7:0] hi [0:2047];
  integer i;
  string nvram_file;
  reg [7:0] nvram_init [0:4095];
  initial begin
    for (i = 0; i < 2048; i = i + 1) begin lo[i] = 8'h0; hi[i] = 8'h0; end
    if ($value$plusargs("nvram=%s", nvram_file)) begin
      $readmemh(nvram_file, nvram_init);
      for (i = 0; i < 2048; i = i + 1) begin lo[i] = nvram_init[2*i]; hi[i] = nvram_init[2*i+1]; end
    end
  end
  reg [15:0] qa;
  reg [7:0]  qb;
  always @(posedge clk) begin
    if (we_a && be_a[0]) lo[addr_a] <= din_a[7:0];
    if (we_a && be_a[1]) hi[addr_a] <= din_a[15:8];
    qa <= {hi[addr_a], lo[addr_a]};
    if (we_b && !addr_b[0]) lo[addr_b[11:1]] <= din_b;
    if (we_b &&  addr_b[0]) hi[addr_b[11:1]] <= din_b;
    qb <= addr_b[0] ? hi[addr_b[11:1]] : lo[addr_b[11:1]];
  end
  assign q_a = qa;
  assign q_b = qb;
`else
  altsyncram #(
    .operation_mode("BIDIR_DUAL_PORT"),
    .width_a(16), .widthad_a(11), .numwords_a(2048), .width_byteena_a(2),
    .width_b(8),  .widthad_b(12), .numwords_b(4096), .width_byteena_b(1),
    .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
    .address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"), .wrcontrol_wraddress_reg_b("CLOCK0"),
    .byteena_reg_b("CLOCK0"), .rdcontrol_reg_b("CLOCK0"),
    .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_mixed_ports("OLD_DATA"),
    .ram_block_type("M10K"), .intended_device_family("Cyclone V"),
    .power_up_uninitialized("FALSE"), .init_file("UNUSED"),
    .clock_enable_input_a("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_a("BYPASS"), .clock_enable_output_b("BYPASS"),
    .lpm_type("altsyncram")
  ) u_ram (
    .clock0(clk),
    .address_a(addr_a), .data_a(din_a), .wren_a(we_a), .byteena_a(be_a), .q_a(q_a),
    .address_b(addr_b), .data_b(din_b), .wren_b(we_b), .byteena_b(1'b1), .q_b(q_b),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .clocken0(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
  );
`endif
endmodule
`default_nettype wire
