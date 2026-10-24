// -----------------------------------------------------------------------------
// tms34010_memory_fabric.sv
//
// Integrated abstract memory fabric for the TMS34010 clients.
//
// The CPU/graphics side retains the core's architectural 1..32-bit,
// bit-addressed request boundary. The field sequencer expands that request
// into aligned 16-bit words, and the fixed-priority arbiter combines those
// words with screen refresh, DRAM refresh, host indirect access, and HOLD.
// Processor on-chip I/O transactions bypass field splitting and select the
// dedicated I/O read/write cycle kinds with their internal read-data payload.
// A captured DPYCTL.SRT sideband converts only resulting graphics pixel words
// into explicit VRAM memory-to-register/register-to-memory cycles.
// Host-indirect requests arrive as aligned words and select those same I/O
// kinds when their held address decodes into the internal register page.
// One abstract controller-facing cycle remains held until acknowledgement.
//
// This module deliberately stops before original-pin phase generation. A
// following local-bus controller converts local_cycle_kind_t plus the selected
// payload into LAD/RAS/CAS/LAL/DEN/DDOUT/W/LRDY behavior.
//
// Spec sources:
//   - 1988 TMS34010 User's Guide §4.1, pages 4-2 through 4-5
//     (architectural fields to aligned 16-bit words).
//   - 1988 TMS34010 User's Guide §11.3, page 11-4
//     (client priority, cycle completion, RMW atomicity, and HOLD restart).
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_memory_fabric
  import tms34010_pkg::*;
#(
  // 1: cycle-accurate memory controller (docs/cycle_accuracy.md): two-state
  // bus cycles and posted CPU writes. 0: upstream behaviour.
  parameter bit          CYCLE_ACCURATE = 1'b1,
  parameter int unsigned CLKS_PER_STATE = 8
)
(
  input  logic                              clk,
  input  logic                              rst,

  input  logic                              cpu_field_req_i,
  input  logic                              cpu_field_we_i,
  input  logic [ADDR_WIDTH-1:0]             cpu_field_addr_i,
  input  logic [FIELD_SIZE_WIDTH-1:0]       cpu_field_size_i,
  input  logic [DATA_WIDTH-1:0]             cpu_field_wdata_i,
  input  logic [DATA_WIDTH-1:0]             cpu_field_keep_i,
  input  logic                              cpu_field_rmw_i,
  // CYCLE_ACCURATE: the request's data and keep mask arrive one clock after
  // it is taken (cpu_field_late_wdata_i/keep_i, valid in that clock).
  input  logic                              cpu_field_late_i,
  input  logic [DATA_WIDTH-1:0]             cpu_field_late_wdata_i,
  input  logic [DATA_WIDTH-1:0]             cpu_field_late_keep_i,
  input  logic                              cpu_field_iaq_i,
  input  logic                              cpu_field_srt_i,
  input  logic                              cpu_field_is_io_i,
  input  logic                              cpu_field_io_we_i,
  input  local_word_t                       cpu_field_io_rdata_i,
  output logic [DATA_WIDTH-1:0]             cpu_field_rdata_o,
  output logic                              cpu_field_ack_o,
  output logic                              cpu_field_busy_o,   // a CPU request (or posted write) is in progress

  input  logic                              host_req_i,
  input  logic                              host_we_i,
  input  logic [ADDR_WIDTH-1:0]             host_addr_i,
  input  local_word_t                       host_wdata_i,
  input  logic                              host_is_io_i,
  input  local_word_t                       host_io_rdata_i,
  output local_word_t                       host_rdata_o,
  output logic                              host_ack_o,

  input  logic                              screen_req_i,
  input  logic [13:0]                       screen_srfaddr_i,
  input  logic [15:0]                       screen_dpytap_i,
  input  logic                              screen_org_i,
  output logic                              screen_ack_o,

  input  logic                              dram_req_i,
  input  logic [7:0]                        dram_row_i,
  input  logic                              dram_cbr_i,

  input  logic                              hold_req_i,
  output logic                              hold_ack_o,

  output logic                              cycle_req_o,
  output local_cycle_kind_t                 cycle_kind_o,
  output logic [ADDR_WIDTH-1:0]             cycle_addr_o,
  output local_word_t                       cycle_wdata_o,
  output local_word_t                       cycle_io_rdata_o,
  output logic                              cycle_iaq_o,
  output logic [13:0]                       cycle_srfaddr_o,
  output logic [15:0]                       cycle_dpytap_o,
  output logic                              cycle_screen_org_o,
  output logic [7:0]                        cycle_dram_row_o,
  input  local_word_t                       cycle_rdata_i,
  input  logic                              cycle_ack_i
);

  logic                          cpu_request_done;
  logic                          arb_cycle_req;
  logic                          arb_cpu_cycle;
  logic [7:0]                    cpu_age_q;
  logic                          timed_ack;
  local_word_t                   timed_rdata;
  logic                          cpu_word_req;
  logic                          cpu_word_we;
  logic [ADDR_WIDTH-1:0]         cpu_word_addr;
  local_word_t                   cpu_word_wdata;
  local_word_t                   cpu_word_rdata;
  logic                          cpu_word_ack;
  logic                          cpu_word_rmw_lock;
  logic                          cpu_word_restart;
  logic [DATA_WIDTH-1:0]         sequenced_field_rdata;
  logic                          sequenced_field_ack;
  logic                          selected_cpu_req;
  logic                          selected_cpu_we;
  logic [ADDR_WIDTH-1:0]         selected_cpu_addr;
  local_word_t                   selected_cpu_wdata;
  logic                          selected_cpu_rmw_lock;
  logic                          cpu_request_active_q;
  logic                          cpu_request_is_io_q;
  logic                          cpu_request_io_we_q;
  logic [ADDR_WIDTH-1:0]         cpu_request_addr_q;
  logic [FIELD_SIZE_WIDTH-1:0]   cpu_request_size_q;
  logic [DATA_WIDTH-1:0]         cpu_request_wdata_q;
  logic [DATA_WIDTH-1:0]         cpu_request_keep_q;
  logic                          cpu_request_rmw_q;
  logic                          cpu_request_iaq_q;
  logic                          cpu_request_srt_q;
  local_word_t                   cpu_request_io_rdata_q;
  logic                          cpu_late_q;     // late data due this clock
  logic [DATA_WIDTH-1:0]         req_wdata, req_keep;

  // Register the architectural request before classifying it as external
  // field traffic or an on-chip I/O cycle. Besides holding the complete
  // transaction, this stage breaks any combinational acknowledge-to-address-
  // decode path through the core's monolithic control block.
  // Posted CPU writes (1988 UG 13.1.1, hidden states): the memory controller
  // takes the field and the CPU carries on; a later CPU request waits here
  // until the controller has finished. The core sees the acknowledge in the
  // clock the field is taken.
  logic cpu_request_posted_q;
  logic cpu_field_capture;
  logic cpu_field_posts;

  // With CYCLE_ACCURATE the next request is taken in the clock a posted
  // write completes, so back-to-back writes keep the bus busy without a gap
  // (the core has already moved on from a posted write).
  assign cpu_field_capture = cpu_field_req_i
      && (!cpu_request_active_q
          || (CYCLE_ACCURATE && cpu_request_posted_q && cpu_request_done));
  // I/O register writes are posted like memory writes (1988 UG 6.2: once
  // the memory controller accepts the request, the next instruction can
  // begin; one request can be queued).
  // cpu_field_io_we_i is the core's write intent for any address (mem_we
  // excludes I/O), so the accept doesn't wait on the address decode.
  assign cpu_field_posts   = CYCLE_ACCURATE && cpu_field_io_we_i;

  always_ff @(posedge clk) begin
    if (rst) begin
      cpu_request_posted_q <= 1'b0;
    end else begin
      if (cpu_field_capture)
        cpu_request_posted_q <= cpu_field_posts;
    end
  end

  // Clocks since the start of the state in which the core raised the
  // current field request (bus timer, docs/cycle_accuracy.md).
  generate
    if (CYCLE_ACCURATE && (CLKS_PER_STATE > 1)) begin : g_age
      localparam int unsigned PW = $clog2(CLKS_PER_STATE);
      // Justification (a): position within the machine state.
      logic [PW-1:0] phase_q;
      always_ff @(posedge clk) begin
        if (rst || (phase_q == PW'(CLKS_PER_STATE - 1)))
          phase_q <= '0;
        else
          phase_q <= phase_q + 1'b1;
      end
      // Justification (a): age of the accepted CPU request.
      always_ff @(posedge clk) begin
        if (rst)
          cpu_age_q <= '0;
        else if (cpu_field_capture)
          cpu_age_q <= 8'(phase_q) + 8'd1;
        else if (cpu_age_q != 8'hFF)
          cpu_age_q <= cpu_age_q + 8'd1;
      end
    end else begin : g_no_age
      assign cpu_age_q = '0;
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      cpu_request_active_q   <= 1'b0;
      cpu_request_is_io_q    <= 1'b0;
      cpu_request_io_we_q    <= 1'b0;
      cpu_request_addr_q     <= '0;
      cpu_request_size_q     <= '0;
      cpu_request_wdata_q    <= '0;
      cpu_request_keep_q     <= '0;
      cpu_request_rmw_q      <= 1'b0;
      cpu_request_iaq_q      <= 1'b0;
      cpu_request_srt_q      <= 1'b0;
    end else if (cpu_request_active_q && !cpu_field_capture) begin
      if (cpu_request_done)
        cpu_request_active_q <= 1'b0;
      if (cpu_late_q) begin
        cpu_request_wdata_q  <= cpu_field_late_wdata_i;
        cpu_request_keep_q   <= cpu_field_late_keep_i;
      end
    end else if (cpu_field_capture) begin
      cpu_request_active_q   <= 1'b1;
      cpu_request_is_io_q    <= cpu_field_is_io_i;
      cpu_request_io_we_q    <= cpu_field_is_io_i
                              ? cpu_field_io_we_i
                              : cpu_field_we_i;
      cpu_request_addr_q     <= cpu_field_addr_i;
      cpu_request_size_q     <= cpu_field_size_i;
      cpu_request_wdata_q    <= cpu_field_wdata_i;
      cpu_request_keep_q     <= cpu_field_keep_i;
      cpu_request_rmw_q      <= cpu_field_rmw_i;
      cpu_request_iaq_q      <= cpu_field_iaq_i;
      cpu_request_srt_q      <= cpu_field_srt_i;
    end
  end

  assign cpu_field_busy_o = cpu_request_active_q;

  // Late write data (CYCLE_ACCURATE): the core raises some writes before their
  // data and keep mask are ready and gives them the clock after the request is
  // taken. That is the first clock anything reads the request's data: the
  // field sequencer, idle since a new request is only taken once the previous
  // one has finished, takes the field in it, and an I/O cycle is presented
  // from it. Both take the late inputs then; the request registers take them
  // at the end of it.
  always_ff @(posedge clk) begin
    if (rst) cpu_late_q <= 1'b0;
    else     cpu_late_q <= CYCLE_ACCURATE && cpu_field_capture && cpu_field_late_i;
  end
  assign req_wdata = cpu_late_q ? cpu_field_late_wdata_i : cpu_request_wdata_q;
  assign req_keep  = cpu_late_q ? cpu_field_late_keep_i  : cpu_request_keep_q;
`ifdef VERILATOR
  // Simulation guard: in the clock late data arrives, the request it belongs
  // to is the active one and nothing has used its data yet - an external field
  // is taken by the sequencer in this clock (idle until now), an I/O request
  // has not finished. Checked only after a reset has been seen (a bench may
  // run clocks before it asserts reset, with state not yet set).
  logic g_armed_q = 1'b0;
  always_ff @(posedge clk)
    if (rst) g_armed_q <= 1'b1;
  always_ff @(posedge clk)
    if (g_armed_q && !rst && cpu_late_q
        && (!cpu_request_active_q || !cpu_request_io_we_q
            || (!cpu_request_is_io_q
                && u_field_sequencer.state_q != u_field_sequencer.FIELD_IDLE)
            || cpu_request_done)) begin
      $display("LATE DATA TOO LATE t=%0t active %0d we %0d io %0d seq %0d done %0d", $time,
               cpu_request_active_q, cpu_request_io_we_q, cpu_request_is_io_q,
               u_field_sequencer.state_q, cpu_request_done);
      $fatal(1);
    end
  // ...and from the next clock the request registers hold the late data.
  logic                  g_late_d_q = 1'b0;
  logic [DATA_WIDTH-1:0] g_wdata_q, g_keep_q;
  always_ff @(posedge clk) begin
    g_late_d_q <= g_armed_q && !rst && cpu_late_q && cpu_request_active_q && !cpu_request_done;
    g_wdata_q  <= cpu_field_late_wdata_i;
    g_keep_q   <= cpu_field_late_keep_i;
    if (g_late_d_q && (cpu_request_wdata_q != g_wdata_q || cpu_request_keep_q != g_keep_q)) begin
      $display("LATE REQ REG MISMATCH t=%0t", $time);
      $fatal(1);
    end
  end
`endif

  // With CYCLE_ACCURATE the I/O read data is sampled a clock after the
  // request is taken (the core holds a read request until it is
  // acknowledged, and the cycle lasts at least two states), keeping the
  // register-file -> ALU -> I/O register path out of the capture clock.
  logic io_sample_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      io_sample_q            <= 1'b0;
      cpu_request_io_rdata_q <= '0;
    end else begin
      io_sample_q <= cpu_field_capture;
      if (CYCLE_ACCURATE ? io_sample_q : cpu_field_capture)
        cpu_request_io_rdata_q <= cpu_field_io_rdata_i;
    end
  end

  tms34010_field_sequencer u_field_sequencer (
    .clk             (clk),
    .rst             (rst),
    .field_req_i     (cpu_request_active_q && !cpu_request_is_io_q),
    .field_we_i      (cpu_request_io_we_q),
    .field_addr_i    (cpu_request_addr_q),
    .field_size_i    (cpu_request_size_q),
    .field_wdata_i   (req_wdata),
    .field_keep_i    (req_keep),
    .field_rmw_i     (cpu_request_rmw_q),
    .field_rdata_o   (sequenced_field_rdata),
    .field_ack_o     (sequenced_field_ack),
    .word_req_o      (cpu_word_req),
    .word_we_o       (cpu_word_we),
    .word_addr_o     (cpu_word_addr),
    .word_wdata_o    (cpu_word_wdata),
    .word_rdata_i    (cpu_word_rdata),
    .word_ack_i      (cpu_word_ack),
    .word_restart_i  (cpu_word_restart),
    .word_rmw_lock_o (cpu_word_rmw_lock)
  );

  always_comb begin
    selected_cpu_req      = cpu_word_req;
    selected_cpu_we       = cpu_word_we;
    selected_cpu_addr     = cpu_word_addr;
    selected_cpu_wdata    = cpu_word_wdata;
    selected_cpu_rmw_lock = cpu_word_rmw_lock;

    if (cpu_request_is_io_q) begin
      selected_cpu_req      = cpu_request_active_q;
      selected_cpu_we       = cpu_request_io_we_q;
      selected_cpu_addr     = cpu_request_addr_q;
      selected_cpu_wdata    = req_wdata[LOCAL_WORD_WIDTH-1:0];
      selected_cpu_rmw_lock = 1'b0;
    end
  end

  assign cpu_field_rdata_o = cpu_request_is_io_q
      ? {{(DATA_WIDTH-LOCAL_WORD_WIDTH){1'b0}}, cpu_request_io_rdata_q}
      : sequenced_field_rdata;
  assign cpu_request_done = cpu_request_active_q
      && (cpu_request_is_io_q ? cpu_word_ack : sequenced_field_ack);
  assign cpu_field_ack_o = (cpu_field_capture && cpu_field_posts)
      || (cpu_request_done && !cpu_request_posted_q);

  tms34010_bus_arbiter u_arbiter (
    .clk               (clk),
    .rst               (rst),
    .hold_req_i        (hold_req_i),
    .hold_ack_o        (hold_ack_o),
    .screen_req_i      (screen_req_i),
    .screen_srfaddr_i  (screen_srfaddr_i),
    .screen_dpytap_i   (screen_dpytap_i),
    .screen_org_i      (screen_org_i),
    .screen_ack_o      (screen_ack_o),
    .dram_req_i        (dram_req_i),
    .dram_row_i        (dram_row_i),
    .dram_cbr_i        (dram_cbr_i),
    .dram_ack_o        (),
    .host_req_i        (host_req_i),
    .host_we_i         (host_we_i),
    .host_addr_i       (host_addr_i),
    .host_wdata_i      (host_wdata_i),
    .host_io_i         (host_is_io_i),
    .host_io_rdata_i   (host_io_rdata_i),
    .host_rdata_o      (host_rdata_o),
    .host_ack_o        (host_ack_o),
    .cpu_req_i         (selected_cpu_req),
    .cpu_we_i          (selected_cpu_we),
    .cpu_addr_i        (selected_cpu_addr),
    .cpu_wdata_i       (selected_cpu_wdata),
    .cpu_io_i          (cpu_request_is_io_q),
    .cpu_io_rdata_i    (cpu_request_io_rdata_q),
    .cpu_iaq_i         (cpu_request_iaq_q),
    .cpu_srt_i         (cpu_request_srt_q),
    .cpu_rmw_lock_i    (selected_cpu_rmw_lock),
    .cpu_rdata_o       (cpu_word_rdata),
    .cpu_ack_o         (cpu_word_ack),
    .cpu_restart_o     (cpu_word_restart),
    .cpu_cycle_o       (arb_cpu_cycle),
    .cycle_req_o       (arb_cycle_req),
    .cycle_kind_o      (cycle_kind_o),
    .cycle_addr_o      (cycle_addr_o),
    .cycle_wdata_o     (cycle_wdata_o),
    .cycle_io_rdata_o  (cycle_io_rdata_o),
    .cycle_iaq_o       (cycle_iaq_o),
    .cycle_srfaddr_o   (cycle_srfaddr_o),
    .cycle_dpytap_o    (cycle_dpytap_o),
    .cycle_screen_org_o(cycle_screen_org_o),
    .cycle_dram_row_o  (cycle_dram_row_o),
    .cycle_rdata_i     (timed_rdata),
    .cycle_ack_i       (timed_ack)
  );

  tms34010_bus_timer #(
    .ENABLE         (CYCLE_ACCURATE),
    .CLKS_PER_STATE (CLKS_PER_STATE)
  ) u_bus_timer (
    .clk         (clk),
    .rst         (rst),
    .req_i       (arb_cycle_req),
    .cpu_cycle_i (arb_cpu_cycle),
    .cpu_age_i   (cpu_age_q),
    .ack_o       (timed_ack),
    .rdata_o     (timed_rdata),
    .ext_req_o   (cycle_req_o),
    .ext_ack_i   (cycle_ack_i),
    .ext_rdata_i (cycle_rdata_i)
  );

endmodule : tms34010_memory_fabric

`default_nettype wire
