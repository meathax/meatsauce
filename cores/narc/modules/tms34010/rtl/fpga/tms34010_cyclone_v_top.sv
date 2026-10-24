// -----------------------------------------------------------------------------
// tms34010_cyclone_v_top.sv
//
// Standalone Cyclone V / DE10-Nano realization boundary. FPGA_CLK1_50 feeds
// the core/local-bus PLL; FPGA_CLK2_50 supplies an independent continuous
// video PLL with phase-separated internal and pin clocks. RESET_N and both
// PLL locks feed separate reset-release chains for the core, 8x local-bus,
// and video domains.
//
// VIDEO_VCLK is a 180-degree PLL output so the internal positive video edge
// corresponds to the original falling-VCLK state-update edge documented by
// A0045. The board adapter deliberately selects the TMS34010's output-clock
// system mode; the reusable pin system still accepts any independent vclk_i.
// It also converts the reusable active-high blank interval to the original
// package's active-low BLANK pin.
//
// External level shifting and attached DRAM/VRAM/host circuitry are board
// responsibilities. The QSF/SDC assigns these ports in Task 0160.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_cyclone_v_top
#(
  // Core clocks per local clock (machine state); 1 = every core clock.
  parameter int unsigned CLKS_PER_STATE = 1,
  // 1: cycle-accurate timing (docs/cycle_accuracy.md). 0: upstream behaviour.
  parameter bit          CYCLE_ACCURATE = 1'b0
)
(
  input  logic        FPGA_CLK1_50,
  input  logic        FPGA_CLK2_50,
  input  logic        RESET_N,

  input  logic        RUN_EMU_N,
  input  logic        HCS_N,
  input  logic        HREAD_N,
  input  logic        HWRITE_N,
  input  logic        HLDS_N,
  input  logic        HUDS_N,
  input  logic [1:0]  HFS,
  inout  wire  [15:0] HD,
  output logic        HRDY,
  output logic        HINT_N,

  input  logic        LINT1_N,
  input  logic        LINT2_N,
  input  logic        HOLD_N,
  output logic        HLDA_EMUA_N,

  output logic        VIDEO_VCLK,
  inout  wire         HSYNC_N,
  inout  wire         VSYNC_N,
  output logic        BLANK,

  input  logic        LRDY,
  inout  wire  [15:0] LAD,
  output logic        LCLK1,
  output logic        LCLK2,
  inout  wire         RAS_N,
  inout  wire         LAL_N,
  inout  wire         CAS_N,
  inout  wire         WE_N,
  inout  wire         TR_QE_N,
  inout  wire         DEN_N,
  inout  wire         DDOUT
);

  logic        core_clk;
  logic        bus_clk8x;
  logic        pll_locked;
  logic        video_clk;
  logic        video_pin_clk;
  logic        video_pll_locked;
  logic        reset_request;
  logic        core_rst;
  logic        bus_rst;
  logic        video_rst;

  logic [15:0] hd_i;
  logic [15:0] hd_o;
  logic [1:0]  hd_oe;
  logic [15:0] lad_i;
  logic [15:0] lad_o;
  logic        lad_oe;
  logic        hsync_n_i;
  logic        vsync_n_i;
  logic        hsync;
  logic        vsync;
  logic        blank;
  logic        hsync_oe;
  logic        vsync_oe;
  logic        ras_n;
  logic        lal_n;
  logic        cas_n;
  logic        we_n;
  logic        tr_qe_n;
  logic        den_n;
  logic        ddout;
  logic        ras_oe;
  logic        lal_oe;
  logic        cas_oe;
  logic        we_oe;
  logic        tr_qe_oe;
  logic        den_oe;
  logic        ddout_oe;

  tms34010_cyclone_v_pll u_clock_pll (
    .ref_clk_i    (FPGA_CLK1_50),
    .pll_rst_i    (!RESET_N),
    .core_clk_o   (core_clk),
    .bus_clk8x_o  (bus_clk8x),
    .locked_o     (pll_locked)
  );

  tms34010_cyclone_v_video_pll u_video_pll (
    .ref_clk_i       (FPGA_CLK2_50),
    .pll_rst_i       (!RESET_N),
    .video_clk_o     (video_clk),
    .video_pin_clk_o (video_pin_clk),
    .locked_o        (video_pll_locked)
  );

  assign reset_request = !RESET_N || !pll_locked || !video_pll_locked;

  tms34010_reset_sync u_core_reset (
    .clk_i         (core_clk),
    .async_reset_i (reset_request),
    .rst_o         (core_rst)
  );

  tms34010_reset_sync u_bus_reset (
    .clk_i         (bus_clk8x),
    .async_reset_i (reset_request),
    .rst_o         (bus_rst)
  );

  tms34010_reset_sync u_video_reset (
    .clk_i         (video_clk),
    .async_reset_i (reset_request),
    .rst_o         (video_rst)
  );

  tms34010_pin_system #(
    .CLKS_PER_STATE (CLKS_PER_STATE),
    .CYCLE_ACCURATE (CYCLE_ACCURATE)
  ) u_pin_system (
    .core_clk_i         (core_clk),
    .bus_clk8x_i        (bus_clk8x),
    .vclk_i             (video_clk),
    .core_rst_i         (core_rst),
    .bus_rst_i          (bus_rst),
    .video_rst_i        (video_rst),
    .video_hsync_n_i    (hsync_n_i),
    .video_vsync_n_i    (vsync_n_i),
    .run_emu_n_i        (RUN_EMU_N),
    .hcs_n_i            (HCS_N),
    .hread_n_i          (HREAD_N),
    .hwrite_n_i         (HWRITE_N),
    .hlds_n_i           (HLDS_N),
    .huds_n_i           (HUDS_N),
    .hfs_i              (HFS),
    .hd_i               (hd_i),
    .hd_o               (hd_o),
    .hd_oe_o            (hd_oe),
    .hrdy_o             (HRDY),
    .hint_n_o           (HINT_N),
    .lint1_n_i          (LINT1_N),
    .lint2_n_i          (LINT2_N),
    .dpyint_set_i       (1'b0),
    .hold_n_i           (HOLD_N),
    .hlda_emua_n_o      (HLDA_EMUA_N),
    .video_hsync_o      (hsync),
    .video_vsync_o      (vsync),
    .video_hblank_o     (),
    .video_vblank_o     (),
    .video_blank_o      (blank),
    .video_hsync_oe_o   (hsync_oe),
    .video_vsync_oe_o   (vsync_oe),
    .lrdy_i             (LRDY),
    .lad_i              (lad_i),
    .lad_o              (lad_o),
    .lad_oe_o           (lad_oe),
    .lclk1_o            (LCLK1),
    .lclk2_o            (LCLK2),
    .ras_n_o            (ras_n),
    .lal_n_o            (lal_n),
    .cas_n_o            (cas_n),
    .we_n_o             (we_n),
    .tr_qe_n_o          (tr_qe_n),
    .den_n_o            (den_n),
    .ddout_o            (ddout),
    .ras_oe_o           (ras_oe),
    .lal_oe_o           (lal_oe),
    .cas_oe_o           (cas_oe),
    .we_oe_o            (we_oe),
    .tr_qe_oe_o         (tr_qe_oe),
    .den_oe_o           (den_oe),
    .ddout_oe_o         (ddout_oe),
    .subphase_o         (),
    .local_init_done_o  (),
    .local_cycle_busy_o (),
    .bridge_busy_o      (),
    .state_o            (),
    .pc_o               (),
    .instr_word_o       (),
    .illegal_opcode_o   ()
  );

  tms34010_fpga_io u_fpga_io (
    .hd_io         (HD),
    .hd_i_o        (hd_i),
    .hd_o_i        (hd_o),
    .hd_oe_i       (hd_oe),
    .lad_io        (LAD),
    .lad_i_o       (lad_i),
    .lad_o_i       (lad_o),
    .lad_oe_i      (lad_oe),
    .hsync_n_io    (HSYNC_N),
    .vsync_n_io    (VSYNC_N),
    .hsync_n_i_o   (hsync_n_i),
    .vsync_n_i_o   (vsync_n_i),
    .hsync_i       (hsync),
    .vsync_i       (vsync),
    .hsync_oe_i    (hsync_oe),
    .vsync_oe_i    (vsync_oe),
    .blank_i       (blank),
    .blank_n_o     (BLANK),
    .ras_n_io      (RAS_N),
    .lal_n_io      (LAL_N),
    .cas_n_io      (CAS_N),
    .we_n_io       (WE_N),
    .tr_qe_n_io    (TR_QE_N),
    .den_n_io      (DEN_N),
    .ddout_io      (DDOUT),
    .ras_n_i       (ras_n),
    .lal_n_i       (lal_n),
    .cas_n_i       (cas_n),
    .we_n_i        (we_n),
    .tr_qe_n_i     (tr_qe_n),
    .den_n_i       (den_n),
    .ddout_i       (ddout),
    .ras_oe_i      (ras_oe),
    .lal_oe_i      (lal_oe),
    .cas_oe_i      (cas_oe),
    .we_oe_i       (we_oe),
    .tr_qe_oe_i    (tr_qe_oe),
    .den_oe_i      (den_oe),
    .ddout_oe_i    (ddout_oe)
  );

  assign VIDEO_VCLK = video_pin_clk;

endmodule : tms34010_cyclone_v_top

`default_nettype wire
