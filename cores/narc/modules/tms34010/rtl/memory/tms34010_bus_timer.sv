// -----------------------------------------------------------------------------
// tms34010_bus_timer.sv
//
// Local memory cycle length, between the arbiter and the external cycle bus.
//
// 1988 UG 5.4.7 and the Section 13 tables: a local memory cycle with no wait
// states takes two machine states. With ENABLE=1 every cycle the arbiter
// issues occupies the bus for 2*CLKS_PER_STATE core clocks. The external
// acknowledge acts as the ready input:
// one that arrives early is held until the cycle's two states are up, one
// that arrives late extends the cycle by whole states (LRDY, pin description
// and 11.4.10: ready is sampled once per state and each wait state is one
// local clock).
//
// The bus is a timeline of whole states. A cycle the CPU asked for is timed
// from the start of the state in which the core raised it (cpu_age_i clocks
// ago), or from when the bus went idle if that is later: on the chip the
// cycle starts at that state boundary, and the few clocks this design's
// decode and fabric registers take are kept inside the cycle's two states
// (docs/cycle_accuracy.md). The same rule absorbs the arbiter's bubble
// between consecutive words of one field. Other clients' cycles are timed
// from when they are presented. The acknowledge is given in the last clock
// of the cycle's last state.
//
// With ENABLE=0 the module is a wire.
//
// Clock domain: core clock. Reset is synchronous active-high (A0003).
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_bus_timer
  import tms34010_pkg::*;
#(
  parameter bit          ENABLE         = 1'b0,
  parameter int unsigned CLKS_PER_STATE = 1
)(
  input  logic        clk,
  input  logic        rst,

  input  logic        req_i,
  input  logic        cpu_cycle_i,   // req_i is a CPU cycle
  input  logic [7:0]  cpu_age_i,     // clocks since the CPU request's state began
  output logic        ack_o,
  output local_word_t rdata_o,

  output logic        ext_req_o,
  input  logic        ext_ack_i,
  input  local_word_t ext_rdata_i
);

  generate
    if (ENABLE) begin : g_timed
      localparam int unsigned CYCLE_CLKS = 2 * CLKS_PER_STATE;
      localparam int unsigned CW = $clog2(CYCLE_CLKS + 1);

      // Justification (a): clocks until the bus is free on the timeline,
      // clocks it has been idle, the current cycle's ownership and the held
      // external response.
      logic [CW-1:0] bus_cnt_q;
      logic [CW-1:0] idle_q;
      logic          active_q;
      logic          ext_done_q;
      local_word_t   rdata_q;

      logic          start;
      logic          ready;
      logic          last;
      logic [7:0]    claim;
      logic [CW-1:0] credit;

      assign start     = req_i && !active_q && (bus_cnt_q == '0);
      assign ext_req_o = req_i && (start || (active_q && !ext_done_q));
      assign ready     = ext_done_q || (ext_req_o && ext_ack_i);
      assign last      = active_q && (bus_cnt_q <= CW'(1));
      assign ack_o     = last && ready;
      assign rdata_o   = ext_done_q ? rdata_q : ext_rdata_i;

      always_comb begin
        claim = 8'd0;
        if (cpu_cycle_i)
          claim = ({{(8-CW){1'b0}}, idle_q} < cpu_age_i)
                ? {{(8-CW){1'b0}}, idle_q} : cpu_age_i;
        if (claim > 8'(CYCLE_CLKS - 1))
          claim = 8'(CYCLE_CLKS - 1);
        credit = CW'(claim);
      end

      always_ff @(posedge clk) begin
        if (rst) begin
          bus_cnt_q  <= '0;
          idle_q     <= '0;
          active_q   <= 1'b0;
          ext_done_q <= 1'b0;
          rdata_q    <= '0;
        end else begin
          if (start)
            bus_cnt_q <= CW'(CYCLE_CLKS - 1) - credit;
          else if (last && !ready)
            bus_cnt_q <= CW'(CLKS_PER_STATE);   // one wait state
          else if (bus_cnt_q != '0)
            bus_cnt_q <= bus_cnt_q - 1'b1;

          if (start || (bus_cnt_q != '0))
            idle_q <= '0;
          else if (idle_q != CW'(CYCLE_CLKS))
            idle_q <= idle_q + 1'b1;

          if (start)
            active_q <= 1'b1;
          else if (ack_o)
            active_q <= 1'b0;

          if (ack_o) begin
            ext_done_q <= 1'b0;
          end else if (ext_req_o && ext_ack_i) begin
            ext_done_q <= 1'b1;
            rdata_q    <= ext_rdata_i;
          end
        end
      end
    end else begin : g_wire
      assign ext_req_o = req_i;
      assign ack_o     = ext_ack_i;
      assign rdata_o   = ext_rdata_i;
    end
  endgenerate

endmodule : tms34010_bus_timer

`default_nettype wire
