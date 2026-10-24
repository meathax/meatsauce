// -----------------------------------------------------------------------------
// tms34010_pin_system.sv
//
// Integrated functional core/memory system plus the original-pin local-bus
// phase engine. The hierarchy has explicit core_clk_i, bus_clk8x_i, and
// vclk_i domains. Coherent MCP handshakes isolate both asynchronous
// core-to-bus commands and the video configuration/status/screen paths.
//
// The asynchronous host controls are converted into one held synchronous
// register request with physical HRDY and byte-lane HD direction. Physical
// active-low HOLD is sampled in the 8× domain, synchronized to the core
// arbiter, and returned as phased HLDA plus explicit local-bus output enables.
// RUN/EMU is synchronized into the core;
// each architectural EMU event and the halt level cross back to the 8×
// domain before Q1/Q2 EMUA is combined with Q3/Q4 HLDA on the original shared
// output. Processor and host-indirect on-chip I/O requests use
// LOCAL_CYCLE_IO_* and carry their internal read data through the coherent
// command bundle.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_pin_system
  import tms34010_pkg::*;
#(
  // Core clocks per local clock (machine state); 1 = every core clock.
  parameter int unsigned CLKS_PER_STATE = 1,
  // 1: cycle-accurate timing (docs/cycle_accuracy.md). 0: upstream behaviour.
  parameter bit          CYCLE_ACCURATE = 1'b0
)
(
  input  logic                              core_clk_i,
  input  logic                              bus_clk8x_i,
  input  logic                              vclk_i,
  input  logic                              core_rst_i,
  input  logic                              bus_rst_i,
  input  logic                              video_rst_i,
  input  logic                              video_hsync_n_i,
  input  logic                              video_vsync_n_i,

  input  logic                              run_emu_n_i,

  input  logic                              hcs_n_i,
  input  logic                              hread_n_i,
  input  logic                              hwrite_n_i,
  input  logic                              hlds_n_i,
  input  logic                              huds_n_i,
  input  logic [1:0]                        hfs_i,
  input  local_word_t                       hd_i,
  output local_word_t                       hd_o,
  output logic [1:0]                        hd_oe_o,
  output logic                              hrdy_o,
  output logic                              hint_n_o,

  input  logic                              lint1_n_i,
  input  logic                              lint2_n_i,
  input  logic                              dpyint_set_i,

  input  logic                              hold_n_i,
  output logic                              hlda_emua_n_o,

  output logic                              video_hsync_o,
  output logic                              video_vsync_o,
  output logic                              video_hblank_o,
  output logic                              video_vblank_o,
  output logic                              video_blank_o,
  output logic                              video_hsync_oe_o,
  output logic                              video_vsync_oe_o,

  input  logic                              lrdy_i,
  input  local_word_t                       lad_i,
  output local_word_t                       lad_o,
  output logic                              lad_oe_o,
  output logic                              lclk1_o,
  output logic                              lclk2_o,
  output logic                              ras_n_o,
  output logic                              lal_n_o,
  output logic                              cas_n_o,
  output logic                              we_n_o,
  output logic                              tr_qe_n_o,
  output logic                              den_n_o,
  output logic                              ddout_o,
  output logic                              ras_oe_o,
  output logic                              lal_oe_o,
  output logic                              cas_oe_o,
  output logic                              we_oe_o,
  output logic                              tr_qe_oe_o,
  output logic                              den_oe_o,
  output logic                              ddout_oe_o,
  output local_subphase_t                   subphase_o,
  output logic                              local_init_done_o,
  output logic                              local_cycle_busy_o,
  output logic                              bridge_busy_o,

  output core_state_t                       state_o,
  output logic [ADDR_WIDTH-1:0]             pc_o,
  output instr_word_t                       instr_word_o,
  output logic                              illegal_opcode_o
);

  logic                              core_cycle_req;
  local_cycle_kind_t                 core_cycle_kind;
  logic [ADDR_WIDTH-1:0]             core_cycle_addr;
  local_word_t                       core_cycle_wdata;
  local_word_t                       core_cycle_io_rdata;
  logic                              core_cycle_iaq;
  logic [13:0]                       core_cycle_srfaddr;
  logic [15:0]                       core_cycle_dpytap;
  logic                              core_cycle_screen_org;
  logic [7:0]                        core_cycle_dram_row;
  local_word_t                       core_cycle_rdata;
  logic                              core_cycle_ack;

  local_cycle_cmd_t                  core_command;
  local_cycle_cmd_t                  local_command;
  logic                              local_cycle_req;
  local_word_t                       local_cycle_rdata;
  logic                              local_cycle_ack;
  logic                              local_hold_req;
  logic                              core_hold_req;
  logic                              core_hold_ack;
  logic                              local_hold_grant;
  logic                              core_run_emu_n;
  logic                              core_emua_n;
  logic                              core_emu_event;
  logic                              core_emu_halt;
  logic                              local_hlda_n;
  logic                              core_host_req;
  logic                              core_host_we;
  host_reg_sel_t                     core_host_reg;
  logic [1:0]                        core_host_be;
  local_word_t                       core_host_wdata;
  local_word_t                       core_host_rdata;
  logic                              core_host_ack;
  logic                              core_host_busy;

  always_comb begin
    core_command            = '0;
    core_command.kind       = core_cycle_kind;
    core_command.addr       = core_cycle_addr;
    core_command.wdata      = core_cycle_wdata;
    core_command.io_rdata   = core_cycle_io_rdata;
    core_command.iaq        = core_cycle_iaq;
    core_command.srfaddr    = core_cycle_srfaddr;
    core_command.dpytap     = core_cycle_dpytap;
    core_command.screen_org = core_cycle_screen_org;
    core_command.dram_row   = core_cycle_dram_row;
  end

  // HOLD is sampled by the physical local-bus engine at the specified LCLK2
  // edge. Only that held level crosses to the core arbiter; its quiescent
  // grant returns through an independent 2FF level synchronizer.
  tms34010_sync_bit #(.RESET_VALUE(1'b0)) u_hold_req_sync (
    .clk     (core_clk_i),
    .rst     (core_rst_i),
    .async_i (local_hold_req),
    .sync_o  (core_hold_req)
  );

  tms34010_sync_bit #(.RESET_VALUE(1'b0)) u_hold_grant_sync (
    .clk     (bus_clk8x_i),
    .rst     (bus_rst_i),
    .async_i (core_hold_ack),
    .sync_o  (local_hold_grant)
  );

  // RUN/EMU is a physical input. Its inactive RUN level is the reset-safe
  // value, and only the synchronized result is sampled by the core.
  tms34010_sync_bit #(.RESET_VALUE(1'b1)) u_run_emu_sync (
    .clk     (core_clk_i),
    .rst     (core_rst_i),
    .async_i (run_emu_n_i),
    .sync_o  (core_run_emu_n)
  );

  tms34010_host_bus u_host_bus (
    .clk          (core_clk_i),
    .rst          (core_rst_i),
    .hcs_n_i      (hcs_n_i),
    .hread_n_i    (hread_n_i),
    .hwrite_n_i   (hwrite_n_i),
    .hlds_n_i     (hlds_n_i),
    .huds_n_i     (huds_n_i),
    .hfs_i        (hfs_i),
    .hd_i         (hd_i),
    .hd_o         (hd_o),
    .hd_oe_o      (hd_oe_o),
    .hrdy_o       (hrdy_o),
    .host_req_o   (core_host_req),
    .host_we_o    (core_host_we),
    .host_reg_o   (core_host_reg),
    .host_be_o    (core_host_be),
    .host_wdata_o (core_host_wdata),
    .host_rdata_i (core_host_rdata),
    .host_ack_i   (core_host_ack),
    .host_busy_i  (core_host_busy)
  );

  tms34010_system #(
    .CLKS_PER_STATE (CLKS_PER_STATE),
    .CYCLE_ACCURATE (CYCLE_ACCURATE)
  ) u_system (
    .clk                (core_clk_i),
    .vclk_i             (vclk_i),
    .rst                (core_rst_i),
    .vclk_rst_i         (video_rst_i),
    .video_hsync_n_i    (video_hsync_n_i),
    .video_vsync_n_i    (video_vsync_n_i),
    .run_emu_n_i        (core_run_emu_n),
    .emua_n_o           (core_emua_n),
    .hcs_n_i            (hcs_n_i),
    .host_req_i         (core_host_req),
    .host_we_i          (core_host_we),
    .host_reg_i         (core_host_reg),
    .host_be_i          (core_host_be),
    .host_wdata_i       (core_host_wdata),
    .host_rdata_o       (core_host_rdata),
    .host_ack_o         (core_host_ack),
    .host_busy_o        (core_host_busy),
    .hint_n_o           (hint_n_o),
    .lint1_n_i          (lint1_n_i),
    .lint2_n_i          (lint2_n_i),
    .dpyint_set_i       (dpyint_set_i),
    .hold_req_i         (core_hold_req),
    .hold_ack_o         (core_hold_ack),
    .video_hsync_o      (video_hsync_o),
    .video_vsync_o      (video_vsync_o),
    .video_hblank_o     (video_hblank_o),
    .video_vblank_o     (video_vblank_o),
    .video_blank_o      (video_blank_o),
    .video_hsync_oe_o   (video_hsync_oe_o),
    .video_vsync_oe_o   (video_vsync_oe_o),
    .cycle_req_o        (core_cycle_req),
    .cycle_kind_o       (core_cycle_kind),
    .cycle_addr_o       (core_cycle_addr),
    .cycle_wdata_o      (core_cycle_wdata),
    .cycle_io_rdata_o   (core_cycle_io_rdata),
    .cycle_iaq_o        (core_cycle_iaq),
    .cycle_srfaddr_o    (core_cycle_srfaddr),
    .cycle_dpytap_o     (core_cycle_dpytap),
    .cycle_screen_org_o (core_cycle_screen_org),
    .cycle_dram_row_o   (core_cycle_dram_row),
    .cycle_rdata_i      (core_cycle_rdata),
    .cycle_ack_i        (core_cycle_ack),
    .state_o            (state_o),
    .pc_o               (pc_o),
    .instr_word_o       (instr_word_o),
    .illegal_opcode_o   (illegal_opcode_o)
  );

  tms34010_local_bus_bridge u_local_bus_bridge (
    .src_clk_i   (core_clk_i),
    .src_rst_i   (core_rst_i),
    .src_req_i   (core_cycle_req),
    .src_cmd_i   (core_command),
    .src_rdata_o (core_cycle_rdata),
    .src_ack_o   (core_cycle_ack),
    .src_busy_o  (bridge_busy_o),
    .dst_clk_i   (bus_clk8x_i),
    .dst_rst_i   (bus_rst_i),
    .dst_req_o   (local_cycle_req),
    .dst_cmd_o   (local_command),
    .dst_rdata_i (local_cycle_rdata),
    .dst_ack_i   (local_cycle_ack)
  );

  tms34010_local_bus u_local_bus (
    .clk8x_i            (bus_clk8x_i),
    .rst                (bus_rst_i),
    .cycle_req_i        (local_cycle_req),
    .cycle_kind_i       (local_command.kind),
    .cycle_addr_i       (local_command.addr),
    .cycle_wdata_i      (local_command.wdata),
    .cycle_iaq_i        (local_command.iaq),
    .cycle_srfaddr_i    (local_command.srfaddr),
    .cycle_dpytap_i     (local_command.dpytap),
    .cycle_screen_org_i (local_command.screen_org),
    .cycle_dram_row_i   (local_command.dram_row),
    .io_rdata_i         (local_command.io_rdata),
    .cycle_rdata_o      (local_cycle_rdata),
    .cycle_ack_o        (local_cycle_ack),
    .cycle_busy_o       (local_cycle_busy_o),
    .init_done_o        (local_init_done_o),
    .hold_n_i           (hold_n_i),
    .hold_req_o         (local_hold_req),
    .hold_grant_i       (local_hold_grant),
    .hlda_n_o           (local_hlda_n),
    .lrdy_i             (lrdy_i),
    .lad_i              (lad_i),
    .lad_o              (lad_o),
    .lad_oe_o           (lad_oe_o),
    .lclk1_o            (lclk1_o),
    .lclk2_o            (lclk2_o),
    .ras_n_o            (ras_n_o),
    .lal_n_o            (lal_n_o),
    .cas_n_o            (cas_n_o),
    .we_n_o             (we_n_o),
    .tr_qe_n_o          (tr_qe_n_o),
    .den_n_o            (den_n_o),
    .ddout_o            (ddout_o),
    .ras_oe_o           (ras_oe_o),
    .lal_oe_o           (lal_oe_o),
    .cas_oe_o           (cas_oe_o),
    .we_oe_o            (we_oe_o),
    .tr_qe_oe_o         (tr_qe_oe_o),
    .den_oe_o           (den_oe_o),
    .ddout_oe_o         (ddout_oe_o),
    .subphase_o         (subphase_o)
  );

  assign core_emu_event =
      (state_o == CORE_EXECUTE) && !core_emua_n;
  // Register the sampled-low execute decision on the same edge as the event,
  // then retain it only while the synchronized pin keeps the core halted.
  // This prevents a faster 8× domain from seeing a one-window gap between
  // the opcode pulse and the repeating halt indication.
  assign core_emu_halt =
      ((state_o == CORE_EXECUTE) && !core_emua_n && !core_run_emu_n)
      || ((state_o == CORE_EMU_HALT) && !core_run_emu_n);

  tms34010_emu_bridge u_emu_bridge (
    .src_clk_i       (core_clk_i),
    .src_rst_i       (core_rst_i),
    .src_event_i     (core_emu_event),
    .src_halt_i      (core_emu_halt),
    .dst_clk_i       (bus_clk8x_i),
    .dst_rst_i       (bus_rst_i),
    .dst_subphase_i  (subphase_o),
    .dst_lclk1_i     (lclk1_o),
    .dst_hlda_n_i    (local_hlda_n),
    .hlda_emua_n_o   (hlda_emua_n_o)
  );

endmodule : tms34010_pin_system

`default_nettype wire
