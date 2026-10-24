// -----------------------------------------------------------------------------
// tms34010_emu_bridge.sv
//
// Lossless core-to-8× bridge for the physical EMUA indication and the final
// shared HLDA/EMUA output mux.
//
// Each one-core-clock EMU execution sets a held request. The 8× domain
// acknowledges that request only after emitting one complete Q1/Q2 EMUA
// pulse, so an arbitrary clock phase cannot shorten or lose the indication.
// The separately registered emulator-halt level is sampled only at the
// Q4-to-Q1 boundary and therefore also remains stable for a complete Q1/Q2
// half-cycle. Q3/Q4 always select the local-bus HLDA component.
//
// The source event must be a one-clock pulse. A following architectural EMU
// instruction cannot execute until its opcode has traversed the same physical
// bus, which leaves enough time for this one-outstanding handshake to retire.
//
// Spec sources:
//   - 1988 TMS34010 User's Guide §2.5, Table 2-5, page 2-10.
//   - §11.4.11, page 11-20.
//   - EMU instruction, page 12-77.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_emu_bridge
  import tms34010_pkg::*;
(
  input  logic              src_clk_i,
  input  logic              src_rst_i,
  input  logic              src_event_i,
  input  logic              src_halt_i,

  input  logic              dst_clk_i,
  input  logic              dst_rst_i,
  input  local_subphase_t   dst_subphase_i,
  input  logic              dst_lclk1_i,
  input  logic              dst_hlda_n_i,

  output logic              hlda_emua_n_o
);

  // Source-registered signals are the only inputs to the CDC synchronizers.
  logic src_request_q;
  logic src_halt_q;
  logic src_ack_sync;

  logic dst_request_sync;
  logic dst_halt_sync;
  logic dst_ack_q;
  logic dst_pulse_wait_q;
  logic dst_pulse_active_q;
  logic dst_halt_phase_q;

  tms34010_sync_bit #(.RESET_VALUE(1'b0)) u_request_sync (
    .clk     (dst_clk_i),
    .rst     (dst_rst_i),
    .async_i (src_request_q),
    .sync_o  (dst_request_sync)
  );

  tms34010_sync_bit #(.RESET_VALUE(1'b0)) u_ack_sync (
    .clk     (src_clk_i),
    .rst     (src_rst_i),
    .async_i (dst_ack_q),
    .sync_o  (src_ack_sync)
  );

  tms34010_sync_bit #(.RESET_VALUE(1'b0)) u_halt_sync (
    .clk     (dst_clk_i),
    .rst     (dst_rst_i),
    .async_i (src_halt_q),
    .sync_o  (dst_halt_sync)
  );

  // A four-phase level handshake stretches the architectural execute pulse
  // until the destination has emitted the complete physical pulse.
  always_ff @(posedge src_clk_i) begin
    if (src_rst_i) begin
      src_request_q <= 1'b0;
      src_halt_q    <= 1'b0;
    end else begin
      src_halt_q <= src_halt_i;

      if (src_event_i)
        src_request_q <= 1'b1;
      else if (src_ack_sync)
        src_request_q <= 1'b0;
    end
  end

  // Destination sequencing starts EMUA only on the Q4B-to-Q1A edge and ends
  // it only on the Q2B-to-Q3A edge. The acknowledge rises on that ending edge
  // and remains registered until the source request has returned low.
  always_ff @(posedge dst_clk_i) begin
    if (dst_rst_i) begin
      dst_ack_q          <= 1'b0;
      dst_pulse_wait_q   <= 1'b0;
      dst_pulse_active_q <= 1'b0;
      dst_halt_phase_q   <= 1'b0;
    end else begin
      if (dst_subphase_i == LOCAL_PHASE_Q4B)
        dst_halt_phase_q <= dst_halt_sync;

      if (!dst_request_sync) begin
        dst_ack_q        <= 1'b0;
        dst_pulse_wait_q <= 1'b0;
      end else if (!dst_ack_q) begin
        if (dst_pulse_active_q) begin
          if (dst_subphase_i == LOCAL_PHASE_Q2B) begin
            dst_pulse_active_q <= 1'b0;
            dst_ack_q          <= 1'b1;
          end
        end else if (dst_pulse_wait_q) begin
          if (dst_subphase_i == LOCAL_PHASE_Q4B) begin
            dst_pulse_wait_q   <= 1'b0;
            dst_pulse_active_q <= 1'b1;
          end
        end else if (dst_subphase_i == LOCAL_PHASE_Q4B) begin
          dst_pulse_active_q <= 1'b1;
        end else begin
          dst_pulse_wait_q <= 1'b1;
        end
      end
    end
  end

  // LCLK1 high selects EMUA during Q1/Q2. LCLK1 low selects HLDA during
  // Q3/Q4. The two functions therefore cannot leak into one another's phase.
  assign hlda_emua_n_o =
      dst_lclk1_i
      ? !(dst_pulse_active_q || dst_halt_phase_q)
      : dst_hlda_n_i;

endmodule : tms34010_emu_bridge

`default_nettype wire
