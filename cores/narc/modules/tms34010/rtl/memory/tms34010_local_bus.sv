// -----------------------------------------------------------------------------
// tms34010_local_bus.sv
//
// Original-pin local-memory cycle phase engine.
//
// One TMS34010 local clock contains Q1..Q4. The documented bus controls often
// change midway through a quarter, and read data is sampled in the middle of
// Q4, so this block runs from a dedicated clock at eight times the local-clock
// rate. It emits LCLK1/LCLK2 plus the LAD and active-low memory controls.
//
// The command request and all payload inputs are synchronous to clk8x_i and
// must remain stable until cycle_ack_o. The integrated MCP bridge connects
// the core-clock fabric to this deliberately single-domain boundary.
//
// Implemented cycles:
//   - ordinary 16-bit word read and late write;
//   - screen-refresh VRAM memory-to-register transfer;
//   - program-controlled pixel memory-to-register/register-to-memory transfer;
//   - RAS-only and CAS-before-RAS DRAM refresh;
//   - on-chip I/O read and write external-pin cycles.
//
// LRDY is sampled at the end of Q1. Each low sample repeats the access period
// for one complete local clock. I/O cycles ignore LRDY. Following reset, eight
// zero-row RAS-only refresh cycles run before an external command can start.
// HOLD is sampled at the same end-Q1 LCLK2 edge. Once the core-side arbiter
// confirms quiescence, HLDA is asserted in Q3/Q4, LAD and the majority control
// outputs release at the following Q2, and DEN/DDOUT release at Q3. Bus
// reacquisition uses the symmetric one-quarter-staggered sequence.
//
// Spec sources:
//   - 1988 TMS34010 User's Guide §11.4, Figures 11-3 through 11-14,
//     pages 11-7 through 11-18 (cycle phases and LRDY).
//   - §11.4.11, Figures 11-15/11-16, pages 11-18 through 11-21
//     (HOLD sampling, early HLDA, high-impedance release/resume).
//   - §11.4.12, Figure 11-17, page 11-22 (eight reset RAS-only cycles).
//   - §11.5, Figure 11-18, pages 11-23/11-24 (address/status format).
//   - §11.5.3, Figure 11-19, pages 11-25 through 11-27 (refresh rows).
//   - §9.10.1.2, Figures 9-13/9-14, pages 9-20 through 9-23
//     (screen-refresh row/column generation).
//
// Reset is the project's synchronous active-high reset (A0003). It defines
// the phase origin and therefore holds LCLK1/LCLK2 at Q1 levels while active;
// the eight-cycle initialization begins immediately after release.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_local_bus
  import tms34010_pkg::*;
(
  input  logic                              clk8x_i,
  input  logic                              rst,

  input  logic                              cycle_req_i,
  input  local_cycle_kind_t                 cycle_kind_i,
  input  logic [ADDR_WIDTH-1:0]             cycle_addr_i,
  input  local_word_t                       cycle_wdata_i,
  input  logic                              cycle_iaq_i,
  input  logic [13:0]                       cycle_srfaddr_i,
  input  logic [15:0]                       cycle_dpytap_i,
  input  logic                              cycle_screen_org_i,
  input  logic [7:0]                        cycle_dram_row_i,
  input  local_word_t                       io_rdata_i,
  output local_word_t                       cycle_rdata_o,
  output logic                              cycle_ack_o,
  output logic                              cycle_busy_o,
  output logic                              init_done_o,

  input  logic                              hold_n_i,
  output logic                              hold_req_o,
  input  logic                              hold_grant_i,
  output logic                              hlda_n_o,

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
  output local_subphase_t                   subphase_o
);

  typedef enum logic [1:0] {
    BUS_RESET  = 2'd0,
    BUS_IDLE   = 2'd1,
    BUS_FIRST  = 2'd2,
    BUS_SECOND = 2'd3
  } local_bus_state_t;

  typedef enum logic [2:0] {
    HOLD_RUN             = 3'd0,
    HOLD_EARLY_ACK       = 3'd1,
    HOLD_RELEASE_MAJORITY= 3'd2,
    HOLD_BUS_RELEASED    = 3'd3,
    HOLD_RESUME_WAIT     = 3'd4,
    HOLD_RESUME_MAJORITY = 3'd5
  } local_hold_state_t;

  local_bus_state_t state_q, state_d;
  local_subphase_t  phase_q;
  local_hold_state_t hold_state_q, hold_state_d;

  // Justification (a): a selected command must survive for both local-clock
  // periods and any LRDY extensions after the producer presents it.
  local_cycle_kind_t             kind_q;
  logic [ADDR_WIDTH-1:0]         addr_q;
  local_word_t                   wdata_q;
  logic                          iaq_q;
  logic [13:0]                   srfaddr_q;
  logic [15:0]                   dpytap_q;
  logic                          screen_org_q;
  logic [7:0]                    dram_row_q;

  // Justification (a): initialization state persists across the specified
  // eight two-period cycles. Four bits represent remaining values 0..8.
  logic [3:0]                    init_remaining_q;
  logic                          init_done_q;

  // Justification (a): ready/extension history controls whether the second
  // local-clock period completes or repeats without prematurely releasing
  // active-low strobes.
  logic                          ready_q;
  logic                          extended_q;
  logic                          second_repeat_q;

  // Justification (a): read data sampled at mid-Q4 is retained through the
  // end-Q4 acknowledgement interval.
  local_word_t                   read_data_q;

  local_cycle_kind_t             active_kind;
  logic [ADDR_WIDTH-1:0]         active_addr;
  local_word_t                   active_wdata;
  logic                          active_iaq;
  logic [13:0]                   active_srfaddr;
  logic [15:0]                   active_dpytap;
  logic                          active_screen_org;
  logic [7:0]                    active_dram_row;
  local_word_t                   row_value;
  local_word_t                   column_value;
  logic [13:0]                   screen_address;
  logic                          bus_active;
  logic                          cycle_complete;
  logic                          active_is_io;
  logic                          release_strobes;
  logic                          hold_req_q;
  logic                          hold_majority_drive;
  logic                          hold_slow_drive;

  function automatic local_word_t word_row_address(
    input logic [ADDR_WIDTH-1:0] address
  );
    return {1'b1, address[26:12]};
  endfunction

  function automatic local_word_t word_column_address(
    input logic [ADDR_WIDTH-1:0] address,
    input logic                  iaq
  );
    return {iaq, 1'b1, address[29:27], address[14:4]};
  endfunction

  function automatic local_word_t refresh_row_address(
    input logic [7:0] row
  );
    return {1'b0, row[6:0], row};
  endfunction

  function automatic local_word_t screen_row_address(
    input logic [13:0] address
  );
    return {1'b1, 3'b000, address[13:2]};
  endfunction

  function automatic local_word_t screen_column_address(
    input logic [13:0] address,
    input logic [15:0] tap
  );
    return {
      2'b00,
      tap[13:12],
      tap[11:6] | address[5:0],
      tap[5:0]
    };
  endfunction

  assign subphase_o = phase_q;
  assign lclk1_o = (phase_q <= LOCAL_PHASE_Q2B);
  assign lclk2_o = (phase_q >= LOCAL_PHASE_Q2A)
                && (phase_q <= LOCAL_PHASE_Q3B);

  always_ff @(posedge clk8x_i) begin
    if (rst) phase_q <= LOCAL_PHASE_Q1A;
    else     phase_q <= local_subphase_t'(phase_q + 3'd1);
  end

  // HOLD is synchronous to LCLK2 and is sampled on its rising edge at the end
  // of Q1 (the Q1B-to-Q2A 8× edge). The sampled active-high level alone
  // crosses to the core arbiter.
  always_ff @(posedge clk8x_i) begin
    if (rst) begin
      hold_req_q <= 1'b0;
    end else if (phase_q == LOCAL_PHASE_Q1B) begin
      hold_req_q <= !hold_n_i;
    end
  end

  assign hold_req_o = hold_req_q;

  // Physical release/reacquisition timing from Figures 11-15/11-16. The
  // core grant is considered only on an end-Q1 sample after reset
  // initialization and any active local cycle have retired.
  always_comb begin
    hold_state_d = hold_state_q;

    unique case (hold_state_q)
      HOLD_RUN: begin
        if ((phase_q == LOCAL_PHASE_Q1B)
            && !hold_n_i
            && hold_grant_i
            && init_done_q
            && (state_q == BUS_IDLE))
          hold_state_d = HOLD_EARLY_ACK;
      end

      HOLD_EARLY_ACK: begin
        if (phase_q == LOCAL_PHASE_Q1B)
          hold_state_d = hold_n_i
                       ? HOLD_RUN
                       : HOLD_RELEASE_MAJORITY;
      end

      HOLD_RELEASE_MAJORITY: begin
        if (phase_q == LOCAL_PHASE_Q2B)
          hold_state_d = HOLD_BUS_RELEASED;
      end

      HOLD_BUS_RELEASED: begin
        if ((phase_q == LOCAL_PHASE_Q1B) && hold_n_i)
          hold_state_d = HOLD_RESUME_WAIT;
      end

      HOLD_RESUME_WAIT: begin
        if (phase_q == LOCAL_PHASE_Q1B)
          hold_state_d = hold_n_i
                       ? HOLD_RESUME_MAJORITY
                       : HOLD_BUS_RELEASED;
      end

      HOLD_RESUME_MAJORITY: begin
        if (phase_q == LOCAL_PHASE_Q2B)
          hold_state_d = HOLD_RUN;
      end

      default: hold_state_d = HOLD_RUN;
    endcase
  end

  always_ff @(posedge clk8x_i) begin
    if (rst) hold_state_q <= HOLD_RUN;
    else     hold_state_q <= hold_state_d;
  end

  always_comb begin
    hold_majority_drive = 1'b0;
    hold_slow_drive     = 1'b0;

    unique case (hold_state_q)
      HOLD_RUN,
      HOLD_EARLY_ACK: begin
        hold_majority_drive = 1'b1;
        hold_slow_drive     = 1'b1;
      end

      HOLD_RELEASE_MAJORITY: begin
        hold_slow_drive = 1'b1;
      end

      HOLD_RESUME_MAJORITY: begin
        hold_majority_drive = 1'b1;
      end

      HOLD_BUS_RELEASED,
      HOLD_RESUME_WAIT: ;
      default: ;
    endcase
  end

  // HLDA occupies only the shared pin's Q3/Q4 half. EMUA multiplexing in
  // Q1/Q2 remains at the pin wrapper boundary.
  assign hlda_n_o =
      lclk1_o
      || !((hold_state_q == HOLD_EARLY_ACK)
           || (hold_state_q == HOLD_RELEASE_MAJORITY)
           || (hold_state_q == HOLD_BUS_RELEASED));

  always_comb begin
    state_d = state_q;

    unique case (state_q)
      BUS_RESET: state_d = BUS_FIRST;

      BUS_IDLE: begin
        if ((phase_q == LOCAL_PHASE_Q4B)
            && cycle_req_i
            && (hold_state_q == HOLD_RUN))
          state_d = BUS_FIRST;
      end

      BUS_FIRST: begin
        if (phase_q == LOCAL_PHASE_Q4B)
          state_d = BUS_SECOND;
      end

      BUS_SECOND: begin
        if ((phase_q == LOCAL_PHASE_Q4B) && ready_q) begin
          if (!init_done_q && (init_remaining_q != 4'd1))
            state_d = BUS_FIRST;
          else
            state_d = BUS_IDLE;
        end
      end

      default: state_d = BUS_RESET;
    endcase
  end

  always_ff @(posedge clk8x_i) begin
    if (rst) state_q <= BUS_RESET;
    else     state_q <= state_d;
  end

  // Capture a command only on the idle-to-first-period boundary.
  always_ff @(posedge clk8x_i) begin
    if (rst) begin
      kind_q        <= LOCAL_CYCLE_WORD_READ;
      addr_q        <= '0;
      wdata_q       <= '0;
      iaq_q         <= 1'b0;
      srfaddr_q     <= '0;
      dpytap_q      <= '0;
      screen_org_q  <= 1'b0;
      dram_row_q    <= '0;
    end else if ((state_q == BUS_IDLE)
                 && (phase_q == LOCAL_PHASE_Q4B)
                 && cycle_req_i) begin
      kind_q        <= cycle_kind_i;
      addr_q        <= cycle_addr_i;
      wdata_q       <= cycle_wdata_i;
      iaq_q         <= cycle_iaq_i;
      srfaddr_q     <= cycle_srfaddr_i;
      dpytap_q      <= cycle_dpytap_i;
      screen_org_q  <= cycle_screen_org_i;
      dram_row_q    <= cycle_dram_row_i;
    end
  end

  assign cycle_complete =
      (state_q == BUS_SECOND)
      && (phase_q == LOCAL_PHASE_Q4B)
      && ready_q;

  always_ff @(posedge clk8x_i) begin
    if (rst) begin
      init_remaining_q <= 4'd8;
      init_done_q      <= 1'b0;
    end else if (!init_done_q && cycle_complete) begin
      init_remaining_q <= init_remaining_q - 4'd1;
      if (init_remaining_q == 4'd1)
        init_done_q <= 1'b1;
    end
  end

  assign init_done_o = init_done_q;

  always_comb begin
    active_kind       = kind_q;
    active_addr       = addr_q;
    active_wdata      = wdata_q;
    active_iaq        = iaq_q;
    active_srfaddr    = srfaddr_q;
    active_dpytap     = dpytap_q;
    active_screen_org = screen_org_q;
    active_dram_row   = dram_row_q;

    if (!init_done_q) begin
      active_kind       = LOCAL_CYCLE_DRAM_RAS;
      active_addr       = '0;
      active_wdata      = '0;
      active_iaq        = 1'b0;
      active_srfaddr    = '0;
      active_dpytap     = '0;
      active_screen_org = 1'b0;
      active_dram_row   = '0;
    end
  end

  assign active_is_io =
      (active_kind == LOCAL_CYCLE_IO_READ)
      || (active_kind == LOCAL_CYCLE_IO_WRITE);

  // LRDY is sampled at the end of Q1. I/O cycles complete in exactly two
  // local clocks and therefore force the sampled-ready value high.
  always_ff @(posedge clk8x_i) begin
    if (rst) begin
      ready_q          <= 1'b0;
      extended_q       <= 1'b0;
      second_repeat_q  <= 1'b0;
    end else if ((state_q == BUS_FIRST)
                 && (phase_q == LOCAL_PHASE_Q4B)) begin
      ready_q          <= 1'b0;
      extended_q       <= 1'b0;
      second_repeat_q  <= 1'b0;
    end else if ((state_q == BUS_SECOND)
                 && (phase_q == LOCAL_PHASE_Q1B)) begin
      if (active_is_io) begin
        ready_q <= 1'b1;
      end else begin
        ready_q <= lrdy_i;
        if (!lrdy_i) extended_q <= 1'b1;
      end
    end else if ((state_q == BUS_SECOND)
                 && (phase_q == LOCAL_PHASE_Q4B)
                 && !ready_q) begin
      second_repeat_q <= 1'b1;
    end else if (cycle_complete) begin
      ready_q          <= 1'b0;
      extended_q       <= 1'b0;
      second_repeat_q  <= 1'b0;
    end
  end

  // Mid-Q4 sampling occurs on the Q4A-to-Q4B edge. I/O read data is supplied
  // by the on-chip register owner; ordinary memory data comes from LAD.
  always_ff @(posedge clk8x_i) begin
    if (rst) begin
      read_data_q <= '0;
    end else if ((state_q == BUS_SECOND)
                 && (phase_q == LOCAL_PHASE_Q4A)
                 && ready_q) begin
      if (active_kind == LOCAL_CYCLE_WORD_READ)
        read_data_q <= lad_i;
      else if (active_kind == LOCAL_CYCLE_IO_READ)
        read_data_q <= io_rdata_i;
      else if (active_kind == LOCAL_CYCLE_PIXEL_MTR)
        // A VRAM memory-to-register cycle returns no LAD data to the CPU.
        // Retain deterministic zero for the architecturally unspecified
        // destination value of an explicit SRT pixel read.
        read_data_q <= '0;
    end
  end

  assign cycle_rdata_o = read_data_q;
  assign cycle_ack_o = init_done_q && cycle_complete;
  assign bus_active = (state_q == BUS_FIRST) || (state_q == BUS_SECOND);
  assign cycle_busy_o = !init_done_q
                      || (state_q != BUS_IDLE)
                      || cycle_req_i
                      || hold_req_q
                      || (hold_state_q != HOLD_RUN);
  assign release_strobes =
      (state_q == BUS_SECOND)
      && (phase_q == LOCAL_PHASE_Q4B)
      && ready_q;

  assign ras_oe_o   = hold_majority_drive;
  assign lal_oe_o   = hold_majority_drive;
  assign cas_oe_o   = hold_majority_drive;
  assign we_oe_o    = hold_majority_drive;
  assign tr_qe_oe_o = hold_majority_drive;
  assign den_oe_o   = hold_slow_drive;
  assign ddout_oe_o = hold_slow_drive;

  always_comb begin
    screen_address = active_screen_org
                   ? active_srfaddr
                   : ~active_srfaddr;
    row_value      = word_row_address(active_addr);
    column_value   = word_column_address(active_addr, active_iaq);

    unique case (active_kind)
      LOCAL_CYCLE_SCREEN_REFRESH: begin
        row_value    = screen_row_address(screen_address);
        column_value = screen_column_address(
            screen_address, active_dpytap);
      end

      LOCAL_CYCLE_DRAM_RAS,
      LOCAL_CYCLE_DRAM_CBR: begin
        row_value    = refresh_row_address(active_dram_row);
        column_value = refresh_row_address(active_dram_row);
      end

      LOCAL_CYCLE_IO_READ,
      LOCAL_CYCLE_IO_WRITE: begin
        // Address bits are zero; the inactive RF/TR/IAQ status bits retain
        // their specified row/column values.
        row_value    = 16'h8000;
        column_value = 16'h4000;
      end

      LOCAL_CYCLE_PIXEL_MTR,
      LOCAL_CYCLE_PIXEL_RTM: begin
        // Explicit pixel SRT cycles retain the ordinary unaltered address.
        // TR status is active low and IAQ is inactive during column time.
        column_value = word_column_address(active_addr, 1'b0);
        column_value[14] = 1'b0;
      end

      LOCAL_CYCLE_WORD_READ,
      LOCAL_CYCLE_WORD_WRITE: ;
      default: ;
    endcase
  end

  // LAD multiplexing. Values documented as undefined are driven as zero; the
  // output enable remains asserted for non-read active phases so no X value
  // enters synthesizable RTL.
  always_comb begin
    lad_o    = '0;
    lad_oe_o = 1'b0;

    if (bus_active) begin
      if (state_q == BUS_FIRST) begin
        lad_oe_o = 1'b1;
        if (active_kind == LOCAL_CYCLE_DRAM_CBR) begin
          if (phase_q >= LOCAL_PHASE_Q2A)
            lad_o = row_value;
        end else if ((phase_q >= LOCAL_PHASE_Q2A)
                     && (phase_q <= LOCAL_PHASE_Q3B)) begin
          lad_o = row_value;
        end else if (phase_q >= LOCAL_PHASE_Q4A) begin
          lad_o = column_value;
        end
      end else begin
        unique case (active_kind)
          LOCAL_CYCLE_WORD_WRITE,
          LOCAL_CYCLE_IO_WRITE: begin
            lad_o    = active_wdata;
            lad_oe_o = 1'b1;
          end

          LOCAL_CYCLE_WORD_READ,
          LOCAL_CYCLE_IO_READ: begin
            lad_o    = '0;
            lad_oe_o = 1'b0;
          end

          LOCAL_CYCLE_SCREEN_REFRESH,
          LOCAL_CYCLE_PIXEL_MTR,
          LOCAL_CYCLE_PIXEL_RTM,
          LOCAL_CYCLE_DRAM_RAS,
          LOCAL_CYCLE_DRAM_CBR: begin
            lad_o    = '0;
            lad_oe_o = 1'b1;
          end

          default: ;
        endcase
      end
    end

    if (!hold_majority_drive)
      lad_oe_o = 1'b0;
  end

  // Active-low pin decode. Defaults are the inactive-high internal-cycle
  // levels. Each arm mirrors the corresponding Chapter 11 timing diagram.
  always_comb begin
    ras_n_o   = 1'b1;
    lal_n_o   = 1'b1;
    cas_n_o   = 1'b1;
    we_n_o    = 1'b1;
    tr_qe_n_o = 1'b1;
    den_n_o   = 1'b1;
    ddout_o   = 1'b1;

    if (bus_active) begin
      unique case (active_kind)
        LOCAL_CYCLE_DRAM_CBR: begin
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q2A))
            cas_n_o = 1'b0;
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q3A))
            lal_n_o = 1'b0;
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q4A))
            ras_n_o = 1'b0;

          if (state_q == BUS_SECOND) begin
            lal_n_o = 1'b0;
            if (!release_strobes) begin
              ras_n_o = 1'b0;
              cas_n_o = 1'b0;
            end
          end
        end

        LOCAL_CYCLE_DRAM_RAS: begin
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q3B))
            ras_n_o = 1'b0;
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q4B))
            lal_n_o = 1'b0;
          if (state_q == BUS_SECOND) begin
            lal_n_o = 1'b0;
            if (!release_strobes)
              ras_n_o = 1'b0;
          end
        end

        LOCAL_CYCLE_IO_READ,
        LOCAL_CYCLE_IO_WRITE: begin
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q3B))
            ras_n_o = 1'b0;
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q4B))
            lal_n_o = 1'b0;
          if (state_q == BUS_SECOND) begin
            lal_n_o = 1'b0;
            if (!release_strobes)
              ras_n_o = 1'b0;
          end
        end

        LOCAL_CYCLE_SCREEN_REFRESH,
        LOCAL_CYCLE_PIXEL_MTR,
        LOCAL_CYCLE_PIXEL_RTM: begin
          // VRAM transfer cycles begin with the external data path in input
          // direction, then release it before the row strobe. No LAD data is
          // transferred during the second period.
          if ((state_q == BUS_FIRST)
              && (phase_q < LOCAL_PHASE_Q2A)) begin
            den_n_o = 1'b0;
            ddout_o = 1'b0;
          end
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q3B))
            ras_n_o = 1'b0;
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q4B))
            lal_n_o = 1'b0;
          if (state_q == BUS_SECOND) begin
            lal_n_o = 1'b0;
            if (!release_strobes) begin
              ras_n_o = 1'b0;
              cas_n_o = 1'b0;
            end
          end
          if ((state_q == BUS_SECOND)
              && !extended_q
              && (phase_q < LOCAL_PHASE_Q1B))
            cas_n_o = 1'b1;
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q2A))
            tr_qe_n_o = 1'b0;
          if ((state_q == BUS_SECOND)
              && !second_repeat_q
              && (phase_q <= LOCAL_PHASE_Q2B))
            tr_qe_n_o = 1'b0;
          // Register-to-memory is distinguished from memory-to-register by
          // W being low at the RAS fall. It rises again before column time.
          if ((active_kind == LOCAL_CYCLE_PIXEL_RTM)
              && (state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q2A)
              && (phase_q <= LOCAL_PHASE_Q3B))
            we_n_o = 1'b0;
        end

        LOCAL_CYCLE_WORD_READ: begin
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q3B))
            ras_n_o = 1'b0;
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q4B))
            lal_n_o = 1'b0;
          if (state_q == BUS_SECOND) begin
            lal_n_o = 1'b0;
            if (!release_strobes)
              ras_n_o = 1'b0;
            if ((extended_q || (phase_q >= LOCAL_PHASE_Q1B))
                && !release_strobes)
              cas_n_o = 1'b0;
            if ((extended_q || (phase_q >= LOCAL_PHASE_Q2A))
                && !release_strobes) begin
              tr_qe_n_o = 1'b0;
              den_n_o   = 1'b0;
            end
            if (extended_q || (phase_q >= LOCAL_PHASE_Q1B))
              ddout_o = 1'b0;
          end
        end

        LOCAL_CYCLE_WORD_WRITE: begin
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q3B))
            ras_n_o = 1'b0;
          if ((state_q == BUS_FIRST)
              && (phase_q >= LOCAL_PHASE_Q4B))
            lal_n_o = 1'b0;
          if (state_q == BUS_SECOND) begin
            lal_n_o = 1'b0;
            den_n_o = 1'b0;
            if (!release_strobes)
              ras_n_o = 1'b0;
            if ((extended_q || (phase_q >= LOCAL_PHASE_Q1B))
                && !release_strobes)
              cas_n_o = 1'b0;
            if ((extended_q || (phase_q >= LOCAL_PHASE_Q2B))
                && !release_strobes)
              we_n_o = 1'b0;
          end
        end

        default: ;
      endcase
    end
  end

endmodule : tms34010_local_bus

`default_nettype wire
